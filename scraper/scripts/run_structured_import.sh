#!/usr/bin/env bash
# Structured card import wrapper. Fetches a free structured dataset such as
# CardAdvisor's Indian cards export and writes normalized drafts to the DB.
#
# Required when writing to the DB:
#   STRUCTURED_IMPORT_SOURCE_ID
#   or STRUCTURED_IMPORT_SOURCE_BASE_URL
#   or STRUCTURED_IMPORT_SOURCE_NAME
#
# One of the following must be set:
#   STRUCTURED_IMPORT_INPUT     local JSON/CSV file path
#   STRUCTURED_IMPORT_INPUT_URL  remote JSON/CSV URL
set -euo pipefail

SCRAPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRAPER_DIR"

if [ -d .venv ]; then
  source .venv/bin/activate
fi

LOG_DIR="${PANDAPAY_SCRAPER_LOG_DIR:-$SCRAPER_DIR/logs}"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/structured-import-$(date +%Y%m%dT%H%M%S).log"

ARGS=()
if [ -n "${STRUCTURED_IMPORT_INPUT_URL:-}" ]; then
  ARGS+=(--input-url "$STRUCTURED_IMPORT_INPUT_URL")
elif [ -n "${STRUCTURED_IMPORT_INPUT:-}" ]; then
  ARGS+=(--input "$STRUCTURED_IMPORT_INPUT")
else
  echo "STRUCTURED_IMPORT_INPUT or STRUCTURED_IMPORT_INPUT_URL must be set" >&2
  exit 2
fi

if [ -n "${STRUCTURED_IMPORT_SOURCE_ID:-}" ]; then
  ARGS+=(--source-id "$STRUCTURED_IMPORT_SOURCE_ID")
elif [ -n "${STRUCTURED_IMPORT_SOURCE_BASE_URL:-}" ]; then
  ARGS+=(--source-base-url "$STRUCTURED_IMPORT_SOURCE_BASE_URL")
elif [ -n "${STRUCTURED_IMPORT_SOURCE_NAME:-}" ]; then
  ARGS+=(--source-name "$STRUCTURED_IMPORT_SOURCE_NAME")
else
  echo "One of STRUCTURED_IMPORT_SOURCE_ID, STRUCTURED_IMPORT_SOURCE_BASE_URL, or STRUCTURED_IMPORT_SOURCE_NAME must be set" >&2
  exit 2
fi

if [ -n "${STRUCTURED_IMPORT_SOURCE_URL:-}" ]; then
  ARGS+=(--source-url "$STRUCTURED_IMPORT_SOURCE_URL")
fi

if [ -n "${STRUCTURED_IMPORT_SOURCE_CLASS:-}" ]; then
  ARGS+=(--source-class "$STRUCTURED_IMPORT_SOURCE_CLASS")
fi

if [ -n "${STRUCTURED_IMPORT_SOURCE_LICENSE:-}" ]; then
  ARGS+=(--source-license "$STRUCTURED_IMPORT_SOURCE_LICENSE")
fi

python -m pandapay_scraper.structured_import "${ARGS[@]}" --write-db >>"$LOG_FILE" 2>&1
echo "Log written to $LOG_FILE"
