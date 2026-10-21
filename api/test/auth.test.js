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
process.env.AUTH_INTERNAL_BASE_URL = 'http://auth.test';
process.env.AUTH_INTERNAL_SERVICE_SECRET = 'test-auth-internal-secret-which-is-over-32-bytes';

const { verifyAccessToken, optionalAuth, requireAuth, requireValidJwt } = require('../src/auth');

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

test('optionalAuth retains the locally verified token for authoritative checks', () => {
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
  assert.equal(req.accessToken, req.headers.authorization.slice(7));
  assert.equal(req.authClaims.sub, 'user-123');
});

test('invalid tokens stay anonymous on public middleware', () => {
  const req = { headers: { authorization: 'Bearer not-a-jwt' } };
  let nextCalls = 0;
  optionalAuth(req, {}, () => { nextCalls += 1; });
  assert.equal(nextCalls, 1);
  assert.equal(req.userId, null);
  assert.equal(req.accessToken, null);
});

test('requireAuth fails closed for a request without an authenticated token', async () => {
  let statusCode;
  let responseBody;
  let nextCalls = 0;
  const response = {
    status(code) { statusCode = code; return this; },
    json(body) { responseBody = body; return this; },
  };
  await requireAuth({ userId: null, accessToken: null }, response, () => { nextCalls += 1; });
  assert.equal(statusCode, 401);
  assert.deepEqual(responseBody, { error: 'session_invalid' });
  assert.equal(nextCalls, 0);
});

test('requireValidJwt admits request with valid signed JWT without session check', () => {
  const token = makeToken('current-access-secret', 'current', { sub: 'production-smoke-test' });
  const req = { headers: { authorization: 'Bearer ' + token } };
  let nextCalls = 0;
  requireValidJwt(req, {}, () => { nextCalls += 1; });
  assert.equal(nextCalls, 1);
  assert.equal(req.userId, 'production-smoke-test');
  assert.equal(req.authClaims.sub, 'production-smoke-test');
});

test('requireValidJwt rejects request with missing or malformed token', () => {
  let statusCode;
  let responseBody;
  let nextCalls = 0;
  const res = {
    status(code) { statusCode = code; return this; },
    json(body) { responseBody = body; return this; },
  };
  requireValidJwt({ headers: {} }, res, () => { nextCalls += 1; });
  assert.equal(statusCode, 401);
  assert.deepEqual(responseBody, { error: 'Missing or invalid access token' });
  assert.equal(nextCalls, 0);

  requireValidJwt({ headers: { authorization: 'Bearer invalid-jwt' } }, res, () => { nextCalls += 1; });
  assert.equal(statusCode, 401);
  assert.deepEqual(responseBody, { error: 'Missing or invalid access token' });
  assert.equal(nextCalls, 0);
});
