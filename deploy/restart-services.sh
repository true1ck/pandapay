#!/usr/bin/env bash
# Build and replace one service at a time on the 1 GB production host.
# Run from the repository root after database migrations have completed.
set -euo pipefail

export COMPOSE_PARALLEL_LIMIT=1
COMPOSE=(docker compose --profile sms-ai -f docker-compose.prod.yml --env-file .env)
ATTEMPTS="${DEPLOY_HEALTH_ATTEMPTS:-30}"
INTERVAL="${DEPLOY_HEALTH_INTERVAL_SECONDS:-5}"
[[ "$ATTEMPTS" =~ ^[1-9][0-9]*$ ]] || { echo 'FATAL: invalid health attempts'; exit 1; }
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || { echo 'FATAL: invalid health interval'; exit 1; }

# Keep the optional AI worker behavior from deploy.sh. Read the token only to
# decide whether to start the worker; never print or pass the secret onward.
AI_WORKER_TOKEN_VALUE="$(sed -n 's/^AI_WORKER_TOKEN=//p' .env 2>/dev/null | sed 's/^"//; s/"$//')"
SERVICES=(auth api rewards-worker backup)
if [ -n "$AI_WORKER_TOKEN_VALUE" ]; then
  SERVICES+=(gemini-worker)
fi
unset AI_WORKER_TOKEN_VALUE

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

# Finish all image builds before replacing any running service. A failed build
# therefore leaves the current containers running. Single-service builds also
# avoid overlapping npm installs and their memory spikes.
for service in "${SERVICES[@]}"; do
  echo "==> Building $service"
  "${COMPOSE[@]}" build "$service"
done

if [[ ! " ${SERVICES[*]} " =~ ' gemini-worker ' ]]; then
  # Disable a worker left by a previous opt-in deployment after all builds
  # have succeeded, so a failed build leaves the running stack untouched.
  "${COMPOSE[@]}" stop gemini-worker >/dev/null 2>&1 || true
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
