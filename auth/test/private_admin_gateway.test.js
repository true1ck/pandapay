'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { createAdminGatewayApp } = require('../src/admin/gateway');

const config = { enabled: true, origin: 'https://localhost:8443', rpId: 'localhost', tokenLookupKey: 't'.repeat(32), introspectionSecret: 's'.repeat(32), sessionEncryptionKey: Buffer.alloc(32, 1), environment: 'synthetic' };
const methods = ['findVerifiedPrincipalByEmail','createLoginChallenge','consumeEmailChallenge','createWebAuthnChallenge','consumeWebAuthnChallenge','getWebAuthnChallenge','listCredentials','getEnrollmentGrant','createEnrollmentGrant','consumeEnrollmentGrant','addCredential','createAdminSession','resolveAdminSessionByToken','loadSession','touchAdminSession','revokeAdminSession','revokeAllAdminSessions','updateAdminSessionVerification','rateLimit','rotateAccessToken','updateCredentialCounter'];
function dependencies(overrides = {}) {
  const repository = Object.fromEntries(methods.map(name => [name, async () => null]));
  Object.assign(repository, { findVerifiedPrincipalByEmail: async () => null, createLoginChallenge: async () => ({}), rateLimit: async () => ({ allowed: true }) }, overrides.repository || {});
  return { emailClient: { sendAdminOtp: async () => {} }, membershipClient: { getAdminMembership: async () => null }, privateApi: { request: async () => ({ status: 503, body: {} }) }, routeManifest: [{ method: 'GET', path: '/admin/me' }], webauthn: { registrationOptions: async () => ({}), verifyRegistration: async () => ({ verified: false }), authenticationOptions: async () => ({}), verifyAuthentication: async () => ({ verified: false }) }, config, ...overrides, repository };
}
async function withServer(app, fn) {
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try { await fn(server.address().port); } finally { await new Promise(resolve => server.close(resolve)); }
}
function post(port, path, { headers = {}, body = {} } = {}) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(body);
    const requestHeaders = { host: 'localhost:8443', origin: config.origin, 'x-admin-protocol': '1', 'x-console-request': '1', 'content-type': 'application/json', 'content-length': Buffer.byteLength(data), ...headers };
    for (const key of Object.keys(requestHeaders)) if (requestHeaders[key] === undefined) delete requestHeaders[key];
    const req = http.request({ host: '127.0.0.1', port, method: 'POST', path, headers: requestHeaders }, res => {
      const chunks = []; res.on('data', c => chunks.push(c)); res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: JSON.parse(Buffer.concat(chunks).toString() || 'null') }));
    });
    req.on('error', reject); req.end(data);
  });
}

test('private gateway rejects unsafe/incomplete construction', () => {
  assert.throws(() => createAdminGatewayApp({ ...dependencies(), config: { ...config, origin: 'http://localhost' } }), /configuration/);
  assert.throws(() => createAdminGatewayApp({ ...dependencies(), webauthn: null }), /WebAuthn/);
  assert.throws(() => createAdminGatewayApp({ ...dependencies(), repository: {} }), /repository missing/);
});

test('unknown identity receives a generic start response and cannot verify email', async () => {
  let mailSent = false;
  const app = createAdminGatewayApp(dependencies({ emailClient: { sendAdminOtp: async () => { mailSent = true; } } }));
  await withServer(app, async port => {
    const started = await post(port, '/browser/login/start', { body: { email: 'unknown@example.test' } });
    assert.equal(started.status, 202);
    assert.equal(started.body.expiresIn, 120);
    assert.match(started.headers['set-cookie'][0], /Secure; HttpOnly; SameSite=Strict/);
    assert.equal(mailSent, false);
    const cookie = started.headers['set-cookie'].map(v => v.split(';')[0]).join('; ');
    const verify = await post(port, '/browser/login/verify-email', { headers: { cookie }, body: { loginId: started.body.loginId, code: '123456' } });
    assert.equal(verify.status, 401);
    assert.deepEqual(verify.body, { error: 'invalid_credentials', version: 1 });
  });
});

test('pre-auth routes reject missing browser headers, wrong origin, host and forwarded spoofing', async () => {
  const app = createAdminGatewayApp(dependencies());
  await withServer(app, async port => {
    const missing = await post(port, '/browser/login/start', { headers: { 'x-console-request': undefined }, body: { email: 'a@example.test' } });
    assert.equal(missing.status, 426);
    const wrongOrigin = await post(port, '/browser/login/start', { headers: { origin: 'https://evil.example' }, body: { email: 'a@example.test' } });
    assert.equal(wrongOrigin.status, 403);
    const forwarded = await post(port, '/browser/login/start', { headers: { 'x-forwarded-host': 'localhost:8443' }, body: { email: 'a@example.test' } });
    assert.equal(forwarded.status, 400);
  });
});

test('introspection requires the dedicated service secret and returns auth-only state', async () => {
  const app = createAdminGatewayApp(dependencies({ repository: { resolveAdminSessionByToken: async () => ({ active: true, actorId: 'actor-1', sessionId: 'session-1', verifiedAt: new Date('2026-01-01T00:00:00Z'), expiresAt: new Date('2026-01-01T00:05:00Z') }) } }));
  await withServer(app, async port => {
    const denied = await post(port, '/internal/admin/session/introspect', { headers: { host: 'internal', origin: undefined }, body: { token: 'x'.repeat(50) } });
    assert.equal(denied.status, 401);
    const accepted = await post(port, '/internal/admin/session/introspect', { headers: { host: 'internal', origin: undefined, 'x-admin-service-secret': config.introspectionSecret }, body: { token: 'x'.repeat(50) } });
    assert.equal(accepted.status, 200);
    assert.equal(accepted.body.assurance, 'email+webauthn-uv');
    assert.equal(accepted.body.userId, 'actor-1');
    assert.equal('permissions' in accepted.body, false);
  });
});
