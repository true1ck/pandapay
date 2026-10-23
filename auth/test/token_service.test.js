const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

// Keep this contract test independent of a developer's root .env. The token
// service only opens a DB connection when refresh-token helpers are called;
// signing an access token is completely local.
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/unused';
process.env.NODE_ENV = 'test';
process.env.JWT_ACCESS_SECRET = 'test-access-secret';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret';
delete process.env.JWT_ISSUER;
delete process.env.JWT_AUDIENCE;
delete process.env.JWT_KEYS_JSON;
delete process.env.JWT_ACTIVE_KEY_ID;

const { signAccessToken } = require('../src/services/tokenService');
const { validateTokenClaims } = require('../src/services/jwtKeys');

test('new access tokens satisfy the protected-route claim contract', () => {
  const emitted = [];
  const originalLog = console.log;
  console.log = (...args) => emitted.push(args.join(' '));
  let token;
  try {
    token = signAccessToken({
      id: '0f5a6e46-5a88-41f0-a3a0-6de00688cc17',
      phone_number: null,
      role: 'user',
      token_version: 1,
    });
  } finally {
    console.log = originalLog;
  }
  assert.deepEqual(emitted, [], 'token minting must not log user or token details');

  const payload = jwt.verify(token, process.env.JWT_ACCESS_SECRET, {
    issuer: 'pandapay-auth',
    audience: 'mobile-app',
  });

  assert.equal(payload.sub, '0f5a6e46-5a88-41f0-a3a0-6de00688cc17');
  assert.equal(payload.aud, 'mobile-app');
  assert.equal(payload.iss, 'pandapay-auth');
  assert.equal(jwt.decode(token, { complete: true }).header.kid, '1');
});

test('protected auth routes reject tokens without the shared claims', () => {
  assert.deepEqual(validateTokenClaims({}), {
    valid: false,
    reason: 'missing_or_invalid_issuer',
  });
});
