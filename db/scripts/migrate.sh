#!/usr/bin/env bash
#
# Applies the product database migrations against ADMIN_DATABASE_URL and the
# separate auth database migrations against AUTH_DATABASE_URL. Both ledgers
# are independent because the services use different databases.
#
# Usage:
#   ADMIN_DATABASE_URL=postgres://postgres:...@host:5432/pandapay \
#   AUTH_DATABASE_URL=postgres://postgres:...@host:5432/pandapay_auth \
#   SEED_DEMO_DATA=false \
#     ./migrate.sh
#
# ADMIN_DATABASE_URL must be a superuser (or equivalently privileged) role —
# same reason db/setup_app_role.sql's grants need one: creating app_user and
# granting across the pandapay schema isn't something app_user itself could
# ever do.

set -Eeuo pipefail

: "${ADMIN_DATABASE_URL:?ADMIN_DATABASE_URL must be set (superuser connection to the target database)}"
: "${AUTH_DATABASE_URL:?AUTH_DATABASE_URL must be set (privileged connection to the auth database)}"
# db/setup_app_role.sql falls back to the committed dev literal
# (app_user_dev_pw) when this is unset — fine for docker-compose.yml's local
# dev flow, not acceptable for anything reachable from the internet. Required
# here so a staging/prod run can't silently ship the dev password.
: "${APP_USER_PASSWORD:?APP_USER_PASSWORD must be set to a real generated password — the dev literal is not safe outside docker-compose.yml}"
: "${REWARD_WORKER_DB_PASSWORD:?REWARD_WORKER_DB_PASSWORD must be set to a distinct generated worker-login password}"
export APP_USER_PASSWORD REWARD_WORKER_DB_PASSWORD
SEED_DEMO_DATA="${SEED_DEMO_DATA:-false}"
DB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH_MIGRATIONS_DIR="${AUTH_MIGRATIONS_DIR:-$(cd "$DB_DIR/.." && pwd)/auth/db/migrations}"

PSQL="psql $ADMIN_DATABASE_URL -v ON_ERROR_STOP=1 -q"

$PSQL -c "create table if not exists schema_migrations (
             filename text primary key,
             applied_at timestamptz not null default now())"

$PSQL -f "$DB_DIR/setup_app_role.sql"

for f in "$DB_DIR"/supabase/migrations/*.sql; do
  name="$(basename "$f")"
  case "$name" in
    0013_cron_jobs.sql)
      # Same gap as local dev and CI: pg_cron isn't in the stock postgres
      # image. If the target Postgres is a managed instance that DOES offer
      # pg_cron (e.g. RDS, Cloud SQL), apply this one by hand once — it is
      # deliberately not silently skipped-forever, just skipped by this script.
      echo "skip    $name (pg_cron unavailable in this runner — apply manually if the target supports it)"
      continue
      ;;
  esac
  already=$($PSQL -tAc "select 1 from schema_migrations where filename = '$name'")
  if [ "$already" = "1" ]; then
    echo "skip    $name (already applied)"
    continue
  fi
  echo "apply   $name"
  $PSQL -f "$f"
  $PSQL -c "insert into schema_migrations (filename) values ('$name')"
done

$PSQL -f "$DB_DIR/setup_app_role.sql"

if [ "$SEED_DEMO_DATA" = "true" ]; then
  for f in "$DB_DIR"/seed/*.sql; do
    name="seed:$(basename "$f")"
    already=$($PSQL -tAc "select 1 from schema_migrations where filename = '$name'")
    if [ "$already" = "1" ]; then
      echo "skip    $name (already applied)"
      continue
    fi
    echo "seed    $name"
    $PSQL -f "$f"
    $PSQL -c "insert into schema_migrations (filename) values ('$name')"
  done
else
  echo "skip    demo seeds (SEED_DEMO_DATA=false)"
fi

AUTH_PSQL="psql $AUTH_DATABASE_URL -v ON_ERROR_STOP=1 -q"
$AUTH_PSQL -c "create table if not exists auth_schema_migrations (
                 version text primary key,
                 applied_at timestamptz not null default now())"

for f in "$AUTH_MIGRATIONS_DIR"/*.sql; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  version="${name%.sql}"
  already=$($AUTH_PSQL -tAc "select 1 from auth_schema_migrations where version = '$version'")
  if [ "$already" = "1" ]; then
    echo "skip    auth/$name (already applied)"
    continue
  fi
  echo "apply   auth/$name"
  $AUTH_PSQL -f "$f"
  $AUTH_PSQL -c "insert into auth_schema_migrations (version) values ('$version')"
done

echo "product and auth migrations complete"
