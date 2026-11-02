"""Group extracted SMS into templates and families, join parser outcomes, write a redacted report.

Usage: python3 -I analyze.py <messages.jsonl> <outdir> [server_out.jsonl] [device_out.jsonl]
Writes <outdir>/templates.json (local, has sample ids) and <outdir>/report.md (redacted skeletons + counts only).
"""
import collections
import hashlib
import json
import re
import sys

def brand(sender):
    s = sender.upper().strip()
    s = re.sub(r"^[A-Z]{2}-", "", s)
    s = re.sub(r"-[STPG]$", "", s)
    return s

SUBS = [
    (re.compile(r"https?://\S+|\b(?:www\.)?[a-z0-9-]+\.(?:com|in|co|io|ly|me)(?:/\S*)?", re.I), "<URL>"),
    (re.compile(r"[\w.\-]+@[\w.\-]+"), "<VPA>"),
    (re.compile(r"(?:rs\.?|inr|₹)\s*[\d,]+(?:\.\d+)?", re.I), "<AMT>"),
    (re.compile(r"\b\d{1,3}(?:,\d{2,3})+(?:\.\d{1,2})?\b|\b\d+\.\d{2}\b"), "<AMT>"),
    (re.compile(r"\b(?:[xX*]{1,12}|\.{2,})\d{2,6}\b"), "<MASK>"),
    (re.compile(r"\b\d{4}-\d{2}-\d{2}(?::\d{2}:\d{2}:\d{2})?\b"), "<DATE>"),
    (re.compile(r"\b\d{1,2}[-/ .](?:\d{1,2}|[A-Za-z]{3,9})[-/ .,]\s?\d{2,4}\b"), "<DATE>"),
    (re.compile(r"\b\d{1,2}(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\d{2,4}\b", re.I), "<DATE>"),
    (re.compile(r"\b\d{1,2}:\d{2}(?::\d{2})?(?:\s?[AP]M)?\b", re.I), "<TIME>"),
    (re.compile(r"\b\d{6,}\b"), "<REF>"),
    (re.compile(r"\d"), "#"),
]
PARTY = re.compile(r"(\b(?:trf to|transferred to|sent to|paid to|to|from|by|favouring|in favour of|info)\s*:?\s+)((?:[A-Z][A-Za-z.&']*\s?){1,4})")

def skeleton(body):
    s = " ".join(body.split())
    for rx, rep in SUBS:
        s = rx.sub(rep, s)
    return s

def redacted(skel):
    return PARTY.sub(lambda m: m.group(1) + "<PARTY> ", skel)

FAMILIES = [
    ("otp_security", r"\botp\b|one.time password|verification code|do not share|never share your"),
    ("ipo_asba_hold", r"\basba\b|\bipo\b|\bunblock|\bblocked\b.*(?:application|mandate|amount)|\blien\b"),
    ("mandate_autopay", r"mandate|autopay|auto.pay|e-?nach|\bumrn\b|standing instruction|\bsi\b"),
    ("card_payment", r"payment.{0,40}(?:received|credited).{0,40}card|card.{0,40}payment.{0,20}(?:received|credited)|towards.{0,30}credit card|\bbbps\b|\bcred\b"),
    ("bill_statement", r"statement|total (?:amt|amount) due|min(?:imum)?\.? (?:amt |amount )?due|due date|bill (?:generated|is due|due)"),
    ("limit", r"credit limit|limit.{0,30}(?:enhanc|increas|revis)"),
    ("reward_points", r"reward points?|\bpoints\b|cashback"),
    ("wallet", r"wallet|amazon pay|zomato money|mobikwik|freecharge|paytm balance|pay balance"),
    ("refund_reversal", r"refund|revers"),
    ("salary_income", r"salary|\bsal\b"),
    ("investment", r"mutual fund|\bsip\b|folio|\bnav\b|\bunits\b|groww|zerodha|upstox|demat|allot|redemption"),
    ("loan_emi", r"\bemi\b|\bloan\b"),
    ("insurance", r"premium|policy"),
    ("failed_declined", r"failed|declined|unsuccessful|insufficient|could not be processed"),
    ("card_spend", r"\bspent\b|purchase|card.{0,30}(?:used|txn|transaction)|txn.{0,30}card"),
    ("debit", r"debited|\bsent\b|\bpaid\b|transferred|withdrawn|withdrawal"),
    ("credit", r"credited|received|deposited"),
    ("balance", r"avl\.? bal|available balance|a/c bal|balance (?:is|in)"),
    ("promotion", r"\boffer|apply now|pre-?approved|eligible|limited period|\bwin\b|exclusive|upgrade|click|% off|discount"),
    ("delivery_service", r"deliver|dispatch|shipped|order|out for delivery|recharge|data pack|validity"),
]
FAMILY_RX = [(n, re.compile(p, re.I)) for n, p in FAMILIES]

def family(body):
    for name, rx in FAMILY_RX:
        if rx.search(body):
            return name
    return "other"

# Families where today's pipeline must NOT book a spend/ledger row (or must book as transfer only).
SHOULD_NOT_BOOK = {"otp_security", "ipo_asba_hold", "limit", "reward_points", "promotion", "delivery_service", "bill_statement", "failed_declined", "balance"}

def load(path):
    out = {}
    if not path:
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            r = json.loads(line)
            out[r["id"]] = r
    return out

def main():
    src, outdir = sys.argv[1], sys.argv[2]
    server = load(sys.argv[3]) if len(sys.argv) > 3 else {}
    device = load(sys.argv[4]) if len(sys.argv) > 4 else {}
    templates = {}
    fam_counts = collections.Counter()
    brand_counts = collections.Counter()
    msgs = [json.loads(l) for l in open(src, encoding="utf-8")]
    TOK = re.compile(r"<[A-Z]+>|[A-Za-z][A-Za-z'.&-]*|[^\sA-Za-z]")
    df = collections.Counter()
    sk_by_id = {}
    for m in msgs:
        sk0 = skeleton(m["body"])
        sk_by_id[m["id"]] = sk0
        df.update(set(t.lower() for t in TOK.findall(sk0) if t[0].isalpha()))
    def coarse(sk0):
        out = []
        for t in TOK.findall(sk0):
            if t[0].isalpha() and df[t.lower()] < 5:
                t = "<W>"
            if t == "<W>" and out and out[-1] == "<W>":
                continue
            out.append(t)
        return " ".join(out)
    for m in msgs:
        b = brand(m["sender"])
        sk = coarse(sk_by_id[m["id"]])
        h = hashlib.sha256((b + "\n" + sk).encode()).hexdigest()[:16]
        fam = family(m["body"])
        fam_counts[fam] += 1
        brand_counts[b] += 1
        t = templates.setdefault(h, {"hash": h, "brand": b, "skeleton": sk, "family": fam, "count": 0,
                                     "ids": [], "first": m["observedAt"], "last": m["observedAt"],
                                     "server": collections.Counter(), "device": collections.Counter()})
        t["count"] += 1
        if len(t["ids"]) < 5:
            t["ids"].append(m["id"])
        t["first"] = min(t["first"], m["observedAt"])
        t["last"] = max(t["last"], m["observedAt"])
        s = server.get(m["id"])
        if s:
            t["server"][f'{"OK" if s["ok"] else "--"}:{s.get("kind") or s.get("reason")}'] += 1
        d = device.get(m["id"])
        if d:
            booked = d.get("disp") == "sync" and d.get("amount") is not None
            t["device"][f'{d.get("event")}/{d.get("disp")}:{d.get("kind") if booked else "-"}'] += 1
    ts = sorted(templates.values(), key=lambda t: -t["count"])
    for t in ts:
        t["server"] = dict(t["server"]); t["device"] = dict(t["device"])
    json.dump(ts, open(f"{outdir}/templates.json", "w"), ensure_ascii=False, indent=1)

    total = len(msgs)
    lines = [f"# Real SMS analysis\n", f"Messages: {total}. Templates: {len(ts)}. Senders (brands): {len(brand_counts)}.\n"]
    covered = 0
    for i, t in enumerate(ts):
        covered += t["count"]
        if covered >= 0.9 * total:
            lines.append(f"Top {i + 1} templates cover 90% of messages.\n"); break
    lines.append("\n## Families\n\n| Family | Messages | Share |\n| --- | --- | --- |")
    for fam, n in fam_counts.most_common():
        lines.append(f"| {fam} | {n} | {n * 100 / max(total, 1):.1f}% |")
    lines.append("\n## Top brands\n\n| Brand | Messages |\n| --- | --- |")
    for b, n in brand_counts.most_common(40):
        lines.append(f"| {b} | {n} |")

    def booked_server(t):
        return sum(v for k, v in t["server"].items() if k.startswith("OK:"))
    def booked_device(t):
        return sum(v for k, v in t["device"].items() if not k.endswith(":-"))
    lines.append("\n## Suspect: booked as money but family says it should not be\n\n| # | Family | Brand | Count | Server booked | Phone booked | Template (redacted) |\n| --- | --- | --- | --- | --- | --- | --- |")
    k = 0
    for t in ts:
        if t["family"] in SHOULD_NOT_BOOK and (booked_server(t) or booked_device(t)):
            k += 1
            lines.append(f"| {k} | {t['family']} | {t['brand']} | {t['count']} | {booked_server(t)} | {booked_device(t)} | {redacted(t['skeleton'])[:180]} |")
            if k >= 60: break
    lines.append("\n## Unparsed money-looking templates (neither parser booked)\n\n| # | Family | Brand | Count | Template (redacted) |\n| --- | --- | --- | --- | --- |")
    k = 0
    for t in ts:
        if t["family"] in {"card_spend", "debit", "credit", "card_payment", "wallet", "refund_reversal", "salary_income", "investment", "mandate_autopay", "loan_emi"} and not booked_server(t) and not booked_device(t):
            k += 1
            lines.append(f"| {k} | {t['family']} | {t['brand']} | {t['count']} | {redacted(t['skeleton'])[:180]} |")
            if k >= 60: break
    lines.append("\n## Phone and server disagree (one books, the other does not)\n\n| # | Family | Brand | Count | Server | Phone | Template (redacted) |\n| --- | --- | --- | --- | --- | --- | --- |")
    k = 0
    for t in ts:
        bs, bd = booked_server(t), booked_device(t)
        if server and device and ((bs == 0) != (bd == 0)):
            k += 1
            lines.append(f"| {k} | {t['family']} | {t['brand']} | {t['count']} | {json.dumps(t['server'])[:60]} | {json.dumps(t['device'])[:60]} | {redacted(t['skeleton'])[:160]} |")
            if k >= 60: break
    lines.append("\n## Top 80 templates\n\n| # | Family | Brand | Count | Server | Phone | Template (redacted) |\n| --- | --- | --- | --- | --- | --- | --- |")
    for i, t in enumerate(ts[:80]):
        lines.append(f"| {i + 1} | {t['family']} | {t['brand']} | {t['count']} | {json.dumps(t['server'])[:60]} | {json.dumps(t['device'])[:60]} | {redacted(t['skeleton'])[:160]} |")
    open(f"{outdir}/report.md", "w").write("\n".join(lines) + "\n")
    print(f"{total} messages, {len(ts)} templates -> {outdir}/report.md")

if __name__ == "__main__":
    main()
