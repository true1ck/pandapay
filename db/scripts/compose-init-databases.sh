#!/bin/bash
# Creates the SECOND database the stack needs, then loads the auth schema into
# it. Runs once, from Postgres' docker-entrypoint-initdb.d, before anything
# connects.
#
# Why this exists: `auth/` and `api/` are separate services with separate
# schemas that happen to both define a `user_devices` table — auth's keyed by
# users.id, the product's keyed by profiles.id and referenced by change_log.
# Sharing one database silently collides on that name. auth/db/pandapay-auth/
# docker-compose.yml has always used a dedicated `pandapay_auth` database;
# this reproduces that inside the single-instance dev stack.
#
# The product schema is NOT loaded here — it is applied by the `db-migrate`
# service, which has to run the migrations in order and re-run the grants
# afterwards. Only the auth schema, which is one self-contained file, is
# loaded at init time.
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE DATABASE pandapay_auth;
EOSQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname pandapay_auth \
  -f /docker-entrypoint-initdb.d/01-auth-schema.sql.tpl

echo "pandapay_auth created and initialised"
