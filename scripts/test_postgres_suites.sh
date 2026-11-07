#!/usr/bin/env bash
# Runs the PostgreSQL-backed suites that `npm test` skips: API and SMS v2 *_pg
# tests, the db/tests/*.sql assertion scripts, and the opt-in *_postgres.js
# fixtures that no other CI job runs. (The private-admin and remaining-security
# fixtures already run in the "security-recovery" job.)
#
# Point it at a DISPOSABLE, loopback PostgreSQL server as a superuser:
#   PG_SUITES_ADMIN_URL=postgresql://postgres:<pw>@127.0.0.1:<port> \
#     bash scripts/test_postgres_suites.sh
# The server must trust loopback logins or accept the URL's password for every
# role (the delivery fixture logs in as roles it creates without passwords).
# Every database below is created here, refused if it already exists, and
# dropped on exit. Cluster-wide roles (app_user, admin_api_runtime) are created
# by the migrations, so use a throwaway cluster, never a shared one.
# The self-contained fixtures also need initdb and pg_ctl on PATH.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root" || exit 1
admin_url=${PG_SUITES_ADMIN_URL:-}
if [ -z "$admin_url" ]; then
  echo 'PG_SUITES_ADMIN_URL is required (a disposable loopback PostgreSQL superuser URL)' >&2
  exit 1
fi
admin_url=${admin_url%/}
# The fixtures accept only loopback, and some only 127.0.0.1 with a password.
case "$admin_url" in
  postgres://*:*@127.0.0.1:*|postgresql://*:*@127.0.0.1:*) ;;
  *) echo 'PG_SUITES_ADMIN_URL must be postgres(ql)://user:password@127.0.0.1:port with no database' >&2; exit 1 ;;
esac
case "${admin_url#*://*@*:}" in
  ''|*[!0-9]*) echo 'PG_SUITES_ADMIN_URL must end in :port, without a database or options' >&2; exit 1 ;;
esac
for tool in psql node; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 1; }
done

# Synthetic, per-run credentials. Only app_user and the private admin runtime
# are used to log in; nothing here is a real secret.
secret() { node -e "process.stdout.write(require('crypto').randomBytes(24).toString('hex'))"; }
app_user_password=$(secret)
reward_worker_password=$(secret)
admin_api_password=$(secret)
sms_ai_worker_password=$(secret)
export JWT_ACCESS_SECRET=${JWT_ACCESS_SECRET:-ci_only_not_a_real_secret_for_pg_suites}

main_db=pandapay_pg_suites
sync_db=sync_transport_test
isolation_db=sync_isolation_upgrade_test
index_db=pg_suites_index_review_test
shared_db=shared_expenses_test
databases="$main_db $sync_db $isolation_db $index_db $shared_db"
created=""

sql() { psql "$admin_url/postgres" -X -q -v ON_ERROR_STOP=1 "$@"; }
cleanup() {
  for db in $created; do sql -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT

for db in $databases shared_expenses_concurrency_test; do
  if [ "$(sql -Atc "SELECT 1 FROM pg_database WHERE datname = '$db'")" = 1 ]; then
    echo "Database $db already exists; refusing to touch it. Use a throwaway server." >&2
    exit 1
  fi
done
for db in $databases; do
  sql -c "CREATE DATABASE $db" && created="$created $db" || exit 1
done

migrate() {
  ADMIN_DATABASE_URL="$admin_url/$1" DB_SSL=false NODE_ENV=test SEED_DEMO_DATA=false \
    APP_USER_PASSWORD="$app_user_password" REWARD_WORKER_DB_PASSWORD="$reward_worker_password" \
    ADMIN_API_DB_PASSWORD="$admin_api_password" SMS_AI_WORKER_DB_PASSWORD="$sms_ai_worker_password" \
    node "$root/db/scripts/product_migrate.js" >/dev/null
}
echo '==> Applying product migrations and role setup'
for db in $main_db $sync_db $isolation_db; do
  migrate "$db" || { echo "Product migrations failed for $db" >&2; exit 1; }
done

failures=""
step() {
  local name=$1; shift
  echo "==> $name"
  if "$@"; then echo "    ok"; else echo "    FAILED: $name"; failures="$failures
  - $name"; fi
}
# A node --test suite must pass AND run every test: these suites skip silently
# when their database URL is missing, which must never look like a pass here.
node_suite() {
  local log
  log=$(mktemp)
  node --test --test-concurrency=1 --test-reporter=spec "$@" >"$log" 2>&1
  local status=$?
  grep -E '^ℹ (tests|pass|fail|skipped) ' "$log" | sed 's/^/    /'
  if [ $status -ne 0 ] || ! grep -q '^ℹ skipped 0$' "$log" || grep -q '^ℹ tests 0$' "$log"; then
    tail -n 80 "$log"; rm -f "$log"; return 1
  fi
  rm -f "$log"
}
psql_file() { psql "$admin_url/$main_db" -X -q -v ON_ERROR_STOP=1 -f "$1" >/dev/null; }

# db/tests/*.sql assertion scripts, in file order, against the migrated schema.
# Not run: legacy SMS learning admin flows that call admin RPCs as app_user.
# The private admin API replaced that path, so these fail on every database
# ("admin required"); delete or rewrite them with the legacy learning tables.
stale_sql=" 20261027170000_sms_ai_learning_proposals_test.sql 20261027180000_sms_ai_proposal_supersede_test.sql 20261028110000_sms_correction_case_review_test.sql 20261028120000_sms_correction_case_rls_test.sql 20261028130000_sms_admin_category_evidence_scope_test.sql "
for file in "$root"/db/tests/*.sql; do
  name=$(basename "$file")
  case "$stale_sql" in *" $name "*) echo "==> db/tests/$name (not run: stale legacy admin flow)"; continue ;; esac
  step "db/tests/$name" psql_file "$file"
done

main_url="$admin_url/$main_db"
admin_runtime_url="postgresql://admin_api_runtime:$admin_api_password@${admin_url#*@}/$main_db"
api_pg_suites() (
  export EMAIL_IMPORT_TEST_DATABASE_URL="$main_url" SMS_V2_TEST_DATABASE_URL="$main_url" \
    SMS_V2_TEST_ADMIN_DATABASE_URL="$admin_runtime_url" \
    SMS_V2_TEST_AI_WORKER_DATABASE_URL="postgresql://sms_ai_worker:$sms_ai_worker_password@${admin_url#*@}/$main_db"
  node_suite api/test/email_import_pg.test.js api/test/sms_v2/*_pg.test.js
)
step 'api email import and SMS v2 *_pg suites' api_pg_suites

# Fixtures that each roll back inside one clean, migrated sync_transport_test.
sync_url="$admin_url/$sync_db"
step 'api sync transport fixture' env PANDAPAY_SYNC_TRANSPORT_TEST_URL="$sync_url" node "$root/api/test/sync_transport_postgres.js"
step 'api typed sync fixture' env PANDAPAY_SYNC_TYPED_TEST_URL="$sync_url" node "$root/api/test/sync_typed_changes_postgres.js"
step 'api sync financial fixture' env PANDAPAY_SYNC_FINANCIAL_TEST_URL="$sync_url" node "$root/api/test/sync_financial_postgres.js"

# Upgrade-shaped isolation fixture: seed, migrate again (a no-op), verify.
isolation_url="$admin_url/$isolation_db"
isolation() {
  PANDAPAY_SYNC_ISOLATION_TEST_URL="$isolation_url" node "$root/api/test/sync_isolation_postgres.js" --seed &&
    migrate "$isolation_db" &&
    APP_USER_PASSWORD="$app_user_password" PANDAPAY_SYNC_ISOLATION_TEST_URL="$isolation_url" \
      node "$root/api/test/sync_isolation_postgres.js"
}
step 'api sync isolation fixture (seed, re-migrate, verify)' isolation
step 'api notification delivery capability fixture' env SECURITY_DELIVERY_TEST_URL="$isolation_url" node "$root/api/test/security_delivery_postgres.js"

step 'db reviewed index reconciliation fixture' env PANDAPAY_INDEX_FIXTURE_URL="$admin_url/$index_db" node "$root/db/tests/reviewed_index_reconciliation_postgres.js"
shared_expense_suites() (
  export PANDAPAY_SHARED_EXPENSES_TEST_URL="$admin_url/$shared_db" \
    PANDAPAY_SHARED_EXPENSES_CONCURRENCY_TEST_URL="$admin_url/shared_expenses_concurrency_test"
  node_suite db/tests/shared_expenses_postgres.test.js db/tests/shared_expenses_concurrency_postgres.test.js
)
step 'db shared expenses suites' shared_expense_suites

# Self-contained fixtures: each starts and removes its own initdb cluster.
step 'db account recovery drop fixture (own cluster)' node "$root/db/tests/account_recovery_drop_postgres.js"
step 'db catalogue label identity fixture (own cluster)' node "$root/db/tests/catalogue_label_identity_postgres.js"
step 'api support tickets fixture (own cluster)' node "$root/api/test/support_tickets_postgres.js"

if [ -n "$failures" ]; then
  echo "PostgreSQL suites failed:$failures"
  exit 1
fi
echo 'All PostgreSQL suites passed'
