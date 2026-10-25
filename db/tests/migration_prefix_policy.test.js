'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { validateMigrationPrefixPolicy, DEFAULT_MANIFEST_PATH } = require('../scripts/migration_prefix_policy');
const { migrationInventory, runProductMigrations, preflightProductMigrations } = require('../scripts/product_migrate');
const { migrationFiles } = require('../../auth/scripts/migrate');

function actualInventory() {
  const db = path.resolve(__dirname, '..');
  return {
    product_migrations: fs.readdirSync(path.join(db, 'supabase/migrations')).filter(name => /^\d+_.*\.sql$/.test(name)),
    product_seeds: fs.readdirSync(path.join(db, 'seed')).filter(name => /^\d+_.*\.sql$/.test(name)),
    auth_migrations: fs.readdirSync(path.join(db, '../auth/db/migrations')).filter(name => /^\d+_.*\.sql$/.test(name)),
  };
}

test('current full inventories retain exact reviewed historical collisions', () => {
  assert.equal(validateMigrationPrefixPolicy(actualInventory()), true);
  assert.ok(migrationInventory(path.resolve(__dirname, '..')).length > 90);
});

test('unique new prefixes are accepted but additional historical and new collisions are refused', () => {
  const inventories = actualInventory();
  inventories.product_migrations.push('20261024010000_future.sql');
  assert.equal(validateMigrationPrefixPolicy(inventories), true);
  for (const extra of ['0037_extra.sql', '37_equivalent_version.sql', '20261024010000_collision.sql']) {
    assert.throws(() => validateMigrationPrefixPolicy({ ...inventories,
      product_migrations: [...inventories.product_migrations, extra] }), /collision/);
  }
  assert.throws(() => validateMigrationPrefixPolicy({ ...inventories,
    auth_migrations: [...inventories.auth_migrations, '0001_duplicate.sql'] }), /collision/);
});

test('removing or renaming reviewed history cannot broaden an exception', () => {
  const inventories = actualInventory();
  const names = inventories.product_migrations.filter(name => name !== '0037_card_catalogue_import.sql');
  assert.throws(() => validateMigrationPrefixPolicy({ ...inventories, product_migrations: names }), /no longer matches/);
  assert.throws(() => validateMigrationPrefixPolicy({ ...inventories,
    product_migrations: [...names, '0037_replacement.sql'] }), /collision/);
});

test('unreadable/malformed manifests and duplicate filenames fail closed', t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prefix-policy-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const file = path.join(dir, 'exceptions.json');
  for (const data of ['{', '{}', JSON.stringify({ ...JSON.parse(fs.readFileSync(DEFAULT_MANIFEST_PATH)), extra: true })]) {
    fs.writeFileSync(file, data);
    assert.throws(() => validateMigrationPrefixPolicy(actualInventory(), { manifestPath: file }), /manifest/);
  }
  assert.throws(() => validateMigrationPrefixPolicy({ auth_migrations: ['0001_a.sql', '0001_a.sql'] }, { manifestPath: null }), /duplicate/);
});

test('product apply and preflight reject collisions before contacting a database', async t => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'prefix-before-ddl-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  fs.mkdirSync(path.join(dir, 'supabase/migrations'), { recursive: true });
  for (const name of ['0001_a.sql', '0001_b.sql']) fs.writeFileSync(path.join(dir, 'supabase/migrations', name), 'SELECT 1;');
  let calls = 0;
  const client = { query() { calls++; assert.fail('invalid inventory must not reach a DB'); } };
  await assert.rejects(runProductMigrations(client, { dbDir: dir }), /collision/);
  await assert.rejects(preflightProductMigrations(client, { dbDir: dir }), /collision/);
  assert.equal(calls, 0);
  assert.throws(() => migrationFiles(path.join(dir, 'supabase/migrations')), /collision/);
});
