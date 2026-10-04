#!/usr/bin/env bash
set -Eeuo pipefail

# Host-native development backend. This uses the local Postgres/Redis services
# on the developer machine and never reads the hosted API/auth .env files.
# The Android emulator reaches these services through 10.0.2.2.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PG_USER="${PANDAPAY_LOCAL_PG_USER:-$(whoami)}"
PG_HOST="${PANDAPAY_LOCAL_PG_HOST:-127.0.0.1}"
PG_PORT="${PANDAPAY_LOCAL_PG_PORT:-5432}"
LOG_DIR="${PANDAPAY_LOCAL_LOG_DIR:-/tmp/pandapay-local}"

mkdir -p "$LOG_DIR"

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required for the local backend." >&2
  exit 1
fi

if ! pg_isready -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" >/dev/null 2>&1; then
  echo "Postgres is not ready at $PG_HOST:$PG_PORT for user $PG_USER." >&2
  echo "Start the local PostgreSQL service, then run this script again." >&2
  exit 1
fi

if ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d pandapay -Atc \
  "select to_regclass('public.card_products')" | rg -q . || \
   ! psql -h "$PG_HOST" -p "$PG_PORT" -U "$PG_USER" -d pandapay_auth -Atc \
  "select to_regclass('public.users')" | rg -q .; then
  echo "Local database schema is incomplete. Expected pandapay and pandapay_auth to be migrated." >&2
  echo "Run the repository database setup/migrations before starting the backend." >&2
  exit 1
fi

if lsof -nP -iTCP:4000 -sTCP:LISTEN >/dev/null 2>&1 || \
   lsof -nP -iTCP:3210 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 4000 or 3210 is already in use. Stop the existing backend first." >&2
  exit 1
fi

API_DATABASE_URL="postgresql://${PG_USER}@${PG_HOST}:${PG_PORT}/pandapay"
AUTH_DATABASE_URL="postgresql://${PG_USER}@${PG_HOST}:${PG_PORT}/pandapay_auth"

env \
  DATABASE_URL="$API_DATABASE_URL" \
  DB_SSL=false \
  PORT=4000 \
  JWT_ACCESS_SECRET=dev_access_secret_change_me \
  node "$ROOT_DIR/api/src/index.js" >"$LOG_DIR/api.log" 2>&1 &
API_PID=$!

env \
  DATABASE_URL="$AUTH_DATABASE_URL" \
  DB_SSL=false \
  PORT=3210 \
  NODE_ENV=development \
  ALLOW_TEST_OTP=true \
  JWT_ACCESS_SECRET=dev_access_secret_change_me \
  JWT_REFRESH_SECRET=dev_refresh_secret_change_me \
  EMAIL_HOST= \
  EMAIL_USER= \
  EMAIL_PASS= \
  EMAIL_FROM= \
  ENABLE_ADMIN_DASHBOARD=false \
  node "$ROOT_DIR/auth/src/index.js" >"$LOG_DIR/auth.log" 2>&1 &
AUTH_PID=$!

cleanup() {
  kill "$API_PID" "$AUTH_PID" 2>/dev/null || true
  wait "$API_PID" "$AUTH_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

for i in $(seq 1 30); do
  if curl -fsS http://127.0.0.1:4000/health >/dev/null 2>&1 && \
     curl -fsS http://127.0.0.1:3210/health >/dev/null 2>&1; then
    printf 'Local PandaPay backend is running.\nAPI:  http://127.0.0.1:4000 (emulator: http://10.0.2.2:4000)\nAuth: http://127.0.0.1:3210 (emulator: http://10.0.2.2:3210)\nPIDs: %s %s\nLogs: %s\n' "$API_PID" "$AUTH_PID" "$LOG_DIR"
    wait "$API_PID" "$AUTH_PID"
    exit $?
  fi
  sleep 1
done

echo "Local backend did not become healthy. Check $LOG_DIR/api.log and $LOG_DIR/auth.log." >&2
exit 1
