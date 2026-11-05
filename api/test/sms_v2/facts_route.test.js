'use strict';
// WP-08 HTTP behaviour that needs no database: contract rejections, limits,
// encodings, hooks and the disabled flag. Anything that would reach SQL is
// covered in facts_pg.test.js.
//   node --test api/test/sms_v2/facts_route.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const express = require('express');

const contracts = require('../../src/sms_v2/contracts');
const { registerSmsV2 } = require('../../src/sms_v2');
const h = require('./helpers');

const INVALID = path.join(contracts.SCHEMA_DIR, 'fixtures', 'invalid', 'request.facts_batch');
const VALID = path.join(contracts.SCHEMA_DIR, 'fixtures', 'valid', 'request.facts_batch', 'full.json');
const USER = h.uuid4();

async function harness({ flag = true, hooks } = {}) {
  const state = { flag, dbCalls: 0 };
  const app = express();
  app.use((req, _res, next) => { req.userId = null; next(); });
  const requireAuth = (req, res, next) => {
    req.userId = req.headers['x-user'] || null;
    return req.userId ? next() : res.status(401).json({ error: 'unauthorized' });
  };
  registerSmsV2(app, {
    requireAuth,
    requireAdmin: (req, res) => res.status(403).json({ error: 'Admin access required' }),
    withUserClient: async () => { state.dbCalls += 1; throw new Error('database must not be reached'); },
    readFlag: async () => (state.flag ? { key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 } : null),
    flagCacheMs: 0,
    signer: null,
    hooks: {
      ...hooks,
      security: {
        verifyAttestation: async () => true,
        checkRate: async () => true,
        checkEntitlement: async () => true,
        ...hooks?.security,
      },
    },
    loadUserCardForState: async () => null,
    applyTransactionState: async () => ({}),
    reverseTransactionState: async () => ({}),
  });
  // A route registered by someone else after ours still gets a parsed JSON body.
  app.post('/sms/v2/echo', (req, res) => res.json({ body: req.body }));
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = async (url, body, { gzip = false, headers = {}, user = USER, raw } = {}) => {
    let payload = raw !== undefined ? raw : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body));
    const hdrs = { 'content-type': 'application/json', ...(user ? { 'x-user': user } : {}), ...headers };
    if (gzip) { payload = zlib.gzipSync(payload); hdrs['content-encoding'] = 'gzip'; }
    const res = await fetch(base + url, { method: 'POST', headers: hdrs, body: payload });
    let json = null;
    try { json = await res.json(); } catch (_) { json = null; }
    return { status: res.status, json, headers: res.headers };
  };
  const get = async (url, { user = USER } = {}) => {
    const res = await fetch(base + url, { headers: user ? { 'x-user': user } : {} });
    let json = null;
    try { json = await res.json(); } catch (_) { json = null; }
    return { status: res.status, json };
  };
  return { state, post, get, close: () => { server.closeAllConnections(); server.close(); } };
}

const FACTS = '/sms/v2/facts:batch';

test('category refresh rejects source, event or instrument mutations before database access', async () => {
  const h1 = await harness();
  try {
    const body = h.batch({ items: [h.item([h.fact({})])] });
    const result = await h1.post('/sms/v2/categories:batch', body);
    assert.equal(result.status, 400);
    assert.equal(h1.state.dbCalls, 0);
  } finally { h1.close(); }
});

test('category refresh uses the SMS v2 flag and membership gate', async () => {
  const disabled = await harness({ flag: false });
  const enabled = await harness();
  try {
    assert.equal((await disabled.post('/sms/v2/categories:batch', h.batch())).status, 404);
    assert.equal((await enabled.post('/sms/v2/categories:batch', h.batch(), { user: null })).status, 401);
    assert.equal(enabled.state.dbCalls, 0);
  } finally { disabled.close(); enabled.close(); }
});

test('every invalid facts_batch fixture is rejected with the code in its file name, before any database work', async () => {
  const h1 = await harness();
  try {
    const files = fs.readdirSync(INVALID).filter((f) => f.endsWith('.json')).sort();
    assert.ok(files.length >= 8);
    for (const f of files) {
      const expected = f.replace(/\.json$/, '').split('~')[0];
      const body = JSON.parse(fs.readFileSync(path.join(INVALID, f), 'utf8'));
      const r = await h1.post(FACTS, body);
      assert.ok(r.status === 400 || r.status === 413, `${f}: status ${r.status}`);
      assert.equal(r.json.error, expected, f);
      if (r.status === 400) assert.ok(r.json.errors.some((e) => e.code === expected), f);
    }
    assert.equal(h1.state.dbCalls, 0);
  } finally { h1.close(); }
});

test('more than 500 items is refused with 413 and the contract code', async () => {
  const h1 = await harness();
  try {
    const body = h.batch({ items: Array.from({ length: 501 }, () => h.item([])) });
    const r = await h1.post(FACTS, body);
    assert.equal(r.status, 413);
    assert.equal(r.json.error, 'request.facts_batch.items_too_many');
    assert.equal(h1.state.dbCalls, 0);
  } finally { h1.close(); }
});

test('a body over 1 MiB as sent is refused, gzip or not', async () => {
  const h1 = await harness();
  try {
    const big = Buffer.alloc(1024 * 1024 + 10, 0x61);
    const plain = await h1.post(FACTS, null, { raw: big });
    assert.equal(plain.status, 413);
    assert.equal(plain.json.error, 'payload_too_large');
    const noise = require('node:crypto').randomBytes(1024 * 1024 + 10); // does not compress
    const gz = await h1.post(FACTS, null, { raw: noise, headers: { 'content-encoding': 'gzip' } });
    assert.ok(gz.status === 413 || gz.status === 400, `gzip noise gave ${gz.status}`);
  } finally { h1.close(); }
});

test('an inflated body over 8 MiB is refused even when it is tiny as sent', async () => {
  const h1 = await harness();
  try {
    const bomb = zlib.gzipSync(Buffer.alloc(20 * 1024 * 1024, 0x20));
    assert.ok(bomb.length < 1024 * 1024);
    const r = await h1.post(FACTS, null, { raw: bomb, headers: { 'content-encoding': 'gzip' }, gzip: false });
    assert.equal(r.status, 413);
    assert.equal(r.json.error, 'payload_too_large');
  } finally { h1.close(); }
});

test('malformed JSON, non-objects and unknown encodings are refused', async () => {
  const h1 = await harness();
  try {
    assert.equal((await h1.post(FACTS, '{"items":')).status, 400);
    assert.equal((await h1.post(FACTS, '[1,2]')).status, 400);
    assert.equal((await h1.post(FACTS, '')).status, 400);
    const br = await h1.post(FACTS, '{}', { headers: { 'content-encoding': 'br' } });
    assert.equal(br.status, 415);
    const empty = await h1.post(FACTS, {});
    assert.equal(empty.status, 400);
  } finally { h1.close(); }
});

test('a gzip body is accepted and validated like a plain one', async () => {
  const h1 = await harness();
  try {
    const invalid = JSON.parse(fs.readFileSync(path.join(INVALID, 'request.facts_batch.info_fact_forbidden.json'), 'utf8'));
    const r = await h1.post(FACTS, invalid, { gzip: true });
    assert.equal(r.status, 400);
    assert.equal(r.json.error, 'request.facts_batch.info_fact_forbidden');
  } finally { h1.close(); }
});

test('the valid contract fixture passes validation and reaches the database layer', async () => {
  const h1 = await harness();
  const origError = console.error;
  console.error = () => {};
  try {
    const body = JSON.parse(fs.readFileSync(VALID, 'utf8'));
    const r = await h1.post(FACTS, body);
    assert.equal(r.status, 500); // the stub database refuses, so validation was passed
    assert.equal(h1.state.dbCalls, 1);
  } finally { console.error = origError; h1.close(); }
});

test('with the flag off every v2 route is a 404 and no body is read or database touched', async () => {
  const h1 = await harness({ flag: false });
  try {
    assert.equal((await h1.post(FACTS, {})).status, 404);
    assert.equal((await h1.post(FACTS, null, { raw: Buffer.alloc(2 * 1024 * 1024, 0x61) })).status, 404);
    assert.equal((await h1.get('/sms/v2/sync')).status, 404);
    assert.equal((await h1.get('/sms/v2/rules')).status, 404);
    assert.equal((await h1.post('/sms/v2/rule-stats:batch', {})).status, 404);
    assert.equal((await h1.get('/admin/sms/v2/rules')).status, 404);
    assert.equal((await h1.get('/sms/v2/anything-else')).status, 404);
    assert.equal(h1.state.dbCalls, 0);
  } finally { h1.close(); }
});

test('with the flag on, the phone routes require authentication', async () => {
  const h1 = await harness();
  try {
    assert.equal((await h1.post(FACTS, {}, { user: null })).status, 401);
    assert.equal((await h1.get('/sms/v2/sync', { user: null })).status, 401);
  } finally { h1.close(); }
});

test('routes registered after ours still receive a parsed JSON body', async () => {
  const h1 = await harness();
  try {
    const r = await h1.post('/sms/v2/echo', { hello: 'world' });
    assert.deepEqual(r.json, { body: { hello: 'world' } });
  } finally { h1.close(); }
});

test('security hooks: attestation denied is 403, rate limited is 429, a throwing hook is 503', async () => {
  const body = JSON.parse(fs.readFileSync(VALID, 'utf8'));
  const seen = [];
  const denyAttest = await harness({ hooks: { security: { verifyAttestation: async () => false } } });
  const denyRate = await harness({ hooks: { security: { checkRate: async (req, key, units) => { seen.push([key, units]); return { ok: false }; } } } });
  const boom = await harness({ hooks: { security: { verifyAttestation: async () => { throw new Error('x'); } } } });
  const origError = console.error;
  console.error = () => {};
  try {
    assert.equal((await denyAttest.post(FACTS, body)).status, 403);
    assert.equal((await denyAttest.get('/sms/v2/sync')).status, 403);
    const limited = await denyRate.post(FACTS, body);
    assert.equal(limited.status, 429);
    assert.deepEqual(seen, [['facts:batch', body.items.length]]);
    assert.equal((await boom.post(FACTS, body)).status, 503);
    assert.equal(denyAttest.state.dbCalls + denyRate.state.dbCalls + boom.state.dbCalls, 0);
  } finally {
    console.error = origError;
    denyAttest.close(); denyRate.close(); boom.close();
  }
});

test('sync rejects a malformed cursor before touching the database', async () => {
  const h1 = await harness();
  try {
    const r = await h1.get('/sms/v2/sync?cursor=%25%25not-a-cursor');
    assert.equal(r.status, 400);
    assert.equal(r.json.error, 'cursor_invalid');
    assert.equal(h1.state.dbCalls, 0);
  } finally { h1.close(); }
});
