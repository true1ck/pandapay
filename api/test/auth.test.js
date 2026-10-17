const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

// Exercise the same rotation-shaped configuration used by production. The
// API must accept both the active and previous access keys during a rotation,
// but must reject a token signed with the wrong issuer or audience.
process.env.NODE_ENV = 'test';
process.env.API_DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'legacy-access-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({
  current: 'current-access-secret',
  previous: 'previous-access-secret',
});
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';

const { verifyAccessToken, optionalAuth, requireAuth } = require('../src/auth');

function makeToken(secret, keyid, claims = {}) {
  return jwt.sign(
    {
      sub: 'user-123',
      role: 'authenticated',
      ...claims,
    },
    secret,
    {
      keyid,
      issuer: 'pandapay-auth',
      audience: 'mobile-app',
      expiresIn: '5m',
    },
  );
}

test('API accepts active and previous access keys with the shared claims', () => {
  const active = verifyAccessToken(
    makeToken('current-access-secret', 'current'),
  );
  const previous = verifyAccessToken(
    makeToken('previous-access-secret', 'previous'),
  );

  assert.equal(active.sub, 'user-123');
  assert.equal(previous.sub, 'user-123');
});

test('API rejects a token with a wrong issuer or audience', () => {
  const wrongIssuer = jwt.sign(
    { sub: 'user-123' },
    'current-access-secret',
    { keyid: 'current', issuer: 'wrong-issuer', audience: 'mobile-app' },
  );
  const wrongAudience = jwt.sign(
    { sub: 'user-123' },
    'current-access-secret',
    { keyid: 'current', issuer: 'pandapay-auth', audience: 'wrong-audience' },
  );

  assert.throws(() => verifyAccessToken(wrongIssuer));
  assert.throws(() => verifyAccessToken(wrongAudience));
});

test('API rejects an unknown key id instead of trying every configured key', () => {
  const unknownKeyId = makeToken('current-access-secret', 'not-configured');
  assert.throws(() => verifyAccessToken(unknownKeyId), /Unknown access token key id/);
});

test('optionalAuth and requireAuth share the same verification result', () => {
  const req = {
    headers: {
      authorization: `Bearer ${makeToken('current-access-secret', 'current')}`,
    },
  };
  let nextCalls = 0;

  optionalAuth(req, {}, () => {
    nextCalls += 1;
  });

  assert.equal(nextCalls, 1);
  assert.equal(req.userId, 'user-123');
  assert.doesNotThrow(() => requireAuth(req, { status: () => {} }, () => {}));
});
