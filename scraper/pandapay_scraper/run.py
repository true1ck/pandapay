"""AD-3.2.5: job orchestration. `python -m pandapay_scraper.run [--source-id ID]`
runs every enabled+ToS-reviewed source (or one specific source for manual
"run now"), respecting the robots gate and rate limiter for every single
fetch, logging a scrape_runs row, and persisting a page_snapshots row only
when content_hash actually changed (AD-3.2.3 skip_unchanged).
"""

from __future__ import annotations

import argparse
import sys

import httpx

from . import db
from .extractor import extract
from .fetcher import fetch_static
from .rate_limit import PerHostRateLimiter
from .robots import RobotsChecker


def run_source(conn, client: httpx.Client, robots: RobotsChecker, limiter: PerHostRateLimiter, source: dict) -> None:
    pages = db.pages_for_source(conn, source["id"])
    run_id = db.start_scrape_run(conn, source["id"])
    fetched = 0
    changed = 0
    try:
        for page in pages:
            url = page["url"]

            robots_result = robots.is_allowed(url)
            db.update_robots_result(conn, source["id"], robots_result.allowed)
            if not robots_result.allowed:
                print(f"  SKIP (robots.txt disallows): {url}")
                continue

            limiter.wait_for_turn(url)

            try:
                result = fetch_static(client, url)
            except httpx.HTTPError as exc:
                failures = db.mark_page_failed(conn, page["id"])
                print(f"  FETCH FAILED ({exc}): {url} [{failures} consecutive failures]")
                if failures >= 3:
                    print(f"  ALERT: {url} has failed {failures} times in a row — investigate.")
                continue

            fetched += 1
            extracted = extract(result.html, selector_hint=page["selector_hint"])
            previous_hash = db.last_snapshot_hash(conn, page["id"])

            if extracted.content_hash == previous_hash:
                db.mark_page_crawled(conn, page["id"], changed=False)
                print(f"  unchanged: {url}")
                continue

            db.insert_snapshot(
                conn,
                source_page_id=page["id"],
                scrape_run_id=run_id,
                content_hash=extracted.content_hash,
                extracted_text=extracted.text,
                http_status=result.status_code,
            )
            db.mark_page_crawled(conn, page["id"], changed=True)
            changed += 1
            print(f"  CHANGED (new snapshot): {url}")

        db.finish_scrape_run(conn, run_id, status="success", pages_fetched=fetched, pages_changed=changed)
    except Exception as exc:  # noqa: BLE001 — a run's own bookkeeping must not be lost on any failure
        db.finish_scrape_run(
            conn, run_id, status="failed", pages_fetched=fetched, pages_changed=changed, error_text=str(exc)
        )
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description="PandaPay scraper — AD-3")
    parser.add_argument("--source-id", help="Run only this source (AD-3.2.5 manual 'run now')")
    args = parser.parse_args()

    conn = db.connect()
    robots = RobotsChecker(httpx.Client())
    limiter = PerHostRateLimiter()

    sources = db.enabled_sources(conn)
    if args.source_id:
        sources = [s for s in sources if str(s["id"]) == args.source_id]
        if not sources:
            print(f"No enabled+ToS-reviewed source with id {args.source_id}", file=sys.stderr)
            return 1

    if not sources:
        print("No enabled+ToS-reviewed sources to crawl.")
        return 0

    with httpx.Client() as client:
        for source in sources:
            print(f"Source: {source['name']} ({source['base_url']})")
            run_source(conn, client, robots, limiter, source)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
