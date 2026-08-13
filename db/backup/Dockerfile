# Runs db/scripts/backup.sh and restore_drill.sh on a schedule.
#
# Those two scripts already exist and are correct (pg_dump + verify + record +
# prune; restore into a throwaway DB + verify) — this is only the missing
# runner. pg_cron (db/supabase/migrations/0013_cron_jobs.sql) can't do it: it
# runs SQL inside Postgres, not shell commands against pg_dump/pg_restore, and
# is skipped entirely in this stack's compose db-migrate step because the
# stock postgres image doesn't ship the extension. There's also no Node-side
# scheduler anywhere in api/ or auth/. A tiny cron container is the whole gap.
#
# Base is postgres:16-alpine, not a bare alpine + apk-installed client — that
# guarantees pg_dump/pg_restore are the same major version as the database
# they're backing up, which a separately-installed postgresql-client package
# would not guarantee.
#
# Build context must be `db/` (not `db/backup/`), so this can COPY the
# existing scripts/ directory — Docker COPY can't reach outside its context
# with `../`. See docker-compose.prod.yml's `backup` service for the
# `context: ./db, dockerfile: backup/Dockerfile` pairing that makes this work.
FROM postgres:16-alpine

RUN apk add --no-cache dcron bash

WORKDIR /backup
COPY scripts/backup.sh ./backup.sh
COPY scripts/restore_drill.sh ./restore_drill.sh
COPY backup/crontab /etc/crontabs/root
RUN chmod +x ./backup.sh ./restore_drill.sh

# Requires the container to be started with an init process (docker run
# --init, or `init: true` in compose — both wire up Docker's built-in tini)
# — NOT a Dockerfile-level dumb-init ENTRYPOINT. dcron's crond calls
# setpgid() on itself at startup, which fails with "setpgid: Operation not
# permitted" (EPERM: pid is a session leader) whenever crond is a direct
# exec-form child of the container's own PID 1, dumb-init included — a
# known dcron/Docker interaction, confirmed here by testing both a
# dumb-init ENTRYPOINT (still failed) and `docker run --init` (works)
# before picking this fix. See docker-compose.prod.yml/staging.yml's
# `backup` service, which sets `init: true`.
#
# -f: stay in the foreground so tini can supervise crond as a real child,
# instead of crond daemonizing and the container exiting immediately.
CMD ["crond", "-f", "-l", "2"]
