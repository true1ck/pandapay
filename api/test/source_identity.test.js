'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { importSourceKey, emailSourceKey } = require('../src/source_identity');

test('the same forwarded email keeps one identity across provider message ids', () => {
  const first = emailSourceKey('user-1', 'alerts@bank.test', 'Purchase', 'INR 499 at AMAZON', 'provider-1');
  const second = emailSourceKey('user-1', 'alerts@bank.test', 'Purchase', 'INR 499 at AMAZON', 'provider-2');
  assert.equal(second, first);
});

test('email identity ignores transport-only whitespace and line-ending changes', () => {
  const first = emailSourceKey('user-1', 'alerts@bank.test', 'Purchase', 'INR 499\r\nat AMAZON', 'one');
  const second = emailSourceKey('user-1', 'alerts@bank.test', ' Purchase ', 'INR 499   at AMAZON', 'two');
  assert.equal(second, first);
});

test('a materially different email remains a different transaction observation', () => {
  const first = emailSourceKey('user-1', 'alerts@bank.test', 'Purchase', 'INR 499 at AMAZON', 'one');
  const second = emailSourceKey('user-1', 'alerts@bank.test', 'Purchase', 'INR 799 at AMAZON', 'two');
  assert.notEqual(second, first);
});

test('source identities are scoped to one profile', () => {
  const occurred = new Date('2026-09-09T12:00:00Z');
  assert.notEqual(
    importSourceKey('user-1', 'BANK', 'INR 499', occurred),
    importSourceKey('user-2', 'BANK', 'INR 499', occurred),
  );
});
