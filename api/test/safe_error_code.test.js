'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { safeErrorCode } = require('../src/safeErrorCode');

test('safeErrorCode keeps supported SQL and platform codes', () => {
  assert.equal(safeErrorCode({ code: '23505', message: 'duplicate contact@example.com' }), '23505');
  assert.equal(safeErrorCode({ code: 'ECONNRESET', message: 'token=secret' }), 'ECONNRESET');
  assert.equal(safeErrorCode({ name: 'TypeError', message: 'private payload' }), 'TypeError');
});

test('safeErrorCode drops arbitrary messages, nested causes, and provider response bodies', () => {
  const marker = 'customer@example.com bearer-secret sql: select * from profiles';
  const error = Object.assign(new Error(marker), {
    code: `provider_${marker}`,
    cause: { message: marker, body: marker },
    response: { body: marker },
  });
  const captured = [];
  const originalError = console.error;
  try {
    console.error = (...args) => captured.push(args);
    console.error('remote notification delivery failed', safeErrorCode(error));
  } finally {
    console.error = originalError;
  }

  assert.deepEqual(captured, [['remote notification delivery failed', 'Error']]);
  assert.equal(JSON.stringify(captured).includes(marker), false);
});

test('safeErrorCode rejects malformed and oversized identifiers', () => {
  assert.equal(safeErrorCode({ code: '23505\ncustomer@example.com' }), 'Error');
  assert.equal(safeErrorCode({ code: 'E' + 'A'.repeat(100) }), 'Error');
  assert.equal(safeErrorCode({ name: 'CustomerError', message: 'sensitive' }), 'Error');
});
