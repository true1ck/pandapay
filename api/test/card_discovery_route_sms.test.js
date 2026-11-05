'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

// POST /card-discovery is registered inside index.js, which boots the whole
// server, so the route source is evaluated against fakes (the same approach
// as consents_purposes.test.js).
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');

function run(body) {
  const start = source.indexOf("app.post('/card-discovery',");
  const end = source.indexOf('\n});', start) + 5;
  let handler;
  const reached = { database: 0 };
  new Function(
    'app', 'requireAuth', 'withUserClient', 'discoverCardsAcrossMessages', 'safeErrorCode',
    source.slice(start, end),
  )(
    { post: (_path, _auth, fn) => { handler = fn; } },
    () => {},
    async () => {
      reached.database += 1;
      throw Object.assign(new Error('stop here'), { code: 'test_stop' });
    },
    () => [],
    (error) => error?.code || 'unknown',
  );
  const res = {
    code: null,
    body: null,
    status(code) { this.code = code; return this; },
    json(payload) { this.body = payload; return this; },
  };
  return handler({ userId: '00000000-0000-4000-8000-000000000001', body }, res)
    .then(() => ({ res, reached }));
}

test('card discovery refuses SMS text outright', async () => {
  const { res, reached } = await run({ smsBodies: ['Rs 500 spent on HDFC Millennia card ending 4567'] });
  assert.equal(res.code, 400);
  assert.equal(res.body.error, 'sms_text_not_accepted');
  assert.equal(reached.database, 0, 'nothing is read for a request that carries SMS text');
});

test('card discovery still works for forwarded email, with or without an empty list', async () => {
  for (const body of [{}, { smsBodies: [] }, undefined]) {
    const { res, reached } = await run(body);
    assert.notEqual(res.code, 400, JSON.stringify(body));
    assert.equal(reached.database, 1);
  }
});

test('the route no longer matches SMS bodies at all', () => {
  const start = source.indexOf("app.post('/card-discovery',");
  const end = source.indexOf('\n});', start);
  const route = source.slice(start, end);
  assert.ok(!/smsMessages|fromSms/.test(route), 'no SMS matching code remains in the route');
});
