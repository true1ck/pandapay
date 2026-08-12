#!/usr/bin/env bash
#
# Plan Phase 0.1 — a real logical backup, replacing the stub.
#
# `POST /backup-runs` in api/src/index.js declares in its own doc comment that
# it is a stub: it inserts a `backup_runs` row claiming success and performs no
# backup. For a personal-finance app that is the single highest-severity gap in
# the whole system — a lost database today is permanent, total user data loss,
# and the `backup_runs` table would show a clean history of successes right up
# until the moment someone tried to restore.
#
# This script is the thing that was missing. It is deliberately a plain
# pg_dump + verify + record + prune, not a bespoke backup system:
#
#   * A managed Postgres with point-in-time recovery is still the primary
#     protection and this does not replace it. PITR covers "the database was
#     corrupted eleven minutes ago"; a logical dump covers "a migration
#     dropped the wrong column last Tuesday" and "we need to move providers",
#     which PITR windows typically do not.
#   * It writes an honest `backup_runs` row — status 'failed' on failure,
#     with the real error — so the table stops being a record of a stub.
#
# Usage:
#   DATABASE_URL=postgres://... BACKUP_DIR=/var/backups/pandapay ./backup.sh
#
# Exit codes: 0 success, non-zero failure (so a cron/systemd unit can alert).

set -Eeuo pipefail

: "${DATABASE_URL:?DATABASE_URL must be set}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pandapay}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
ARCHIVE="${BACKUP_DIR}/pandapay-${STAMP}.dump"

mkdir -p "$BACKUP_DIR"

# Records the outcome in `backup_runs` whatever happens. Deliberately runs on
# the failure path too: a backup system whose failures are invisible is worse
# than none, because it manufactures confidence.
# Column names checked against the real table, not assumed: backup_runs has
# `size_bytes` and `error_text` (0009_platform_ops.sql), NOT a `notes` column.
# An INSERT naming a column that doesn't exist fails silently under the
# `|| echo WARN` below, which would have left this script appearing to work
# while recording nothing at all.
record_run() {
  local status="$1" location="$2" size="${3:-NULL}" err="${4:-}"
  local err_sql="NULL"
  [ -n "$err" ] && err_sql="\$\$${err}\$\$"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c \
    "INSERT INTO backup_runs (kind, status, location, size_bytes, error_text)
     VALUES ('logical', '${status}', '${location}', ${size}, ${err_sql})" \
    >/dev/null 2>&1 || echo "WARN: could not write backup_runs row" >&2
}

on_error() {
  local line="$1"
  record_run 'failed' "${ARCHIVE}" NULL "backup.sh failed at line ${line}"
  echo "BACKUP FAILED at line ${line}" >&2
}
trap 'on_error $LINENO' ERR

echo "==> Dumping to ${ARCHIVE}"
# --format=custom so pg_restore can do selective/parallel restores; a plain SQL
# dump can only be replayed whole, which is the wrong tool when the incident is
# "one table needs rolling back".
pg_dump "$DATABASE_URL" \
  --format=custom \
  --compress=9 \
  --no-owner \
  --no-privileges \
  --file="$ARCHIVE"

echo "==> Verifying"
# A dump that cannot be listed cannot be restored. `pg_restore --list` parses
# the archive's table of contents and fails on a truncated or corrupt file —
# catching the "disk filled up halfway through" case that otherwise only
# surfaces during an actual emergency.
pg_restore --list "$ARCHIVE" >/dev/null

SIZE="$(wc -c < "$ARCHIVE" | tr -d ' ')"
if [ "$SIZE" -lt 1024 ]; then
  echo "Dump is implausibly small (${SIZE} bytes) — treating as a failure" >&2
  exit 1
fi
echo "==> OK (${SIZE} bytes)"

record_run 'success' "${ARCHIVE}" "${SIZE}"

echo "==> Pruning backups older than ${RETENTION_DAYS} days"
# Pruning runs only after a verified success, so a run of failures can never
# delete the last good backup.
find "$BACKUP_DIR" -name 'pandapay-*.dump' -type f -mtime "+${RETENTION_DAYS}" -delete

echo "==> Done"
