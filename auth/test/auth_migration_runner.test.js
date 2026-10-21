const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

process.env.NODE_ENV = 'test';
process.env.JWT_ACCESS_SECRET = 'migration-runner-test-access-secret';
process.env.JWT_REFRESH_SECRET = 'migration-runner-test-refresh-secret';
process.env.PHONE_LOOKUP_HMAC_KEY = 'test-phone-lookup-hmac-key-0123456789abcdef';

function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

test('auth migration runner applies the versioned digest migration once and backfills both tables', async () => {
  const migrationRunner = load('../scripts/migrate.js', {
    '../src/db': {},
    '../src/utils/encryptedPhoneSearch': require('../src/utils/encryptedPhoneSearch'),
    '../src/utils/fieldEncryption': { decryptPhoneNumber: value => value },
  });
  const applied = new Set();
  const records = {
    users: [{ id: 'u-1', phone_number: '+919876543210' }],
    otp_requests: [{ id: 'o-1', phone_number: '+918765432109' }],
  };
  const updates = [];
  const statements = [];
  const client = {
    async query(sql, args = []) {
      statements.push(sql.trim().split(/\s+/).slice(0, 4).join(' '));
      if (sql.includes('SELECT version FROM auth_schema_migrations')) {
        return { rows: applied.has(args[0]) ? [{ version: args[0] }] : [] };
      }
      if (sql.includes('INSERT INTO auth_schema_migrations')) {
        applied.add(args[0]); return { rows: [] };
      }
      if (sql.includes('SELECT id, phone_number FROM users')) return { rows: records.users };
      if (sql.includes('SELECT id, phone_number FROM otp_requests')) return { rows: records.otp_requests };
      if (sql.includes('UPDATE users SET phone_lookup_hash')) {
        updates.push({ table: 'users', hash: args[0], id: args[1] }); records.users = []; return { rows: [] };
      }
      if (sql.includes('UPDATE otp_requests SET phone_lookup_hash')) {
        updates.push({ table: 'otp_requests', hash: args[0], id: args[1] }); records.otp_requests = []; return { rows: [] };
      }
      return { rows: [] };
    },
    release() {},
  };
  let connects = 0;
  const pool = { async connect() { connects++; return client; } };
  await migrationRunner.runMigrations(pool);
  await migrationRunner.runMigrations(pool);
  assert.equal(connects, 2);
  assert.equal(applied.size, 1);
  assert.deepEqual(updates.map(update => update.table), ['users', 'otp_requests']);
  assert.equal(statements.filter(statement => statement === 'BEGIN').length, 1);
});

test('auth migration runner refuses to proceed without the stable digest key', async () => {
  const migrationRunner = load('../scripts/migrate.js', {
    '../src/db': {},
    '../src/utils/encryptedPhoneSearch': require('../src/utils/encryptedPhoneSearch'),
    '../src/utils/fieldEncryption': { decryptPhoneNumber: value => value },
  });
  const currentKey = process.env.PHONE_LOOKUP_HMAC_KEY;
  delete process.env.PHONE_LOOKUP_HMAC_KEY;
  let connected = false;
  try {
    await assert.rejects(
      migrationRunner.runMigrations({ async connect() { connected = true; } }),
      /PHONE_LOOKUP_HMAC_KEY/,
    );
  } finally {
    process.env.PHONE_LOOKUP_HMAC_KEY = currentKey;
  }
  assert.equal(connected, false);
});
