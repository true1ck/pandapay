const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const crypto = require('node:crypto');

// Keep this contract test independent of a developer's root .env. The token
// service only opens a DB connection when refresh-token helpers are called;
// signing an access token is completely local.
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/unused';
process.env.NODE_ENV = 'test';
process.env.JWT_ACCESS_SECRET = 'test-access-secret';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret';
const legacyPhoneKey = crypto.randomBytes(32);
const versionedPhoneKey = crypto.randomBytes(32);
process.env.ENCRYPTION_ENABLED = 'true';
process.env.ENCRYPTION_KEY = legacyPhoneKey.toString('base64');
process.env.ENCRYPTION_READ_KEYS_JSON = JSON.stringify([['test_v2', versionedPhoneKey.toString('base64')]]);
delete process.env.ENCRYPTION_V2_WRITES_ENABLED;
delete process.env.JWT_ISSUER;
delete process.env.JWT_AUDIENCE;
delete process.env.JWT_KEYS_JSON;
delete process.env.JWT_ACTIVE_KEY_ID;

const { signAccessToken } = require('../src/services/tokenService');
const { validateTokenClaims } = require('../src/services/jwtKeys');
const { encryptPhoneNumber } = require('../src/utils/fieldEncryption');

function makeV2Phone(phone) {
  const keyId = 'test_v2';
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', versionedPhoneKey, iv);
  cipher.setAAD(Buffer.concat([
    Buffer.from('pandapay-field-encryption-v2\0', 'utf8'), Buffer.from(keyId, 'utf8'),
  ]));
  const ciphertext = Buffer.concat([cipher.update(phone, 'utf8'), cipher.final()]);
  return ['v2', keyId, iv, cipher.getAuthTag(), ciphertext]
    .map((part, index) => index < 2 ? part : part.toString('base64')).join(':');
}

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
  assert.equal(payload.phone_number, null);
  assert.equal(jwt.decode(token, { complete: true }).header.kid, '1');
});

test('access-token phone claim stays canonical plaintext for legacy, v2, and formatted legacy phone storage', () => {
  const legacy = encryptPhoneNumber('+919876543210');
  const versioned = makeV2Phone('+918765432109');
  const cases = [
    [legacy, '+919876543210'],
    [versioned, '+918765432109'],
    ['+91 (98765) 43210', '+919876543210'],
  ];
  for (const [storedPhone, expected] of cases) {
    const token = signAccessToken({ id: 'user-1', phone_number: storedPhone, role: 'user', token_version: 1 });
    const payload = jwt.decode(token);
    assert.equal(payload.phone_number, expected);
    assert.doesNotMatch(payload.phone_number, /^v2:/);
  }
});

test('damaged or unreadable stored phone fails token issuance without falling back to ciphertext', () => {
  const legacy = encryptPhoneNumber('+919876543210');
  const parts = legacy.split(':');
  parts[1] = Buffer.alloc(16).toString('base64');
  for (const phone_number of [parts.join(':'), makeV2Phone('+918765432109').replace('test_v2', 'unknown')]) {
    assert.throws(() => signAccessToken({ id: 'user-1', phone_number, role: 'user', token_version: 1 }),
      error => error.code === 'FIELD_ENCRYPTION_ERROR');
  }
  const wrongLegacyKey = crypto.randomBytes(32);
  const iv = crypto.randomBytes(12);
  const wrongCipher = crypto.createCipheriv('aes-256-gcm', wrongLegacyKey, iv);
  const bytes = Buffer.concat([wrongCipher.update('+919876543210', 'utf8'), wrongCipher.final()]);
  const wrongKeyStored = [iv, wrongCipher.getAuthTag(), bytes].map(value => value.toString('base64')).join(':');
  assert.throws(() => signAccessToken({ id: 'user-1', phone_number: wrongKeyStored, role: 'user', token_version: 1 }),
    error => error.code === 'FIELD_ENCRYPTION_ERROR');
});

test('protected auth routes reject tokens without the shared claims', () => {
  assert.deepEqual(validateTokenClaims({}), {
    valid: false,
    reason: 'missing_or_invalid_issuer',
  });
});
