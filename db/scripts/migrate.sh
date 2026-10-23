#!/usr/bin/env bash
# One orchestration path for product schema, auth schema and required data jobs.
set -Eeuo pipefail
: "${ADMIN_DATABASE_URL:?ADMIN_DATABASE_URL is required}"
AUTH_MIGRATION_DATABASE_URL="${AUTH_MIGRATION_DATABASE_URL:-${AUTH_DATABASE_URL:-}}"
: "${AUTH_MIGRATION_DATABASE_URL:?AUTH_MIGRATION_DATABASE_URL or AUTH_DATABASE_URL is required}"
: "${APP_USER_PASSWORD:?APP_USER_PASSWORD must be explicitly configured}"
: "${REWARD_WORKER_DB_PASSWORD:?REWARD_WORKER_DB_PASSWORD must be explicitly configured}"
: "${PHONE_LOOKUP_HMAC_KEY:?The existing PHONE_LOOKUP_HMAC_KEY is required}"
DB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AUTH_APP_DIR="${AUTH_APP_DIR:-$(cd "$DB_DIR/.." && pwd)/auth}"
# A blank optional SMS worker password leaves its newer dedicated role untouched.
: "${SMS_LEARNING_WORKER_DB_PASSWORD-}"
export DB_DIR AUTH_APP_DIR AUTH_MIGRATION_DATABASE_URL APP_USER_PASSWORD REWARD_WORKER_DB_PASSWORD SMS_LEARNING_WORKER_DB_PASSWORD
command -v node >/dev/null || { echo 'Node.js is required by the canonical migration runner' >&2; exit 1; }
node "$DB_DIR/scripts/product_migrate.js"
node "$AUTH_APP_DIR/scripts/migrate.js"
echo 'Product/auth schema migrations and required auth backfill verified'
