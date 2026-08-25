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
# - It never touches .env. Secrets live only on the host and are gitignored,
#   so `git reset --hard` below leaves them alone.
set -euo pipefail

SHA="${1:?usage: deploy.sh <commit-sha>}"
APP_DIR="/home/ubuntu/apps/pandapay"
REPO="https://github.com/true1ck/pandapay.git"
BACKUP_DIR="/home/ubuntu/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

cd "$APP_DIR"

echo "==> Preflight: .env must exist (it is gitignored and host-only)"
test -s .env || { echo "FATAL: $APP_DIR/.env missing — refusing to deploy"; exit 1; }

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
docker compose -f docker-compose.prod.yml --env-file .env up -d --build api auth backup

echo "==> Waiting for health"
for i in $(seq 1 30); do
  if curl -fsS -m 5 http://127.0.0.1:4000/health >/dev/null 2>&1 \
     && curl -fsS -m 5 http://127.0.0.1:3210/health >/dev/null 2>&1; then
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
