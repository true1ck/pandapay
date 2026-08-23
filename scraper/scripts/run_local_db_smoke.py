#!/usr/bin/env python3
"""Local DB smoke test for the scraper queue.

Run this after the Docker stack is up and `SCRAPER_DATABASE_URL` points at the
local Postgres instance. The script performs a real end-to-end sanity check:
- connect to the scraper database
- create a temporary card target
- enqueue the same job twice and verify dedupe
- claim the job with `fetch_next_job`
- mark it complete
- optionally promote a temporary draft if source/issuer seed data exists

The script is intentionally destructive only to its own temporary rows and
cleans them up before exit.
"""

from __future__ import annotations

import argparse
import sys
from contextlib import suppress
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


SCRAPER_ROOT = Path(__file__).resolve().parents[1]
if str(SCRAPER_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRAPER_ROOT))


def _fetch_one(conn, sql: str, params: tuple | None = None):
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchone()


def _delete_where(conn, table: str, clause: str, params: tuple) -> None:
    with conn.cursor() as cur:
        cur.execute(f"DELETE FROM {table} WHERE {clause}", params)
    if hasattr(conn, "commit"):
        conn.commit()


def run_smoke(promote: bool = True) -> int:
    from pandapay_scraper.queue_models import (
        CardCrawlJob,
        CardTarget,
        complete_job,
        fetch_next_job,
        get_db,
        queue_job,
        upsert_target,
    )

    conn = get_db()
    cleanup: dict[str, list[str]] = {
        "card_products": [],
        "card_source_drafts": [],
        "card_crawl_jobs": [],
        "card_targets": [],
    }

    try:
        card_key = f"smoke-{uuid4().hex[:12]}"
        target = CardTarget(
            issuer_name="Smoke Issuer",
            card_name=f"Smoke Test Card {card_key[-6:]}",
            card_key=card_key,
            aliases=["smoke-test"],
        )
        target_id = upsert_target(conn, target)
        cleanup["card_targets"].append(target_id)
        target_row = _fetch_one(conn, "SELECT * FROM card_targets WHERE id = %s", (target_id,))
        print("target_row:", target_row)

        job = CardCrawlJob(card_target_id=target_id, job_type="discover", payload={"smoke_test": True})
        first_job_id = queue_job(conn, job)
        second_job_id = queue_job(conn, job)
        if first_job_id != second_job_id:
            raise RuntimeError("Queue dedupe did not return the same row id for the same job")
        queued_job_row = _fetch_one(conn, "SELECT * FROM card_crawl_jobs WHERE id = %s", (first_job_id,))
        print("queued_job_row:", queued_job_row)

        job_count = _fetch_one(
            conn,
            """
            SELECT count(*) AS n
              FROM card_crawl_jobs
             WHERE card_target_id = %s AND job_type = 'discover'
            """,
            (target_id,),
        )
        if int(job_count["n"]) != 1:
            raise RuntimeError(f"Expected 1 deduped job row, found {job_count['n']}")

        claimed = fetch_next_job(conn)
        if claimed is None:
            raise RuntimeError("fetch_next_job returned no job")
        if str(claimed["id"]) != str(first_job_id):
            raise RuntimeError(f"fetch_next_job returned {claimed['id']}, expected {first_job_id}")
        if claimed["state"] != "running":
            raise RuntimeError(f"fetch_next_job did not mark job running (state={claimed['state']})")
        print("claimed_job_row:", claimed)

        complete_job(conn, claimed["id"])
        finished = _fetch_one(conn, "SELECT state FROM card_crawl_jobs WHERE id = %s", (claimed["id"],))
        if finished is None or finished["state"] != "succeeded":
            raise RuntimeError("complete_job did not persist the succeeded state")
        print("finished_job_row:", finished)
        cleanup["card_crawl_jobs"].append(claimed["id"])

        print(f"Queue smoke passed for target {target_id} and job {claimed['id']}")

        if promote:
            issuer = _fetch_one(conn, "SELECT * FROM issuers ORDER BY created_at ASC LIMIT 1")
            source = _fetch_one(conn, "SELECT * FROM sources ORDER BY created_at ASC LIMIT 1")
            if issuer is None or source is None:
                print("Promotion smoke skipped: issuers/sources seed data is not present")
                return 0

            from pandapay_scraper.db import insert_card_source_draft
            from pandapay_scraper.promotion import promote_draft

            draft_id = insert_card_source_draft(
                conn,
                source_id=str(source["id"]),
                source_page_id=None,
                source_url=str(source["base_url"]),
                source_class=str(source.get("source_class") or "issuer_official"),
                source_license=str(source.get("license_note") or "") or None,
                card_key=f"{card_key}-draft",
                card_name=target.card_name,
                issuer_name=issuer["name"],
                network="VISA",
                tier="SMOKE",
                as_of=datetime.now(timezone.utc).date(),
                source_payload={"smoke_test": True},
                normalized_fields={"smoke_test": True},
                field_confidence={"smoke_test": 1.0},
                evidence=[{"field": "smoke_test", "value": True, "source": str(source["base_url"])}],
                confidence=1.0,
                status="ready",
            )
            cleanup["card_source_drafts"].append(draft_id)

            product_id = promote_draft(conn, draft_id)
            cleanup["card_products"].append(product_id)

            product = _fetch_one(conn, "SELECT id, slug, name FROM card_products WHERE id = %s", (product_id,))
            if product is None:
                raise RuntimeError("Promoted product row was not found")

            print(f"Promotion smoke passed for card_product {product_id}")

        return 0
    finally:
        with suppress(Exception):
            for product_id in cleanup["card_products"]:
                _delete_where(conn, "card_products", "id = %s", (product_id,))
            for draft_id in cleanup["card_source_drafts"]:
                _delete_where(conn, "card_source_drafts", "id = %s", (draft_id,))
            for job_id in cleanup["card_crawl_jobs"]:
                _delete_where(conn, "card_crawl_jobs", "id = %s", (job_id,))
            for target_id in cleanup["card_targets"]:
                _delete_where(conn, "card_targets", "id = %s", (target_id,))
        with suppress(Exception):
            conn.close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Smoke test the local scraper DB queue pipeline")
    parser.add_argument(
        "--skip-promotion",
        action="store_true",
        help="Only validate queue dedupe / fetch / complete, skip temporary promotion",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Print the row data fetched from the local database",
    )
    args = parser.parse_args(argv)
    return run_smoke(promote=not args.skip_promotion)


if __name__ == "__main__":
    raise SystemExit(main())
