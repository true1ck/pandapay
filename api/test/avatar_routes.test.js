'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerAvatarRoutes, createLimiter } = require('../src/avatar_routes');

const ME = '11111111-1111-4111-8111-111111111111';
const FRIEND = '22222222-2222-4222-8222-222222222222';
const STRANGER = '33333333-3333-4333-8333-333333333333';
const SECRET = 'service-secret-value-that-must-never-leak-0123456789';

function rig({ members = [FRIEND], authReply, authThrows, limiter, authed = true } = {}) {
  const authCalls = [];
  const fetchImpl = async (url, opts) => {
    authCalls.push({ url, headers: opts.headers });
    if (authThrows) throw authThrows;
    return authReply(url);
  };
  const withUserClient = async (userId, fn) => fn({
    async query(sql, params) {
      assert.match(sql, /shares_context_with/);
      assert.equal(userId, ME);
      return { rows: [{ ok: members.includes(params[0]) }] };
    },
  });
  const app = express();
  registerAvatarRoutes(app, {
    requireAuth: (req, res, next) => { if (!authed) return res.status(401).json({ error: 'no' }); req.userId = ME; next(); },
    withUserClient, fetchImpl, baseUrl: 'http://auth.test', serviceSecret: SECRET, limiter, logger: { error() {} },
  });
  return { app, authCalls };
}
async function call(r, path) {
  const server = r.app.listen(0);
  try {
    const res = await fetch(`http://127.0.0.1:${server.address().port}${path}`);
    const buf = Buffer.from(await res.arrayBuffer());
    return { res, buf, text: buf.toString('utf8') };
  } finally { server.close(); }
}
const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
const img = (bytes, type = 'image/png') => new Response(bytes, { status: 200, headers: { 'content-type': type } });

test('non-member gets the same 404 as a non-existent user, and auth is never asked', async () => {
  const r = rig({ authReply: () => { throw new Error('must not call auth'); } });
  const a = await call(r, `/avatars/${STRANGER}`);
  const b = await call(r, '/avatars/44444444-4444-4444-8444-444444444444');
  assert.equal(a.res.status, 404);
  assert.equal(b.res.status, 404);
  assert.equal(a.text, b.text);
  assert.deepEqual(JSON.parse(a.text), { error: 'not_found' });
  assert.equal(r.authCalls.length, 0);
});

test('member gets preset; photo_shared maps to has_photo', async () => {
  const r = rig({ authReply: () => json({ preset: 'panda', photo_shared: true, version: 3, extra: 'x' }) });
  const { res, text } = await call(r, `/avatars/${FRIEND}`);
  assert.equal(res.status, 200);
  assert.deepEqual(JSON.parse(text), { preset: 'panda', has_photo: true, version: 3 });
  assert.equal(r.authCalls[0].url, `http://auth.test/internal/avatar/${FRIEND}`);
});

test('has_photo is false when auth says not shared', async () => {
  const r = rig({ authReply: () => json({ preset: null, photo_shared: false, version: 1 }) });
  const { text } = await call(r, `/avatars/${FRIEND}`);
  assert.deepEqual(JSON.parse(text), { preset: null, has_photo: false, version: 1 });
});

test('auth 404 becomes our 404', async () => {
  const r = rig({ authReply: () => json({ error: 'not_found' }, 404) });
  const { res, text } = await call(r, `/avatars/${FRIEND}`);
  assert.equal(res.status, 404);
  assert.deepEqual(JSON.parse(text), { error: 'not_found' });
});

test('photo bytes returned only when shared, with hardened headers', async () => {
  const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 1, 2, 3]);
  const r = rig({ authReply: () => img(bytes) });
  const { res, buf } = await call(r, `/avatars/${FRIEND}/photo`);
  assert.equal(res.status, 200);
  assert.deepEqual(buf, bytes);
  assert.equal(res.headers.get('content-type'), 'image/png');
  assert.equal(res.headers.get('x-content-type-options'), 'nosniff');
  assert.equal(res.headers.get('content-security-policy'), "default-src 'none'; sandbox");
  assert.equal(res.headers.get('cache-control'), 'private, max-age=60');
  const nope = rig({ authReply: () => json({ error: 'not_found' }, 404) });
  assert.equal((await call(nope, `/avatars/${FRIEND}/photo`)).res.status, 404);
  const nonMember = rig({ members: [], authReply: () => { throw new Error('no'); } });
  assert.equal((await call(nonMember, `/avatars/${FRIEND}/photo`)).res.status, 404);
});

test('content-type allow-list: jpeg ok (params stripped), svg/html/other refused', async () => {
  const ok = await call(rig({ authReply: () => img(Buffer.from([1]), 'image/jpeg; charset=binary') }), `/avatars/${FRIEND}/photo`);
  assert.equal(ok.res.status, 200);
  assert.equal(ok.res.headers.get('content-type'), 'image/jpeg');
  for (const type of ['image/svg+xml', 'text/html', 'application/octet-stream']) {
    const bad = await call(rig({ authReply: () => img(Buffer.from([1]), type) }), `/avatars/${FRIEND}/photo`);
    assert.equal(bad.res.status, 503, type);
    assert.deepEqual(JSON.parse(bad.text), { error: 'avatar_unavailable' });
  }
});

test('oversized photo is refused, exactly 200 KB is allowed', async () => {
  const big = await call(rig({ authReply: () => img(Buffer.alloc(200 * 1024 + 1, 1)) }), `/avatars/${FRIEND}/photo`);
  assert.equal(big.res.status, 503);
  const edge = await call(rig({ authReply: () => img(Buffer.alloc(200 * 1024, 1)) }), `/avatars/${FRIEND}/photo`);
  assert.equal(edge.res.status, 200);
});

test('auth down or erroring gives 503 avatar_unavailable', async () => {
  const cases = [
    { authThrows: new Error('ECONNREFUSED') },
    { authThrows: Object.assign(new Error('t'), { name: 'TimeoutError' }) },
    { authReply: () => json({ error: 'x' }, 500) },
    { authReply: () => json({}, 401) },
  ];
  for (const opts of cases) {
    for (const p of [`/avatars/${FRIEND}`, `/avatars/${FRIEND}/photo`]) {
      const { res, text } = await call(rig(opts), p);
      assert.equal(res.status, 503);
      assert.deepEqual(JSON.parse(text), { error: 'avatar_unavailable' });
    }
  }
});

test('bad uuid is 400 and unauthenticated is 401', async () => {
  const r = rig({ authReply: () => json({}) });
  assert.equal((await call(r, '/avatars/not-a-uuid')).res.status, 400);
  assert.equal((await call(r, '/avatars/not-a-uuid/photo')).res.status, 400);
  const u = rig({ authed: false, authReply: () => json({}) });
  assert.equal((await call(u, `/avatars/${FRIEND}`)).res.status, 401);
  assert.equal((await call(u, `/avatars/${FRIEND}/photo`)).res.status, 401);
});

test('service secret goes to auth and never appears in any response', async () => {
  const r = rig({ authReply: (url) => (url.endsWith('/photo') ? img(Buffer.from([1, 2])) : json({ preset: 'a', photo_shared: true, version: 1 })) });
  const a = await call(r, `/avatars/${FRIEND}`);
  const b = await call(r, `/avatars/${FRIEND}/photo`);
  assert.equal(r.authCalls.length, 2);
  for (const c of r.authCalls) assert.equal(c.headers['x-auth-service-secret'], SECRET);
  for (const x of [a, b]) {
    assert.ok(!x.text.includes(SECRET));
    for (const [, v] of x.res.headers) assert.ok(!v.includes(SECRET));
  }
  const down = await call(rig({ authThrows: new Error(`fail ${SECRET}`) }), `/avatars/${FRIEND}`);
  assert.ok(!down.text.includes(SECRET));
});

test('per-user rate limit returns 429 after the cap', async () => {
  const limiter = createLimiter({ max: 2 });
  const r = rig({ limiter, authReply: () => json({ preset: null, photo_shared: false, version: 0 }) });
  const server = r.app.listen(0);
  try {
    const url = `http://127.0.0.1:${server.address().port}/avatars/${FRIEND}`;
    assert.equal((await fetch(url)).status, 200);
    assert.equal((await fetch(url)).status, 200);
    assert.equal((await fetch(url)).status, 429);
  } finally { server.close(); }
});

test('profile-name: a co-member gets the profile name, trimmed; no name is null; a stranger gets the generic 404', async () => {
  const named = (name) => {
    const r = rig({ authReply: () => { throw new Error('auth is not needed for the name'); } });
    return r;
  };
  // Own rig variant whose SQL fake also returns a name.
  const app = express();
  const make = (name) => {
    const a = express();
    registerAvatarRoutes(a, {
      requireAuth: (req, _res, next) => { req.userId = ME; next(); },
      withUserClient: async (_id, fn) => fn({ async query(sql, params) {
        assert.match(sql, /member_profile_name/);
        return { rows: [{ ok: params[0] === FRIEND, name: params[0] === FRIEND ? name : null }] };
      } }),
      fetchImpl: async () => { throw new Error('must not call auth'); }, baseUrl: 'http://auth.test', serviceSecret: SECRET, logger: { error() {} },
    });
    return { app: a, authCalls: [] };
  };
  assert.ok(app && named);
  const ok = await call(make('  Asha Rao '), `/avatars/${FRIEND}/profile-name`);
  assert.equal(ok.res.status, 200);
  assert.deepEqual(JSON.parse(ok.text), { profile_name: 'Asha Rao' });
  const none = await call(make(null), `/avatars/${FRIEND}/profile-name`);
  assert.deepEqual(JSON.parse(none.text), { profile_name: null });
  const stranger = await call(make('X'), `/avatars/${STRANGER}/profile-name`);
  assert.equal(stranger.res.status, 404);
  assert.deepEqual(JSON.parse(stranger.text), { error: 'not_found' });
  assert.doesNotMatch(ok.text, new RegExp(SECRET));
});
