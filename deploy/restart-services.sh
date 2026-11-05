#!/usr/bin/env bash
# Build and replace one service at a time on the 1 GB production host.
# Run from the repository root after database migrations have completed.
set -euo pipefail

export COMPOSE_PARALLEL_LIMIT=1
COMPOSE=(docker compose --profile sms-ai --profile sms-learning -f docker-compose.prod.yml --env-file .env)
BACKUP_MODE=offhost
mode_count="$(awk '/^BACKUP_MODE=/ { n++ } END { print n+0 }' .env)"
if [ "$mode_count" -gt 1 ]; then
  echo 'FATAL: duplicate BACKUP_MODE entries' >&2; exit 1
elif [ "$mode_count" -eq 1 ]; then
  BACKUP_MODE="$(sed -n 's/^BACKUP_MODE=//p' .env | sed 's/^"//; s/"$//')"
fi
case "$BACKUP_MODE" in
  local) COMPOSE+=(-f docker-compose.backup-local.yml) ;;
  offhost) ;;
  *) echo 'FATAL: BACKUP_MODE must be local or offhost' >&2; exit 1 ;;
esac
export BACKUP_MODE
backup_keys=(BACKUP_AGE_RECIPIENTS_FILE)
if [ "$BACKUP_MODE" = offhost ]; then
  backup_keys+=(BACKUP_DESTINATION_A BACKUP_DESTINATION_B)
fi
for key in "${backup_keys[@]}"; do
  count="$(awk -v key="$key" 'index($0, key "=") == 1 { n++ } END { print n+0 }' .env)"
  if [ "$count" -ne 1 ] || ! grep -Eq "^${key}=.+" .env; then
    echo "FATAL: expected exactly one nonempty $key" >&2; exit 1
  fi
done
ATTEMPTS="${DEPLOY_HEALTH_ATTEMPTS:-30}"
INTERVAL="${DEPLOY_HEALTH_INTERVAL_SECONDS:-5}"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo 'FATAL: invalid health attempts'; exit 1; }
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo 'FATAL: invalid health interval'; exit 1; }

SERVICES=(auth api rewards-worker backup)

wait_for_service() {
  local service="$1" url="$2" id status attempt
  for ((attempt=1; attempt<=ATTEMPTS; attempt++)); do
    if [ -n "$url" ]; then
      if curl -fsS --max-time 5 "$url" >/dev/null 2>&1; then
        echo "    $service ready"
        return 0
      fi
    else
      id="$("${COMPOSE[@]}" ps -q "$service")"
      if [ -n "$id" ]; then
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id")"
        if [ "$status" = healthy ] || { [ "$service" = backup ] && [ "$status" = running ]; }; then
          echo "    $service ready"
          return 0
        fi
      fi
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ]; then sleep "$INTERVAL"; fi
  done
  echo "FATAL: $service did not become ready; stopping the rollout"
  return 1
}

# Finish all image builds before replacing any running service. The normal
# standalone path builds here; deploy.sh can prebuild the reviewed target
# archive before fencing database writers and set this flag to keep builds
# outside the maintenance window.
if [ "${DEPLOY_IMAGES_PREBUILT:-0}" = "1" ]; then
  echo '==> Using target images prebuilt before the maintenance window'
else
  for service in "${SERVICES[@]}"; do
    echo "==> Building $service"
    "${COMPOSE[@]}" build "$service"
  done
fi

for service in "${SERVICES[@]}"; do
  echo "==> Starting $service"
  "${COMPOSE[@]}" up -d --no-build --no-deps "$service"
  case "$service" in
    auth) wait_for_service "$service" http://127.0.0.1:3210/ready ;;
    api) wait_for_service "$service" http://127.0.0.1:4000/ready ;;
    *) wait_for_service "$service" '' ;;
  esac
done

# A green API health check alone does not prove that opted-in dismissal
# feedback can be recorded. Keep the key private and check only its length.
"${COMPOSE[@]}" exec -T api node -e \
  "process.exit((process.env.SMS_LEARNING_HMAC_KEY || '').length >= 32 ? 0 : 1)" || {
  echo 'FATAL: API started without a usable SMS learning feedback key'
  exit 1
}
