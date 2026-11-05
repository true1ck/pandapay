'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createCatalogueHandler, V1_SQL, V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL,
} = require('../src/catalogue_route');

function responseDouble() {
  return {
    statusCode: 200,
    body: undefined,
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
  };
}

function harness(rowsBySql) {
  const calls = [];
  const users = [];
  const handler = createCatalogueHandler({
    withUserClient: async (user, cb) => {
      users.push(user);
      return cb({ query: async (sql) => { calls.push(sql); return { rows: rowsBySql[sql] ?? [] }; } });
    },
    logger: { error() {} },
  });
  return { handler, calls, users };
}

test('v1 is the default: same query, same { cards } shape', async () => {
  const cards = [{ id: 'c1', reward_rules: [] }];
  const { handler, calls } = harness({ [V1_SQL]: cards });
  const res = responseDouble();
  await handler({ query: {} }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { cards });
  assert.deepEqual(calls, [V1_SQL]);
  assert.equal(V1_SQL, 'SELECT * FROM v_card_catalogue_export ORDER BY name');
});

test('v1 also serves a missing query object and unknown schema values', async () => {
  for (const req of [{}, { query: { schema: '1' } }, { query: { schema: '3' } }, { query: { schema: ['2', '2'] } }]) {
    const { handler, calls } = harness({ [V1_SQL]: [] });
    const res = responseDouble();
    await handler(req, res);
    assert.deepEqual(res.body, { cards: [] });
    assert.deepEqual(calls, [V1_SQL]);
  }
});

test('schema=2 returns cards, active merchants and active platforms', async () => {
  const cards = [{ id: 'c1', model_status: 'partial', unlock_rules: [] }];
  const merchants = [{ slug: 'swiggy', name: 'Swiggy', parent_slug: null, category_slug: 'dining',
    aliases: ['swiggy'], vpa_prefixes: ['swiggy'], mcc: ['5814'] }];
  const platforms = [{ slug: 'phonepe_app', name: 'PhonePe app', kind: 'payment_app', issuer_slug: null, aliases: ['phonepe'] }];
  const { handler, calls, users } = harness({
    [V2_CARDS_SQL]: cards, [V2_MERCHANTS_SQL]: merchants, [V2_PLATFORMS_SQL]: platforms,
  });
  const res = responseDouble();
  await handler({ query: { schema: '2' }, user: { id: 'u1' } }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { schema: 2, cards, merchants, platforms });
  assert.deepEqual(calls, [V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL]);
  assert.deepEqual(users, [{ id: 'u1' }]);
  assert.match(V2_MERCHANTS_SQL, /WHERE is_active/);
  assert.match(V2_PLATFORMS_SQL, /WHERE is_active/);
});

test('database failure gives the existing 500 body and logs only a code', async () => {
  const logged = [];
  const handler = createCatalogueHandler({
    withUserClient: async () => { const e = new Error('secret detail'); e.code = '57P01'; throw e; },
    logger: { error: (...a) => logged.push(a) },
  });
  for (const query of [{}, { schema: '2' }]) {
    const res = responseDouble();
    await handler({ query }, res);
    assert.equal(res.statusCode, 500);
    assert.deepEqual(res.body, { error: 'internal_error' });
  }
  assert.ok(logged.every((a) => !JSON.stringify(a).includes('secret detail')));
});
