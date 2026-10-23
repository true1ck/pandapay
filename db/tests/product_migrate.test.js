'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { statements, transactionalSql, runProductMigrations, migrationInventory, legacyBaseline, captureReadOnlyBaseline, preflightProductMigrations, safeMigrationDiagnostic } = require('../scripts/product_migrate');
const { safeProductMigrationCategory } = require('../scripts/rehearse_product_upgrade');

test('product CLI diagnostic is one machine-readable safe JSON line', () => {
  const diagnostic = safeMigrationDiagnostic(new Error('customer@example.com and raw SQL must stay private'));
  const line = `Product database migration failed: ${JSON.stringify(diagnostic)}`;
  assert.deepEqual(JSON.parse(line.slice('Product database migration failed: '.length)), {
    code: 'migration_failed', category: 'operation_failed',
  });
  assert.equal(line.includes('customer@example.com'), false);
  assert.equal(safeProductMigrationCategory(line), 'migration_operation_failed');
});

test('the complete existing product migration chain can be ledgered transactionally', () => {
  const dir = path.resolve(__dirname, '../supabase/migrations');
  for (const file of fs.readdirSync(dir).filter(name => name.endsWith('.sql') && name !== '0013_cron_jobs.sql')) {
    assert.doesNotThrow(() => transactionalSql(fs.readFileSync(path.join(dir, file), 'utf8')), file);
  }
});
test('outer transactions are normalized without changing quoted SQL and PL/pgSQL', () => {
  const inner = "DO $job$ BEGIN RAISE NOTICE 'COMMIT;'; END $job$;\nSELECT 'a;''b';";
  assert.deepEqual(statements(transactionalSql(`-- historical migration\nBEGIN;\n${inner}\nCOMMIT; -- done`)).map(value => value.trim()).filter(Boolean), statements(inner).map(value => value.trim()).filter(Boolean));
  for (const sql of ['BEGIN; SELECT 1;', 'CREATE INDEX CONCURRENTLY x ON y(z);', 'SELECT 1; COMMIT;', '\\i unexpected.sql']) {
    assert.throws(() => transactionalSql(sql), /transaction|job/);
  }
});

function fixture(t, { applied = [], failSql = false, acquired = true } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'product-migration-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, 'supabase/migrations'), { recursive: true });
  fs.writeFileSync(path.join(dir, 'supabase/migrations/0001_fixture.sql'), 'CREATE TABLE fixture(id integer);');
  const calls = [];
  const client = { schemaFingerprint: async () => 'synthetic-schema-fingerprint', async query(sql, params) {
    calls.push({ sql, params });
    if (sql.includes('pg_try_advisory_lock')) return { rows: [{ acquired }] };
    if (sql === 'SELECT pg_export_snapshot() AS snapshot') return { rows: [{ snapshot: '00000005-0000006D-1' }] };
    if (sql.startsWith('SELECT filename')) return { rows: applied };
    if (failSql && sql.includes('CREATE TABLE fixture')) throw new Error('synthetic failure');
    return { rows: [] };
  } };
  return { client, calls, options: { dbDir: dir } };
}
test('DDL and checksum ledger commit atomically and release the session lock', async t => {
  const f = fixture(t);
  await runProductMigrations(f.client, f.options);
  const sql = f.calls.map(call => call.sql);
  assert.ok(sql.indexOf('BEGIN') < sql.findIndex(value => value.includes('CREATE TABLE fixture')));
  assert.ok(sql.findIndex(value => value.startsWith('INSERT INTO schema_migrations')) < sql.indexOf('COMMIT'));
  assert.match(sql.at(-1), /pg_advisory_unlock/);
});
test('failed DDL rolls back and never writes a success ledger entry', async t => {
  const f = fixture(t, { failSql: true });
  await assert.rejects(runProductMigrations(f.client, f.options), /0001_fixture/);
  assert.ok(f.calls.some(call => call.sql === 'ROLLBACK'));
  assert.equal(f.calls.some(call => call.sql.startsWith('INSERT INTO schema_migrations')), false);
  assert.match(f.calls.at(-1).sql, /pg_advisory_unlock/);
});
test('changed history and unreviewed checksum adoption fail before new DDL', async t => {
  for (const checksum of [null, 'wrong']) {
    const f = fixture(t, { applied: [{ filename: '0001_fixture.sql', checksum }] });
    await assert.rejects(runProductMigrations(f.client, f.options), /checksum/);
    assert.equal(f.calls.some(call => call.sql === 'BEGIN'), false);
  }
});
test('explicit reviewed adoption records checksum without replaying historical DDL', async t => {
  const f = fixture(t, { applied: [{ filename: '0001_fixture.sql', checksum: null }] });
  const baselineFile = path.join(f.options.dbDir, 'reviewed-baseline.json');
  fs.writeFileSync(baselineFile, JSON.stringify(await legacyBaseline(f.client, migrationInventory(f.options.dbDir), ['0001_fixture.sql'])));
  const snapshots = [];
  f.client.schemaFingerprint = async snapshot => { snapshots.push(snapshot); return 'synthetic-schema-fingerprint'; };
  await runProductMigrations(f.client, { ...f.options, adoptLegacyChecksums: true, legacyBaselineFile: baselineFile });
  assert.deepEqual(snapshots, ['00000005-0000006D-1']);
  assert.equal(f.calls.some(call => call.sql.includes('CREATE TABLE fixture')), false);
  const update = f.calls.find(call => call.sql.startsWith('UPDATE schema_migrations'));
  assert.match(update.params[0], /^[a-f0-9]{64}$/);
  assert.ok(f.calls.findIndex(call => call.sql === 'COMMIT') < f.calls.indexOf(update));
});
test('unknown historical migrations and changed reviewed schema block adoption', async t => {
  const unknown = fixture(t, { applied: [{ filename: 'removed.sql', checksum: 'x' }] });
  await assert.rejects(runProductMigrations(unknown.client, unknown.options), /Unknown applied/);
  const f = fixture(t, { applied: [{ filename: '0001_fixture.sql', checksum: null }] });
  const baselineFile = path.join(f.options.dbDir, 'reviewed-baseline.json');
  fs.writeFileSync(baselineFile, JSON.stringify(await legacyBaseline(f.client, migrationInventory(f.options.dbDir), ['0001_fixture.sql'])));
  f.client.schemaFingerprint = async () => 'changed-schema';
  await assert.rejects(runProductMigrations(f.client, { ...f.options, adoptLegacyChecksums: true, legacyBaselineFile: baselineFile }), /differs/);
  assert.equal(f.calls.some(call => call.sql === 'BEGIN'), false);
});
test('legacy v1 baseline is rejected and requires a fresh independently reviewed v2 capture', async t => {
  const f = fixture(t, { applied: [{ filename: '0001_fixture.sql', checksum: null }] });
  const baselineFile = path.join(f.options.dbDir, 'legacy-v1.json');
  fs.writeFileSync(baselineFile, JSON.stringify({
    format: 'pandapay-reviewed-product-baseline-v1', ledger: [['0001_fixture.sql', 'old']], schemaSha256: 'old',
  }));
  await assert.rejects(runProductMigrations(f.client, {
    ...f.options, adoptLegacyChecksums: true, legacyBaselineFile: baselineFile,
  }), /v2 legacy baseline/);
});
test('a concurrent migration cannot start any DDL', async t => {
  const f = fixture(t, { acquired: false });
  await assert.rejects(runProductMigrations(f.client, f.options), /Another product migration/);
  assert.equal(f.calls.some(call => call.sql.startsWith('CREATE TABLE')), false);
});
test('read-only baseline ledger and schema dump share one held snapshot', async t => {
  const f = fixture(t, { applied: [{ filename: '0001_fixture.sql' }] });
  const query = f.client.query.bind(f.client);
  f.client.query = async (sql, params) => {
    if (sql === 'SELECT pg_export_snapshot() AS snapshot') {
      f.calls.push({ sql, params });
      return { rows: [{ snapshot: '00000005-0000006D-1' }] };
    }
    return query(sql, params);
  };
  f.client.schemaFingerprint = async snapshot => {
    assert.equal(snapshot, '00000005-0000006D-1');
    assert.equal(f.calls.at(-1).sql, 'SELECT filename FROM schema_migrations ORDER BY filename');
    return 'synthetic-schema-fingerprint';
  };
  const result = await captureReadOnlyBaseline(f.client, migrationInventory(f.options.dbDir));
  assert.equal(result.ledger.length, 1);
  assert.equal(f.calls[0].sql, 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  assert.equal(f.calls.at(-1).sql, 'COMMIT');
  assert.equal(f.calls.some(call => /^(CREATE|ALTER|UPDATE|INSERT|DELETE)/.test(call.sql)), false);
});
test('baseline failure releases the held read-only snapshot', async t => {
  const f = fixture(t);
  const query = f.client.query.bind(f.client);
  f.client.query = async (sql, params) => {
    if (sql === 'SELECT pg_export_snapshot() AS snapshot') {
      f.calls.push({ sql, params });
      return { rows: [] };
    }
    return query(sql, params);
  };
  await assert.rejects(captureReadOnlyBaseline(f.client, migrationInventory(f.options.dbDir)), /snapshot is unavailable/);
  assert.equal(f.calls.at(-1).sql, 'ROLLBACK');
});

function preflightFixture(t, options = {}) {
  const f = fixture(t, options);
  const query = f.client.query.bind(f.client);
  f.client.query = async (sql, params) => {
    if (sql === 'SELECT pg_export_snapshot() AS snapshot') {
      f.calls.push({ sql, params });
      return { rows: [{ snapshot: '00000005-0000006D-1' }] };
    }
    if (sql.includes('to_regclass')) {
      f.calls.push({ sql, params });
      return { rows: [{ present: options.present !== false }] };
    }
    return query(sql, params);
  };
  return f;
}
test('empty database preflight is read-only and reports pending work without bootstrapping', async t => {
  const f = preflightFixture(t, { present: false });
  assert.deepEqual(await preflightProductMigrations(f.client, f.options), { applied: 0, legacy: 0, pending: 1 });
  assert.equal(f.calls[0].sql, 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  assert.equal(f.calls.at(-1).sql, 'COMMIT');
  assert.equal(f.calls.some(call => /^(CREATE|ALTER|UPDATE|INSERT|DELETE)/.test(call.sql)), false);
});
test('legacy preflight requires matching reviewed schema/history but never adopts checksums', async t => {
  const f = preflightFixture(t, { applied: [{ filename: '0001_fixture.sql', checksum: null }] });
  await assert.rejects(preflightProductMigrations(f.client, f.options), /reviewed/);
  assert.equal(f.calls.at(-1).sql, 'ROLLBACK');
  const file = path.join(f.options.dbDir, 'baseline.json');
  fs.writeFileSync(file, JSON.stringify(await legacyBaseline(f.client, migrationInventory(f.options.dbDir), ['0001_fixture.sql'])));
  f.client.schemaFingerprint = async snapshot => {
    assert.equal(snapshot, '00000005-0000006D-1');
    return 'synthetic-schema-fingerprint';
  };
  assert.deepEqual(await preflightProductMigrations(f.client, { ...f.options, adoptLegacyChecksums: true, legacyBaselineFile: file }),
    { applied: 1, legacy: 1, pending: 0 });
  assert.equal(f.calls.some(call => /^(CREATE|ALTER|UPDATE|INSERT|DELETE)/.test(call.sql)), false);
});
test('preflight rejects unknown history before generating any schema fingerprint', async t => {
  const f = preflightFixture(t, { applied: [{ filename: '0002_unreviewed.sql', checksum: null }] });
  f.client.schemaFingerprint = () => { throw new Error('must not run'); };
  await assert.rejects(preflightProductMigrations(f.client, f.options), /Unknown applied/);
  assert.equal(f.calls.at(-1).sql, 'ROLLBACK');
});
