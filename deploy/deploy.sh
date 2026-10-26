#!/usr/bin/env bash
#
# Deploys one commit to the production backend host.
#
# Run BY the GitHub Actions workflow (.github/workflows/deploy-prod.yml),
# which pipes this file over SSH — the script lives in the repo so it is
# reviewed and versioned like anything else, rather than existing only as a
# blob of shell inside a YAML step.
#
# Also safe to run by hand on the host:
#     bash deploy/deploy.sh <commit-sha>
#
# IDEMPOTENT. Re-running on the same commit re-applies migrations (they are
# all `if not exists` / `or replace`), rebuilds identical images, and
# restarts. Nothing accumulates.
#
# WHAT THIS DELIBERATELY DOES NOT DO
# ----------------------------------
# - It never publishes catalogue cards. Publishing writes `verified_at`,
#   which asserts a human checked that card's terms against the issuer.
#   See db/seed/0005_publish_demo_cards.sql.
# - It never runs db/seed/. Those are demo fixtures with approximate reward
#   rates; SEED_DEMO_DATA must stay false here.
# - It never replaces .env. Secrets live only on the host and are gitignored,
#   so `git reset --hard` below leaves them alone. The CI workflow may pass
#   notification-provider values explicitly; never the whole file is replaced.
set -euo pipefail

SHA="${1:?usage: deploy.sh <commit-sha>}"
APP_DIR="/home/ubuntu/apps/pandapay"
REPO="https://github.com/true1ck/pandapay.git"
BACKUP_DIR="/home/ubuntu/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

cd "$APP_DIR"

echo "==> Preflight: .env must exist (it is gitignored and host-only)"
test -s .env || { echo "FATAL: $APP_DIR/.env missing — refusing to deploy"; exit 1; }

echo "==> Preflight: validating service configuration keys"
check_single_env_key() {
  local key="$1"
  local count
  count="$(awk -v key="$key" 'index($0, key "=") == 1 { count++ } END { print count + 0 }' .env)"
  if [ "$count" -ne 1 ]; then
    echo "FATAL: .env must contain exactly one $key entry (found $count)"
    exit 1
  fi
  if ! grep -Eq "^${key}=.+" .env; then
    echo "FATAL: .env has an empty $key entry"
    exit 1
  fi
}

# Writes one allow-listed value into the host .env. The whole file is never
# replaced, only the named key, and the result keeps its 0600 permissions.
upsert_env_value() {
  local key="$1"
  local value="$2"
  local tmp=".env.tmp.$$"
  awk -v key="$key" -v value="$value" '
    BEGIN { replaced = 0 }
    index($0, key "=") == 1 {
      print key "=" value
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) print key "=" value
    }
  ' .env > "$tmp"
  chmod 600 "$tmp"
  mv "$tmp" .env
}

if ! grep -Eq '^PHONE_LOOKUP_HMAC_KEY=.{32,}$' .env; then
  echo "FATAL: .env must contain a stable PHONE_LOOKUP_HMAC_KEY of at least 32 characters"
  exit 1
fi

# Compose checks presence later, but these checks must happen before the
# backup/migration steps so a legacy or ambiguous .env cannot start a partial
# deployment. JWT_KEYS_JSON, when used, is validated by both services at
# startup, including its active key id and JSON shape.
for key in \
  ADMIN_DATABASE_URL \
  APP_USER_PASSWORD \
  API_DATABASE_URL \
  AUTH_DATABASE_URL \
  JWT_ACCESS_SECRET \
  JWT_REFRESH_SECRET \
  PHONE_LOOKUP_HMAC_KEY \
  INBOUND_EMAIL_WEBHOOK_SECRET \
  PARTNER_WEBHOOK_SECRET \
  IMAP_ENCRYPTION_KEY \
  CORS_ALLOWED_ORIGINS \
  ENCRYPTION_KEY; do
  check_single_env_key "$key"
done

for key in DATABASE_URL JWT_ISSUER JWT_AUDIENCE JWT_ACTIVE_KEY_ID; do
  if grep -Eq "^${key}=" .env; then
    check_single_env_key "$key"
  fi
done

# The notification provider is a server-side integration. Keep its project
# key out of the repository and mobile app; the workflow may provision only
# these two host values. The phone-lookup HMAC key remains host-only and stable.
if [ -n "${NOTIFICATION_SERVICE_URL:-}" ] || [ -n "${NOTIFICATION_SERVICE_API_KEY:-}" ]; then
  [ -n "${NOTIFICATION_SERVICE_URL:-}" ] || {
    echo "FATAL: NOTIFICATION_SERVICE_URL was not supplied"
    exit 1
  }
  [ -n "${NOTIFICATION_SERVICE_API_KEY:-}" ] || {
    echo "FATAL: NOTIFICATION_SERVICE_API_KEY was not supplied"
    exit 1
  }
  upsert_env_value NOTIFICATION_SERVICE_URL "$NOTIFICATION_SERVICE_URL"
  upsert_env_value NOTIFICATION_SERVICE_API_KEY "$NOTIFICATION_SERVICE_API_KEY"
  echo "    notification provider configuration updated"
fi

if [ -n "${GOOGLE_PLACES_API_KEY:-}" ]; then
  upsert_env_value GOOGLE_PLACES_API_KEY "$GOOGLE_PLACES_API_KEY"
  echo "    google places api key configuration updated"
fi

if [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${AI_WORKER_TOKEN:-}" ]; then
  [ -n "${GEMINI_API_KEY:-}" ] && [ -n "${AI_WORKER_TOKEN:-}" ] || {
    echo "FATAL: AI_WORKER_TOKEN and GEMINI_API_KEY must be supplied together"
    exit 1
  }
  upsert_env_value AI_WORKER_TOKEN "$AI_WORKER_TOKEN"
  upsert_env_value GEMINI_API_KEY "$GEMINI_API_KEY"
  [ -n "${GEMINI_FALLBACK_API_KEY:-}" ] && upsert_env_value GEMINI_FALLBACK_API_KEY "$GEMINI_FALLBACK_API_KEY"
  [ -n "${GEMINI_MODEL:-}" ] && upsert_env_value GEMINI_MODEL "$GEMINI_MODEL"
  [ -n "${GEMINI_FALLBACK_MODEL:-}" ] && upsert_env_value GEMINI_FALLBACK_MODEL "$GEMINI_FALLBACK_MODEL"
  upsert_env_value GEMINI_REQUESTS_PER_MINUTE "${GEMINI_REQUESTS_PER_MINUTE:-30}"
  echo "    Gemini worker configuration updated"
fi

# Gemini is a server-only, opt-in integration. Require a strong worker token
# when enabled, and persist only values supplied by the host operator/secret
# store. Never print either secret.
ensure_optional_env_key() {
  local key="$1"
  local count
  count="$(awk -v key="$key" 'index($0, key "=") == 1 { count++ } END { print count + 0 }' .env)"
  if [ "$count" -gt 1 ]; then
    echo "FATAL: .env must contain at most one $key entry (found $count)"
    exit 1
  fi
  if [ "$count" -eq 0 ]; then
    upsert_env_value "$key" ""
  fi
}
ensure_optional_env_key AI_WORKER_TOKEN
ensure_optional_env_key GEMINI_API_KEY
ensure_optional_env_key GEMINI_FALLBACK_API_KEY
ensure_optional_env_key GEMINI_MODEL
ensure_optional_env_key GEMINI_FALLBACK_MODEL
ensure_optional_env_key SMS_LEARNING_DATABASE_URL
ensure_optional_env_key SMS_LEARNING_HMAC_KEY
ensure_optional_env_key SMS_LEARNING_WORKER_DB_PASSWORD
AI_WORKER_TOKEN_VALUE="$(sed -n 's/^AI_WORKER_TOKEN=//p' .env | sed 's/^"//; s/"$//')"
GEMINI_API_KEY_VALUE="$(sed -n 's/^GEMINI_API_KEY=//p' .env | sed 's/^"//; s/"$//')"
if { [ -n "$AI_WORKER_TOKEN_VALUE" ] && [ -z "$GEMINI_API_KEY_VALUE" ]; } \
  || { [ -z "$AI_WORKER_TOKEN_VALUE" ] && [ -n "$GEMINI_API_KEY_VALUE" ]; }; then
  echo "FATAL: AI_WORKER_TOKEN and GEMINI_API_KEY must both be set or both be blank"
  exit 1
fi
if [ -n "$AI_WORKER_TOKEN_VALUE" ] && [ "${#AI_WORKER_TOKEN_VALUE}" -lt 32 ]; then
  echo "FATAL: AI_WORKER_TOKEN must contain at least 32 characters"
  exit 1
fi
SMS_LEARNING_DATABASE_URL_VALUE="$(sed -n 's/^SMS_LEARNING_DATABASE_URL=//p' .env | sed 's/^"//; s/"$//')"
SMS_LEARNING_HMAC_KEY_VALUE="$(sed -n 's/^SMS_LEARNING_HMAC_KEY=//p' .env | sed 's/^"//; s/"$//')"
if { [ -n "$SMS_LEARNING_DATABASE_URL_VALUE" ] && [ -z "$SMS_LEARNING_HMAC_KEY_VALUE" ]; } \
  || { [ -z "$SMS_LEARNING_DATABASE_URL_VALUE" ] && [ -n "$SMS_LEARNING_HMAC_KEY_VALUE" ]; }; then
  echo "FATAL: SMS_LEARNING_DATABASE_URL and SMS_LEARNING_HMAC_KEY must both be set or both be blank"
  exit 1
fi
if [ -n "$SMS_LEARNING_HMAC_KEY_VALUE" ] && [ "${#SMS_LEARNING_HMAC_KEY_VALUE}" -lt 32 ]; then
  echo "FATAL: SMS_LEARNING_HMAC_KEY must contain at least 32 characters"
  exit 1
fi
SMS_LEARNING_WORKER_DB_PASSWORD_VALUE="$(sed -n 's/^SMS_LEARNING_WORKER_DB_PASSWORD=//p' .env | sed 's/^"//; s/"$//')"
# Enabling the learner means configuring its dedicated DB URL (which embeds
# the login password) together with the bootstrap password — both set, or the
# worker stays disabled and both stay blank.
if { [ -n "$SMS_LEARNING_DATABASE_URL_VALUE" ] && [ -z "$SMS_LEARNING_WORKER_DB_PASSWORD_VALUE" ]; } \
  || { [ -z "$SMS_LEARNING_DATABASE_URL_VALUE" ] && [ -n "$SMS_LEARNING_WORKER_DB_PASSWORD_VALUE" ]; }; then
  echo "FATAL: SMS_LEARNING_DATABASE_URL and SMS_LEARNING_WORKER_DB_PASSWORD must both be set or both be blank"
  exit 1
fi
if [ -n "$SMS_LEARNING_WORKER_DB_PASSWORD_VALUE" ] && [ "${#SMS_LEARNING_WORKER_DB_PASSWORD_VALUE}" -lt 32 ]; then
  echo "FATAL: SMS_LEARNING_WORKER_DB_PASSWORD must contain at least 32 characters"
  exit 1
fi

echo "==> Backing up the database before migrating"
mkdir -p "$BACKUP_DIR"
DBURL="$(grep -E '^ADMIN_DATABASE_URL=' .env | cut -d= -f2- | tr -d '"'"'"'')"
if [ -n "$DBURL" ]; then
  # Client major version must be >= the server's or pg_dump refuses. Read
  # the server version and pull the matching image rather than pinning a
  # number here that silently rots — that pin is exactly what left twelve
  # consecutive nightly backups as 0-byte files.
  SERVER_MAJOR="$(docker run --rm -e U="$DBURL" postgres:17-alpine \
      sh -lc 'psql "$U" -tAc "show server_version;"' 2>/dev/null | cut -d. -f1 | tr -d '[:space:]')"
  IMG="postgres:${SERVER_MAJOR:-17}-alpine"
  docker pull -q "$IMG" >/dev/null
  docker run --rm -e U="$DBURL" "$IMG" \
    sh -lc 'pg_dump "$U" --no-owner --no-acl -Fc' > "$BACKUP_DIR/predeploy-$STAMP.dump"
  # A dump that cannot be listed is not a backup. Fail the deploy rather
  # than migrate with no way back.
  docker run --rm -v "$BACKUP_DIR:/b" "$IMG" pg_restore -l "/b/predeploy-$STAMP.dump" > /dev/null
  echo "    backup ok: $(du -h "$BACKUP_DIR/predeploy-$STAMP.dump" | cut -f1)"
else
  echo "FATAL: ADMIN_DATABASE_URL not found in .env — refusing to migrate without a backup"
  exit 1
fi

echo "==> Syncing working tree to $SHA"
if [ ! -d .git ]; then
  # First run converts the copied directory into a real checkout in place.
  # `git init` + fetch + reset (rather than a fresh clone) is what preserves
  # .env and the backups directory that already live here.
  echo "    no .git — initialising in place (preserves untracked .env)"
  git init -q
  git remote add origin "$REPO"
fi
git remote set-url origin "$REPO"
git fetch -q --depth=50 origin "$SHA" 2>/dev/null || git fetch -q origin master
git reset -q --hard "$SHA"
git clean -qfd -e .env -e .env.prod -e node_modules
echo "    now at: $(git log --oneline -1)"

echo "==> Applying migrations"
# db-migrate is a one-shot service; --exit-code-from surfaces a failed
# migration as a failed deploy instead of a container that quietly exited 1.
docker compose -f docker-compose.prod.yml --env-file .env \
  up --build --abort-on-container-exit --exit-code-from db-migrate db-migrate

echo "==> Rebuilding and restarting services"
bash deploy/restart-services.sh

echo "==> Waiting for health"
for i in $(seq 1 30); do
  if curl -fsS -m 5 http://127.0.0.1:4000/ready >/dev/null 2>&1 \
     && curl -fsS -m 5 http://127.0.0.1:3210/ready >/dev/null 2>&1; then
    echo "    healthy after ${i}0s"
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "FATAL: services did not become healthy"
    docker compose -f docker-compose.prod.yml logs --tail=40 api auth
    exit 1
  fi
  sleep 10
done

echo "==> Pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

echo "==> Deployed $SHA"
