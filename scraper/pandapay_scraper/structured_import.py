"""CLI for importing structured card datasets into PandaPay drafts.

Usage examples:
- Print normalized rows from a CardAdvisor download:
  `python -m pandapay_scraper.structured_import --input cards.json`
- Persist them to the DB staging table:
  `python -m pandapay_scraper.structured_import --input cards.json --write-db --source-id <uuid>`
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import httpx

from .structured_cards import (
    DEFAULT_SOURCE_CLASS,
    DEFAULT_SOURCE_LICENSE,
    load_cards_from_csv,
    load_cards_from_json,
    load_cards_from_path,
)


def _download_dataset(url: str) -> tuple[str, str]:
    headers = {"User-Agent": "PandaPayStructuredImport/1.0 (+https://pandapay.example/bot)"}
    with httpx.Client(timeout=30, follow_redirects=True) as client:
        response = client.get(url, headers=headers)
        response.raise_for_status()
        content_type = response.headers.get("content-type", "").lower()
        return response.text, content_type


def _load_from_remote(url: str, *, source_class: str, source_license: str | None, source_url: str | None):
    from urllib.parse import urlparse

    raw_text, content_type = _download_dataset(url)
    suffix = Path(urlparse(url).path).suffix.lower()
    if not suffix:
        suffix = ".csv" if "csv" in content_type else ".json"
    if suffix == ".csv":
        return load_cards_from_csv(raw_text, source_class=source_class, source_license=source_license, source_url=source_url or url)
    return load_cards_from_json(raw_text, source_class=source_class, source_license=source_license, source_url=source_url or url)


def main(argv: list[str] | None = None) -> int:
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass

    parser = argparse.ArgumentParser(description="Import structured card data into PandaPay drafts")
    input_group = parser.add_mutually_exclusive_group(required=True)
    input_group.add_argument("--input", help="Path to a JSON or CSV dataset")
    input_group.add_argument("--input-url", help="Remote JSON or CSV dataset URL to fetch and import")
    parser.add_argument("--source-id", help="sources.id row to attach the drafts to")
    parser.add_argument("--source-base-url", help="Look up the source by base_url instead of id")
    parser.add_argument("--source-name", help="Look up the source by exact name instead of id")
    parser.add_argument("--source-url", help="Canonical source URL for the dataset")
    parser.add_argument("--source-class", default=DEFAULT_SOURCE_CLASS, help="Structured source class label")
    parser.add_argument("--source-license", default=DEFAULT_SOURCE_LICENSE, help="License label to record")
    parser.add_argument("--write-db", action="store_true", help="Persist drafts to the DB staging table")
    parser.add_argument("--jsonl", action="store_true", help="Print one normalized draft per line instead of a JSON array")
    args = parser.parse_args(argv)

    if args.input_url:
        drafts = _load_from_remote(
            args.input_url,
            source_class=args.source_class,
            source_license=args.source_license,
            source_url=args.source_url,
        )
    else:
        drafts = load_cards_from_path(
            Path(args.input),
            source_class=args.source_class,
            source_license=args.source_license,
            source_url=args.source_url,
        )

    if not args.write_db:
        rows = [draft.to_row() for draft in drafts]
        if args.jsonl:
            for row in rows:
                print(json.dumps(row, ensure_ascii=False))
        else:
            print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0

    from . import db

    conn = db.connect()
    try:
        source_id = args.source_id
        if not source_id:
            source_row = None
            if args.source_base_url:
                source_row = db.source_by_base_url(conn, args.source_base_url)
            elif args.source_name:
                source_row = db.source_by_name(conn, args.source_name)

            if source_row is not None:
                source_id = str(source_row["id"])

        if not source_id:
            print(
                "--source-id, --source-base-url, or --source-name is required when --write-db is enabled",
                file=sys.stderr,
            )
            return 2

        for draft in drafts:
            db.insert_card_source_draft(
                conn,
                source_id=source_id,
                source_page_id=None,
                source_url=draft.source_url,
                source_class=draft.source_class,
                source_license=draft.source_license,
                card_key=draft.card_key,
                card_name=draft.card_name,
                issuer_name=draft.issuer_name,
                network=draft.network,
                tier=draft.tier,
                as_of=draft.as_of,
                source_payload=draft.source_payload,
                normalized_fields=draft.normalized_fields,
                field_confidence=draft.field_confidence,
                evidence=draft.evidence,
                confidence=draft.confidence,
                status="draft",
            )
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    raise SystemExit(main())
