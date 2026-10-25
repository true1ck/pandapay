'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  INGEST_CONVERSION_SQL, MAX_BODY_BYTES, MAX_TOKEN_BYTES, MAX_REFERENCE_BYTES,
  MAX_COMMISSION, createPartnerConversionPostHandler, validateConversion, validSignature,
} = require('../src/partner_conversion_route');

const SECRET = 'synthetic-partner-secret-for-tests';
function response() {
  return { statusCode: 200, status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; } };
}
function request(body = { clickToken: 'fixture-click' }, signature = SECRET) {
  return { body, get(name) { assert.equal(name, 'x-partner-signature'); return signature; } };
}

for (const matched of [true, false]) {
  test(`postback preserves 202 ${matched ? 'matched' : 'unknown'} response and calls only the private RPC`, async () => {
    const calls = [];
    const handler = createPartnerConversionPostHandler({ secret: SECRET,
      pool: { query: async (...args) => { calls.push(args); return { rows: [{ matched }] }; } },
      logger: { error() { assert.fail('should not log'); } },
    });
    const res = response();
    await handler(request({ clickToken: 'fixture-click', status: 'approved', commissionInr: 123.45,
      externalRef: 'ref-123', secret: 'must-not-store', email: 'must-not-store@example.invalid' }), res);
    assert.equal(res.statusCode, 202);
    assert.deepEqual(res.body, { ok: true, matched });
    assert.deepEqual(calls, [[INGEST_CONVERSION_SQL, ['fixture-click', 'approved', 123.45, 'ref-123']]]);
  });
}

test('missing status and commission retain pending/null defaults; missing/empty refs use one null identity', async () => {
  for (const externalRef of [undefined, null, '']) {
    assert.deepEqual(validateConversion({ clickToken: 'fixture-click', externalRef }), {
      clickToken: 'fixture-click', status: 'pending', commissionInr: null, externalRef: null,
    });
  }
  assert.equal(validateConversion({ clickToken: 'fixture-click', externalRef: ' ref ' }).externalRef, ' ref ');
});

test('signature comparison is byte-safe for UTF-8 values and rejects missing/malformed signatures', () => {
  assert.equal(validSignature('å', 'å'), true);
  assert.equal(validSignature('å', 'ab'), false);
  assert.equal(validSignature('', SECRET), false);
  assert.equal(validSignature(null, SECRET), false);
  assert.equal(validSignature([SECRET], SECRET), false);
});

test('unset secret or separate capability pool is 503; signature failure does not touch a database', async () => {
  let calls = 0;
  const pool = { query() { calls += 1; assert.fail('unexpected SQL'); } };
  for (const [options, req, code, error] of [
    [{ pool }, request(), 503, 'webhook_not_configured'],
    [{ secret: SECRET, pool }, request(undefined, 'bad'), 401, 'invalid_signature'],
    [{ secret: SECRET }, request(), 503, 'webhook_not_configured'],
  ]) {
    const res = response();
    await createPartnerConversionPostHandler(options)(req, res);
    assert.equal(res.statusCode, code);
    assert.deepEqual(res.body, { error });
  }
  assert.equal(calls, 0);
});

test('all valid statuses and bounded numeric values pass without changing commission semantics', () => {
  for (const status of ['pending', 'approved', 'rejected', 'reversed']) {
    for (const commissionInr of [null, 0, 1.239, -3.45, MAX_COMMISSION, -MAX_COMMISSION]) {
      const input = validateConversion({ clickToken: 'fixture-click', status, commissionInr });
      assert.equal(input.error, undefined);
      assert.equal(input.commissionInr, commissionInr);
    }
  }
});

test('invalid/unbounded body fails before private capability is called', async () => {
  const bodies = [null, [], 'body', {}, { clickToken: '' }, { clickToken: 1 },
    { clickToken: 'a'.repeat(MAX_TOKEN_BYTES + 1) }, { clickToken: 'å'.repeat(MAX_TOKEN_BYTES) },
    { clickToken: 'token\n' }, { clickToken: 'ok', status: 'paid' },
    { clickToken: 'ok', status: false }, { clickToken: 'ok', commissionInr: '2' },
    { clickToken: 'ok', commissionInr: Infinity }, { clickToken: 'ok', commissionInr: NaN },
    { clickToken: 'ok', commissionInr: MAX_COMMISSION + 1 },
    { clickToken: 'ok', externalRef: {} }, { clickToken: 'ok', externalRef: 'a'.repeat(MAX_REFERENCE_BYTES + 1) },
    { clickToken: 'ok', externalRef: 'ref\u0000' }, { clickToken: 'ok', extra: 'a'.repeat(MAX_BODY_BYTES) },
  ];
  for (const body of bodies) {
    const res = response();
    await createPartnerConversionPostHandler({ secret: SECRET,
      pool: { query() { assert.fail('invalid input must not query'); } } })(request(body), res);
    assert.equal(res.statusCode, 400);
    assert.equal(typeof res.body.error, 'string');
  }
});

test('database failure logs only a fixed message and keeps internal details out of HTTP', async () => {
  const messages = [];
  const handler = createPartnerConversionPostHandler({ secret: SECRET,
    pool: { query() { throw new Error('password=private external-reference=private'); } },
    logger: { error(...args) { messages.push(args); } },
  });
  const res = response();
  await handler(request(), res);
  assert.equal(res.statusCode, 500);
  assert.deepEqual(res.body, { error: 'internal_error' });
  assert.deepEqual(messages, [['POST /partner-conversions/webhook failed']]);
});

test('unexpected capability result cannot be interpreted as a matched success', async () => {
  for (const rows of [[], [{ matched: 'true' }], [{ matched: null }]]) {
    const res = response();
    await createPartnerConversionPostHandler({ secret: SECRET,
      pool: { query: async () => ({ rows }) }, logger: { error() {} } })(request(), res);
    assert.equal(res.statusCode, 500);
  }
});

test('public factory remains isolated from environment and generic API database imports', () => {
  const fs = require('node:fs');
  const source = fs.readFileSync(require.resolve('../src/partner_conversion_route'), 'utf8');
  assert.doesNotMatch(source, /require\(['"]\.\/db['"]\)|process\.env|dotenv|raw_payload/);
});

test('standalone PostgreSQL guard permits only named empty local fixtures and explicit private bridge attestation', () => {
  const { fixtureConfig, expectedServerAddress } = require('./partner_conversion_postgres');
  for (const url of [undefined, 'postgresql://a:b@example.invalid/partner_conversion_test',
    'postgresql://a:b@127.0.0.1/postgres', 'postgresql://a:b@127.0.0.1/partner_conversion_test?sslmode=disable',
    'postgresql://a@127.0.0.1/partner_conversion_test']) assert.throws(() => fixtureConfig(url));
  assert.equal(fixtureConfig('postgresql://a:b@127.0.0.1:5433/partner_conversion_test').database, 'partner_conversion_test');
  assert.equal(expectedServerAddress('127.0.0.1'), true);
  assert.equal(expectedServerAddress('172.17.0.2'), false);
  assert.equal(expectedServerAddress('172.17.0.2', '172.17.0.2'), true);
  assert.equal(expectedServerAddress('172.17.0.2', '172.17.0.3'), false);
  assert.equal(expectedServerAddress('8.8.8.8', '8.8.8.8'), false);
});
