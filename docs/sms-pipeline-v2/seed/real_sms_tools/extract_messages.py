"""Extract institutional (bank/service) SMS from a copy of macOS Messages chat.db.

Reads only senders that look like DLT headers (letters, e.g. AX-HDFCBK-S or HDFCBK).
Phone numbers, emails and contact names are skipped. Output stays local (mode 600).

Usage: python3 -I extract_messages.py <chat.db> <out.jsonl> [days=365]
"""
import json
import os
import re
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
PHONE = re.compile(r"^\+?\d[\d\s-]{6,}$")
EMAIL = re.compile(r"@")
DLT = re.compile(r"^(?:[A-Z]{2}-)?[A-Z0-9]{3,9}(?:-[A-Z])?$")
IOS_TAG = re.compile(r"\(([a-z_]+)\)$", re.I)


def apple_time(value):
    if value is None:
        return None
    seconds = value / 1e9 if value > 1e12 else value
    return APPLE_EPOCH + timedelta(seconds=seconds)


def decode_attributed_body(blob):
    """Pull the plain string out of an NSAttributedString typedstream blob."""
    if not blob:
        return None
    i = blob.find(b"NSString")
    if i < 0:
        return None
    j = blob.find(b"+", i)
    if j < 0 or j + 1 >= len(blob):
        return None
    length = blob[j + 1]
    start = j + 2
    if length == 0x81:
        length = int.from_bytes(blob[j + 2:j + 4], "little")
        start = j + 4
    elif length == 0x82:
        length = int.from_bytes(blob[j + 2:j + 5], "little")
        start = j + 5
    return blob[start:start + length].decode("utf-8", "replace")


def split_tag(sender):
    s = (sender or "").strip()
    m = IOS_TAG.search(s)
    tag = m.group(1).lower() if m else None
    return (s[:m.start()] if m else s).strip(), tag


def is_institutional(sender):
    if not sender:
        return False
    s = split_tag(sender)[0].upper()
    if PHONE.match(s) or EMAIL.search(s):
        return False
    return bool(DLT.match(s)) and any(c.isalpha() for c in s)


def main():
    db_path, out_path = sys.argv[1], sys.argv[2]
    days = int(sys.argv[3]) if len(sys.argv) > 3 else 365
    cutoff = datetime.now(timezone.utc) - timedelta(days=days)
    con = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    rows = con.execute(
        """SELECT m.ROWID, m.date, m.text, m.attributedBody, h.id, m.service
             FROM message m JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 0
              AND h.id NOT LIKE '+%' AND h.id NOT LIKE '%@%'
              AND h.id GLOB '*[A-Za-z]*'
              AND m.date >= ?""",
        (int((cutoff - APPLE_EPOCH).total_seconds() * 1e9),),
    )
    kept = skipped_personal = skipped_old = empty = 0
    senders = {}
    fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as out:
        for rowid, date, text, body_blob, sender, service in rows:
            when = apple_time(date)
            if when is None or when < cutoff:
                skipped_old += 1
                continue
            if not is_institutional(sender):
                skipped_personal += 1
                continue
            body = text or decode_attributed_body(body_blob)
            if not body or not body.strip():
                empty += 1
                continue
            sender, tag = split_tag(sender)
            sender = sender.upper()
            senders[sender] = senders.get(sender, 0) + 1
            out.write(json.dumps({"id": rowid, "sender": sender, "iosFilter": tag, "body": body,
                                  "observedAt": when.isoformat(), "service": service},
                                 ensure_ascii=False) + "\n")
            kept += 1
    print(json.dumps({"kept": kept, "skipped_personal_or_unknown": skipped_personal,
                      "skipped_older": skipped_old, "empty": empty,
                      "distinct_senders": len(senders)}))


if __name__ == "__main__":
    main()
