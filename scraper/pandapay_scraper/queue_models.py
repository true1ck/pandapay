from __future__ import annotations

from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, Field

try:  # pragma: no cover - exercised implicitly when psycopg is installed
    from psycopg.types.json import Jsonb
except ImportError:  # pragma: no cover - lets unit tests run without psycopg
    def Jsonb(value):
        return value


try:  # pragma: no cover - the real environment provides this
    from . import db as scraper_db
except Exception:  # pragma: no cover - module remains importable for unit tests
    scraper_db = None


class CardTarget(BaseModel):
    id: Optional[str] = None
    issuer_name: str
    card_name: str
    card_key: str
    aliases: List[str] = Field(default_factory=list)
    status: str = "pending"
    coverage_priority: int = 100
    notes: Optional[str] = None


class CardCrawlJob(BaseModel):
    id: Optional[str] = None
    card_target_id: Optional[str] = None
    source_id: Optional[str] = None
    source_page_id: Optional[str] = None
    job_type: str
    priority: int = 100
    state: str = "queued"
    attempts: int = 0
    next_run_at: Optional[datetime] = None
    last_error: Optional[str] = None
    payload: Dict[str, Any] = Field(default_factory=dict)


def get_db():
    if scraper_db is None:
        raise RuntimeError("SCRAPER_DATABASE_URL is not available in this test environment")
    return scraper_db.connect()


@contextmanager
def _cursor(conn):
    with conn.cursor() as cur:
        yield cur
    if hasattr(conn, "commit"):
        conn.commit()


def upsert_target(conn, target: CardTarget) -> str:
    payload = target.model_dump(exclude_none=True)
    payload["aliases"] = Jsonb(payload.get("aliases", []))
    with _cursor(conn) as cur:
        cur.execute(
            """
            INSERT INTO card_targets (issuer_name, card_name, card_key, aliases, status, coverage_priority, notes)
            VALUES (%s, %s, %s, %s, %s, %s, %s)
            ON CONFLICT (card_key) DO UPDATE SET
              issuer_name = EXCLUDED.issuer_name,
              card_name = EXCLUDED.card_name,
              aliases = EXCLUDED.aliases,
              status = EXCLUDED.status,
              coverage_priority = EXCLUDED.coverage_priority,
              notes = EXCLUDED.notes,
              updated_at = now()
            RETURNING id
            """,
            (
                payload["issuer_name"],
                payload["card_name"],
                payload["card_key"],
                payload["aliases"],
                payload.get("status", "pending"),
                payload.get("coverage_priority", 100),
                payload.get("notes"),
            ),
        )
        row = cur.fetchone()
    return str(row["id"])


def queue_job(conn, job: CardCrawlJob) -> str:
    if not job.card_target_id:
        raise ValueError("card_target_id is required for queue jobs")

    payload = job.model_dump(exclude_none=True, mode="json")
    next_run_at = payload.pop("next_run_at", None)
    if next_run_at is None:
        next_run_at = datetime.now(timezone.utc)

    with _cursor(conn) as cur:
        cur.execute(
            """
            INSERT INTO card_crawl_jobs (
              card_target_id, source_id, source_page_id, job_type, priority,
              state, attempts, next_run_at, last_error, payload
            )
            VALUES (
              %s, %s, %s, %s, %s,
              %s, %s, %s, %s, %s
            )
            ON CONFLICT (
              card_target_id,
              COALESCE(source_id, '00000000-0000-0000-0000-000000000000'::uuid),
              COALESCE(source_page_id, '00000000-0000-0000-0000-000000000000'::uuid),
              job_type
            ) DO UPDATE SET
              priority = LEAST(card_crawl_jobs.priority, EXCLUDED.priority),
              state = CASE
                WHEN card_crawl_jobs.state IN ('queued', 'running') THEN card_crawl_jobs.state
                ELSE EXCLUDED.state
              END,
              attempts = CASE
                WHEN card_crawl_jobs.state IN ('queued', 'running') THEN GREATEST(card_crawl_jobs.attempts, EXCLUDED.attempts)
                ELSE EXCLUDED.attempts
              END,
              next_run_at = CASE
                WHEN card_crawl_jobs.state IN ('queued', 'running') THEN LEAST(card_crawl_jobs.next_run_at, EXCLUDED.next_run_at)
                ELSE EXCLUDED.next_run_at
              END,
              last_error = COALESCE(EXCLUDED.last_error, card_crawl_jobs.last_error),
              payload = card_crawl_jobs.payload || EXCLUDED.payload,
              updated_at = now()
            RETURNING id
            """,
            (
                job.card_target_id,
                job.source_id,
                job.source_page_id,
                job.job_type,
                job.priority,
                job.state,
                job.attempts,
                next_run_at,
                job.last_error,
                Jsonb(payload.get("payload", {})),
            ),
        )
        row = cur.fetchone()
    return str(row["id"])


def fetch_next_job(conn) -> Optional[dict]:
    with _cursor(conn) as cur:
        cur.execute(
            """
            WITH next_job AS (
              SELECT id
                FROM card_crawl_jobs
               WHERE state = 'queued'
                 AND next_run_at <= now()
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
            """
        )
        return cur.fetchone()


def complete_job(conn, job_id: str, next_job_type: Optional[str] = None, payload: dict | None = None):
    with _cursor(conn) as cur:
        cur.execute(
            """
            UPDATE card_crawl_jobs
               SET state = 'succeeded',
                   last_error = NULL,
                   updated_at = now()
             WHERE id = %s
            RETURNING card_target_id, source_id, source_page_id, priority, payload
            """,
            (job_id,),
        )
        row = cur.fetchone()

    if next_job_type and row:
        merged_payload = dict(row["payload"] or {})
        if payload:
            merged_payload.update(payload)
        queue_job(
            conn,
            CardCrawlJob(
                card_target_id=str(row["card_target_id"]),
                source_id=str(row["source_id"]) if row["source_id"] else None,
                source_page_id=str(row["source_page_id"]) if row["source_page_id"] else None,
                job_type=next_job_type,
                priority=int(row["priority"]),
                payload=merged_payload,
            ),
        )


def fail_job(conn, job_id: str, error: str):
    with _cursor(conn) as cur:
        cur.execute(
            """
            UPDATE card_crawl_jobs
               SET last_error = %s,
                   state = CASE WHEN attempts >= 3 THEN 'failed' ELSE 'queued' END,
                   next_run_at = CASE
                     WHEN attempts >= 3 THEN next_run_at
                     ELSE now() + make_interval(mins => attempts * 5)
                   END,
                   updated_at = now()
             WHERE id = %s
            RETURNING state
            """,
            (error, job_id),
        )
        row = cur.fetchone()
    return row["state"] if row else "failed"
