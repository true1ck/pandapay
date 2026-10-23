'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
  ISOLATED_ATTESTATION,
  validateProductTarget,
  safeChildEnvironment,
  hashTableRowsWithCursor,
  safeFailureCategory,
  safeProductMigrationCategory,
  runBounded,
  assertOriginalTablesPreserved,
  assertRuntimeRolesPreserved,
  assertProductLedger,
  captureProductState,
  runProductUpgrade,
} = require('../scripts/rehearse_product_upgrade');

function fixture(t) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'product-upgrade-rehearsal-test-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  const baseline = path.join(root, 'reviewed-product-baseline.json');
  fs.writeFileSync(baseline, '{}', { mode: 0o600 });
  const pgpass = path.join(root, 'pgpass');
  fs.writeFileSync(pgpass, '127.0.0.1:5432:*:pp_recovery_admin:synthetic\n', { mode: 0o600 });
  fs.chmodSync(pgpass, 0o600);
  const firstSql = path.join(root, '0001_existing.sql');
  const secondSql = path.join(root, '0002_new.sql');
  fs.writeFileSync(firstSql, 'CREATE TABLE first_fixture(id integer);');
  fs.writeFileSync(secondSql, 'CREATE TABLE second_fixture(id integer);');
  return { root, baseline, pgpass, firstSql, secondSql };
}

function validEnv(baseline, pgpass = path.join(path.dirname(baseline), 'pgpass')) {
  return {
    RESTORE_PRODUCT_TARGET_URL: 'postgresql://restore:synthetic@127.0.0.1:5432/pprestore_0123456789abcdefabcd_p',
    RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION: ISOLATED_ATTESTATION,
    RESTORE_PRODUCT_EXACT_COMPARISON: 'passed',
    PRODUCT_REVIEWED_BASELINE_FILE: baseline,
    PGPASSFILE: pgpass,
    PP_RECOVERY_CONTAINER: 'pandapay-recovery-0123456789abcdef',
    PP_RECOVERY_HOST_PORT: '55432',
    PP_RECOVERY_PASSWORD: 'must-not-be-inherited',
    PRODUCT_DATABASE_URL: 'postgresql://source-secret.invalid/source',
    AUTH_DATABASE_URL: 'postgresql://source-auth.invalid/source',
    AUTH_MIGRATION_DATABASE_URL: 'postgresql://source-auth-migration.invalid/source',
    ENCRYPTION_KEY: 'must-not-be-inherited',
    PHONE_LOOKUP_HMAC_KEY: 'must-not-be-inherited',
    SMS_LEARNING_WORKER_DB_PASSWORD: 'must-not-be-inherited',
    PATH: '/synthetic/pg-adapter:/usr/bin',
    NODE_ENV: 'test',
    DB_SSL: 'false',
  };
}

test('product target requires the generated loopback database and both attestations', t => {
  const env = validEnv(fixture(t).baseline);
  assert.equal(validateProductTarget(env).target.hostname, '127.0.0.1');
  for (const invalid of [
    { ...env, RESTORE_PRODUCT_TARGET_URL: 'postgresql://h:p@localhost:5432/pprestore_0123456789abcdefabcd_p' },
    { ...env, RESTORE_PRODUCT_TARGET_URL: 'postgresql://h:p@127.0.0.1:5432/pprestore_0123456789abcdefabcd_a' },
    { ...env, RESTORE_PRODUCT_TARGET_URL: 'postgresql://h:p@192.168.1.3:5432/pprestore_0123456789abcdefabcd_p' },
    { ...env, RESTORE_PRODUCT_TARGET_URL: 'postgresql://h:p@127.0.0.1:5432/pprestore_0123456789abcdefabcd_p?HOST=remote.invalid' },
    { ...env, RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION: '' },
    { ...env, RESTORE_PRODUCT_EXACT_COMPARISON: '' },
  ]) assert.throws(() => validateProductTarget(invalid));
});

test('foreign tables fail closed without querying their external data source', async () => {
  const calls = [];
  const client = { async query(sql) {
    calls.push(sql);
    if (sql.includes("c.relkind = 'f'")) return { rows: [{ present: true }] };
    return { rows: [] };
  } };
  await assert.rejects(captureProductState(client), /foreign_table_review_required/);
  assert.equal(calls.some(sql => sql.includes('FROM pg_class c') && sql.includes("c.relkind IN ('r', 'p', 'm')")), false);
  assert.equal(calls.at(-1), 'ROLLBACK');
});

test('migration child environment carries only the restored target and disposable role credentials', t => {
  const { baseline, pgpass } = fixture(t);
  const env = validEnv(baseline, pgpass);
  const target = new URL(env.RESTORE_PRODUCT_TARGET_URL);
  let random = 0;
  const child = safeChildEnvironment(env, target, env.PRODUCT_REVIEWED_BASELINE_FILE, '/isolated/auth', '/isolated/db', size => {
    random++;
    return Buffer.alloc(size, random);
  });
  assert.equal(child.ADMIN_DATABASE_URL, target.toString());
  assert.equal(child.MIGRATION_ADOPT_LEGACY_CHECKSUMS, 'true');
  assert.equal(child.MIGRATION_LEGACY_BASELINE_FILE, env.PRODUCT_REVIEWED_BASELINE_FILE);
  assert.equal(child.SMS_LEARNING_WORKER_DB_PASSWORD, '');
  assert.equal(child.PGPASSFILE, pgpass);
  assert.equal(child.PP_RECOVERY_CONTAINER, 'pandapay-recovery-0123456789abcdef');
  assert.equal(child.PP_RECOVERY_HOST_PORT, '55432');
  assert.notEqual(child.APP_USER_PASSWORD, child.REWARD_WORKER_DB_PASSWORD);
  for (const forbidden of [
    'PRODUCT_DATABASE_URL', 'AUTH_DATABASE_URL', 'AUTH_MIGRATION_DATABASE_URL',
    'ENCRYPTION_KEY', 'PHONE_LOOKUP_HMAC_KEY', 'PP_RECOVERY_PASSWORD',
  ]) assert.equal(Object.hasOwn(child, forbidden), false);
  assert.equal(child.PATH, env.PATH);
});

test('row fingerprint cursor orders canonical JSON text under C collation', async () => {
  const calls = [];
  const client = { async query(sql) {
    calls.push(sql);
    if (sql.startsWith('FETCH')) return { rows: calls.filter(call => call.startsWith('FETCH')).length === 1
      ? [{ canonical: '{"id": 1}' }] : [] };
    return { rows: [] };
  } };
  const result = await hashTableRowsWithCursor(client, 'public', 'profiles', ['id']);
  const declare = calls.find(sql => sql.startsWith('DECLARE'));
  assert.match(declare, /SELECT canonical\s+FROM\s*\(\s*SELECT to_jsonb\(t\)::text AS canonical/s);
  assert.match(declare, /ORDER BY canonical COLLATE "C"/);
  assert.equal(result.rows, 1);
});

test('recovery adapter inputs and pgpass path are bounded before inheritance', t => {
  const { baseline, pgpass } = fixture(t);
  const env = validEnv(baseline, pgpass);
  for (const invalid of [
    { ...env, PP_RECOVERY_CONTAINER: 'unexpected-container' },
    { ...env, PP_RECOVERY_HOST_PORT: '65536' },
    { ...env, PGPASSFILE: path.join(path.dirname(pgpass), 'missing') },
  ]) assert.throws(() => safeChildEnvironment(invalid, new URL(env.RESTORE_PRODUCT_TARGET_URL), baseline, '/auth', '/db'));
});

test('failure diagnostics expose only fixed categories', () => {
  assert.equal(safeFailureCategory(new Error('contact secret from database')), 'operation_failed');
  assert.equal(safeFailureCategory({ rehearsalCode: 'migration_checksum_drift', message: 'customer data' }), 'migration_checksum_drift');
  assert.equal(safeFailureCategory({ rehearsalCode: 'customer@example.com', message: 'leak' }), 'operation_failed');
});

test('bounded migration diagnostics retain only an anchored allowlisted category', async () => {
  const canonical = "Product database migration failed: {\n  code: 'migration_failed',\n  category: 'role_setup_failed'\n}\n";
  assert.equal(safeProductMigrationCategory(canonical), 'migration_role_setup_failed');
  assert.equal(safeProductMigrationCategory('Product database migration failed: {"code":"migration_failed","category":"legacy_baseline_review_required"}\n'), 'migration_legacy_baseline_review_required');
  assert.equal(safeProductMigrationCategory('Product database migration failed: {"code":"42703","migration":"0012_fixture.sql","category":"operation_failed"}\n'), 'migration_operation_failed');
  assert.equal(safeProductMigrationCategory('Runtime warning containing private data\nProduct database migration failed: {"code":"migration_failed","category":"legacy_baseline_review_required"}\n'), 'migration_legacy_baseline_review_required');
  assert.equal(safeProductMigrationCategory('Product database migration failed: {"code":"migration_failed","category":"operation_failed","message":"secret"}\n'), null);
  assert.equal(safeProductMigrationCategory(`prefix ${canonical}`), null);
  assert.equal(safeProductMigrationCategory("Product database migration failed: { code: 'migration_failed', category: 'customer@example.com' }"), null);

  const jsonDiagnostic = 'Product database migration failed: {"code":"migration_failed","category":"role_setup_failed"}\n';
  const fakeSpawn = (_command, _args, options) => {
    const child = new (require('node:events').EventEmitter)();
    child.stderr = new (require('node:events').EventEmitter)();
    child.kill = () => {};
    process.nextTick(() => {
      child.stderr.emit('data', Buffer.from(jsonDiagnostic + 'Sensitive contact and DB detail: person@example.com\n'));
      child.emit('close', 1);
    });
    assert.deepEqual(options.stdio, ['ignore', 'ignore', 'pipe']);
    return child;
  };
  await assert.rejects(runBounded('node', [], { spawn: fakeSpawn, timeoutMs: 1000, phase: 'apply' }), error => {
    assert.equal(error.rehearsalCode, 'migration_role_setup_failed');
    assert.equal(error.message, 'migration_role_setup_failed');
    assert.equal(error.rehearsalStage, 'apply');
    assert.equal(error.message.includes('person@example.com'), false);
    return true;
  });
});

test('bounded command failures classify only fixed missing-module categories and retain their stage', async () => {
  const spawnError = (_command, _args, options) => {
    const child = new (require('node:events').EventEmitter)();
    child.stderr = new (require('node:events').EventEmitter)();
    child.kill = () => {};
    process.nextTick(() => {
      const error = new Error('private executable path');
      error.code = 'ENOENT';
      child.emit('error', error);
    });
    assert.deepEqual(options.stdio, ['ignore', 'ignore', 'pipe']);
    return child;
  };
  await assert.rejects(runBounded('node', [], { spawn: spawnError, timeoutMs: 1000, phase: 'preflight' }), error => {
    assert.equal(error.rehearsalCode, 'migration_spawn_not_found');
    assert.equal(error.rehearsalStage, 'preflight');
    assert.equal(error.message, 'migration_spawn_not_found');
    return true;
  });

  const moduleError = (_command, _args) => {
    const child = new (require('node:events').EventEmitter)();
    child.stderr = new (require('node:events').EventEmitter)();
    child.kill = () => {};
    process.nextTick(() => {
      child.stderr.emit('data', Buffer.from("Error: Cannot find module '/private/secret/path/module.js'\n"));
      child.emit('close', 1);
    });
    return child;
  };
  await assert.rejects(runBounded('node', [], { spawn: moduleError, timeoutMs: 1000, phase: 'replay' }), error => {
    assert.equal(error.rehearsalCode, 'migration_node_module_not_found');
    assert.equal(error.rehearsalStage, 'replay');
    assert.equal(error.message.includes('/private/secret'), false);
    return true;
  });
});

test('data equality uses original table columns and preserves every original ledger identity', () => {
  const tableKey = 'public\u0000profiles';
  const before = {
    tables: new Map([[tableKey, { columns: ['id', 'history'] }]]),
    fingerprints: new Map([[tableKey, { rows: 2, sha256: 'a'.repeat(64) }]]),
    ledger: [{ filename: '0001.sql', appliedAt: '2026-01-01 00:00:00+00' }],
  };
  const after = {
    tables: new Map([[tableKey, { columns: ['id', 'history', 'new_column'] }]]),
    fingerprints: new Map([[tableKey, { rows: 2, sha256: 'a'.repeat(64) }]]),
    ledger: [
      { filename: '0001.sql', appliedAt: '2026-01-01 00:00:00+00' },
      { filename: '0002.sql', appliedAt: '2026-01-02 00:00:00+00' },
    ],
  };
  assert.doesNotThrow(() => assertOriginalTablesPreserved(before, after));
  after.fingerprints.set(tableKey, { rows: 3, sha256: 'b'.repeat(64) });
  assert.throws(() => assertOriginalTablesPreserved(before, after), /table_data_changed/);
});

test('role preservation keeps existing worker roles and rejects optional SMS role creation', () => {
  const required = [
    { rolname: 'app_user', rolcanlogin: true, rolsuper: false, rolbypassrls: false },
    { rolname: 'rewards_worker_login', rolcanlogin: true, rolsuper: false, rolbypassrls: false },
  ];
  assert.doesNotThrow(() => assertRuntimeRolesPreserved(required, required));
  assert.throws(() => assertRuntimeRolesPreserved(required, [
    ...required,
    { rolname: 'sms_learning_worker', rolcanlogin: true, rolsuper: false, rolbypassrls: false },
  ]), /optional_worker_created/);
  assert.throws(() => assertRuntimeRolesPreserved(required, [required[0]]), /runtime_role_unavailable/);
});

test('all product ledger entries must match known local migration checksums', t => {
  const { firstSql, secondSql } = fixture(t);
  const inventory = () => [['0001_existing.sql', firstSql], ['0002_new.sql', secondSql]];
  const hash = file => require('node:crypto').createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  assert.equal(assertProductLedger([
    { filename: '0001_existing.sql', checksum: hash(firstSql) },
    { filename: '0002_new.sql', checksum: hash(secondSql) },
  ], inventory, '/unused'), 2);
  for (const ledger of [
    [{ filename: 'removed.sql', checksum: hash(firstSql) }],
    [{ filename: '0001_existing.sql', checksum: '0'.repeat(64) }],
    [{ filename: '0001_existing.sql', checksum: null }],
  ]) assert.throws(() => assertProductLedger(ledger, inventory, '/unused'));
});

test('rehearsal orders check, apply, replay and verifies the synthetic restored copy', async t => {
  const { root, baseline, firstSql, secondSql } = fixture(t);
  const env = validEnv(baseline);
  let applied = false;
  const roles = [
    { rolname: 'app_user', rolcanlogin: true, rolsuper: false, rolbypassrls: false },
    { rolname: 'rewards_worker_login', rolcanlogin: true, rolsuper: false, rolbypassrls: false },
  ];
  const client = {
    async connect() {},
    async query(sql) {
      if (sql.includes('FROM pg_class c')) return { rows: [
        { schema_name: 'public', table_name: 'profiles', column_name: 'id', ordinal: 1 },
        { schema_name: 'public', table_name: 'profiles', column_name: 'history', ordinal: 2 },
        ...(applied ? [{ schema_name: 'public', table_name: 'profiles', column_name: 'new_migration_column', ordinal: 3 }] : []),
      ] };
      if (sql.includes('to_regclass')) return { rows: [{ present: true }] };
      if (sql.includes('FROM public.schema_migrations')) return { rows: [
        { filename: '0001_existing.sql', applied_at: '2026-01-01 00:00:00+00', checksum: applied ? require('node:crypto').createHash('sha256').update(fs.readFileSync(firstSql)).digest('hex') : null },
        ...(applied ? [{ filename: '0002_new.sql', applied_at: '2026-01-02 00:00:00+00', checksum: require('node:crypto').createHash('sha256').update(fs.readFileSync(secondSql)).digest('hex') }] : []),
      ] };
      if (sql.includes('FROM pg_roles')) return { rows: roles };
      return { rows: [] };
    },
  };
  const order = [];
  const fingerprintColumns = [];
  const runner = { migrationInventory: () => [['0001_existing.sql', firstSql], ['0002_new.sql', secondSql]] };
  const result = await runProductUpgrade({
    env, client, runner, dbDir: root, authDir: path.join(root, 'auth'),
    fingerprintTable: async (_client, _schema, _table, columns) => {
      fingerprintColumns.push(columns);
      return { rows: 2, sha256: 'a'.repeat(64) };
    },
    runMigration: async (command, childEnv, phase) => {
      order.push([command, phase]);
      assert.equal(childEnv.MIGRATION_ADOPT_LEGACY_CHECKSUMS, 'true');
      assert.equal(childEnv.SMS_LEARNING_WORKER_DB_PASSWORD, '');
      if (command === 'apply') applied = true;
    },
  });
  assert.deepEqual(order, [['--check', 'preflight'], ['apply', 'apply'], ['apply', 'replay']]);
  assert.deepEqual(fingerprintColumns, [['id', 'history'], ['id', 'history']]);
  assert.deepEqual(result, { tablesPreserved: 1, ledgerEntriesVerified: 2, runtimeRolesPreserved: 2, applyReplay: true });
});
