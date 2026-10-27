const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const learning = require('../src/sms_learning');

const VALID_KEY = 'test-learning-secret-key-0123456789';

test('sender fingerprints are stable HMACs and do not expose sender text', () => {
  const first = learning.senderFingerprint('VM-HDFCBK-S', VALID_KEY);
  assert.match(first, /^[0-9a-f]{64}$/);
  assert.equal(first, learning.senderFingerprint(' vm-hdfcbk-s ', VALID_KEY));
  assert.notEqual(first, learning.senderFingerprint('VM-ICICIB-S', VALID_KEY));
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
  process.env.SMS_LEARNING_HMAC_KEY = VALID_KEY;
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
  process.env.SMS_LEARNING_HMAC_KEY = VALID_KEY;
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

test('strict fail-closed when SMS_LEARNING_HMAC_KEY is missing or < 32 chars (no fallback secret)', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  try {
    // 1. Verify DEFAULT_HMAC_SECRET is removed
    assert.equal(learning.DEFAULT_HMAC_SECRET, undefined);

    for (const badKey of [undefined, '', 'short-key', 'too_short_less_than_32_chars!']) {
      if (badKey === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
      else process.env.SMS_LEARNING_HMAC_KEY = badKey;

      assert.equal(learning.getHmacKey(), null);
      assert.equal(learning.senderFingerprint('VM-HDFCBK-S'), null);
      assert.equal(learning.senderFingerprint('VM-HDFCBK-S', badKey), null);

      let dbTouched = false;
      const fakeClient = {
        async query() {
          dbTouched = true;
          return { rows: [] };
        },
      };

      // recordLearningExample must fail closed returning { recorded: 0, disabled: true, error: 'missing_hmac_secret' }
      const exRes = await learning.recordLearningExample(fakeClient, {
        profileId: '00000000-0000-0000-0000-000000000001',
        sender: 'VM-HDFCBK-S',
        factFamily: 'posted_movement',
        sampleBody: 'Spent Rs. 500 at Store',
      });
      assert.deepEqual(exRes, { recorded: 0, disabled: true, error: 'missing_hmac_secret' });
      assert.equal(dbTouched, false, 'DB should not be touched when HMAC key is missing/<32 chars');

      // recordConfirmedCorrection must return { recorded: 0, disabled: true }
      const corrRes = await learning.recordConfirmedCorrection(fakeClient, {
        profileId: '00000000-0000-0000-0000-000000000001',
        sourceKey: 'a'.repeat(64),
        sender: 'VM-HDFCBK-S',
        family: 'bill_obligation',
        fields: ['amountDueInr'],
      });
      assert.deepEqual(corrRes, { recorded: 0, disabled: true });
      assert.equal(dbTouched, false, 'DB should not be touched when HMAC key is missing/<32 chars');

      // New rows retain profile lineage, so consent revocation must still erase
      // them even when the historical HMAC key is unavailable.
      const delRes = await learning.deleteLearningExamplesForUser(fakeClient, '00000000-0000-0000-0000-000000000001');
      assert.equal(delRes, 0);
      assert.equal(dbTouched, true, 'erasure must run even when the HMAC key is missing');
    }
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});

test('opt-out consent check for recordLearningExample', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = VALID_KEY;
  try {
    const queries = [];
    const client = {
      async query(sql, params) {
        queries.push({ sql, params });
        if (sql.includes('FROM profiles')) {
          return { rows: [{ contributions_opt_in: false }] };
        }
        return { rows: [{ id: 'example-1' }] };
      },
    };

    const res = await learning.recordLearningExample(client, {
      profileId: '00000000-0000-0000-0000-000000000001',
      sender: 'VM-HDFCBK-S',
      factFamily: 'posted_movement',
      sampleBody: 'Spent Rs. 100 on Card ending 1234',
    });

    assert.deepEqual(res, { recorded: 0, disabled: true });
    assert.equal(queries.length, 1);
    assert.match(queries[0].sql, /SELECT contributions_opt_in FROM profiles/);

    // Profile missing altogether (no rows returned)
    queries.length = 0;
    const missingProfileClient = {
      async query(sql, params) {
        queries.push({ sql, params });
        return { rows: [] };
      },
    };
    const missingRes = await learning.recordLearningExample(missingProfileClient, {
      profileId: '00000000-0000-0000-0000-000000000002',
      sender: 'VM-HDFCBK-S',
      factFamily: 'posted_movement',
      sampleBody: 'Spent Rs. 100 on Card ending 1234',
    });
    assert.deepEqual(missingRes, { recorded: 0, disabled: true });
    assert.equal(queries.length, 1);
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});

test('learning feedback writes once on a database without the four-column conflict index', async () => {
  const rows = [];
  let inserts = 0;
  const client = {
    async query(sql, params) {
      if (sql.includes('FROM profiles')) return { rows: [{ contributions_opt_in: true }] };
      if (sql.includes('pg_advisory_xact_lock')) return { rows: [] };
      if (sql.startsWith('SELECT id FROM public.sms_learning_examples')) {
        return { rows: rows.length ? [{ id: rows[0].id }] : [] };
      }
      if (sql.includes('INSERT INTO public.sms_learning_examples')) {
        if (/ON CONFLICT\s*\(/.test(sql)) {
          const error = new Error('no matching unique constraint');
          error.code = '42P10';
          throw error;
        }
        inserts++;
        rows.push({ id: 'example-1', params });
        return { rows: [{ id: 'example-1' }] };
      }
      throw new Error(`unexpected query: ${sql}`);
    },
  };
  const input = {
    profileId: '00000000-0000-0000-0000-000000000001',
    sender: 'VM-HDFCBK-S',
    factFamily: 'ignore_noise',
    sampleBody: 'Your offer is available',
    hmacKey: VALID_KEY,
  };

  const first = await learning.recordLearningExample(client, input);
  const second = await learning.recordLearningExample(client, input);
  assert.equal(first.recorded, 1);
  assert.equal(second.recorded, 0);
  assert.equal(second.error, undefined);
  assert.equal(inserts, 1);
});

test('redaction of PII (card numbers, phone numbers, urls, emails)', async () => {
  const rawText = 'Paid Rs 1,500 for order at https://shop.example.com/checkout?ref=abc to merchant@example.in. Contact +919876543210 or 09876543210. Card 4111 2222 3333 4567 debited.';
  const redacted = learning.redactBody(rawText);

  assert.doesNotMatch(redacted, /https?:\/\//i);
  assert.ok(redacted.includes('[URL]'));

  assert.doesNotMatch(redacted, /merchant@example\.in/);
  assert.ok(redacted.includes('[EMAIL]'));

  assert.doesNotMatch(redacted, /9876543210/);
  assert.ok(redacted.includes('[PHONE]'));

  assert.doesNotMatch(redacted, /4111\s*2222\s*3333/);
  assert.ok(redacted.includes('XXXX4567'));

  // Verify that recordLearningExample redacts PII before database storage
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = VALID_KEY;
  try {
    let insertQuery = null;
    let insertParams = null;
    const client = {
      async query(sql, params) {
        if (sql.includes('FROM profiles')) {
          return { rows: [{ contributions_opt_in: true }] };
        }
        if (sql.includes('INSERT INTO public.sms_learning_examples')) {
          insertQuery = sql;
          insertParams = params;
          return { rows: [{ id: '00000000-0000-0000-0000-000000000099' }] };
        }
        return { rows: [] };
      },
    };

    const result = await learning.recordLearningExample(client, {
      profileId: '00000000-0000-0000-0000-000000000001',
      sender: 'VM-HDFCBK-S',
      factFamily: 'posted_movement',
      sampleBody: rawText,
      extractedFields: { amountInr: 1500, last4: '4567' },
    });

    assert.equal(result.recorded, 1);
    assert.equal(result.disabled, false);
    assert.ok(insertQuery);
    // insertParams[4] is sample_body
    const storedBody = insertParams[4];
    assert.doesNotMatch(storedBody, /https?:\/\//i);
    assert.doesNotMatch(storedBody, /merchant@example\.in/);
    assert.doesNotMatch(storedBody, /9876543210/);
    assert.doesNotMatch(storedBody, /4111\s*2222\s*3333/);
    assert.ok(storedBody.includes('[URL]'));
    assert.ok(storedBody.includes('[EMAIL]'));
    assert.ok(storedBody.includes('[PHONE]'));
    assert.ok(storedBody.includes('XXXX4567'));
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});

test('user deletion lineage via deleteLearningExamplesForUser', async () => {
  const original = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = VALID_KEY;
  try {
    const userId = '00000000-0000-0000-0000-000000000001';
    const calls = [];
    const client = {
      async query(sql, params) {
        calls.push({ sql, params });
        return { rows: [{ deleted: 4 }] };
      },
    };

    // 1. Using environment key
    const deletedCount = await learning.deleteLearningExamplesForUser(client, userId);
    assert.equal(deletedCount, 4);
    assert.equal(calls.length, 1);
    assert.match(calls[0].sql, /pandapay\.sms_delete_learning_examples_for_user/);
    assert.equal(calls[0].params[0], userId);
    assert.equal(calls[0].params[1], VALID_KEY);

    // Verify expected user_hash computation matches the key
    const expectedHash = crypto.createHmac('sha256', VALID_KEY).update(userId).digest('hex');
    assert.match(expectedHash, /^[0-9a-f]{64}$/);

    // 2. Using explicit valid key
    const explicitKey = 'explicit-custom-learning-key-32chars!';
    calls.length = 0;
    const customDeleted = await learning.deleteLearningExamplesForUser(client, userId, explicitKey);
    assert.equal(customDeleted, 4);
    assert.equal(calls[0].params[1], explicitKey);

    // 3. An invalid explicit key cannot erase legacy hash-only rows, but the
    // profile-linked erasure still runs without using an invalid key.
    calls.length = 0;
    const shortKeyDeleted = await learning.deleteLearningExamplesForUser(client, userId, 'too-short');
    assert.equal(shortKeyDeleted, 4);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].params[1], null);

    // 4. Missing profileId returns 0 without DB call
    calls.length = 0;
    const noUserDeleted = await learning.deleteLearningExamplesForUser(client, null);
    assert.equal(noUserDeleted, 0);
    assert.equal(calls.length, 0);
  } finally {
    if (original === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = original;
  }
});
