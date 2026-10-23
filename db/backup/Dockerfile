# Runs the paired encrypted backup on a schedule. Restore drills run on a
# separately controlled recovery host, which alone receives the private age
# identity and explicit RESTORE_* PostgreSQL URLs.
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
ARG POSTGRES_CLIENT_MAJOR=17
FROM postgres:${POSTGRES_CLIENT_MAJOR}-alpine

RUN apk add --no-cache dcron bash age python3 coreutils

WORKDIR /backup
COPY scripts/backup.sh ./backup.sh
COPY scripts/restore_drill.sh ./restore_drill.sh
COPY scripts/backup_common.sh ./backup_common.sh
COPY scripts/backup_manifest.py ./backup_manifest.py
COPY scripts/restore_urls.py ./restore_urls.py
COPY scripts/pg_connection.py ./pg_connection.py
COPY scripts/backup_snapshot.py ./backup_snapshot.py
COPY scripts/backup_payload.sh ./backup_payload.sh
COPY backup/crontab /etc/crontabs/root
RUN chmod +x ./backup.sh ./restore_drill.sh ./backup_manifest.py ./restore_urls.py ./pg_connection.py

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

COPY scripts/backup_storage.py ./backup_storage.py
