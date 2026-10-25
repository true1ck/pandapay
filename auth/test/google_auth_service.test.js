'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Module = require('node:module');

// Inject a provider client, never a live URL/config file or test-token bypass.
const filename = path.resolve(__dirname, '../src/services/googleAuthService.js');
const loaded = new Module(filename, module);
loaded.filename = filename;
loaded.paths = Module._nodeModulePaths(path.dirname(filename));
loaded.require = name => name === '../config' ? {} : require(name);
loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
const { createGoogleTokenVerifier, verifiedGoogleIdentity } = loaded.exports;
const audience = 'synthetic.apps.googleusercontent.com';
function payload(changes = {}) {
  return {
    sub: '123456789', iss: 'https://accounts.google.com', aud: audience,
    email: 'User@gmail.com', email_verified: true,
    exp: Math.floor(Date.now() / 1000) + 120, name: 'Synthetic User', ...changes,
  };
}

test('Google verifier uses signature-verifying client with configured audience', async () => {
  let args;
  const verify = createGoogleTokenVerifier({ audience, client: {
    async verifyIdToken(value) { args = value; return { getPayload: () => payload() }; },
  } });
  const identity = await verify('synthetic-token');
  assert.deepEqual(args, { idToken: 'synthetic-token', audience });
  assert.equal(identity.googleId, '123456789');
  assert.equal(identity.email, 'user@gmail.com');
  assert.equal(identity.emailAuthoritative, true);
});

for (const [label, change] of Object.entries({
  'wrong issuer': { iss: 'https://attacker.invalid' },
  'wrong audience': { aud: 'other-client' },
  'missing subject': { sub: undefined },
  'oversized subject': { sub: 's'.repeat(256) },
  'non-string subject': { sub: 123 },
  'malformed subject': { sub: 'contains spaces' },
  'unverified email': { email_verified: false },
  'string email verification': { email_verified: 'true' },
  'missing email': { email: undefined },
  'malformed email': { email: 'bad-email' },
  'expired token': { exp: Math.floor(Date.now() / 1000) - 1 },
  'missing expiry': { exp: undefined },
})) {
  test(`Google verifier rejects ${label}`, () => {
    assert.throws(() => verifiedGoogleIdentity(payload(change), audience), { code: 'GOOGLE_TOKEN_INVALID' });
  });
}

test('Google third-party email requires separate contact proof; Workspace is authoritative', () => {
  assert.equal(verifiedGoogleIdentity(payload({ email: 'user@example.net' }), audience).emailAuthoritative, false);
  assert.equal(verifiedGoogleIdentity(payload({ email: 'user@example.net', hd: 'example.net' }), audience).emailAuthoritative, true);
});

test('Google token can identify an Android presenter while keeping the verified server audience', () => {
  assert.equal(verifiedGoogleIdentity(payload({ azp: 'android.apps.googleusercontent.com' }), audience).googleId, '123456789');
});

test('historical magic token has no bypass and provider failures are redacted', async () => {
  let calls = 0;
  const verify = createGoogleTokenVerifier({ audience, client: {
    async verifyIdToken() { calls++; throw new Error('SENSITIVE_PROVIDER_DETAILS'); },
  } });
  await assert.rejects(verify('TEST_GOOGLE_TOKEN'), error => error.code === 'GOOGLE_TOKEN_INVALID' && !error.message.includes('SENSITIVE'));
  assert.equal(calls, 1);
  await assert.rejects(createGoogleTokenVerifier({ audience, client: null })('TEST_GOOGLE_TOKEN'), { code: 'GOOGLE_AUTH_UNAVAILABLE' });
});
