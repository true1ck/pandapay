const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'legacy-access-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({
  current: 'current-access-secret',
  previous: 'previous-access-secret',
});
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';

const authMiddleware = require('../src/middleware/authMiddleware');

test('auth middleware rejects unknown key ids without trying configured keys', async () => {
  const token = jwt.sign(
    { sub: 'user-123' },
    'current-access-secret',
    {
      keyid: 'not-configured',
      issuer: 'pandapay-auth',
      audience: 'mobile-app',
      expiresIn: '5m',
    },
  );
  const response = {
    statusCode: null,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };

  await authMiddleware({ headers: { authorization: `Bearer ${token}` } }, response, () => {
    assert.fail('middleware must reject an unknown key id');
  });

  assert.equal(response.statusCode, 401);
  assert.deepEqual(response.body, { error: 'Invalid or expired token' });
});
