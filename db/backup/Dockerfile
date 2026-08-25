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
# Base is a postgres image, not a bare alpine + apk-installed client, so
# pg_dump/pg_restore are a known major version rather than whatever the
# package index happens to serve.
#
# MUST BE >= THE SERVER'S MAJOR VERSION. pg_dump refuses outright when the
# server is newer:
#
#   pg_dump: error: aborting because of server version mismatch
#   pg_dump: detail: server version: 17.6; pg_dump version: 16.14
#
# and the wrapper script only checks the exit code AFTER the file is
# created, so a failed run still leaves a 0-byte .dump behind that looks
# like a backup in a directory listing. That is exactly what happened: this
# was pinned to 16 while the database moved to Supabase Postgres 17.6, and
# TWELVE CONSECUTIVE DAILY BACKUPS were empty files before anyone looked.
# The nightly restore drill did catch it ("input file is too short"), but
# nothing surfaced that failure anywhere a human would see it.
#
# If the server is upgraded again, this pin has to move with it.
#
# Build context must be `db/` (not `db/backup/`), so this can COPY the
# existing scripts/ directory — Docker COPY can't reach outside its context
# with `../`. See docker-compose.prod.yml's `backup` service for the
# `context: ./db, dockerfile: backup/Dockerfile` pairing that makes this work.
FROM postgres:17-alpine

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
