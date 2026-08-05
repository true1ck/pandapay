"""Thin psycopg wrapper — the scraper connects as its own least-privilege
role (see db/setup_scraper_role.sql), same principle as api/'s app_user:
never the postgres superuser, so a scraper bug can't do more damage than a
scraper should be able to.
"""

from __future__ import annotations

import os
from contextlib import contextmanager
from typing import Any, Iterator

import psycopg
from psycopg.rows import dict_row


def connect() -> psycopg.Connection:
    database_url = os.environ.get("SCRAPER_DATABASE_URL")
    if not database_url:
        raise RuntimeError("SCRAPER_DATABASE_URL is not set (see scraper/example.env)")
    return psycopg.connect(database_url, row_factory=dict_row)


@contextmanager
def cursor(conn: psycopg.Connection) -> Iterator[psycopg.Cursor]:
    with conn.cursor() as cur:
        yield cur
    conn.commit()


def enabled_sources(conn: psycopg.Connection) -> list[dict[str, Any]]:
    """AD-3.1.2: only sources that are both is_enabled AND tos_reviewed are
    ever crawled — the DB CHECK constraint already guarantees is_enabled
    implies tos_reviewed, this query is just the read-side mirror of that
    guarantee, not a second independent gate.
    """
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM sources WHERE is_enabled = true AND tos_reviewed = true ORDER BY name"
        )
        return cur.fetchall()


def pages_for_source(conn: psycopg.Connection, source_id: str) -> list[dict[str, Any]]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT * FROM source_pages WHERE source_id = %s AND is_enabled = true ORDER BY url",
            (source_id,),
        )
        return cur.fetchall()


def update_robots_result(conn: psycopg.Connection, source_id: str, allowed: bool) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "UPDATE sources SET robots_allows = %s, robots_checked_at = now() WHERE id = %s",
            (allowed, source_id),
        )
    conn.commit()


def start_scrape_run(conn: psycopg.Connection, source_id: str, triggered_by: str = "manual") -> str:
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO scrape_runs (source_id, triggered_by, status, started_at)
               VALUES (%s, %s, 'running', now()) RETURNING id""",
            (source_id, triggered_by),
        )
        run_id = cur.fetchone()["id"]
    conn.commit()
    return str(run_id)


def finish_scrape_run(
    conn: psycopg.Connection,
    run_id: str,
    *,
    status: str,
    pages_fetched: int,
    pages_changed: int,
    error_text: str | None = None,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """UPDATE scrape_runs
                  SET status = %s, pages_fetched = %s, pages_changed = %s,
                      error_text = %s, finished_at = now(),
                      duration_ms = extract(epoch from (now() - started_at)) * 1000
                WHERE id = %s""",
            (status, pages_fetched, pages_changed, error_text, run_id),
        )
    conn.commit()


def last_snapshot(conn: psycopg.Connection, source_page_id: str) -> dict[str, Any] | None:
    with conn.cursor() as cur:
        cur.execute(
            """SELECT id, content_hash, extracted_text FROM page_snapshots
                WHERE source_page_id = %s
                ORDER BY captured_at DESC LIMIT 1""",
            (source_page_id,),
        )
        return cur.fetchone()


def insert_snapshot(
    conn: psycopg.Connection,
    *,
    source_page_id: str,
    scrape_run_id: str,
    content_hash: str,
    extracted_text: str,
    http_status: int,
) -> str:
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO page_snapshots
                 (source_page_id, scrape_run_id, content_hash, extracted_text, http_status)
               VALUES (%s, %s, %s, %s, %s)
               ON CONFLICT (source_page_id, content_hash) DO NOTHING
               RETURNING id""",
            (source_page_id, scrape_run_id, content_hash, extracted_text, http_status),
        )
        row = cur.fetchone()
    conn.commit()
    return str(row["id"]) if row else ""


def mark_page_crawled(conn: psycopg.Connection, source_page_id: str, *, changed: bool) -> None:
    with conn.cursor() as cur:
        if changed:
            cur.execute(
                """UPDATE source_pages
                      SET last_crawled_at = now(), last_changed_at = now(), consecutive_failures = 0
                    WHERE id = %s""",
                (source_page_id,),
            )
        else:
            cur.execute(
                "UPDATE source_pages SET last_crawled_at = now(), consecutive_failures = 0 WHERE id = %s",
                (source_page_id,),
            )
    conn.commit()


def find_open_alert(conn: psycopg.Connection, card_product_id: str, field_path: str) -> dict | None:
    with conn.cursor() as cur:
        cur.execute(
            """SELECT * FROM policy_change_alerts
                WHERE card_product_id = %s AND field_path = %s AND state = 'open'""",
            (card_product_id, field_path),
        )
        return cur.fetchone()


def create_alert(
    conn: psycopg.Connection,
    *,
    card_product_id: str,
    field_path: str,
    field_label: str,
) -> str:
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO policy_change_alerts
                 (card_product_id, field_path, field_label, signal_count,
                  distinct_signal_kinds, corroboration_score)
               VALUES (%s, %s, %s, 1, 1, 0.25)
               RETURNING id""",
            (card_product_id, field_path, field_label),
        )
        alert_id = cur.fetchone()["id"]
    conn.commit()
    return str(alert_id)


def reinforce_alert(conn: psycopg.Connection, alert_id: str, *, new_signal_kind: bool) -> None:
    """AD-4.5: a second signal on the SAME (card, field) corroborates the
    existing alert rather than fanning out into a new one — signal_count
    always increments, distinct_signal_kinds and corroboration_score only
    move when this is a genuinely different *kind* of signal (two
    scrape_diffs on the same page in a row shouldn't out-weigh one scrape
    agreeing with one user_report).
    """
    with conn.cursor() as cur:
        if new_signal_kind:
            cur.execute(
                """UPDATE policy_change_alerts
                      SET signal_count = signal_count + 1,
                          distinct_signal_kinds = distinct_signal_kinds + 1,
                          corroboration_score = LEAST(corroboration_score + 0.25, 1.0),
                          last_signal_at = now()
                    WHERE id = %s""",
                (alert_id,),
            )
        else:
            cur.execute(
                """UPDATE policy_change_alerts
                      SET signal_count = signal_count + 1, last_signal_at = now()
                    WHERE id = %s""",
                (alert_id,),
            )
    conn.commit()


def alert_has_signal_kind(conn: psycopg.Connection, alert_id: str, signal: str) -> bool:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT 1 FROM policy_alert_evidence WHERE alert_id = %s AND signal = %s LIMIT 1",
            (alert_id, signal),
        )
        return cur.fetchone() is not None


def insert_alert_evidence(
    conn: psycopg.Connection,
    *,
    alert_id: str,
    snapshot_id: str,
    excerpt: str,
) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO policy_alert_evidence (alert_id, signal, snapshot_id, excerpt)
               VALUES (%s, 'scrape_diff', %s, %s)""",
            (alert_id, snapshot_id, excerpt),
        )
    conn.commit()


def insert_extraction_proposal(
    conn: psycopg.Connection,
    *,
    snapshot_id: str,
    card_product_id: str,
    proposed_fields: dict,
    model_confidence: float,
    evidence_excerpt: str,
) -> str:
    import json

    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO extraction_proposals
                 (snapshot_id, card_product_id, model_name, proposed_fields,
                  model_confidence, evidence_excerpt)
               VALUES (%s, %s, 'heuristic-regex-v1', %s, %s, %s)
               RETURNING id""",
            (snapshot_id, card_product_id, json.dumps(proposed_fields), model_confidence, evidence_excerpt),
        )
        proposal_id = cur.fetchone()["id"]
    conn.commit()
    return str(proposal_id)


def mark_page_failed(conn: psycopg.Connection, source_page_id: str) -> int:
    """AD-3.2.5: failure alerting after 3 consecutive failures — returns the
    new failure count so the caller can decide whether to alert.
    """
    with conn.cursor() as cur:
        cur.execute(
            """UPDATE source_pages SET consecutive_failures = consecutive_failures + 1
                WHERE id = %s RETURNING consecutive_failures""",
            (source_page_id,),
        )
        count = cur.fetchone()["consecutive_failures"]
    conn.commit()
    return count
