'use strict';

// The gateway used to parse every private API reply into objects and serialise it again just to forward it. For the
// 14 MB card catalogue that peaked near 190 MB in a 1 GB host (21 Nov 2026), and the memory then sat in swap. The proxy
// now streams the reply's bytes to the browser as they arrive; the size limit and the JSON-only rule still hold.

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { Writable } = require('node:stream');
const { createPrivateApiClient } = require('../src/admin/server');
const { createAdminGatewayApp, COOKIE, digest } = require('../src/admin/gateway');

async function upstream(handler) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { server, baseUrl: new URL(`http://127.0.0.1:${server.address().port}`), close: () => new Promise((r) => server.close(r)) };
}

function collector() {
  const chunks = [];
  const sink = new Writable({ write(chunk, _enc, done) { chunks.push(Buffer.from(chunk)); done(); } });
  return { sink, bytes: () => Buffer.concat(chunks), heads: [] };
}

test('a streamed reply reaches the sink byte for byte, piece by piece, without being parsed or held whole', async () => {
  const pieces = ['{"cards":[', '{"id":"a","name":"Card \\u00e9"}', ',{"id":"b"}', '],"n":2}'];
  const api = await upstream(async (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json; charset=utf-8' });
    for (const p of pieces) { res.write(p); await new Promise((r) => setTimeout(r, 5)); }
    res.end();
  });
  try {
    const out = collector();
    const parse = JSON.parse;
    let parsed = 0;
    // Count only parses called directly from the gateway's code (Node's fetch parses its own settings internally).
    JSON.parse = (...args) => { const caller = new Error().stack.split('\n')[2] || ''; if (/src[\\/]admin[\\/]/.test(caller)) parsed += 1; return parse(...args); };
    let result;
    try {
      result = await createPrivateApiClient(api.baseUrl).request({ method: 'GET', path: '/admin/cards', accessToken: 't', sink: out.sink, onHead: (s) => out.heads.push(s) });
    } finally { JSON.parse = parse; }
    assert.equal(result.streamed, true);
    assert.deepEqual(out.heads, [200]);
    assert.equal(out.bytes().toString('utf8'), pieces.join(''));
    assert.equal(parsed, 0, 'nothing parsed');
  } finally { await api.close(); }
});

test('a reply that is not JSON, or declared over the limit, is refused before anything is sent', async () => {
  const api = await upstream((req, res) => {
    if (req.url.startsWith('/admin/html')) { res.writeHead(200, { 'content-type': 'text/html' }); return res.end('<b>x</b>'); }
    const body = JSON.stringify({ big: 'x'.repeat(5000) });
    res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) }); return res.end(body);
  });
  try {
    const client = createPrivateApiClient(api.baseUrl);
    for (const [path, limit, error] of [['/admin/html', 4096, /not JSON/], ['/admin/big', 1000, /exceeded limit/]]) {
      const out = collector();
      await assert.rejects(client.request({ method: 'GET', path, accessToken: 't', maxResponseBytes: limit, sink: out.sink, onHead: (s) => out.heads.push(s) }), error);
      assert.deepEqual(out.heads, [], `${path}: no status sent`);
      assert.equal(out.bytes().length, 0, `${path}: no bytes sent`);
    }
  } finally { await api.close(); }
});

test('a reply with no declared length that grows past the limit is cut off', async () => {
  const api = await upstream(async (req, res) => {
    res.writeHead(200, { 'content-type': 'application/json' });
    for (let i = 0; i < 10; i++) { res.write('x'.repeat(500)); await new Promise((r) => setTimeout(r, 2)); }
    res.end();
  });
  try {
    const out = collector();
    await assert.rejects(createPrivateApiClient(api.baseUrl).request({ method: 'GET', path: '/admin/cards', accessToken: 't', maxResponseBytes: 1200, sink: out.sink, onHead: () => {} }), /exceeded limit/);
    assert.ok(out.bytes().length <= 1200, 'never more than the limit forwarded');
  } finally { await api.close(); }
});

test('an empty reply is forwarded as null, as before', async () => {
  const api = await upstream((req, res) => { res.writeHead(200); res.end(); });
  try {
    const out = collector();
    await createPrivateApiClient(api.baseUrl).request({ method: 'POST', path: '/admin/x', accessToken: 't', body: {}, sink: out.sink, onHead: (s) => out.heads.push(s) });
    assert.deepEqual(out.heads, [200]);
    assert.equal(out.bytes().toString(), 'null');
  } finally { await api.close(); }
});

test('without a sink the reply is still parsed (the sign-in membership check reads its fields)', async () => {
  const api = await upstream((req, res) => { res.writeHead(200, { 'content-type': 'application/json' }); res.end('{"isAdmin":true}'); });
  try {
    const result = await createPrivateApiClient(api.baseUrl).request({ method: 'GET', path: '/admin/me', accessToken: 't' });
    assert.deepEqual(result.body, { isAdmin: true });
  } finally { await api.close(); }
});

const config = { enabled: true, origin: 'https://localhost:8443', rpId: 'localhost', tokenLookupKey: 't'.repeat(32), introspectionSecret: 's'.repeat(32), sessionEncryptionKey: Buffer.alloc(32, 1), environment: 'synthetic' };
function encrypt(value, key) {
  const iv = crypto.randomBytes(12); const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64url');
}

async function gatewayCall(privateApi) {
  const sessionCookie = 'session-cookie-value';
  const state = {
    id: 'session-1', user_id: 'actor-1', verified_at: new Date().toISOString(),
    absolute_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    access_token_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    csrf_digest: digest('csrf-token', config.tokenLookupKey),
    encrypted_upstream_token: encrypt('u'.repeat(43), config.sessionEncryptionKey),
  };
  const repository = new Proxy({
    loadSession: async (value) => (value === digest(sessionCookie, config.tokenLookupKey) ? state : null),
    touchAdminSession: async () => ({ ok: true }),
    rateLimit: async () => ({ allowed: true }),
  }, { get: (target, name) => (name in target ? target[name] : async () => null) });
  const app = createAdminGatewayApp({
    repository, emailClient: { sendAdminOtp: async () => {} }, membershipClient: { getAdminMembership: async () => null }, privateApi,
    routeManifest: [{ method: 'GET', path: '/admin/cards' }],
    webauthn: { registrationOptions: async () => ({}), verifyRegistration: async () => ({ verified: false }), authenticationOptions: async () => ({}), verifyAuthentication: async () => ({ verified: false }) },
    config,
  });
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    return await new Promise((resolve) => {
      const req = http.request({ host: '127.0.0.1', port: server.address().port, method: 'GET', path: '/browser/api/admin/cards', headers: { host: 'localhost:8443', cookie: `${COOKIE}=${sessionCookie}`, 'x-admin-protocol': '1', 'x-console-request': '1' } }, (res) => {
        const chunks = []; res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, type: res.headers['content-type'], body: Buffer.concat(chunks), complete: res.complete }));
        res.on('error', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks), complete: false }));
      });
      req.on('error', () => resolve({ status: 0, complete: false })); req.end();
    });
  } finally { await new Promise((resolve) => server.close(resolve)); }
}

test('the browser proxy streams the private API reply to the browser unchanged, as JSON', async () => {
  const bytes = Buffer.from('{"cards":[1,2,3],"note":"kept exactly"}');
  const seen = [];
  const reply = await gatewayCall({ request: async (options) => {
    seen.push(options);
    options.onHead(200); options.sink.write(bytes.subarray(0, 10)); options.sink.write(bytes.subarray(10)); options.sink.end();
    return { status: 200, streamed: true };
  } });
  assert.equal(reply.status, 200);
  assert.match(reply.type, /^application\/json/);
  assert.ok(reply.body.equals(bytes), 'same bytes as the private API sent');
  assert.ok(seen[0].sink && typeof seen[0].onHead === 'function');
});

test('a failure before anything was sent is a clean 503; a failure mid-stream ends the connection, never a partial 200', async () => {
  const before = await gatewayCall({ request: async () => { throw new Error('private API reply is not JSON'); } });
  assert.equal(before.status, 503);
  const midway = await gatewayCall({ request: async (options) => {
    options.onHead(200); options.sink.write('{"cards":[1,'); await new Promise((r) => setTimeout(r, 5));
    throw new Error('private API response exceeded limit');
  } });
  assert.equal(midway.complete, false, 'the browser sees a broken reply, not a finished one');
});

test('replies reach the browser exactly as before: a 204 stays an empty 204 with no content type, JSON keeps its bytes and headers', async () => {
  const body = JSON.stringify({ rules: [{ id: 'r1', note: '<b>&</b> é' }], n: 1 });
  const api = await upstream((req, res) => {
    if (req.url.startsWith('/admin/cards/gone')) { res.writeHead(204); return res.end(); }
    res.writeHead(201, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(body) }); return res.end(body);
  });
  const sessionCookie = 'session-cookie-value';
  const state = {
    id: 'session-1', user_id: 'actor-1', verified_at: new Date().toISOString(),
    absolute_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    access_token_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    csrf_digest: digest('csrf-token', config.tokenLookupKey),
    encrypted_upstream_token: encrypt('u'.repeat(43), config.sessionEncryptionKey),
  };
  const repository = new Proxy({
    loadSession: async (value) => (value === digest(sessionCookie, config.tokenLookupKey) ? state : null),
    touchAdminSession: async () => ({ ok: true }),
    rateLimit: async () => ({ allowed: true }),
  }, { get: (target, name) => (name in target ? target[name] : async () => null) });
  const app = createAdminGatewayApp({
    repository, emailClient: { sendAdminOtp: async () => {} }, membershipClient: { getAdminMembership: async () => null },
    privateApi: createPrivateApiClient(api.baseUrl),
    routeManifest: [{ method: 'GET', path: '/admin/cards/:id' }],
    webauthn: { registrationOptions: async () => ({}), verifyRegistration: async () => ({ verified: false }), authenticationOptions: async () => ({}), verifyAuthentication: async () => ({ verified: false }) },
    config,
  });
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const get = (path) => new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: server.address().port, method: 'GET', path, headers: { host: 'localhost:8443', cookie: `${COOKIE}=${sessionCookie}`, 'x-admin-protocol': '1', 'x-console-request': '1' } }, (res) => {
      const chunks = []; res.on('data', (c) => chunks.push(c)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8') }));
    });
    req.on('error', reject); req.end();
  });
  try {
    const gone = await get('/browser/api/admin/cards/gone');
    assert.equal(gone.status, 204);
    assert.equal(gone.body, '');
    assert.equal(gone.headers['content-type'], undefined);
    const json = await get('/browser/api/admin/cards/one');
    assert.equal(json.status, 201);
    assert.equal(json.body, body, 'same text, including characters some serialisers escape');
    assert.equal(json.headers['content-type'], 'application/json; charset=utf-8');
    assert.equal(json.headers['cache-control'], 'no-store');
  } finally { await new Promise((resolve) => server.close(resolve)); await api.close(); }
});
