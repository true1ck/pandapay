#!/usr/bin/env python3
"""Human-in-the-loop tool for clearing scraper `sources` rows for crawling.

scraper/CANDIDATE_SOURCES.md is explicit that flipping `tos_reviewed` is a
product-owner decision, not something an agent or script can decide on its
own: each row needs a human to have actually read that issuer's terms of
service and concluded scraping the listed page is permitted. This script
does not make that call — it only records one, so the decision is durable,
attributed to a real admin_users row, and audited the same way every other
admin-console write is (admin_audit_log), instead of someone hand-editing
`sources` with psql and leaving no trail.

The DB still owns the real gate: `sources.enabled_requires_tos_review`
(database.sql) rejects `is_enabled = true` unless `tos_reviewed = true`,
regardless of what this script does. RLS also requires `app.user_id` to
resolve to an active admin_users row (0011_rls_policies.sql pandapay.is_admin()),
so this only works for a real admin.

Usage:
    export DATABASE_URL=postgresql://app_user:...@host:5432/pandapay   # NOT postgres/scraper_role

    # See current review status for every candidate source.
    python review_source.py list

    # Record that a human read an issuer's ToS and clear it for crawling.
    python review_source.py review \\
        --source "ICICI Bank" \\
        --admin-email reviewer@pandapay.example \\
        --tos-url https://www.icicibank.com/terms-and-conditions \\
        --note "Read site ToS 2026-08-12: no restriction on automated access \\
                to public product pages; scraping public card listing pages \\
                for our own comparison product is permitted." \\
        --confirm-tos-read \\
        --enable

    # Undo a prior review (e.g. ToS changed, or it was recorded in error).
    python review_source.py revoke --source "ICICI Bank" \\
        --admin-email reviewer@pandapay.example \\
        --note "ToS updated 2026-09-01 to prohibit automated access; disabling."

Sources whose robots.txt is a blanket `Disallow: /` (AU Small Finance Bank at
the time CANDIDATE_SOURCES.md was written) additionally require
--acknowledge-robots-disallow, because CANDIDATE_SOURCES.md flags that as a
signal strong enough to warrant separate discussion even after ToS review.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import psycopg
from psycopg.rows import dict_row

MIN_NOTE_LEN = 20


def check_note(note: str) -> None:
    if len(note.strip()) < MIN_NOTE_LEN:
        raise ValueError(
            f"--note must be at least {MIN_NOTE_LEN} characters — record what you actually "
            "read and concluded, not a placeholder."
        )


def check_confirm_tos_read(confirmed: bool) -> None:
    if not confirmed:
        raise ValueError(
            "Refusing to proceed without --confirm-tos-read. This flag exists so nobody "
            "flips this flag by accident or on a script's say-so — pass it only if you "
            "personally read the issuer's terms of service at --tos-url."
        )


def check_robots_disallow(robots_allows: bool | None, acknowledged: bool, source_name: str) -> None:
    if robots_allows is False and not acknowledged:
        raise ValueError(
            f"{source_name} has robots_allows = false (blanket crawler disallow). "
            "CANDIDATE_SOURCES.md flags this as a signal strong enough to need separate "
            "discussion even after ToS review. Re-run with --acknowledge-robots-disallow "
            "if you're intentionally proceeding anyway."
        )


def connect() -> psycopg.Connection:
    database_url = os.environ.get("DATABASE_URL")
    if not database_url:
        raise SystemExit(
            "DATABASE_URL is not set. Point it at app_user (see db/setup_app_role.sql), "
            "not postgres and not scraper_role — this script needs RLS to enforce that "
            "the caller is a real active admin."
        )
    return psycopg.connect(database_url, row_factory=dict_row)


def resolve_admin(cur: psycopg.Cursor, email: str) -> dict:
    cur.execute(
        "SELECT id, email, role, is_active FROM admin_users WHERE email = %s",
        (email,),
    )
    admin = cur.fetchone()
    if admin is None:
        raise SystemExit(f"No admin_users row for {email!r}. Cannot attribute this review to anyone.")
    if not admin["is_active"]:
        raise SystemExit(f"admin_users row for {email!r} is not active.")
    return admin


def resolve_source(cur: psycopg.Cursor, source: str) -> dict:
    cur.execute("SELECT * FROM sources WHERE id::text = %s OR name = %s", (source, source))
    row = cur.fetchone()
    if row is None:
        raise SystemExit(f"No sources row matches id or name {source!r}. Run `list` to see options.")
    return row


def cmd_list(conn: psycopg.Connection, admin_email: str) -> None:
    with conn.cursor() as cur:
        admin = resolve_admin(cur, admin_email)
        cur.execute("SELECT set_config('app.user_id', %s, true)", (str(admin["id"]),))
        cur.execute(
            """SELECT id, name, kind, robots_allows, tos_reviewed, is_enabled, tos_note
               FROM sources ORDER BY name"""
        )
        rows = cur.fetchall()
    conn.commit()
    if not rows:
        print("No sources rows found.")
        return
    for row in rows:
        robots = "allow" if row["robots_allows"] else ("DISALLOW" if row["robots_allows"] is False else "unknown")
        note = (row["tos_note"] or "").replace("\n", " ")
        if len(note) > 60:
            note = note[:57] + "..."
        print(
            f"{row['id']}  {row['name']:<28} kind={row['kind']:<14} "
            f"robots={robots:<8} tos_reviewed={row['tos_reviewed']!s:<5} "
            f"is_enabled={row['is_enabled']!s:<5} note={note!r}"
        )


def cmd_review(conn: psycopg.Connection, args: argparse.Namespace) -> None:
    try:
        check_note(args.note)
        check_confirm_tos_read(args.confirm_tos_read)
    except ValueError as exc:
        raise SystemExit(str(exc))

    with conn.cursor() as cur:
        admin = resolve_admin(cur, args.admin_email)
        cur.execute("SELECT set_config('app.user_id', %s, true)", (str(admin["id"]),))
        source = resolve_source(cur, args.source)

        try:
            check_robots_disallow(source["robots_allows"], args.acknowledge_robots_disallow, source["name"])
        except ValueError as exc:
            raise SystemExit(str(exc))

        before = {
            "tos_reviewed": source["tos_reviewed"],
            "is_enabled": source["is_enabled"],
            "tos_note": source["tos_note"],
        }
        after = {
            "tos_reviewed": True,
            "is_enabled": bool(args.enable),
            "tos_note": f"[{args.tos_url}] {args.note}" if args.tos_url else args.note,
        }

        cur.execute(
            """UPDATE sources SET tos_reviewed = %(tos_reviewed)s,
                                   is_enabled = %(is_enabled)s,
                                   tos_note = %(tos_note)s
               WHERE id = %(id)s""",
            {**after, "id": source["id"]},
        )
        cur.execute(
            """INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
               VALUES (%s, 'source_tos_review', 'sources', %s, %s, %s, %s)""",
            (admin["id"], source["id"], json.dumps(before), json.dumps(after), args.note),
        )
    conn.commit()
    print(f"Recorded ToS review for {source['name']!r}: tos_reviewed=true, is_enabled={after['is_enabled']}.")


def cmd_revoke(conn: psycopg.Connection, args: argparse.Namespace) -> None:
    try:
        check_note(args.note)
    except ValueError as exc:
        raise SystemExit(str(exc))

    with conn.cursor() as cur:
        admin = resolve_admin(cur, args.admin_email)
        cur.execute("SELECT set_config('app.user_id', %s, true)", (str(admin["id"]),))
        source = resolve_source(cur, args.source)

        before = {
            "tos_reviewed": source["tos_reviewed"],
            "is_enabled": source["is_enabled"],
            "tos_note": source["tos_note"],
        }
        after = {"tos_reviewed": False, "is_enabled": False, "tos_note": args.note}

        cur.execute(
            """UPDATE sources SET tos_reviewed = false, is_enabled = false, tos_note = %s
               WHERE id = %s""",
            (args.note, source["id"]),
        )
        cur.execute(
            """INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason)
               VALUES (%s, 'source_tos_revoke', 'sources', %s, %s, %s, %s)""",
            (admin["id"], source["id"], json.dumps(before), json.dumps(after), args.note),
        )
    conn.commit()
    print(f"Revoked ToS clearance for {source['name']!r}: tos_reviewed=false, is_enabled=false.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_list = sub.add_parser("list", help="Show review status for every sources row.")
    p_list.add_argument("--admin-email", required=True, help="Active admin_users.email making this query.")

    p_review = sub.add_parser("review", help="Record that a human cleared a source's ToS for crawling.")
    p_review.add_argument("--source", required=True, help="sources.id or exact sources.name.")
    p_review.add_argument("--admin-email", required=True)
    p_review.add_argument("--tos-url", help="URL/document that was actually read.")
    p_review.add_argument("--note", required=True, help="What was read and concluded (>= 20 chars).")
    p_review.add_argument(
        "--confirm-tos-read", action="store_true",
        help="Required. Pass only if you personally read the issuer's terms of service.",
    )
    p_review.add_argument(
        "--enable", action="store_true",
        help="Also set is_enabled=true (source becomes live for the scraper). Omit to review-only.",
    )
    p_review.add_argument(
        "--acknowledge-robots-disallow", action="store_true",
        help="Required if the source's robots.txt is a blanket Disallow: /.",
    )

    p_revoke = sub.add_parser("revoke", help="Undo a prior review (sets tos_reviewed and is_enabled back to false).")
    p_revoke.add_argument("--source", required=True)
    p_revoke.add_argument("--admin-email", required=True)
    p_revoke.add_argument("--note", required=True, help="Why this is being revoked (>= 20 chars).")

    args = parser.parse_args()
    conn = connect()
    try:
        if args.command == "list":
            cmd_list(conn, args.admin_email)
        elif args.command == "review":
            cmd_review(conn, args)
        elif args.command == "revoke":
            cmd_revoke(conn, args)
    except psycopg.Error as exc:
        conn.rollback()
        print(f"Database error: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
