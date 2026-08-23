from __future__ import annotations

import argparse
import logging
import re
import time
from dataclasses import dataclass
from datetime import date
from typing import Any

import httpx

from pandapay_scraper.fetcher import fetch_static
from pandapay_scraper.promotion import promote_draft
from pandapay_scraper.issuer_profiles import get_sbi_profile
from pandapay_scraper.queue_models import (
    CardCrawlJob,
    complete_job,
    fail_job,
    fetch_next_job,
    get_db,
    queue_job,
)

try:  # pragma: no cover - the full scraper environment provides selectolax
    from pandapay_scraper.extractor import extract
except ImportError:  # pragma: no cover - keeps the worker importable in lean test envs
    import hashlib

    @dataclass
    class _FallbackExtractedContent:
        text: str
        content_hash: str

    def extract(html: str, selector_hint: str | None = None):
        text = re.sub(r"<[^>]+>", " ", html)
        text = " ".join(text.split())
        return _FallbackExtractedContent(
            text=text,
            content_hash=hashlib.sha256(text.encode("utf-8")).hexdigest(),
        )

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


def _slugify(value: str) -> str:
    import re

    text = str(value or "").strip().lower()
    text = re.sub(r"[^a-z0-9]+", "-", text)
    return text.strip("-")


def _fetch_one(conn, query: str, params: tuple[Any, ...]) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(query, params)
        return cur.fetchone()


def _resolve_target(conn, target_id: str) -> dict[str, Any]:
    target = _fetch_one(conn, "SELECT * FROM card_targets WHERE id = %s", (target_id,))
    if target is None:
        raise ValueError(f"card_target {target_id} not found")
    return target


def _resolve_sources_for_target(conn, target: dict[str, Any]) -> list[dict[str, Any]]:
    issuer_slug = _slugify(target["issuer_name"])
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT s.*
              FROM issuers i
              JOIN sources s ON s.issuer_id = i.id
             WHERE (lower(i.name) = lower(%s) OR i.slug = %s)
               AND s.is_enabled = true
               AND s.tos_reviewed = true
             ORDER BY s.source_priority ASC, s.name ASC
            """,
            (target["issuer_name"], issuer_slug),
        )
        sources = cur.fetchall()
        if sources:
            return sources

        cur.execute(
            """
            SELECT *
              FROM sources
             WHERE is_enabled = true
               AND tos_reviewed = true
               AND (lower(name) = lower(%s) OR lower(name) LIKE lower(%s))
             ORDER BY source_priority ASC, name ASC
            """,
            (target["issuer_name"], f"%{target['issuer_name']}%"),
        )
        return cur.fetchall()


def _source_page_by_id(conn, source_page_id: str) -> dict[str, Any] | None:
    return _fetch_one(conn, "SELECT * FROM source_pages WHERE id = %s", (source_page_id,))


def handle_discover(conn, job):
    target = _resolve_target(conn, job["card_target_id"])
    logger.info("Discovering sources for target %s (%s)", target["card_name"], target["card_key"])

    sources = _resolve_sources_for_target(conn, target)
    if not sources:
        raise ValueError(f"No enabled sources found for issuer {target['issuer_name']}")

    created = 0
    for source in sources:
        pages = []
        with conn.cursor() as cur:
            cur.execute(
                "SELECT * FROM source_pages WHERE source_id = %s AND is_enabled = true ORDER BY url",
                (source["id"],),
            )
            pages = cur.fetchall()

        if pages:
            for page in pages:
                queue_job(
                    conn,
                    CardCrawlJob(
                        card_target_id=job["card_target_id"],
                        source_id=str(source["id"]),
                        source_page_id=str(page["id"]),
                        job_type="fetch",
                        priority=job["priority"],
                        payload={
                            "source_url": page["url"],
                            "selector_hint": page.get("selector_hint"),
                            "source_name": source["name"],
                            "page_role": page.get("page_role"),
                        },
                    ),
                )
                created += 1
        else:
            queue_job(
                conn,
                CardCrawlJob(
                    card_target_id=job["card_target_id"],
                    source_id=str(source["id"]),
                    job_type="fetch",
                    priority=job["priority"],
                    payload={
                        "source_url": source["base_url"],
                        "source_name": source["name"],
                    },
                ),
            )
            created += 1

    with conn.cursor() as cur:
        cur.execute(
            "UPDATE card_targets SET status = %s, updated_at = now() WHERE id = %s",
            ("crawlable", target["id"]),
        )

    logger.info("Queued %s fetch jobs for target %s", created, target["card_key"])
    complete_job(conn, job["id"])


def handle_fetch(conn, http_client: httpx.Client, job):
    payload = dict(job["payload"] or {})
    source_page = _source_page_by_id(conn, job["source_page_id"]) if job.get("source_page_id") else None
    source_url = payload.get("source_url") or (source_page["url"] if source_page else None)
    if not source_url:
        raise ValueError("fetch job is missing a source_url")

    logger.info("Fetching %s", source_url)
    result = fetch_static(http_client, source_url)

    complete_job(
        conn,
        job["id"],
        next_job_type="extract",
        payload={
            **payload,
            "source_url": source_url,
            "final_url": result.final_url,
            "html": result.html,
            "http_status": result.status_code,
        },
    )


def handle_extract(conn, job):
    payload = dict(job["payload"] or {})
    html = payload.get("html")
    if not html:
        raise ValueError("extract job is missing html")

    selector_hint = payload.get("selector_hint")
    extracted = extract(html, selector_hint=selector_hint)
    logger.info("Extracted %s chars from %s", len(extracted.text), payload.get("source_url") or "unknown source")

    complete_job(
        conn,
        job["id"],
        next_job_type="normalize",
        payload={
            **payload,
            "extracted_text": extracted.text,
            "content_hash": extracted.content_hash,
        },
    )


def handle_normalize(conn, job):
    target = _resolve_target(conn, job["card_target_id"])
    payload = dict(job["payload"] or {})
    source_page = _source_page_by_id(conn, job["source_page_id"]) if job.get("source_page_id") else None
    source = _fetch_one(conn, "SELECT * FROM sources WHERE id = %s", (job["source_id"],)) if job.get("source_id") else None

    if job.get("source_id") is None:
        raise ValueError("normalize job requires source_id")

    try:
        profile = get_sbi_profile(target["card_name"])
        payload["structured_profile"] = profile
        logger.info("Merged structured profile for %s", target["card_name"])
    except KeyError:
        logger.info("No structured profile found for %s", target["card_name"])

    draft_id = _insert_draft(
        conn,
        job=job,
        target=target,
        source=source,
        source_page=source_page,
        payload=payload,
    )
    logger.info("Created draft %s for target %s", draft_id, target["card_key"])
    complete_job(conn, job["id"], next_job_type="promote", payload={"draft_id": draft_id})


def _insert_draft(conn, *, job, target, source, source_page, payload: dict[str, Any]) -> str:
    from pandapay_scraper import db as scraper_db

    source_url = payload.get("final_url") or payload.get("source_url") or (source_page["url"] if source_page else None)
    if not source_url:
        raise ValueError("normalize job is missing a source_url")

    source_class = source.get("source_class") if source else "third_party_page"
    source_license = source.get("license_note") if source else None
    as_of = date.today()
    structured_profile = payload.get("structured_profile") or {}

    normalized_fields = {
        "extracted_text": payload.get("extracted_text"),
        "content_hash": payload.get("content_hash"),
        "source_url": source_url,
        "source_name": source["name"] if source else payload.get("source_name"),
        "page_role": source_page.get("page_role") if source_page else payload.get("page_role"),
    }
    if structured_profile:
        normalized_fields.update(
            {
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
            }
        )

    evidence = []
    if payload.get("extracted_text"):
        evidence.append(
            {
                "field": "extracted_text",
                "value": payload["extracted_text"][:500],
                "source": source_url,
            }
        )
    if structured_profile.get("source_excerpt"):
        evidence.append(
            {
                "field": "source_excerpt",
                "value": structured_profile["source_excerpt"],
                "source": source_url,
            }
        )

    return scraper_db.insert_card_source_draft(
        conn,
        source_id=job["source_id"],
        source_page_id=job.get("source_page_id"),
        source_url=source_url,
        source_class=source_class,
        source_license=source_license,
        card_key=target["card_key"],
        card_name=target["card_name"],
        issuer_name=target["issuer_name"],
        network=payload.get("network"),
        tier=payload.get("tier"),
        as_of=payload.get("as_of") or as_of,
        source_payload=payload,
        normalized_fields=normalized_fields,
        field_confidence={
            "card_key": 1.0,
            "card_name": 1.0,
            "issuer_name": 1.0,
            "extracted_text": 0.5 if payload.get("extracted_text") else 0.0,
        },
        evidence=evidence,
        confidence=0.5 if payload.get("extracted_text") else 0.2,
        status="ready",
    )


def handle_promote(conn, job):
    payload = dict(job["payload"] or {})
    draft_id = payload.get("draft_id")
    if not draft_id:
        raise ValueError("promote job is missing draft_id")

    product_id = promote_draft(conn, draft_id)
    logger.info("Promoted draft %s to card product %s", draft_id, product_id)
    complete_job(conn, job["id"])


def run_worker(job_type: str | None = None):
    conn = get_db()
    with httpx.Client(follow_redirects=True) as client:
        while True:
            job = fetch_next_job(conn)
            if not job:
                time.sleep(5)
                continue

            logger.info("Processing job %s of type %s", job["id"], job["job_type"])
            try:
                if job["job_type"] == "discover":
                    handle_discover(conn, job)
                elif job["job_type"] == "fetch":
                    handle_fetch(conn, client, job)
                elif job["job_type"] == "extract":
                    handle_extract(conn, job)
                elif job["job_type"] == "normalize":
                    handle_normalize(conn, job)
                elif job["job_type"] == "promote":
                    handle_promote(conn, job)
                else:
                    fail_job(conn, job["id"], "unknown job_type")
            except Exception as exc:  # noqa: BLE001
                logger.exception("Job failed")
                fail_job(conn, job["id"], str(exc))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--job-type", type=str, help="Specific job type to run (optional)")
    args = parser.parse_args()

    logger.info("Starting queue runner...")
    run_worker(job_type=args.job_type)
