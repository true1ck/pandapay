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
