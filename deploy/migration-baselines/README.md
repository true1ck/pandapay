# Reviewed migration baselines

The product runner refuses to assign checksums to historical ledger rows
unless an independently reviewed baseline matches the applied filenames,
current file digests and the database schema. JSON files here are gitignored.

Generate a manifest read-only using the migration image's Node entry point,
with this directory mounted writable at `/reviewed`:

```sh
docker compose -f docker-compose.prod.yml --env-file .env run --rm --no-deps \
  -v "$PWD/deploy/migration-baselines:/reviewed" --entrypoint node db-migrate \
  /db/scripts/product_migrate.js --write-baseline /reviewed/product.json
```

Review the source database and a restored clone against the known released
schema and recorded migration effects. Generating a fingerprint alone does
not establish that those effects were correct. After review, configure
`MIGRATION_LEGACY_BASELINE_FILE=/run/migration-baselines/product.json` and
`MIGRATION_ADOPT_LEGACY_CHECKSUMS=true` for the one-time adoption. Subsequent
runs reject changed migration checksums. Keep the reviewed file/release
evidence recoverable outside this checkout.

The auth runner separately verifies the known legacy migration's columns and
indexes before adopting its checksum. No adoption setting automatically marks
an unknown or renamed migration applied.

Product baseline v2 combines a `pg_dump --schema-only --no-acl` definition
fingerprint (owners remain included) with a canonical catalog inventory of
database, schema, relation, column, routine, type, language, foreign-data
wrapper/server, tablespace, large-object metadata, parameter, and default ACLs.
The ACL inventory records owners and grantor, grantee, privilege, and grant
option by semantic object identity; large objects retain their actual OIDs,
without including blob contents. Built-in language and tablespace bootstrap
owners are normalized only when the catalog owner is a superuser; a
non-superuser owner remains part of the fingerprint. All grant tuples remain
covered in either case.
Extension owners and tracked extension-member owners are included. Generated
target database names and provider `pg_init_privs` defaults are excluded. If a
required catalog or ACL policy cannot be represented, fingerprinting fails
closed and the restore/adoption stays gated for manual review. Only named local
CHECK definitions are normalized from their exact raw catalog form to
PostgreSQL's pretty form; missing checks or other definition changes fail
closed. Existing v1 product baselines must be captured and independently
reviewed again in v2 before legacy checksum adoption.
