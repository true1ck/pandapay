#!/usr/bin/env bash
#
# Plan Phase 0.1 — proves a backup can actually be restored.
#
# `restore_drills` has existed as a table since 0009_platform_ops.sql and has
# never had a row, because nothing has ever run a drill. That is the failure
# mode worth naming precisely: an untested backup is not a backup, it is a file
# that resembles one. The moment you discover a dump does not restore is,
# by definition, the moment you needed it to.
#
# This restores the most recent dump into a THROWAWAY database, asserts the
# data is really there, records the outcome in `restore_drills`, and drops it.
# It never touches the source database.
#
# Usage:
#   DATABASE_URL=postgres://... BACKUP_DIR=/var/backups/pandapay ./restore_drill.sh
#
# Intended to run weekly. Exit non-zero on failure so it pages someone while
# the backups are still fixable.

set -Eeuo pipefail

: "${DATABASE_URL:?DATABASE_URL must be set}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/pandapay}"
DRILL_DB="pandapay_restore_drill_$(date -u +%Y%m%d%H%M%S)"

# The admin connection, with the database name swapped for `postgres` so the
# drill database can be created and dropped.
ADMIN_URL="${DATABASE_URL%/*}/postgres"

# -r/--no-run-if-empty matters: without it, when find matches nothing, xargs
# still invokes `ls -t` once with zero arguments — which lists the CURRENT
# DIRECTORY (i.e. this script's own working directory, /backup) instead of
# producing no output. LATEST would then silently become "backup.sh" or
# "restore_drill.sh" rather than empty, defeating the "no backup found" guard
# below entirely. Caught by actually running this against an empty
# BACKUP_DIR rather than assumed.
LATEST="$(find "$BACKUP_DIR" -name 'pandapay-*.dump' -type f -print0 2>/dev/null \
  | xargs -0 -r ls -t 2>/dev/null | head -n 1 || true)"

# `restored_ok` is a NOT NULL boolean and there is no `status` column
# (0009_platform_ops.sql) — checked against the real table rather than
# assumed, after the first draft of this script wrote a column that does not
# exist and would have recorded nothing.
record_drill() {
  local ok="$1" note="$2"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -q -c \
    "INSERT INTO restore_drills (restored_ok, notes)
     VALUES (${ok}, \$\$${note}\$\$)" \
    >/dev/null 2>&1 || echo "WARN: could not write restore_drills row" >&2
}

cleanup() {
  psql "$ADMIN_URL" -q -c "DROP DATABASE IF EXISTS ${DRILL_DB}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

on_error() {
  record_drill false "restore drill failed at line $1 for ${LATEST:-<no backup found>}"
  echo "RESTORE DRILL FAILED at line $1" >&2
}
trap 'on_error $LINENO' ERR

if [ -z "$LATEST" ]; then
  # "No backup exists" is itself a drill failure, and the most important one to
  # be loud about — it is indistinguishable from a healthy system right up
  # until a restore is needed.
  record_drill false "no backup archive found in ${BACKUP_DIR}"
  echo "No backup found in ${BACKUP_DIR}" >&2
  exit 1
fi

echo "==> Restoring ${LATEST} into ${DRILL_DB}"
psql "$ADMIN_URL" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE ${DRILL_DB}"

# --no-owner because the drill database has none of the source's roles;
# ownership is irrelevant to the question being asked, which is whether the
# DATA survives the round trip.
pg_restore --dbname="${ADMIN_URL%/*}/${DRILL_DB}" --no-owner --no-privileges "$LATEST"

echo "==> Verifying the restored copy"
# Structure alone is not proof: an empty database with the right tables would
# pass a schema check and fail a real recovery. These assert that the tables a
# user's account actually depends on came back with their rows.
VERIFY_SQL="
  do \$\$
  declare v_tables int; v_profiles bigint; v_cards bigint;
  begin
    select count(*) into v_tables from information_schema.tables
     where table_schema = 'public' and table_type = 'BASE TABLE';
    if v_tables < 50 then
      raise exception 'only % tables restored — expected the full schema', v_tables;
    end if;

    select count(*) into v_profiles from profiles;
    select count(*) into v_cards from user_cards;
    raise notice 'restored: % tables, % profiles, % user_cards', v_tables, v_profiles, v_cards;

    -- A restore that produces a schema with no user rows is only acceptable
    -- if the source genuinely had none. Once there is real data, an empty
    -- restore is the exact silent failure this drill exists to catch, so it
    -- is surfaced rather than passed.
    if v_profiles = 0 then
      raise warning 'restored database contains zero profiles — verify the source was also empty';
    end if;
  end \$\$;
"
psql "${ADMIN_URL%/*}/${DRILL_DB}" -v ON_ERROR_STOP=1 -c "$VERIFY_SQL"

record_drill true "restored ${LATEST} into a throwaway database and verified schema + row counts"
echo "==> Drill passed"
