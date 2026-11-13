const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');
const express = require('express');

process.env.NODE_ENV = 'test';
const svc = require('../src/services/userAvatar');
const { AvatarError } = svc;

const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(400, 7)]);
const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(400, 3)]);

// In-memory users row answering the four statements the service issues.
function world(extra = {}) {
  const row = { id: 'me', deleted: false, is_active: true, avatar_preset: null, avatar_photo: null, avatar_photo_type: null, avatar_photo_shared: false, avatar_updated_at: null, ...extra };
  const query = async (sql, args = []) => {
    const live = row.id === args[0] && !row.deleted && row.is_active;
    if (sql.includes('SELECT avatar_preset, (avatar_photo IS NOT NULL)')) {
      return { rows: live ? [{ avatar_preset: row.avatar_preset, has_photo: row.avatar_photo !== null, avatar_photo_shared: row.avatar_photo_shared, avatar_updated_at: row.avatar_updated_at }] : [] };
    }
    if (sql.includes('avatar_photo_shared = TRUE AND avatar_photo IS NOT NULL')) {
      const ok = live && row.avatar_photo_shared === true && row.avatar_photo !== null;
      return { rows: ok ? [{ avatar_photo: row.avatar_photo, avatar_photo_type: row.avatar_photo_type }] : [] };
    }
    if (sql.includes('AS photo_shared')) {
      return { rows: live ? [{ avatar_preset: row.avatar_preset, photo_shared: row.avatar_photo !== null && row.avatar_photo_shared === true, avatar_updated_at: row.avatar_updated_at }] : [] };
    }
    if (sql.includes('SET avatar_photo_shared = $2')) {
      if (!live) return { rows: [] };
      row.avatar_photo_shared = args[1]; row.avatar_updated_at = new Date(Date.now() + 4000); return { rows: [{ id: row.id }] };
    }
    if (sql.includes('SELECT avatar_photo, avatar_photo_type')) {
      return { rows: live ? [{ avatar_photo: row.avatar_photo, avatar_photo_type: row.avatar_photo_type }] : [] };
    }
    if (sql.includes('SET avatar_preset = $2')) {
      if (!live) return { rows: [] };
      row.avatar_preset = args[1]; row.avatar_updated_at = new Date(Date.now() + 1000); return { rows: [{ id: row.id }] };
    }
    if (sql.includes('SET avatar_photo = $2')) {
      if (!live) return { rows: [] };
      row.avatar_photo = args[1]; row.avatar_photo_type = args[2]; row.avatar_updated_at = new Date(Date.now() + 2000); return { rows: [{ id: row.id }] };
    }
    if (sql.includes('SET avatar_photo = NULL')) {
      if (!live) return { rows: [] };
      if (!sql.includes('avatar_photo_shared = FALSE')) throw new Error('removePhoto must reset sharing');
      row.avatar_photo_shared = false;
      row.avatar_photo = null; row.avatar_photo_type = null; row.avatar_updated_at = new Date(Date.now() + 3000); return { rows: [{ id: row.id }] };
    }
    throw new Error(`Unexpected SQL: ${sql.slice(0, 60)}`);
  };
  return { row, query };
}

test('a fresh account has no avatar', async () => {
  const w = world();
  assert.deepEqual(await svc.getAvatar({ query: w.query, userId: 'me' }), { preset: null, has_photo: false, share_photo: false, version: 0 });
});

test('every preset id is accepted, anything else is not', async () => {
  const w = world();
  for (const preset of svc.PRESETS) {
    const out = await svc.setPreset({ query: w.query, userId: 'me', preset });
    assert.equal(out.preset, preset);
  }
  for (const bad of ['', 'PANDA', 'panda; drop', 'x'.repeat(30), 5, undefined, {}]) {
    await assert.rejects(svc.setPreset({ query: w.query, userId: 'me', preset: bad }), e => e instanceof AvatarError && e.code === 'preset_invalid');
  }
});

test('a preset can be cleared back to the initial letter, and the version moves', async () => {
  const w = world();
  const a = await svc.setPreset({ query: w.query, userId: 'me', preset: 'panda' });
  const b = await svc.setPreset({ query: w.query, userId: 'me', preset: null });
  assert.equal(b.preset, null);
  assert.ok(b.version >= a.version);
});

test('a JPEG and a PNG photo are stored with their real type', async () => {
  const w = world();
  assert.equal((await svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG, declaredType: 'image/jpeg' })).has_photo, true);
  assert.equal(w.row.avatar_photo_type, 'image/jpeg');
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: PNG, declaredType: 'image/png' });
  assert.equal(w.row.avatar_photo_type, 'image/png');
});

test('the type comes from the bytes: a mislabelled or non-image upload is refused', async () => {
  const w = world();
  const html = Buffer.from('<html><script>alert(1)</script></html>'.padEnd(300, ' '));
  await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: html, declaredType: 'image/jpeg' }), e => e.code === 'photo_type_unsupported');
  await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: PNG, declaredType: 'image/jpeg' }), e => e.code === 'photo_invalid');
  assert.equal(w.row.avatar_photo, null);
});

test('empty, tiny and oversized photos are refused', async () => {
  const w = world();
  await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: Buffer.alloc(0) }), e => e.code === 'photo_invalid');
  await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG.subarray(0, 10) }), e => e.code === 'photo_invalid');
  const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(svc.MAX_PHOTO_BYTES, 1)]);
  await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: big }), e => e.code === 'photo_too_large' && e.status === 413);
});

test('the owner can read the photo back, and remove it', async () => {
  const w = world();
  await assert.rejects(svc.getPhoto({ query: w.query, userId: 'me' }), e => e.code === 'no_photo');
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG });
  const photo = await svc.getPhoto({ query: w.query, userId: 'me' });
  assert.equal(photo.type, 'image/jpeg');
  assert.ok(photo.bytes.equals(JPEG));
  const out = await svc.removePhoto({ query: w.query, userId: 'me' });
  assert.equal(out.has_photo, false);
});

test('a deleted or disabled account cannot read or change an avatar', async () => {
  for (const extra of [{ deleted: true }, { is_active: false }]) {
    const w = world(extra);
    await assert.rejects(svc.getAvatar({ query: w.query, userId: 'me' }), e => e.code === 'account_unavailable');
    await assert.rejects(svc.setPreset({ query: w.query, userId: 'me', preset: 'panda' }), e => e.code === 'account_unavailable');
    await assert.rejects(svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG }), e => e.code === 'account_unavailable');
    await assert.rejects(svc.removePhoto({ query: w.query, userId: 'me' }), e => e.code === 'account_unavailable');
  }
});

// ---- the HTTP layer, including the real raw-body upload ----

function load(relativePath, dependencies) {
  const filename = path.resolve(__dirname, relativePath);
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

async function harness(t, { user = { id: 'me', device_id: 'device-1' } } = {}) {
  const w = world();
  const router = load('../src/routes/avatarRoutes.js', {
    '../db': { query: w.query },
    '../middleware/authMiddleware': (req, _res, next) => { req.user = user; next(); },
    '../middleware/userRateLimit': { userRateLimitRead: (_q, _r, n) => n(), userRateLimitWrite: (_q, _r, n) => n() },
  });
  const app = express();
  app.use(express.json());
  app.use('/users/me/avatar', router);
  const server = await new Promise(resolve => { const l = app.listen(0, '127.0.0.1', () => resolve(l)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}/users/me/avatar`;
  return { w, base };
}

test('HTTP: preset, photo upload, owner-only download with safe headers, and delete', async t => {
  const { base } = await harness(t);
  let r = await fetch(`${base}/preset`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ preset: 'bamboo' }) });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).preset, 'bamboo');
  assert.equal(r.headers.get('cache-control'), 'no-store');

  r = await fetch(`${base}/photo`, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: JPEG });
  assert.equal(r.status, 200);
  assert.equal((await r.json()).has_photo, true);

  r = await fetch(`${base}/photo`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'image/jpeg');
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
  assert.match(r.headers.get('content-security-policy'), /sandbox/);
  assert.ok(Buffer.from(await r.arrayBuffer()).equals(JPEG));

  r = await fetch(`${base}/photo`, { method: 'DELETE' });
  assert.equal((await r.json()).has_photo, false);
  assert.equal((await fetch(`${base}/photo`)).status, 404);
});

test('HTTP: bad preset bodies, a JSON upload to the photo route and oversized photos are refused', async t => {
  const { base, w } = await harness(t);
  const put = (suffix, headers, body) => fetch(`${base}${suffix}`, { method: 'PUT', headers, body });
  assert.equal((await put('/preset', { 'content-type': 'application/json' }, JSON.stringify({ preset: 'nope' }))).status, 400);
  assert.equal((await put('/preset', { 'content-type': 'application/json' }, JSON.stringify({}))).status, 400);
  assert.equal((await put('/preset', { 'content-type': 'application/json' }, JSON.stringify({ preset: 'panda', extra: 1 }))).status, 400);
  assert.equal((await put('/photo', { 'content-type': 'application/json' }, JSON.stringify({ photo: 'x' }))).status, 415);
  const big = Buffer.concat([JPEG, Buffer.alloc(svc.MAX_PHOTO_BYTES, 1)]);
  const r = await put('/photo', { 'content-type': 'image/jpeg' }, big);
  assert.equal(r.status, 413);
  assert.equal((await r.json()).error, 'photo_too_large');
  assert.equal(w.row.avatar_photo, null);
});

test('HTTP: a recovery session cannot change the avatar', async t => {
  const { base } = await harness(t, { user: { id: 'me', device_id: 'device-1', recovery_channel: 'email' } });
  assert.equal((await fetch(`${base}/preset`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ preset: 'panda' }) })).status, 403);
  assert.equal((await fetch(`${base}/photo`, { method: 'PUT', headers: { 'content-type': 'image/jpeg' }, body: JPEG })).status, 403);
  assert.equal((await fetch(`${base}/photo`, { method: 'DELETE' })).status, 403);
});

// ---- consent to show the photo to other people ----

test('sharing is off by default, can be toggled, and only booleans are accepted', async () => {
  const w = world();
  assert.equal((await svc.getAvatar({ query: w.query, userId: 'me' })).share_photo, false);
  assert.equal((await svc.setSharing({ query: w.query, userId: 'me', share: true })).share_photo, true);
  assert.equal(w.row.avatar_photo_shared, true);
  assert.equal((await svc.setSharing({ query: w.query, userId: 'me', share: false })).share_photo, false);
  for (const bad of ['true', 1, null, undefined, {}]) {
    await assert.rejects(svc.setSharing({ query: w.query, userId: 'me', share: bad }), e => e.code === 'sharing_invalid' && e.status === 400);
  }
  const gone = world({ deleted: true });
  await assert.rejects(svc.setSharing({ query: gone.query, userId: 'me', share: true }), e => e.code === 'account_unavailable');
});

test('removing the photo turns sharing off; replacing it keeps the flag', async () => {
  const w = world();
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG });
  await svc.setSharing({ query: w.query, userId: 'me', share: true });
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: PNG });
  assert.equal(w.row.avatar_photo_shared, true);
  const out = await svc.removePhoto({ query: w.query, userId: 'me' });
  assert.equal(out.share_photo, false);
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG });
  assert.equal(w.row.avatar_photo_shared, false);
});

test('public avatar: preset only while the photo is private, photo once shared', async () => {
  const w = world();
  await svc.setPreset({ query: w.query, userId: 'me', preset: 'sun' });
  await svc.setPhoto({ query: w.query, userId: 'me', bytes: JPEG });
  let pub = await svc.getPublicAvatar({ query: w.query, userId: 'me' });
  assert.deepEqual(Object.keys(pub).sort(), ['photo_shared', 'preset', 'version']);
  assert.equal(pub.preset, 'sun');
  assert.equal(pub.photo_shared, false);
  assert.equal(await svc.getPublicPhoto({ query: w.query, userId: 'me' }), null);
  await svc.setSharing({ query: w.query, userId: 'me', share: true });
  pub = await svc.getPublicAvatar({ query: w.query, userId: 'me' });
  assert.equal(pub.photo_shared, true);
  const photo = await svc.getPublicPhoto({ query: w.query, userId: 'me' });
  assert.ok(photo.bytes.equals(JPEG));
  assert.equal(photo.type, 'image/jpeg');
});

test('public avatar: sharing on with no photo reports no photo; unknown, deleted, inactive are null', async () => {
  const w = world();
  await svc.setSharing({ query: w.query, userId: 'me', share: true });
  assert.equal((await svc.getPublicAvatar({ query: w.query, userId: 'me' })).photo_shared, false);
  assert.equal(await svc.getPublicPhoto({ query: w.query, userId: 'me' }), null);
  assert.equal(await svc.getPublicAvatar({ query: w.query, userId: 'someone-else' }), null);
  for (const extra of [{ deleted: true }, { is_active: false }]) {
    const x = world({ ...extra, avatar_photo: JPEG, avatar_photo_type: 'image/jpeg', avatar_photo_shared: true });
    assert.equal(await svc.getPublicAvatar({ query: x.query, userId: 'me' }), null);
    assert.equal(await svc.getPublicPhoto({ query: x.query, userId: 'me' }), null);
  }
});

test('HTTP: the sharing route validates its body, persists, and is blocked for recovery sessions', async t => {
  const { base, w } = await harness(t);
  const put = (b, body) => fetch(`${b}/sharing`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  for (const bad of [{}, { share_photo: 'yes' }, { share_photo: 1 }, { share_photo: true, extra: 1 }, [true], { shared: true }]) {
    const r = await put(base, bad);
    assert.equal(r.status, 400);
    assert.equal((await r.json()).error, 'sharing_invalid');
  }
  assert.equal(w.row.avatar_photo_shared, false);
  let r = await put(base, { share_photo: true });
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(await r.json()).sort(), ['has_photo', 'preset', 'share_photo', 'version']);
  assert.equal(w.row.avatar_photo_shared, true);
  r = await fetch(base);
  assert.equal((await r.json()).share_photo, true);

  const rec = await harness(t, { user: { id: 'me', device_id: 'device-1', recovery_channel: 'email' } });
  assert.equal((await put(rec.base, { share_photo: true })).status, 403);
  assert.equal(rec.w.row.avatar_photo_shared, false);
});

// ---- the internal service-to-service endpoints ----

const SECRET = 'test-internal-service-secret-at-least-32-bytes';
const UID = '11111111-2222-4333-8444-555555555555';
const OTHER_UID = '99999999-2222-4333-8444-555555555555';

async function internalHarness(t, { secret = SECRET, extra = {} } = {}) {
  const w = world({ id: UID, ...extra });
  let calls = 0;
  const query = (...a) => { calls += 1; return w.query(...a); };
  const router = load('../src/routes/internalRoutes.js', {
    '../config': { authInternalServiceSecret: secret },
    '../db': { query },
    '../services/currentSessionVerification': { verifyCurrentSession: async () => ({}) },
  });
  const app = express(); app.use(express.json()); app.use('/internal', router);
  const server = await new Promise(resolve => { const l = app.listen(0, '127.0.0.1', () => resolve(l)); });
  t.after(() => { server.closeAllConnections(); server.close(); });
  const base = `http://127.0.0.1:${server.address().port}/internal/avatar`;
  const get = (suffix, headers = { 'x-auth-service-secret': SECRET }) => fetch(`${base}/${suffix}`, { headers });
  return { w, get, calls: () => calls };
}

test('internal avatar: needs the service secret (401 wrong/missing, 503 unconfigured) and a UUID', async t => {
  const h = await internalHarness(t);
  assert.equal((await h.get(UID, {})).status, 401);
  assert.equal((await h.get(UID, { 'x-auth-service-secret': 'wrong-secret-wrong-secret-wrong-secret' })).status, 401);
  assert.equal((await h.get(`${UID}/photo`, {})).status, 401);
  assert.equal(h.calls(), 0);
  for (const bad of ['not-a-uuid', '123', 'me', `${UID}x`]) {
    assert.equal((await h.get(bad)).status, 400);
    assert.equal((await h.get(`${bad}/photo`)).status, 400);
  }
  assert.equal(h.calls(), 0);
  const off = await internalHarness(t, { secret: null });
  assert.equal((await off.get(UID)).status, 503);
  assert.equal((await off.get(`${UID}/photo`)).status, 503);
});

test('internal avatar: private photo shows preset only; shared photo is served with safe headers', async t => {
  const h = await internalHarness(t, { extra: { avatar_preset: 'wave', avatar_photo: JPEG, avatar_photo_type: 'image/jpeg' } });
  let r = await h.get(UID);
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.deepEqual(Object.keys(body).sort(), ['photo_shared', 'preset', 'version']);
  assert.equal(body.preset, 'wave');
  assert.equal(body.photo_shared, false);
  const privatePhoto = await h.get(`${UID}/photo`);
  assert.equal(privatePhoto.status, 404);
  assert.deepEqual(await privatePhoto.json(), { error: 'not_found' });

  h.w.row.avatar_photo_shared = true;
  r = await h.get(UID);
  assert.equal((await r.json()).photo_shared, true);
  r = await h.get(`${UID}/photo`);
  assert.equal(r.status, 200);
  assert.equal(r.headers.get('content-type'), 'image/jpeg');
  assert.equal(r.headers.get('x-content-type-options'), 'nosniff');
  assert.match(r.headers.get('content-security-policy'), /sandbox/);
  assert.equal(r.headers.get('cache-control'), 'no-store');
  assert.ok(Buffer.from(await r.arrayBuffer()).equals(JPEG));
});

test('internal avatar: private photo, no photo, unknown and deleted users get the identical 404', async t => {
  const cases = [
    { avatar_photo: JPEG, avatar_photo_type: 'image/jpeg', avatar_photo_shared: false },
    { avatar_photo_shared: true },
    { avatar_photo_shared: false },
    { deleted: true, avatar_photo: JPEG, avatar_photo_type: 'image/jpeg', avatar_photo_shared: true },
    { is_active: false, avatar_photo: JPEG, avatar_photo_type: 'image/jpeg', avatar_photo_shared: true },
  ];
  const seen = [];
  for (const extra of cases) {
    const h = await internalHarness(t, { extra });
    const r = await h.get(`${UID}/photo`);
    seen.push([r.status, await r.text(), r.headers.get('content-type')]);
  }
  const h = await internalHarness(t);
  const unknown = await h.get(`${OTHER_UID}/photo`);
  seen.push([unknown.status, await unknown.text(), unknown.headers.get('content-type')]);
  for (const s of seen) assert.deepEqual(s, seen[0]);
  assert.equal(seen[0][0], 404);
  assert.equal(seen[0][1], JSON.stringify({ error: 'not_found' }));
  const gone = await internalHarness(t, { extra: { deleted: true } });
  const g = await gone.get(UID);
  assert.equal(g.status, 404);
  assert.deepEqual(await g.json(), { error: 'not_found' });
  assert.equal((await h.get(OTHER_UID)).status, 404);
});
