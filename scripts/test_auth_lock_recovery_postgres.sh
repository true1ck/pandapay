#!/usr/bin/env bash
# Runs the real-PostgreSQL fixtures for the account lock and recovery work, on a throwaway
# cluster it creates itself and deletes afterwards. Nothing here touches any other database.
#
#   bash scripts/test_auth_lock_recovery_postgres.sh
#
# Needs initdb, pg_ctl, psql and node on PATH (on macOS with Homebrew: /opt/homebrew/bin).
# These fixtures are not in `npm test` (they need a database) and, like the other auth
# *_postgres.js fixtures, are not run by CI, so run this before pushing anything that
# touches auth/db/migrations, the phone claim, email identity, recovery or the device limit.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
for tool in initdb pg_ctl psql node; do
  command -v "$tool" >/dev/null || { echo "$tool is required on PATH" >&2; exit 1; }
done

# macOS refuses to start a server whose process has no valid locale.
[ "$(uname)" = Darwin ] && export LC_ALL=${LC_ALL:-en_US.UTF-8}
work=$(mktemp -d "${TMPDIR:-/tmp}/pandapay-auth-pg.XXXXXX")
port=$(node -e "const s=require('net').createServer().listen(0,'127.0.0.1',()=>{console.log(s.address().port);s.close()})")
cleanup() {
  pg_ctl -D "$work/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# --no-locale matches the CI cluster, so a test that depends on collation fails here too.
initdb -D "$work/data" -U postgres -A trust --no-locale --encoding=UTF8 >/dev/null || exit 1
pg_ctl -D "$work/data" -l "$work/pg.log" -w \
  -o "-p $port -c listen_addresses=127.0.0.1 -c unix_socket_directories=''" start >/dev/null || { cat "$work/pg.log" >&2; exit 1; }
base="postgres://postgres@127.0.0.1:$port"
for db in phone_claim_test email_canonical_test recovery_email_test account_recovery_test; do
  psql "$base/postgres" -X -q -v ON_ERROR_STOP=1 -c "CREATE DATABASE $db" || exit 1
done

failed=0
run() {
  local label=$1; shift
  echo "==> $label"
  if (cd "$root/auth" && env "$@"); then echo "    ok"; else echo "    FAILED: $label" >&2; failed=1; fi
}
run 'phone claim'        PHONE_CLAIM_TEST_DATABASE_URL="$base/phone_claim_test"           node --test --test-timeout=120000 test/phone_claim_postgres.js
run 'email canonical'    EMAIL_CANONICAL_TEST_DATABASE_URL="$base/email_canonical_test"   node --test --test-timeout=120000 test/email_canonical_postgres.js
run 'recovery email'     RECOVERY_EMAIL_TEST_DATABASE_URL="$base/recovery_email_test"     node --test --test-timeout=120000 test/recovery_email_postgres.js
run 'account recovery and support tool' ACCOUNT_RECOVERY_TEST_DATABASE_URL="$base/account_recovery_test" node --test --test-timeout=120000 test/account_recovery_postgres.js
run 'device limit and cluster tool' DEVICE_LIMIT_TEST_DATABASE_URL="$base/account_recovery_test" node --test --test-timeout=120000 test/device_account_limit_postgres.js

if [ "$failed" = 0 ]; then echo 'All lock and recovery PostgreSQL fixtures passed.'; else echo 'Some fixtures failed.' >&2; fi
exit "$failed"
