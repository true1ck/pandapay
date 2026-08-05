#!/usr/bin/env bash
# AD-3.2.5: weekly default crawl. Invoked by cron or a systemd timer (see
# pandapay-scraper.timer in this directory) — not run automatically by
# anything in this repo, since db.enabled_sources() returns nothing until a
# real source is added and ToS-reviewed (still true as of this writing;
# db/supabase/migrations/0011 seeds none, see PROGRESS.md item 1). Safe to
# schedule right now regardless: main() exits cleanly with "No enabled+ToS-
# reviewed sources to crawl." when the sources table is empty.
set -euo pipefail

SCRAPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRAPER_DIR"

if [ -d .venv ]; then
  source .venv/bin/activate
fi

LOG_DIR="${PANDAPAY_SCRAPER_LOG_DIR:-$SCRAPER_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run-$(date +%Y%m%dT%H%M%S).log"

python -m pandapay_scraper.run "$@" >>"$LOG_FILE" 2>&1
echo "Log written to $LOG_FILE"
