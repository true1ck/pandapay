'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const zlib = require('node:zlib');
const express = require('express');
const {
  createCatalogueHandler, V1_SQL, V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL, FINGERPRINT_SQL,
} = require('../src/catalogue_route');
const { createFeedbackRateLimiter } = require('../src/feedback_rate_limit');

function responseDouble() {
  return {
    statusCode: 200,
    body: undefined,
    headers: {},
    status(code) { this.statusCode = code; return this; },
    json(value) { this.body = value; return this; },
    set(k, v) { this.headers[k] = v; return this; },
    end() { return this; },
  };
}

const FINGERPRINT = {
  max_data_version: '7', card_count: '2', merchants_updated_at: '2026-11-05 10:00:00+00',
  merchants_total: '3', merchants_active: '3', platforms_total: '1', platforms_active: '1',
};

function harness(rowsBySql, { limiter } = {}) {
  const calls = [];
  const users = [];
  const state = { fingerprint: { ...FINGERPRINT } };
  const handler = createCatalogueHandler({
    withUserClient: async (user, cb) => {
      users.push(user);
      return cb({
        query: async (sql) => {
          calls.push(sql);
          if (sql === FINGERPRINT_SQL) return { rows: [state.fingerprint] };
          return { rows: rowsBySql[sql] ?? [] };
        },
      });
    },
    logger: { error() {} },
    limiter,
  });
  return { handler, calls, users, state };
}

const HEAVY = [V1_SQL, V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL];

test('v1 is the default: same query, same { cards } shape', async () => {
  const cards = [{ id: 'c1', reward_rules: [] }];
  const { handler, calls } = harness({ [V1_SQL]: cards });
  const res = responseDouble();
  await handler({ query: {}, ip: '1.1.1.1' }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { cards });
  assert.deepEqual(calls.filter((s) => HEAVY.includes(s)), [V1_SQL]);
  assert.equal(V1_SQL, 'SELECT * FROM v_card_catalogue_export ORDER BY name');
});

test('v1 also serves a missing query object and unknown schema values', async () => {
  for (const req of [{ ip: 'a' }, { ip: 'a', query: { schema: '1' } }, { ip: 'a', query: { schema: '3' } },
    { ip: 'a', query: { schema: ['2', '2'] } }]) {
    const { handler, calls } = harness({ [V1_SQL]: [] });
    const res = responseDouble();
    await handler(req, res);
    assert.deepEqual(res.body, { cards: [] });
    assert.deepEqual(calls.filter((s) => HEAVY.includes(s)), [V1_SQL]);
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
  await handler({ query: { schema: '2' }, user: { id: 'u1' }, ip: 'x' }, res);
  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.body, { schema: 2, cards, merchants, platforms });
  assert.deepEqual(calls.filter((s) => HEAVY.includes(s)), [V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL]);
  assert.ok(users.every((u) => u && u.id === 'u1'));
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
    await handler({ query, ip: 'z' }, res);
    assert.equal(res.statusCode, 500);
    assert.deepEqual(res.body, { error: 'internal_error' });
    assert.equal(res.headers.ETag, undefined, 'error responses must not carry cache validators');
  }
  assert.ok(logged.every((a) => !JSON.stringify(a).includes('secret detail')));
});

// ── hardening (D33d) ─────────────────────────────────────────────────────

test('ETag is stable across calls, differs by feed, and changes with card or directory rows', async () => {
  const { handler, state } = harness({});
  const etag = async (query) => {
    const res = responseDouble();
    await handler({ query, ip: 'e' }, res);
    return res.headers.ETag;
  };
  const a1 = await etag({});
  const a2 = await etag({});
  const b1 = await etag({ schema: '2' });
  assert.match(a1, /^"[0-9a-f]{32}"$/);
  assert.equal(a1, a2);
  assert.notEqual(a1, b1);
  state.fingerprint.max_data_version = '8';
  const afterCard = await etag({});
  assert.notEqual(afterCard, a1);
  state.fingerprint.max_data_version = '7';
  state.fingerprint.merchants_updated_at = '2026-11-06 09:00:00+00';
  assert.notEqual(await etag({ schema: '2' }), b1);
  state.fingerprint.merchants_updated_at = FINGERPRINT.merchants_updated_at;
  state.fingerprint.platforms_active = '0';
  assert.notEqual(await etag({ schema: '2' }), b1);
});

test('matching If-None-Match answers 304 without running any heavy view query', async () => {
  for (const query of [{}, { schema: '2' }]) {
    const { handler, calls } = harness({});
    const first = responseDouble();
    await handler({ query, ip: 'f' }, first);
    const etag = first.headers.ETag;
    calls.length = 0;
    const res = responseDouble();
    await handler({ query, ip: 'f', headers: { 'if-none-match': `"other", ${etag}` } }, res);
    assert.equal(res.statusCode, 304);
    assert.equal(res.headers.ETag, etag);
    assert.equal(res.headers['Cache-Control'], 'public, max-age=300');
    assert.deepEqual(calls, [FINGERPRINT_SQL]);
    assert.ok(!calls.includes(V2_CARDS_SQL) && !calls.includes(V1_SQL));
    // a stale validator falls through to the full response
    const stale = responseDouble();
    await handler({ query, ip: 'f', headers: { 'if-none-match': '"stale"' } }, stale);
    assert.equal(stale.statusCode, 200);
  }
});

test('both feeds send Cache-Control: public, max-age=300', async () => {
  for (const query of [{}, { schema: '2' }]) {
    const { handler } = harness({});
    const res = responseDouble();
    await handler({ query, ip: 'c' }, res);
    assert.equal(res.headers['Cache-Control'], 'public, max-age=300');
  }
});

test('rate limit: 429 with Retry-After past the limit, none below it, per IP', async () => {
  const limiter = createFeedbackRateLimiter({ windowMs: 60_000, authenticatedLimit: 3, anonymousLimit: 3 });
  const { handler } = harness({}, { limiter });
  for (let i = 0; i < 3; i += 1) {
    const ok = responseDouble();
    await handler({ query: {}, ip: '9.9.9.9' }, ok);
    assert.equal(ok.statusCode, 200, `request ${i + 1} must pass`);
  }
  const blocked = responseDouble();
  await handler({ query: {}, ip: '9.9.9.9' }, blocked);
  assert.equal(blocked.statusCode, 429);
  assert.deepEqual(blocked.body, { error: 'rate_limited' });
  assert.ok(Number(blocked.headers['Retry-After']) >= 1);
  const other = responseDouble();
  await handler({ query: {}, ip: '8.8.8.8' }, other);
  assert.equal(other.statusCode, 200);
});

// ── over real HTTP: byte-identity and gzip ───────────────────────────────

function listen(app) {
  return new Promise((resolve) => {
    const server = app.listen(0, '127.0.0.1', () => resolve(server));
  });
}

function get(server, path, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port: server.address().port, path, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, raw: Buffer.concat(chunks) }));
    }).on('error', reject);
  });
}

const CARDS = [{ id: 'c1', name: 'Zed', reward_rules: [{ id: 'r1', rate: '5.0000', unit: 'points_per_100' }], note: 'é ₹' },
  { id: 'c2', name: 'Alpha', reward_rules: [], note: null }];

function fakeUserClient(state) {
  return async (_user, cb) => cb({
    query: async (sql) => {
      if (sql === FINGERPRINT_SQL) return { rows: [state.fingerprint] };
      if (sql === V1_SQL) return { rows: CARDS };
      if (sql === V2_CARDS_SQL) return { rows: CARDS };
      if (sql === V2_MERCHANTS_SQL) return { rows: [{ slug: 'swiggy' }] };
      if (sql === V2_PLATFORMS_SQL) return { rows: [{ slug: 'phonepe_app' }] };
      throw new Error('unexpected sql');
    },
  });
}

test('v1 body bytes equal the previous handler output; gzip decodes to the identical body', async () => {
  const state = { fingerprint: { ...FINGERPRINT } };
  const withUserClient = fakeUserClient(state);
  const legacy = express();
  legacy.get('/catalogue', async (req, res) => {
    const result = await withUserClient(req.user || null, (client) => client.query(V1_SQL));
    res.json({ cards: result.rows });
  });
  const current = express();
  current.get('/catalogue', createCatalogueHandler({ withUserClient, logger: { error() {} } }));
  const [legacyServer, currentServer] = [await listen(legacy), await listen(current)];
  try {
    for (const path of ['/catalogue', '/catalogue?schema=1', '/catalogue?schema=3']) {
      const old = await get(legacyServer, path);
      const plain = await get(currentServer, path);
      assert.deepEqual(plain.raw, old.raw, `${path}: v1 bytes must be unchanged`);
      assert.equal(plain.headers['content-type'], old.headers['content-type']);
      const gz = await get(currentServer, path, { 'accept-encoding': 'gzip' });
      assert.equal(gz.headers['content-encoding'], 'gzip');
      assert.deepEqual(zlib.gunzipSync(gz.raw), old.raw, `${path}: gzip must decode to the identical body`);
      assert.match(gz.headers['content-type'], /^application\/json/);
      assert.notEqual(gz.headers.etag, plain.headers.etag, 'gzip representation has its own validator');
    }
    const v2plain = await get(currentServer, '/catalogue?schema=2');
    const v2gz = await get(currentServer, '/catalogue?schema=2', { 'accept-encoding': 'gzip, br' });
    assert.deepEqual(zlib.gunzipSync(v2gz.raw), v2plain.raw);
    assert.equal(JSON.parse(v2plain.raw).schema, 2);
    // an identity-only client never receives gzip
    const identity = await get(currentServer, '/catalogue', { 'accept-encoding': 'identity' });
    assert.equal(identity.headers['content-encoding'], undefined);
    // conditional GET over HTTP
    const cond = await get(currentServer, '/catalogue?schema=2', { 'if-none-match': v2plain.headers.etag });
    assert.equal(cond.status, 304);
    assert.equal(cond.raw.length, 0);
  } finally {
    legacyServer.close();
    currentServer.close();
  }
});
