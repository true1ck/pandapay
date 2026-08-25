#!/usr/bin/env bash
#
# End-to-end CardPipeline -> PandaPay draft catalogue sync.
#
# Safe to re-run while extraction continues. The collector snapshots only
# checklist rows marked done; the importer skips byte-identical cards, never
# publishes, and never writes verified_at.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIPELINE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)/CardPipeline"
OUT_DIR="$SCRIPT_DIR/.staging"
ADMIN_ID="${CARD_IMPORT_ADMIN_ID:-}"
DRY_RUN=false
FORCE=false
INCLUDE_UNLISTED=false

usage() {
  echo "Usage: sync_card_catalogue.sh [--pipeline <CardPipeline root>] [--out <dir>]"
  echo "       [--admin-id <admin_users.id>] [--dry-run] [--force] [--include-unlisted]"
  echo
  echo "CARD_IMPORT_ADMIN_ID may be used instead of --admin-id."
}

take_value() {
  local flag="$1"
  local value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    echo "$flag requires a value" >&2
    exit 1
  fi
  echo "$value"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pipeline)
      PIPELINE_ROOT="$(take_value "$1" "${2:-}")"
      shift 2
      ;;
    --out)
      OUT_DIR="$(take_value "$1" "${2:-}")"
      shift 2
      ;;
    --admin-id)
      ADMIN_ID="$(take_value "$1" "${2:-}")"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --include-unlisted)
      INCLUDE_UNLISTED=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$ADMIN_ID" ]]; then
  echo "--admin-id or CARD_IMPORT_ADMIN_ID is required." >&2
  exit 1
fi
if [[ ! -d "$PIPELINE_ROOT" ]]; then
  echo "CardPipeline directory does not exist: $PIPELINE_ROOT" >&2
  exit 1
fi

COLLECT_ARGS=(--pipeline "$PIPELINE_ROOT" --out "$OUT_DIR")
if [[ "$INCLUDE_UNLISTED" == true ]]; then COLLECT_ARGS+=(--include-unlisted); fi

IMPORT_ARGS=(
  --input "$OUT_DIR/all-collected.json"
  --admin-id "$ADMIN_ID"
  --report-dir "$OUT_DIR"
)
if [[ "$DRY_RUN" == true ]]; then IMPORT_ARGS+=(--dry-run); fi
if [[ "$FORCE" == true ]]; then IMPORT_ARGS+=(--force); fi

echo "==> Collecting accepted CardPipeline outputs"
node "$SCRIPT_DIR/collect_card_pipeline.js" "${COLLECT_ARGS[@]}"

echo
echo "==> Importing catalogue drafts"
node "$SCRIPT_DIR/import_card_pipeline.js" "${IMPORT_ARGS[@]}"

echo
echo "Sync complete. Cards remain drafts until a human publishes them."
