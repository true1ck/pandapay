'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  DATA_ERROR_REPORT_LIMITS, VISIBLE_CARD_SQL, REPORT_METADATA_SQL, INSERT_DATA_ERROR_REPORT_SQL,
  createDataErrorReportHandler, registerDataErrorReportRoute,
} = require('../src/data_error_reports');
const { createFeedbackRateLimiter } = require('../src/feedback_rate_limit');

const CARD = 'abcdef00-0000-4000-8000-000000000001';
const OWNER = '10000000-0000-4000-8000-000000000002';
const OTHER = '10000000-0000-4000-8000-000000000003';
const REPORT = '10000000-0000-4000-8000-000000000004';
const CREATED_AT = new Date('2026-10-26T06:07:08.009Z');
const body = { cardProductId: CARD, fieldPath: 'reward_rules[0].rate', shownValue: '2%', claimedValue: '3%' };

function response() {
  return { code: 200, headers: {}, body: null,
    status(code) { this.code = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(value) { this.body = value; return this; } };
}

function harness({ visible = true, insertError = null, limiter } = {}) {
  const calls = [], logs = [], identities = [];
  const withUserClient = async (identity, callback) => {
    identities.push(identity);
    return callback({ query: async (sql, params) => {
      calls.push([sql, params]);
      if (sql === VISIBLE_CARD_SQL) return { rows: visible ? [{ id: CARD }] : [] };
      if (sql === REPORT_METADATA_SQL) return { rows: [{ id: REPORT, created_at: CREATED_AT }] };
      if (sql === INSERT_DATA_ERROR_REPORT_SQL) {
        if (insertError) throw insertError;
        return { rows: [], rowCount: 1 };
      }
      assert.fail('unexpected database query');
    } });
  };
  const options = { withUserClient, limiter, logger: { error: (...args) => logs.push(args) } };
  return { options, calls, logs, identities, handler: createDataErrorReportHandler(options) };
}

test('public report route preserves the receipt and uses backend identity with parameterized insert', async () => {
  for (const userId of [null, OWNER]) {
    const h = harness();
    let route;
    const optionalAuth = (_req, _res, next) => next();
    registerDataErrorReportRoute({ post(...args) { route = args; } }, { ...h.options, optionalAuth });
    assert.equal(route[0], '/data-error-reports');
    assert.equal(route[1], optionalAuth);
    const res = response();
    await route[2]({ userId, ip: '203.0.113.10', body: { ...body, profileId: OTHER, state: 'resolved', sourceUrl: 'https://issuer.example/rates' } }, res);
    assert.equal(res.code, 201);
    assert.deepEqual(res.body, { errorReport: { id: REPORT, card_product_id: CARD,
      field_path: body.fieldPath, state: 'pending', created_at: CREATED_AT } });
    assert.deepEqual(h.identities, [userId]);
    assert.deepEqual(h.calls[2], [INSERT_DATA_ERROR_REPORT_SQL,
      [REPORT, userId, CARD, body.fieldPath, '2%', '3%', 'https://issuer.example/rates', null]]);
  }
});

test('malformed IDs and oversized or nontext fields fail before database access', async () => {
  const invalid = [null, [], 'text', { ...body, cardProductId: 'not-uuid' }, { ...body, fieldPath: ' ' }];
  for (const [field, max] of Object.entries(DATA_ERROR_REPORT_LIMITS)) {
    invalid.push({ ...body, [field]: 'x'.repeat(max + 1) });
    invalid.push({ ...body, [field]: { token: 'private' } });
    invalid.push({ ...body, [field]: 'bad\u0000value' });
  }
  for (const value of invalid) {
    const h = harness(), res = response();
    await h.handler({ ip: '203.0.113.10', body: value }, res);
    assert.equal(res.code, 400);
    assert.equal(h.calls.length, 0);
    assert.equal(h.identities.length, 0);
  }
});

test('unknown or policy-hidden cards return 404 without creating a report', async () => {
  const h = harness({ visible: false }), res = response();
  await h.handler({ ip: '203.0.113.10', body }, res);
  assert.equal(res.code, 404);
  assert.deepEqual(res.body, { error: 'card_product not found' });
  assert.deepEqual(h.calls, [[VISIBLE_CARD_SQL, [CARD]]]);
});

test('empty scalar values retain their contract and field paths are trimmed', async () => {
  const h = harness(), res = response();
  await h.handler({ ip: '203.0.113.10', body: { ...body, cardProductId: CARD.toUpperCase(), fieldPath: ' annual_fee ',
    shownValue: '', claimedValue: null, sourceUrl: '', attachmentPath: '' } }, res);
  assert.equal(res.code, 201);
  assert.equal(res.body.errorReport.card_product_id, CARD, 'receipt keeps PostgreSQL UUID formatting');
  assert.deepEqual(h.calls[2][1], [REPORT, null, CARD.toUpperCase(), 'annual_fee', '', null, null, null]);
});

test('database write errors return a safe response and never issue a success receipt', async () => {
  const h = harness({ insertError: Object.assign(new Error('private URL and report text'), { code: '23503' }) });
  const res = response();
  await h.handler({ ip: '203.0.113.10', body }, res);
  assert.equal(res.code, 500);
  assert.deepEqual(res.body, { error: 'internal_error' });
  assert.deepEqual(h.logs, [['POST /data-error-reports error', '23503']]);
  assert.doesNotMatch(JSON.stringify([res.body, h.logs]), /private|URL|report text/);
});

test('report limits bind profiles across IP changes and anonymous sources before database work', async () => {
  let now = 0;
  const h = harness({ limiter: createFeedbackRateLimiter({ now: () => now,
    authenticatedLimit: 1, anonymousLimit: 1, windowMs: 60_000 }) });
  for (const [userId, ip, expected] of [
    [OWNER, '203.0.113.1', 201], [OWNER, '203.0.113.2', 429],
    [OTHER, '203.0.113.1', 201], [null, '203.0.113.1', 201], [null, '203.0.113.1', 429],
  ]) {
    const res = response(), before = h.calls.length;
    await h.handler({ userId, ip, body }, res);
    assert.equal(res.code, expected);
    if (expected === 429) {
      assert.equal(res.headers['Retry-After'], '60');
      assert.equal(h.calls.length, before);
    }
  }
  now = 60_001;
  const retry = response();
  await h.handler({ userId: OWNER, ip: '203.0.113.2', body }, retry);
  assert.equal(retry.code, 201);
});

test('saturated feedback identity maps retain existing quotas and admit new identities after expiry', () => {
  let now = 0;
  const limiter = createFeedbackRateLimiter({ now: () => now, maxEntries: 1, windowMs: 1000, anonymousLimit: 2 });
  assert.equal(limiter.consume('one', false).allowed, true);
  for (let i = 0; i < 100; i++) assert.equal(limiter.consume(`other-${i}`, false).allowed, false);
  assert.equal(limiter.consume('one', false).allowed, true);
  assert.equal(limiter.consume('one', false).allowed, false);
  now = 1001;
  assert.equal(limiter.consume('two', false).allowed, true);
});
