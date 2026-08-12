#!/usr/bin/env python3
"""End-to-end smoke test against a RUNNING backend.

Every bug found during the first real end-to-end run of this stack was
invisible to the existing checks, and each one would have been caught here:

  * `POST /transactions` never wrote `expected_value_inr`, so "rewards earned"
    was structurally zero for every user while every endpoint returned 200.
  * `GET /catalogue` returned an empty list on a fresh stack, so the app's core
    question — "which card should I use" — had nothing to rank.
  * `setup_app_role.sql` was fatal on its first run, so `docker compose up`
    failed outright on a clean machine.
  * `db-migrate` was not re-runnable, so `docker compose up` worked exactly
    once per volume.

Unit tests could not have caught any of them: they are integration failures
between services, between the two databases, or between the schema and the
data. Status codes alone would not have caught the first one either, which is
why this asserts on VALUES, not just on 2xx.

Usage:
    python3 scripts/smoke_test.py [--api URL] [--auth URL]

Exits non-zero on the first failure so CI fails loudly.
"""

import argparse
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

FAILURES = []


def call(base, method, path, body=None, token=None, timeout=25):
    req = urllib.request.Request(base + path, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, (json.loads(raw) if raw else {})
        except json.JSONDecodeError:
            return e.code, {}
    except Exception as e:  # connection refused, timeout, DNS
        return 0, {"error": str(e)}


def check(label, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"  [{status}] {label}" + (f"  — {detail}" if detail and not condition else ""))
    if not condition:
        FAILURES.append(label)
    return condition


def latest_dev_otp():
    """Reads the OTP from the auth service's dev-only log line.

    Only ever works when ALLOW_TEST_OTP is on and NODE_ENV is not production —
    the service refuses to log it otherwise, which is the correct behaviour and
    the reason this script cannot be pointed at a real environment.
    """
    out = subprocess.run(
        ["docker", "compose", "logs", "auth", "--tail", "60"],
        capture_output=True, text=True,
    ).stdout
    codes = re.findall(r"code: '(\d+)'", out)
    return codes[-1] if codes else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--api", default="http://localhost:4000")
    ap.add_argument("--auth", default="http://localhost:3210")
    args = ap.parse_args()
    API, AUTH = args.api, args.auth

    print("=== services reachable ===")
    code, _ = call(API, "GET", "/health")
    if not check("api /health", code == 200, f"got {code}"):
        print("\napi/ is not reachable — is the stack running?")
        return 1
    code, _ = call(AUTH, "GET", "/health")
    check("auth /health", code == 200, f"got {code}")

    print("=== catalogue is populated ===")
    code, cat = call(API, "GET", "/catalogue")
    cards = cat.get("cards", [])
    # An empty catalogue means the app cannot answer its core question. This is
    # a real failure, not an acceptable empty state.
    check("GET /catalogue returns published cards", len(cards) > 0, f"{len(cards)} cards")
    if not cards:
        return 1
    check("cards carry reward rules",
          any(c.get("reward_rules") for c in cards))
    check("has_apply_url exposed (migration 0030)",
          all("has_apply_url" in c for c in cards))

    print("=== OTP sign-in ===")
    phone = f"+9190000{int(time.time()) % 100000:05d}"
    code, _ = call(AUTH, "POST", "/auth/request-otp", {"phone_number": phone})
    check("POST /auth/request-otp", code == 200, f"got {code}")
    time.sleep(2)
    otp = latest_dev_otp()
    if not check("dev OTP available in the log", bool(otp),
                 "needs ALLOW_TEST_OTP=true and a non-production NODE_ENV"):
        return 1
    code, tok = call(AUTH, "POST", "/auth/verify-otp",
                     {"phone_number": phone, "code": otp, "device_id": "smoke-test"})
    if not check("POST /auth/verify-otp returns tokens", "access_token" in tok, str(tok)[:90]):
        return 1
    token = tok["access_token"]

    print("=== cross-service JWT (auth mints, api verifies) ===")
    code, _ = call(API, "GET", "/profile", token=token)
    check("api accepts an auth-issued token", code == 200, f"got {code}")
    check("api rejects an absent token", call(API, "GET", "/user-cards")[0] == 401)

    print("=== profile bridge (auth DB -> product DB) ===")
    code, prof = call(API, "POST", "/profile",
                      {"displayName": "Smoke Test", "phoneNumber": phone}, token=token)
    check("POST /profile creates the product profile", code == 201, f"got {code}")
    check("profile id matches the auth user id",
          prof.get("profile", {}).get("id") == tok["user"]["id"])

    print("=== the money path: a spend must actually earn ===")
    target = None
    for c in cards:
        for rule in (c.get("reward_rules") or []):
            if rule.get("category_id") and rule.get("unit") == "cashback_percent":
                target = (c, rule)
                break
        if target:
            break
    if not check("a cashback rule exists to test against", target is not None):
        return 1
    card, rule = target

    code, j = call(API, "POST", "/user-cards",
                   {"cardProductId": card["id"], "nickname": "Smoke"}, token=token)
    check("POST /user-cards", code == 201, f"got {code}")
    uc = j.get("userCard", {}).get("id")

    _, before = call(API, "GET", "/home-summary", token=token)
    code, _ = call(API, "POST", "/transactions",
                   {"userCardId": uc, "amountInr": 2000, "categoryId": rule["category_id"],
                    "merchantName": "Smoke Merchant", "occurredAt": "2026-08-12T12:00:00Z"},
                   token=token)
    check("POST /transactions", code == 201, f"got {code}")
    _, after = call(API, "GET", "/home-summary", token=token)

    expected = 2000 * float(rule["rate"]) / 100
    delta = (float(after["homeSummary"]["rewardsThisMonthInr"])
             - float(before["homeSummary"]["rewardsThisMonthInr"]))
    # THE assertion this file exists for. Everything above returned 200 while
    # this was silently broken.
    check(f"a Rs.2000 spend at {rule['rate']}% earns Rs.{expected:.0f}",
          abs(delta - expected) < 0.01, f"home-summary moved by Rs.{delta:.2f}")

    print("=== features from the plan ===")
    code, _ = call(API, "PUT", "/user-settings",
                   {"settings": {"appearance_theme_mode_v1": "dark"}}, token=token)
    check("1.1 PUT /user-settings", code == 200, f"got {code}")
    _, s = call(API, "GET", "/user-settings", token=token)
    check("1.1 settings round-trip", s.get("settings", {}).get("appearance_theme_mode_v1") == "dark")

    code, imp = call(API, "POST", "/user-cards/import",
                     {"cards": [{"localId": "l1", "cardProductId": cards[1]["id"]}]}, token=token)
    check("1.2 guest import", code == 201, f"got {code}")
    _, again = call(API, "POST", "/user-cards/import",
                    {"cards": [{"localId": "l1", "cardProductId": cards[1]["id"]}]}, token=token)
    check("1.2 import is idempotent",
          [r["status"] for r in again.get("results", [])] == ["already_present"])

    code, _ = call(API, "POST", "/acceptance-reports",
                   {"vpa": "smoke@okaxis", "network": "visa", "rail": "upi_qr",
                    "result": "declined"}, token=token)
    check("2.1 acceptance report refused without opt-in", code == 403, f"got {code}")
    call(API, "POST", "/profile/contributions-opt-in", {"optIn": True}, token=token)
    code, _ = call(API, "POST", "/acceptance-reports",
                   {"vpa": "smoke@okaxis", "network": "visa", "rail": "upi_qr",
                    "result": "declined", "gridLat": 12.9712, "gridLng": 77.5946}, token=token)
    check("2.1 acceptance report accepted after opt-in", code == 201, f"got {code}")

    code, _ = call(API, "POST", "/analytics/events",
                   {"events": [{"event": "app_opened", "props": {"source": "smoke"}}]}, token=token)
    check("2.2 analytics accepted", code == 202, f"got {code}")

    code, dev = call(API, "POST", "/sync/register-device",
                     {"platform": "android", "label": "Smoke"}, token=token)
    check("4 sync device registered", code == 201, f"got {code}")
    device_id = dev.get("deviceId")
    _, txns = call(API, "GET", "/transactions", token=token)
    txn_id = txns["transactions"][0]["id"]
    code, push = call(API, "POST", "/sync/push",
                      {"deviceId": device_id, "changes": [{
                          "entity": "transactions", "entityId": txn_id, "op": "update",
                          "payload": {"merchant_name": "Synced Name"},
                          "fieldClocks": {"merchant_name": 9999999999999},
                          "clientSeq": 1}]}, token=token)
    check("4 sync push applied", push.get("appliedCount") == 1, str(push)[:90])
    _, txns = call(API, "GET", "/transactions", token=token)
    check("4 sync push changed the row",
          any(t.get("merchant_name") == "Synced Name" for t in txns["transactions"]))
    _, pull = call(API, "GET", f"/sync/pull?deviceId={device_id}&since=0", token=token)
    check("4 pull excludes the pushing device's own changes",
          len(pull.get("changes", [])) == 0, f"{len(pull.get('changes', []))} echoed back")

    print()
    if FAILURES:
        print(f"FAILED — {len(FAILURES)} check(s): " + "; ".join(FAILURES))
        return 1
    print("All smoke checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
