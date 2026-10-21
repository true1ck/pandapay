const test = require('node:test');
const assert = require('node:assert/strict');
const learning = require('../src/sms_learning');

test('sender fingerprints are stable HMACs and do not expose sender text', () => {
  const key = 'test-learning-secret-key-0123456789';
  const first = learning.senderFingerprint('VM-HDFCBK-S', key);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(first, learning.senderFingerprint(' vm-hdfcbk-s ', key));
  assert.notEqual(first, learning.senderFingerprint('VM-ICICIB-S', key));
  assert.equal(learning.senderFingerprint('VM-HDFCBK-S', 'short'), null);
});

test('changedSafeFields records field names only and ignores arbitrary keys', () => {
  assert.deepEqual(
    learning.changedSafeFields(
      { amountDueInr: 1200, dueDate: '2026-11-01', accountNumber: '123456' },
      { amountDueInr: 1400, dueDate: '2026-11-01', accountNumber: '654321', arbitrary: 'secret' },
    ),
    ['amountDueInr'],
  );
});

test('confirmed correction inserts only dedup hash, sender fingerprint, family and field label', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'test-learning-secret-key-0123456789';
  const calls = [];
  try {
    const outcome = await learning.recordConfirmedCorrection({
      async query(sql, params) {
        calls.push({ sql, params });
        if (sql.startsWith('SELECT contributions_opt_in')) {
          return { rows: [{ contributions_opt_in: true }] };
        }
        return { rowCount: 1 };
      },
    }, {
      profileId: 'profile-1',
      sourceKey: 'a'.repeat(64),
      sender: 'VM-HDFCBK-S',
      family: 'bill_obligation',
      fields: ['amountDueInr', 'accountNumber', 'amountDueInr'],
    });
    assert.equal(outcome.recorded, 1);
    assert.equal(calls.length, 2);
    assert.deepEqual(calls[0].params, ['profile-1']);
    assert.equal(calls[1].params[0], 'profile-1');
    assert.equal(calls[1].params[1], 'a'.repeat(64));
    assert.match(calls[1].params[2], /^[0-9a-f]{64}$/);
    assert.deepEqual(calls[1].params.slice(3), ['bill_obligation', 'amountDueInr']);
    assert.doesNotMatch(JSON.stringify(calls), /VM-HDFCBK-S|accountNumber|secret|1200/);
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});

test('shared learning stays disabled when profile contribution consent is off', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'test-learning-secret-key-0123456789';
  const calls = [];
  try {
    const outcome = await learning.recordConfirmedCorrection({
      async query(sql, params) {
        calls.push({ sql, params });
        return { rows: [{ contributions_opt_in: false }], rowCount: 1 };
      },
    }, {
      profileId: 'profile-1', sourceKey: 'a'.repeat(64), sender: 'SENDER',
      family: 'bill_obligation', fields: ['amountDueInr'],
    });
    assert.deepEqual(outcome, { recorded: 0, disabled: true });
    assert.equal(calls.length, 1);
    assert.match(calls[0].sql, /SELECT contributions_opt_in FROM profiles/);
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});

test('learning is disabled without a configured HMAC secret', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  delete process.env.SMS_LEARNING_HMAC_KEY;
  try {
    let called = false;
    const outcome = await learning.recordConfirmedCorrection({
      async query() { called = true; },
    }, {
      profileId: 'profile-1', sourceKey: 'a'.repeat(64), sender: 'SENDER',
      family: 'bill_obligation', fields: ['amountDueInr'],
    });
    assert.deepEqual(outcome, { recorded: 0, disabled: true });
    assert.equal(called, false);
  } finally {
    if (original !== undefined) process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});
