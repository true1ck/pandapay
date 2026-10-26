'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createPostgresFeedbackRateLimiter } = require('../src/feedback_rate_limit');
const { createSupportTicketHandler } = require('../src/support_tickets');

test('shared feedback limiter sends only a namespaced opaque digest to its fixed RPC', async () => {
  const calls = [];
  const client = { query: async query => {
    calls.push(query);
    return { rows: [{ allowed: true, retry_after_seconds: 0 }] };
  }, release() {} };
  const limiter = createPostgresFeedbackRateLimiter({
    pool: { connect: async () => client }, digestSecret: 's'.repeat(32),
  });
  const result = await limiter.consume('203.0.113.4', false, 'support_tickets');
  assert.deepEqual(result, { allowed: true, retryAfterSeconds: 0 });
  assert.equal(calls[0].text, 'SELECT * FROM feedback_admission.consume($1, $2, $3)');
  assert.deepEqual(calls[0].values.slice(0, 1), ['support_tickets']);
  assert.match(calls[0].values[1], /^[0-9a-f]{64}$/);
  assert.notEqual(calls[0].values[1], '203.0.113.4');
  assert.deepEqual(calls[0].values.slice(2), [false]);
  assert.equal((await limiter.consume('203.0.113.4', false, 'other')).unavailable, true);
});

test('shared feedback limiter rejects concurrent work before borrowing its single pool connection', async () => {
  let releaseQuery;
  let connects = 0;
  const pending = new Promise(resolve => { releaseQuery = resolve; });
  const limiter = createPostgresFeedbackRateLimiter({
    pool: { async connect() { connects += 1; return { query: () => pending, release() {} }; } },
    digestSecret: 's'.repeat(32),
  });
  const first = limiter.consume('profile', true, 'support_tickets');
  await new Promise(resolve => setImmediate(resolve));
  await assert.rejects(() => limiter.consume('profile-2', true, 'data_error_reports'), /busy/);
  assert.equal(connects, 1);
  releaseQuery({ rows: [{ allowed: false, retry_after_seconds: 42 }] });
  assert.deepEqual(await first, { allowed: false, retryAfterSeconds: 42 });
});

test('shared feedback limiter releases connection and local admission slot after store errors', async () => {
  let releases = 0;
  let calls = 0;
  const limiter = createPostgresFeedbackRateLimiter({
    pool: { async connect() { return { async query() { calls += 1; throw new Error('offline'); }, release() { releases += 1; } }; } },
    digestSecret: 's'.repeat(32),
  });
  await assert.rejects(() => limiter.consume('ip', false, 'data_error_reports'), /offline/);
  assert.equal(releases, 1);
  await assert.rejects(() => limiter.consume('ip', false, 'data_error_reports'), /offline/);
  assert.equal(calls, 2);
});

test('shared feedback limiter rejects malformed identities and malformed database results', async () => {
  let queries = 0;
  const limiter = createPostgresFeedbackRateLimiter({
    pool: { async connect() { return { async query() {
      queries += 1;
      return { rows: [{ allowed: true, retry_after_seconds: 'NaN' }] };
    }, release() {} }; } },
    digestSecret: 's'.repeat(32),
  });
  assert.equal((await limiter.consume('x'.repeat(257), false, 'support_tickets')).unavailable, true);
  assert.equal((await limiter.consume('profile', 'yes', 'support_tickets')).unavailable, true);
  assert.equal(queries, 0);
  await assert.rejects(() => limiter.consume('profile', true, 'support_tickets'), /invalid_result/);
});

test('feedback handler fails closed with retryable 503 when shared admission is unavailable', async () => {
  const response = {
    headers: {}, statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = body; return this; },
  };
  const handler = createSupportTicketHandler({
    limiter: { async consume() { throw new Error('store unavailable'); } },
    withUserClient: async () => { throw new Error('must not write'); },
  });
  await handler({ userId: null, ip: '203.0.113.8', body: { kind: 'bug', message: 'test' } }, response);
  assert.equal(response.statusCode, 503);
  assert.equal(response.headers['Retry-After'], '5');
  assert.equal(response.body.error, 'feedback_admission_unavailable');
});
