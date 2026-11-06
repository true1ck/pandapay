'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const crypto = require('node:crypto');
const { createAdminGatewayApp, COOKIE, digest, replyLimits } = require('../src/admin/gateway');

const MB = 1024 * 1024;
const config = { enabled: true, origin: 'https://localhost:8443', rpId: 'localhost', tokenLookupKey: 't'.repeat(32), introspectionSecret: 's'.repeat(32), sessionEncryptionKey: Buffer.alloc(32, 1), environment: 'synthetic' };

// Same AES-256-GCM packing the gateway uses for the session's upstream token.
function encrypt(value, key) {
  const iv = crypto.randomBytes(12); const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), ciphertext]).toString('base64url');
}

test('only the card catalogue list is allowed a large, slow reply', () => {
  const small = replyLimits('GET', '/admin/referrals');
  assert.equal(small.maxResponseBytes, 4 * MB);
  assert.equal(small.timeoutMs, 10_000);
  const large = replyLimits('GET', '/admin/cards');
  assert.ok(large.maxResponseBytes >= 24 * MB, 'the catalogue list needs room for about 14 MB');
  assert.ok(large.timeoutMs >= 30_000, 'and more than the 10 s default to read it');
  // Writes to the same path and every other read keep the small limits.
  assert.deepEqual(replyLimits('POST', '/admin/cards'), small);
  assert.deepEqual(replyLimits('GET', '/admin/cards/:id/status'), small);
  assert.deepEqual(replyLimits('GET', '/admin/me'), small);
});

test('the private API client honours a longer timeout but never beyond its hard bound', () => {
  const { boundedTimeoutMs, MAX_PRIVATE_API_MS } = require('../src/admin/server');
  assert.equal(boundedTimeoutMs(5_000), 5_000);
  assert.equal(boundedTimeoutMs(10_000), 10_000);
  assert.equal(boundedTimeoutMs(40_000), 40_000, 'the catalogue list asks for 40 s and must get it');
  assert.equal(boundedTimeoutMs(10 * 60_000), MAX_PRIVATE_API_MS);
  assert.ok(MAX_PRIVATE_API_MS >= replyLimits('GET', '/admin/cards').timeoutMs);
});

test('the proxy hands each route its own reply limits', async () => {
  const sessionCookie = 'session-cookie-value';
  const state = {
    id: 'session-1', user_id: 'actor-1', verified_at: new Date().toISOString(),
    absolute_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    access_token_expires_at: new Date(Date.now() + 3_600_000).toISOString(),
    csrf_digest: digest('csrf-token', config.tokenLookupKey),
    encrypted_upstream_token: encrypt('u'.repeat(43), config.sessionEncryptionKey),
  };
  const repository = new Proxy({
    loadSession: async value => (value === digest(sessionCookie, config.tokenLookupKey) ? state : null),
    touchAdminSession: async () => ({ ok: true }),
    rateLimit: async () => ({ allowed: true }),
  }, { get: (target, name) => (name in target ? target[name] : async () => null) });
  const seen = [];
  const privateApi = { request: async options => { seen.push(options); return { status: 200, body: { ok: true } }; } };
  const app = createAdminGatewayApp({
    repository, emailClient: { sendAdminOtp: async () => {} }, membershipClient: { getAdminMembership: async () => null }, privateApi,
    routeManifest: [{ method: 'GET', path: '/admin/cards' }, { method: 'POST', path: '/admin/cards' }, { method: 'GET', path: '/admin/me' }],
    webauthn: { registrationOptions: async () => ({}), verifyRegistration: async () => ({ verified: false }), authenticationOptions: async () => ({}), verifyAuthentication: async () => ({ verified: false }) },
    config,
  });
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const call = (method, path) => new Promise((resolve, reject) => {
    const headers = { host: 'localhost:8443', cookie: `${COOKIE}=${sessionCookie}`, 'x-admin-protocol': '1', 'x-console-request': '1' };
    let data = '';
    if (method !== 'GET') Object.assign(headers, { origin: config.origin, 'x-csrf-token': 'csrf-token', 'content-type': 'application/json' }), data = '{}';
    headers['content-length'] = Buffer.byteLength(data);
    const req = http.request({ host: '127.0.0.1', port: server.address().port, method, path, headers }, res => { res.resume(); res.on('end', () => resolve(res.statusCode)); });
    req.on('error', reject); req.end(data);
  });
  try {
    assert.equal(await call('GET', '/browser/api/admin/cards'), 200);
    assert.equal(await call('GET', '/browser/api/admin/me'), 200);
    assert.equal(await call('POST', '/browser/api/admin/cards'), 200);
  } finally { await new Promise(resolve => server.close(resolve)); }

  assert.equal(seen.length, 3);
  const [cardsList, me, cardsWrite] = seen;
  assert.equal(cardsList.path, '/admin/cards');
  assert.ok(cardsList.maxResponseBytes >= 24 * MB && cardsList.timeoutMs >= 30_000);
  assert.equal(me.maxResponseBytes, 4 * MB);
  assert.equal(me.timeoutMs, 10_000);
  assert.equal(cardsWrite.method, 'POST');
  assert.equal(cardsWrite.maxResponseBytes, 4 * MB);
  assert.equal(cardsWrite.timeoutMs, 10_000);
});
