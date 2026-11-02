'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { safeMigrationDiagnostic } = require('../scripts/product_migrate');
test('product migration diagnostics omit database messages, details and nested causes', () => {
  const secret = 'customer@example.invalid bearer-private-token';
  const error = Object.assign(new Error(secret), { detail: secret,
    cause: { code: '23505', message: secret, detail: secret } });
  const diagnostic = safeMigrationDiagnostic(error);
  assert.equal(diagnostic.code, '23505');
  assert.ok(!JSON.stringify(diagnostic).includes(secret));
  assert.ok(!JSON.stringify(diagnostic).includes('customer'));
});
test('product migration diagnostics retain reviewed filenames and fixed failure category', () => {
  assert.deepEqual(safeMigrationDiagnostic(Object.assign(new Error('Product migration failed'), {
    migrationFile: '0002_example.sql', cause: { code: '42501' },
  })), { code: '42501', migration: '0002_example.sql', category: 'operation_failed' });
  assert.equal(safeMigrationDiagnostic(new Error('Applied migration checksum mismatch: private-value')).category, 'ledger_checksum');
  assert.ok(!Object.hasOwn(safeMigrationDiagnostic({ migrationFile: 'private@example.invalid', code: 'private-token' }), 'migration'));
});
test('product migration diagnostics classify safe infrastructure causes without retaining stderr', () => {
  const secret = 'postgres://private-user:private-password@example.invalid/private-db';
  const diagnostic = safeMigrationDiagnostic(Object.assign(new Error('Command failed: pg_dump'), {
    stderr: Buffer.from(`pg_dump: error: aborting because of server version mismatch\n${secret}`),
  }));
  assert.deepEqual(diagnostic, { code: 'migration_failed', category: 'pg_dump_version_mismatch' });
  assert.equal(JSON.stringify(diagnostic).includes(secret), false);
  assert.equal(safeMigrationDiagnostic(Object.assign(new Error('Command failed: pg_dump'), {
    stderr: 'pg_dump: error: permission denied for schema private',
  })).category, 'schema_dump_permission_denied');
});
test('baseline failures expose only a safe phase and category', () => {
  const dumpError = Object.assign(new Error('Command failed: pg_dump --dbname secret'), {
    baselinePhase: 'schema_dump', stderr: Buffer.from('password=secret')
  });
  assert.deepEqual(safeMigrationDiagnostic(dumpError), {
    code: 'migration_failed', phase: 'schema_dump', category: 'schema_dump_failed'
  });
  const catalogError = Object.assign(new Error('ACL inventory is unavailable'), {
    baselinePhase: 'catalog_fingerprint'
  });
  assert.deepEqual(safeMigrationDiagnostic(catalogError), {
    code: 'migration_failed', phase: 'catalog_fingerprint', category: 'schema_fingerprint_failed'
  });
});
