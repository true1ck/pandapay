#!/usr/bin/env python3
"""Queue-based fetch smoke for four SBI cards.

This uses the real local scraper database and the real queue primitives, but
stops after normalize so we can inspect the fetched data before any live
catalogue promotion.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

import httpx


SCRAPER_ROOT = Path(__file__).resolve().parents[1]
if str(SCRAPER_ROOT) not in sys.path:
    sys.path.insert(0, str(SCRAPER_ROOT))

from pandapay_scraper.db import connect, insert_card_source_draft  # noqa: E402
from pandapay_scraper.fetcher import fetch_static  # noqa: E402
from pandapay_scraper.issuer_profiles import get_sbi_profile  # noqa: E402
from pandapay_scraper.queue_models import CardCrawlJob, CardTarget, complete_job, queue_job, upsert_target  # noqa: E402

try:  # pragma: no cover - the real scraper environment may provide selectolax
    from pandapay_scraper.extractor import extract  # noqa: E402
except ImportError:  # pragma: no cover
    from pandapay_scraper.queue_runner import extract  # noqa: E402


SBI_TARGETS = [
    {
        "name": "SBI AURUM Credit Card",
        "url": "https://www.sbicard.com/aurum/",
    },
    {
        "name": "SBI Card ELITE",
        "url": "https://www.sbicard.com/en/personal/credit-cards/sbi-card-elite.html",
    },
    {
        "name": "SBI Card ELITE Advantage",
        "url": "https://www.sbicard.com/en/personal/credit-cards/lifestyle/sbi-card-elite-advantage.page",
    },
    {
        "name": "SBI ELITE Credit Card",
        "url": "https://www.sbicard.com/en/personal/credit-cards/sbi-card-elite.html",
    },
]


@dataclass
class TempRow:
    table: str
    id: str


def _slugify(value: str) -> str:
    import re

    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def _fetch_one(conn, sql: str, params: tuple | None = None):
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchone()


def _fetch_all(conn, sql: str, params: tuple | None = None):
    with conn.cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchall()


def _claim_next_job_for_targets(conn, target_ids: list[str]):
    with conn.cursor() as cur:
        cur.execute(
            """
            WITH next_job AS (
              SELECT id
                FROM card_crawl_jobs
               WHERE state = 'queued'
                 AND card_target_id = ANY(%s::uuid[])
               ORDER BY priority DESC, next_run_at ASC, created_at ASC
               FOR UPDATE SKIP LOCKED
               LIMIT 1
            )
            UPDATE card_crawl_jobs c
               SET state = 'running',
                   attempts = attempts + 1,
                   updated_at = now()
              FROM next_job
             WHERE c.id = next_job.id
         RETURNING c.*;
            """,
            (target_ids,),
        )
        return cur.fetchone()


def _cleanup(conn, rows: list[TempRow]) -> None:
    for row in rows:
        with conn.cursor() as cur:
            cur.execute(f"DELETE FROM {row.table} WHERE id = %s", (row.id,))
    conn.commit()


def run() -> int:
    conn = connect()
    cleanup_targets: list[str] = []
    cleanup_drafts: list[str] = []
    cleanup_jobs: list[str] = []
    try:
        issuer = _fetch_one(conn, "SELECT * FROM issuers WHERE slug = %s LIMIT 1", ("sbi",))
        if issuer is None:
            raise RuntimeError("SBI issuer row not found")

        listing_source = _fetch_one(
            conn,
            """
            SELECT * FROM sources
             WHERE issuer_id = %s AND is_enabled = true AND tos_reviewed = true
             ORDER BY source_priority ASC, created_at ASC
             LIMIT 1
            """,
            (issuer["id"],),
        )
        if listing_source is None:
            raise RuntimeError("No enabled SBI source row found")
        mitc_source = _fetch_one(
            conn,
            "SELECT * FROM sources WHERE base_url = %s LIMIT 1",
            ("https://www.sbicard.com/en/most-important-terms-and-conditions.page",),
        )
        if mitc_source is None:
            raise RuntimeError("SBI MITC source row not found")

        for item in SBI_TARGETS:
            profile = get_sbi_profile(item["name"])
            target = CardTarget(
                issuer_name=issuer["name"],
                card_name=item["name"],
                card_key=profile["card_key"],
                aliases=[],
            )
            target_id = upsert_target(conn, target)
            cleanup_targets.append(target_id)
            queue_job(
                conn,
                CardCrawlJob(
                    card_target_id=target_id,
                    source_id=str(listing_source["id"]),
                    source_page_id=None,
                    job_type="fetch",
                    payload={
                        "source_url": item["url"],
                        "source_name": listing_source["name"],
                        "page_kind": "product",
                        "structured_profile": profile,
                    },
                ),
            )
            queue_job(
                conn,
                CardCrawlJob(
                    card_target_id=target_id,
                    source_id=str(mitc_source["id"]),
                    source_page_id=None,
                    job_type="fetch",
                    payload={
                        "source_url": mitc_source["base_url"],
                        "source_name": mitc_source["name"],
                        "page_kind": "mitc",
                        "structured_profile": profile,
                    },
                ),
            )

        conn.commit()
        target_ids = cleanup_targets
        seen_drafts: list[dict] = []
        with httpx.Client(follow_redirects=True, timeout=30) as client:
            while True:
                job = _claim_next_job_for_targets(conn, target_ids)
                if job is None:
                    break

                payload = dict(job["payload"] or {})
                if job["job_type"] == "fetch":
                    result = fetch_static(client, payload["source_url"])
                    complete_job(
                        conn,
                        str(job["id"]),
                        next_job_type="extract",
                        payload={
                            **payload,
                            "source_url": payload["source_url"],
                            "final_url": result.final_url,
                            "html": result.html,
                            "http_status": result.status_code,
                        },
                    )
                    print(f"[fetch] {payload['source_url']} -> {result.status_code} {result.final_url}")
                    continue

                if job["job_type"] == "extract":
                    html = payload.get("html") or ""
                    extracted = extract(html, selector_hint=payload.get("selector_hint"))
                    complete_job(
                        conn,
                        str(job["id"]),
                        next_job_type="normalize",
                        payload={**payload, "extracted_text": extracted.text, "content_hash": extracted.content_hash},
                    )
                    print(f"[extract] {str(job['card_target_id'])} chars={len(extracted.text)} hash={extracted.content_hash[:12]}")
                    continue

                if job["job_type"] == "normalize":
                    target_row = _fetch_one(conn, "SELECT card_name, card_key FROM card_targets WHERE id = %s", (job["card_target_id"],))
                    structured_profile = dict(payload.get("structured_profile") or get_sbi_profile(target_row["card_name"]))
                    draft_id = insert_card_source_draft(
                        conn,
                        source_id=str(job["source_id"]),
                        source_page_id=None,
                        source_url=payload.get("final_url") or payload.get("source_url"),
                        source_class=structured_profile.get("source_class") or "issuer_official",
                        source_license=structured_profile.get("source_license"),
                        card_key=target_row["card_key"],
                        card_name=target_row["card_name"],
                        issuer_name=issuer["name"],
                        network=structured_profile.get("network") or payload.get("network"),
                        tier=structured_profile.get("tier") or payload.get("tier"),
                        as_of=None,
                        source_payload={**payload, "structured_profile": structured_profile},
                        normalized_fields={
                            "source_url": payload.get("final_url") or payload.get("source_url"),
                            "content_hash": payload.get("content_hash"),
                            "extracted_text": payload.get("extracted_text"),
                            "annual_fee_inr": structured_profile.get("annual_fee_inr"),
                            "joining_fee_inr": structured_profile.get("joining_fee_inr"),
                            "point_value_inr": structured_profile.get("point_value_inr"),
                            "base_reward_unit": structured_profile.get("base_reward_unit"),
                            "base_reward_rate": structured_profile.get("base_reward_rate"),
                            "reward_rules": structured_profile.get("reward_rules") or [],
                            "fee_waiver_rules": structured_profile.get("fee_waiver_rules") or [],
                            "milestone_rules": structured_profile.get("milestone_rules") or [],
                            "benefits": structured_profile.get("benefits") or [],
                            "forex": structured_profile.get("forex"),
                            "fuel": structured_profile.get("fuel"),
                            "source_excerpt": structured_profile.get("source_excerpt"),
                            "source_links": structured_profile.get("source_links") or {},
                            "variant_note": structured_profile.get("variant_note"),
                        },
                        field_confidence={
                            "extracted_text": 0.5,
                            "content_hash": 0.5,
                            "annual_fee_inr": 1.0,
                            "joining_fee_inr": 1.0,
                            "point_value_inr": 1.0,
                            "base_reward_rate": 1.0,
                        },
                        evidence=[
                            {
                                "field": "extracted_text",
                                "value": (payload.get("extracted_text") or "")[:500],
                                "source": payload.get("final_url") or payload.get("source_url"),
                            }
                            {
                                "field": "source_excerpt",
                                "value": structured_profile.get("source_excerpt"),
                                "source": payload.get("final_url") or payload.get("source_url"),
                            },
                        ],
                        confidence=0.95,
                        status="ready",
                    )
                    complete_job(conn, str(job["id"]))
                    cleanup_drafts.append(draft_id)
                    seen_drafts.append(
                        {
                            "draft_id": draft_id,
                            "target_id": str(job["card_target_id"]),
                            "source_url": payload.get("final_url") or payload.get("source_url"),
                            "extracted_text": payload.get("extracted_text"),
                        }
                    )
                    print(f"[normalize] draft={draft_id} target={job['card_target_id']}")
                    continue

        drafts = _fetch_all(
            conn,
            """
            SELECT d.id, d.card_name, d.card_key, d.source_url, d.status, d.source_page_id,
                   d.normalized_fields
              FROM card_source_drafts d
              JOIN card_targets t ON t.card_key = d.card_key
             WHERE t.id = ANY(%s::uuid[])
             ORDER BY d.created_at ASC
            """,
            (target_ids,),
        )
        print("\nDRAFTS")
        for draft in drafts:
            normalized = draft["normalized_fields"] or {}
            text = (normalized.get("extracted_text") or "").strip().replace("\n", " ")
            print(
                {
                    "card_name": draft["card_name"],
                    "card_key": draft["card_key"],
                    "status": draft["status"],
                    "source_url": draft["source_url"],
                    "snippet": text[:400],
                }
            )
        print(f"\nCreated {len(drafts)} draft rows for the four SBI cards.")
        return 0
    finally:
        with conn.cursor() as cur:
            if cleanup_targets:
                cur.execute(
                    "UPDATE card_crawl_jobs SET state = 'skipped', updated_at = now() WHERE card_target_id = ANY(%s::uuid[])",
                    (cleanup_targets,),
                )
                if cleanup_drafts:
                    cur.execute(
                        "UPDATE card_source_drafts SET status = 'rejected', updated_at = now() WHERE id = ANY(%s::uuid[])",
                        (cleanup_drafts,),
                    )
                cur.execute(
                    "UPDATE card_targets SET status = 'retired', updated_at = now() WHERE id = ANY(%s::uuid[])",
                    (cleanup_targets,),
                )
        conn.commit()
        conn.close()


if __name__ == "__main__":
    raise SystemExit(run())
