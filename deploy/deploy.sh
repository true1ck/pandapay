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
#     bash deploy/deploy.sh <commit-sha> [source-ref]
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

SHA="${1:?usage: deploy.sh <commit-sha> [source-ref]}"
SOURCE_REF="${2:-master}"
APP_DIR="/home/ubuntu/apps/pandapay"
REPO="https://github.com/true1ck/pandapay.git"

cd "$APP_DIR"

# API/auth and data-writing workers stay fenced from the paired final backup
# until the new migrations and service health checks pass. The window covers
# the stopped-service work
# as a whole; a timeout after source replacement intentionally leaves them
# stopped for forward recovery rather than starting an old binary on a new DB.
MAINTENANCE_WINDOW_SECONDS="${DEPLOY_MAINTENANCE_WINDOW_SECONDS:-1800}"
[[ "$MAINTENANCE_WINDOW_SECONDS" =~ ^[1-9][0-9]*$ ]] && (( MAINTENANCE_WINDOW_SECONDS >= 300 && MAINTENANCE_WINDOW_SECONDS <= 7200 )) || {
  echo 'FATAL: DEPLOY_MAINTENANCE_WINDOW_SECONDS must be 300..7200 seconds'
  exit 1
}
command -v timeout >/dev/null || { echo 'FATAL: timeout is required for the bounded maintenance window' >&2; exit 1; }
MAINTENANCE_DEADLINE=0
SERVICES_FENCED=0
SOURCE_REPLACEMENT_STARTED=0
DEPLOY_BACKUP_STAGE=''
DEPLOY_TARGET_STAGE=''
DB_CA_TEMP=''
OLD_WRITER_CONTAINER_IDS=()
BACKUP_COMPOSE_FILES=()

remaining_maintenance_seconds() {
  local remaining=$((MAINTENANCE_DEADLINE - SECONDS))
  (( remaining > 0 )) || return 1
  printf '%s' "$remaining"
}

run_in_maintenance_window() {
  local label="$1" seconds
  shift
  seconds="$(remaining_maintenance_seconds)" || {
    echo "FATAL: deployment maintenance window expired before $label" >&2
    return 124
  }
  echo "==> $label (maintenance time remaining: ${seconds}s)"
  timeout --kill-after=10s --foreground "${seconds}s" "$@"
}

stop_writer_services_best_effort() {
  local compose_stop_failed=0 query_failed=0 container_id active_output
  if ! timeout --kill-after=10s --foreground 60s docker compose --profile sms-ai --profile sms-learning \
    -f docker-compose.prod.yml "${BACKUP_COMPOSE_FILES[@]}" --env-file .env stop --timeout 30 "${WRITE_SERVICES[@]}"; then
    compose_stop_failed=1
  fi

  # If Compose timed out or failed after starting part of the rollout, query
  # any still-running target containers and stop them directly by ID.
  local -a active_ids=()
  if active_output="$(timeout --kill-after=10s --foreground 20s docker compose --profile sms-ai --profile sms-learning \
    -f docker-compose.prod.yml "${BACKUP_COMPOSE_FILES[@]}" --env-file .env ps -q "${WRITE_SERVICES[@]}" 2>/dev/null)"; then
    while IFS= read -r container_id; do
      [ -n "$container_id" ] && active_ids+=("$container_id")
    done <<< "$active_output"
  else
    query_failed=1
  fi
  if (( ${#active_ids[@]} > 0 )); then
    if ! timeout --kill-after=10s --foreground 60s docker stop --time 10 "${active_ids[@]}"; then
      return 1
    fi
  fi
  (( compose_stop_failed == 0 || query_failed == 0 ))
}

on_exit() {
  local status=$?
  trap - EXIT
  if (( status != 0 && SERVICES_FENCED == 1 && SOURCE_REPLACEMENT_STARTED == 0 )); then
    echo 'Deployment stopped before source replacement; attempting to resume the original writer containers.' >&2
    if (( ${#OLD_WRITER_CONTAINER_IDS[@]} > 0 )) && ! timeout --kill-after=10s --foreground 60s docker start "${OLD_WRITER_CONTAINER_IDS[@]}"; then
      echo 'FATAL: could not resume the old services; inspect Docker and restore service availability manually.' >&2
    fi
  elif (( status != 0 && SERVICES_FENCED == 1 && SOURCE_REPLACEMENT_STARTED == 1 )); then
    echo 'FATAL: source replacement began; stopping all writer services before reporting failure.' >&2
    if ! stop_writer_services_best_effort; then
      echo 'FATAL: Compose could not confirm all writers stopped; inspect Docker and stop any remaining writer containers before proceeding.' >&2
    fi
    echo 'Recover forward with this commit after resolving the failure; do not start the old images.' >&2
  fi
  if [ -n "$DEPLOY_BACKUP_STAGE" ]; then rm -rf -- "$DEPLOY_BACKUP_STAGE"; fi
  if [ -n "$DEPLOY_TARGET_STAGE" ]; then rm -rf -- "$DEPLOY_TARGET_STAGE"; fi
  if [ -n "$DB_CA_TEMP" ]; then rm -f -- "$DB_CA_TEMP"; fi
  exit "$status"
}
trap on_exit EXIT

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

# The production database is Supabase's session pooler. Its certificate chain
# is intentionally not trusted by the base image's public CA store, so strict
# hostname verification needs Supabase's reviewed public root CA. Bootstrap it
# only for the known Supabase pooler hostname, verify the pinned public
# fingerprint, and export it for Compose without persisting or printing the
# certificate. Other providers must supply their own reviewed DB_SSL_CA.
configure_database_tls() {
  local db_ssl db_ca admin_url expected actual
  db_ssl=true
  if grep -q '^DB_SSL=' .env; then
    check_single_env_key DB_SSL
    db_ssl="$(sed -n 's/^DB_SSL=//p' .env | sed 's/^"//; s/"$//')"
  fi
  [ "$db_ssl" = true ] || {
    echo 'FATAL: production deployment requires DB_SSL=true for verified database TLS' >&2
    exit 1
  }

  db_ca=""
  if grep -q '^DB_SSL_CA=' .env; then
    [ "$(awk 'index($0, "DB_SSL_CA=") == 1 { count++ } END { print count + 0 }' .env)" -eq 1 ] || {
      echo 'FATAL: .env must contain at most one DB_SSL_CA entry' >&2
      exit 1
    }
    db_ca="$(sed -n 's/^DB_SSL_CA=//p' .env | sed 's/^"//; s/"$//')"
  fi
  if [ -n "$db_ca" ]; then
    export DB_SSL=true DB_SSL_CA="$db_ca"
    return 0
  fi

  admin_url="$(sed -n 's/^ADMIN_DATABASE_URL=//p' .env | sed 's/^"//; s/"$//')"
  case "$admin_url" in
    *pooler.supabase.com:*)
      command -v curl >/dev/null 2>&1 || {
        echo 'FATAL: curl is required to obtain the reviewed Supabase database CA' >&2
        exit 1
      }
      command -v openssl >/dev/null 2>&1 || {
        echo 'FATAL: openssl is required to verify the reviewed Supabase database CA' >&2
        exit 1
      }
      DB_CA_TEMP="$(mktemp)"
      curl --fail --silent --show-error --location --max-time 20 \
        https://supabase-downloads.s3-ap-southeast-1.amazonaws.com/prod/ssl/prod-ca-2021.crt > "$DB_CA_TEMP"
      expected='807025AD50D4ED219D2C9C7D299C004F824EB00CF7F65AFEF607D07B72E6CAFA'
      actual="$(openssl x509 -in "$DB_CA_TEMP" -outform DER 2>/dev/null | sha256sum | awk '{print toupper($1)}')"
      [ "$actual" = "$expected" ] || {
        echo 'FATAL: downloaded Supabase database CA fingerprint is not the reviewed value' >&2
        exit 1
      }
      export DB_SSL=true DB_SSL_CA="$(cat "$DB_CA_TEMP")"
      echo '    verified reviewed Supabase database CA for strict TLS'
      ;;
    *)
      # Leave the system trust path available for providers using a public CA;
      # a private/provider CA must be supplied explicitly and will fail closed
      # in the migration/runtime TLS resolver if it is missing.
      export DB_SSL=true
      ;;
  esac
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
  ENCRYPTION_KEY \
  BACKUP_AGE_RECIPIENTS_FILE; do
  check_single_env_key "$key"
done

configure_database_tls

# Only the host file may opt into local storage; inherited shell values must
# not silently relax the offhost default. Reject ambiguity before downtime.
BACKUP_MODE=offhost
if grep -q '^BACKUP_MODE=' .env; then
  check_single_env_key BACKUP_MODE
  BACKUP_MODE="$(sed -n 's/^BACKUP_MODE=//p' .env | sed 's/^"//; s/"$//')"
fi
case "$BACKUP_MODE" in
  local|offhost) ;;
  *) echo 'FATAL: BACKUP_MODE must be local or offhost' >&2; exit 1 ;;
esac
export BACKUP_MODE
if [ "$BACKUP_MODE" = local ] && [ -s docker-compose.backup-local.yml ]; then
  BACKUP_COMPOSE_FILES=(-f docker-compose.backup-local.yml)
fi
for key in BACKUP_DESTINATION_A BACKUP_DESTINATION_B; do
  if [ "$BACKUP_MODE" = offhost ] || grep -q "^${key}=" .env; then
    check_single_env_key "$key"
  fi
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
if [ -z "$SMS_LEARNING_HMAC_KEY_VALUE" ]; then
  # Feedback collection runs in the API even when the optional cross-user
  # rule worker is off. Generate this once on the host so previously queued
  # dismissals can be stored; never rotate it on routine deployments.
  command -v openssl >/dev/null 2>&1 || {
    echo 'FATAL: openssl is required to provision the SMS learning key'
    exit 1
  }
  SMS_LEARNING_HMAC_KEY_VALUE="$(openssl rand -hex 32)"
  upsert_env_value SMS_LEARNING_HMAC_KEY "$SMS_LEARNING_HMAC_KEY_VALUE"
  echo '    SMS learning feedback key provisioned'
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

echo "==> Fetching the reviewed deployment commit"
[[ "$SHA" =~ ^[a-fA-F0-9]{7,40}$ ]] || { echo 'FATAL: expected a commit SHA'; exit 1; }
git check-ref-format --branch "$SOURCE_REF" >/dev/null 2>&1 || {
  echo 'FATAL: expected a valid source branch/ref'; exit 1;
}
if [ ! -d .git ]; then
  # First run converts the copied directory into a real checkout in place.
  # `git init` + fetch + reset (rather than a fresh clone) is what preserves
  # .env and the backups directory that already live here.
  echo "    no .git — initialising in place (preserves untracked .env)"
  git init -q
  git remote add origin "$REPO"
fi
git remote set-url origin "$REPO"
# A depth-limited fetch can hide the deployed ancestor on a long-lived branch.
# Restore complete history before evaluating ancestry; never waive the check.
if [ "$(git rev-parse --is-shallow-repository)" = true ]; then
  git fetch -q --unshallow origin "$SOURCE_REF"
else
  git fetch -q origin "$SOURCE_REF"
fi
# A delayed Actions run or manual rerun must never reset a newer deployment to
# an older, though once-tested, source branch commit. Refresh the requested
# source ref now and require the reviewed SHA to be its exact tip before
# building anything.
git fetch -q origin "$SOURCE_REF"
TARGET_COMMIT="$(git rev-parse --verify "${SHA}^{commit}")" || {
  echo 'FATAL: reviewed target commit is unavailable locally.' >&2
  exit 1
}
SOURCE_COMMIT="$(git rev-parse --verify "refs/remotes/origin/$SOURCE_REF")" || {
  echo 'FATAL: could not resolve the current source ref tip.' >&2
  exit 1
}
if [ "$TARGET_COMMIT" != "$SOURCE_COMMIT" ]; then
  echo 'FATAL: refusing a stale deployment target; it must equal the current source ref tip.' >&2
  exit 1
fi
# A copied legacy directory has no verifiable ancestry. Reconcile it to a
# reviewed commit before deploying; do not use this script to bootstrap an
# unknown running source tree or to roll a server backwards.
SERVER_HEAD="$(git rev-parse --verify HEAD 2>/dev/null)" || {
  echo 'FATAL: server checkout has no verifiable HEAD; reconcile source history before deploying.' >&2
  exit 1
}
if ! git merge-base --is-ancestor "$SERVER_HEAD" "$TARGET_COMMIT"; then
  echo 'FATAL: target is not a descendant of the server HEAD; rollback or divergent source is blocked.' >&2
  exit 1
fi
SHA="$TARGET_COMMIT"
# Lets the services tag error reports and metrics with the release they run.
export PANDAPAY_GIT_SHA="$SHA"
# Build every target image before downtime from the reviewed commit archive.
# This avoids doing Docker builds inside the bounded write-fencing window.
DEPLOY_TARGET_STAGE="$(mktemp -d)"
git archive "$SHA" | tar -x -C "$DEPLOY_TARGET_STAGE"
TARGET_COMPOSE=(docker compose --profile sms-ai --profile sms-learning -f "$DEPLOY_TARGET_STAGE/docker-compose.prod.yml" --env-file "$APP_DIR/.env")
if [ "$BACKUP_MODE" = local ]; then
  test -s "$DEPLOY_TARGET_STAGE/docker-compose.backup-local.yml" || {
    echo 'FATAL: target is missing the local backup override' >&2; exit 1;
  }
  TARGET_COMPOSE+=(-f "$DEPLOY_TARGET_STAGE/docker-compose.backup-local.yml")
fi
# Reviewed JSON files are deliberately gitignored. Use the host's protected
# directory for the archived target as well as after the source replacement.
export MIGRATION_BASELINES_DIR="$APP_DIR/deploy/migration-baselines"
# Legacy checkouts predate this required bind mount. Create only its empty
# protected directory; reviewed manifests and adoption remain operator-owned.
if [ ! -e "$MIGRATION_BASELINES_DIR" ]; then
  mkdir -m 700 -p "$MIGRATION_BASELINES_DIR"
fi
[ -d "$MIGRATION_BASELINES_DIR" ] && [ ! -L "$MIGRATION_BASELINES_DIR" ] || {
  echo 'FATAL: migration baseline mount must be a real directory' >&2; exit 1;
}
echo "==> Building target images before the maintenance window"
"${TARGET_COMPOSE[@]}" build api auth rewards-worker backup db-migrate

echo "==> Read-only product migration and auth contact preflight before downtime"
timeout --kill-after=10s --foreground 240s "${TARGET_COMPOSE[@]}" run --rm --no-deps \
  --entrypoint node db-migrate /db/scripts/product_migrate.js --check
timeout --kill-after=10s --foreground 120s "${TARGET_COMPOSE[@]}" run --rm --no-deps \
  --entrypoint node db-migrate /workspace/auth/scripts/auditContactUniqueness.js --require-unique

WRITE_SERVICES=(auth api rewards-worker)
echo "==> Checking the running Compose service inventory against this release"
active_services="$(timeout --kill-after=10s --foreground 20s docker ps \
  --filter label=com.docker.compose.project=pandapay-prod \
  --format '{{.ID}} {{.Label "com.docker.compose.project"}} {{.Label "com.docker.compose.service"}}')" || {
  echo 'FATAL: could not inventory the production project; refusing to fence services.' >&2
  exit 1
}
while read -r container_id live_project live_service extra; do
  [ -n "$container_id" ] || continue
  if [ "$live_project" != "pandapay-prod" ] || [ -z "$live_service" ] || [ -n "${extra:-}" ]; then
    echo 'FATAL: a production container has missing or mismatched Compose labels; refusing to fence services.' >&2
    exit 1
  fi
  case "$live_service" in
    auth|api|rewards-worker|backup|db-migrate|maps-scraper) ;;
    *)
      echo 'FATAL: an unreviewed production service is running; reconcile the deployed release and all writers before downtime.' >&2
      exit 1
      ;;
  esac
done <<< "$active_services"

echo "==> Fencing API/auth and background writer services before the paired backup"
for service in "${WRITE_SERVICES[@]}"; do
  container_ids="$(docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml "${BACKUP_COMPOSE_FILES[@]}" --env-file .env ps -q "$service")" || {
    echo "FATAL: could not inventory the existing $service container; refusing to fence writers without a recovery list." >&2
    exit 1
  }
  while IFS= read -r container_id; do
    [ -n "$container_id" ] && OLD_WRITER_CONTAINER_IDS+=("$container_id")
  done <<< "$container_ids"
done
MAINTENANCE_DEADLINE=$((SECONDS + MAINTENANCE_WINDOW_SECONDS))
SERVICES_FENCED=1
run_in_maintenance_window 'Stopping writer services with a 30-second graceful timeout' \
  docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml --env-file .env \
    "${BACKUP_COMPOSE_FILES[@]}" stop --timeout 30 "${WRITE_SERVICES[@]}"

echo "==> Creating and verifying the paired encrypted product/auth backup"
run_in_maintenance_window 'Paired backup' \
  "${TARGET_COMPOSE[@]}" \
    run --rm --no-deps backup /backup/backup.sh
echo "==> Backup copies verified; syncing working source"
SOURCE_REPLACEMENT_STARTED=1
git reset -q --hard "$SHA"
git clean -qfd -e .env -e .env.prod -e node_modules
if [ "$BACKUP_MODE" = local ]; then
  BACKUP_COMPOSE_FILES=(-f docker-compose.backup-local.yml)
fi
echo "    now at: $(git log --oneline -1)"

# db-migrate is a one-shot service; --exit-code-from surfaces a failed
# migration as a failed deploy instead of a container that quietly exited 1.
run_in_maintenance_window 'Applying migrations' \
  docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml "${BACKUP_COMPOSE_FILES[@]}" --env-file .env \
    up --no-build --abort-on-container-exit --exit-code-from db-migrate db-migrate

echo "==> Rebuilding and restarting services"
run_in_maintenance_window 'Starting prebuilt target images with readiness checks' \
  env DEPLOY_IMAGES_PREBUILT=1 bash deploy/restart-services.sh

run_in_maintenance_window 'Final API/auth health verification' bash -s <<'FINAL_HEALTH_CHECK'
echo "==> Waiting for final API/auth health"
for i in $(seq 1 30); do
  if curl -fsS -m 5 http://127.0.0.1:4000/ready >/dev/null 2>&1 \
     && curl -fsS -m 5 http://127.0.0.1:3210/ready >/dev/null 2>&1; then
    echo "    healthy after ${i}0s"
    exit 0
  fi
  if [ "$i" -lt 30 ]; then sleep 10; fi
done
echo "FATAL: services did not become healthy"
files=()
if [ "$BACKUP_MODE" = local ]; then files=(-f docker-compose.backup-local.yml); fi
docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml "${files[@]}" --env-file .env logs --tail=40 api auth
exit 1
FINAL_HEALTH_CHECK
SERVICES_FENCED=0

echo "==> Pruning dangling images"
docker image prune -f >/dev/null 2>&1 || true

echo "==> Deployed $SHA"
