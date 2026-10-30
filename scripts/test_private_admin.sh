#!/usr/bin/env bash
set -euo pipefail
task_root=$(cd "$(dirname "$0")/.." && pwd)
task_pg_dir=$(mktemp -d /tmp/pandapay-admin-pg.XXXXXX)
cleanup() {
  pg_ctl -D "$task_pg_dir/data" -m immediate stop >/dev/null 2>&1 || true
  rm -rf "$task_pg_dir"
}
trap cleanup EXIT
initdb -D "$task_pg_dir/data" -U postgres -A trust --no-locale > "$task_pg_dir/init.log" 2>&1
pg_ctl -D "$task_pg_dir/data" -l "$task_pg_dir/server.log" -o "-k $task_pg_dir -p 55487 -h ''" start >/dev/null
cd "$task_root"
ADMIN_TEST_PG_SOCKET="$task_pg_dir" node --test tests/admin_console_security/postgres.test.js
ADMIN_TEST_PG_SOCKET="$task_pg_dir" node --test tests/admin_console_security/full_schema.test.js
node --test auth/test/private_admin_gateway.test.js auth/test/public_admin_isolation.test.js api/test/admin_api_factory.test.js
python3 -m unittest discover -s tests/admin_console_security
node scripts/sync_admin_contracts.js --check
