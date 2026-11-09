'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerRecoveryInternalRoutes, hasServiceSecret, normalizeRequest } = require('../src/recovery_internal_routes');

const SECRET = 'a'.repeat(40);
const USER = '11111111-2222-4333-8444-555555555555';

async function harness(t, { rows = [{ has_cards: true, matched: true }], secret = SECRET, fail = false } = {}) {
  const seen = [];
  const app = express();
  app.use(express.json());
  registerRecoveryInternalRoutes(app, {
    serviceSecret: () => secret,
    withUserClient: async (userId, work) => {
      seen.push(['user', userId]);
      if (fail) throw Object.assign(new Error('boom'), { code: 'XX000' });
      return work({ query: async (sql, params) => { seen.push(['query', params]); return { rows }; } });
    },
  });
  const server = await new Promise(resolve => { const l = app.listen(0, '127.0.0.1', () => resolve(l)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const post = async (body, headers = { 'x-auth-service-secret': SECRET }) => {
    const r = await fetch(`http://127.0.0.1:${server.address().port}/internal/recovery/card-fact`, {
      method: 'POST', headers: { 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
    });
    return { status: r.status, body: await r.json(), cache: r.headers.get('cache-control') };
  };
  return { seen, post };
}

test('the secret check is constant-time and refuses short, wrong or missing secrets', () => {
  assert.equal(hasServiceSecret(SECRET, SECRET), true);
  assert.equal(hasServiceSecret('b'.repeat(40), SECRET), false);
  assert.equal(hasServiceSecret(undefined, SECRET), false);
  assert.equal(hasServiceSecret('short', 'short'), false, 'a configured secret under 32 characters is never accepted');
  assert.equal(hasServiceSecret(SECRET, null), false);
});

test('only the two booleans leave, and the question is asked as that user', async t => {
  const h = await harness(t);
  const r = await h.post({ user_id: USER, last4: '4821' });
  assert.deepEqual([r.status, r.body, r.cache], [200, { has_cards: true, matched: true }, 'no-store']);
  assert.deepEqual(h.seen[0], ['user', USER]);
  assert.deepEqual(h.seen[1], ['query', [USER, '4821']]);
});

test('a month answer asks no card question and never reports a match', async t => {
  const h = await harness(t, { rows: [{ has_cards: false, matched: true }] });
  const r = await h.post({ user_id: USER, last4: null });
  assert.deepEqual(r.body, { has_cards: false, matched: false });
});

test('no secret, a wrong secret, or an unset server secret gets no answer', async t => {
  const h = await harness(t);
  assert.equal((await h.post({ user_id: USER, last4: '4821' }, {})).status, 401);
  assert.equal((await h.post({ user_id: USER, last4: '4821' }, { 'x-auth-service-secret': 'b'.repeat(40) })).status, 401);
  assert.equal(h.seen.length, 0, 'no database work happens before the secret is right');
  const unset = await harness(t, { secret: null });
  assert.equal((await unset.post({ user_id: USER, last4: '4821' })).status, 503);
});

test('a malformed request is refused before the database is touched', async t => {
  const h = await harness(t);
  for (const body of [{}, { user_id: 'nope', last4: '4821' }, { user_id: USER, last4: '482' }, { user_id: USER, last4: 4821 },
    { user_id: USER, last4: '4821', extra: 1 }, { user_id: USER, last4: '4821; DROP' }]) {
    assert.equal((await h.post(body)).status, 400, JSON.stringify(body));
  }
  assert.equal(h.seen.length, 0);
  assert.equal(normalizeRequest([USER]), null);
});

test('a database failure is a bare 500 with no detail', async t => {
  const h = await harness(t, { fail: true });
  const r = await h.post({ user_id: USER, last4: '4821' });
  assert.deepEqual([r.status, r.body], [500, { error: 'internal_error' }]);
});
