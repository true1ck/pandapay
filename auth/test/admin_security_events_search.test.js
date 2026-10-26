'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

process.env.NODE_ENV = 'test';
process.env.DATABASE_URL = 'postgres://unused:unused@localhost:5432/unused';
process.env.JWT_ACCESS_SECRET = 'test-access-secret';
process.env.JWT_REFRESH_SECRET = 'test-refresh-secret';
process.env.PHONE_LOOKUP_HMAC_KEY = 'test-phone-lookup-hmac-key-0123456789abcdef';
const legacyKey = crypto.randomBytes(32);
const versionedKey = crypto.randomBytes(32);
process.env.ENCRYPTION_ENABLED = 'true';
process.env.ENCRYPTION_KEY = legacyKey.toString('base64');
process.env.ENCRYPTION_READ_KEYS_JSON = JSON.stringify([['admin_test_v2', versionedKey.toString('base64')]]);

const { createSecurityEventSearchFilter, maskStoredPhone, maskAuditPhoneText } = require('../src/routes/adminRoutes');
const { encryptPhoneNumber } = require('../src/utils/fieldEncryption');
const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');

function makeV2(phone) {
  const keyId = 'admin_test_v2';
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', versionedKey, iv);
  cipher.setAAD(Buffer.concat([
    Buffer.from('pandapay-field-encryption-v2\0', 'utf8'), Buffer.from(keyId, 'utf8'),
  ]));
  const ciphertext = Buffer.concat([cipher.update(phone, 'utf8'), cipher.final()]);
  return ['v2', keyId, iv, cipher.getAuthTag(), ciphertext]
    .map((part, index) => index < 2 ? part : part.toString('base64')).join(':');
}

test('admin phone display decrypts legacy and v2 storage and masks every digit except the last four', () => {
  assert.equal(maskStoredPhone(encryptPhoneNumber('+919876543210')), '+********3210');
  assert.equal(maskStoredPhone(makeV2('+919876543210')), '+********3210');
  assert.equal(maskStoredPhone(null), null);
});

test('admin phone display omits damaged or unknown-key ciphertext instead of returning it', () => {
  const legacy = encryptPhoneNumber('+919876543210').split(':');
  legacy[1] = Buffer.alloc(16).toString('base64');
  const unknown = makeV2('+919876543210').replace('admin_test_v2', 'unknown_key');
  for (const value of [legacy.join(':'), unknown, 'not-a-phone']) {
    assert.equal(maskStoredPhone(value), null);
  }
});

test('partial text search retains email/name/id behavior without querying ciphertext', () => {
  const filter = createSecurityEventSearchFilter('alice@example.test', 3);
  assert.match(filter.sql, /aa\.user_id::text ILIKE \$3/);
  assert.match(filter.sql, /u\.email ILIKE \$3/);
  assert.match(filter.sql, /u\.name ILIKE \$3/);
  assert.doesNotMatch(filter.sql, /phone_number|phone_lookup_hash/);
  assert.deepEqual(filter.values, ['%alice@example.test%']);
});

test('canonical phone search uses only exact HMAC lookup and never ciphertext ILIKE', () => {
  const filter = createSecurityEventSearchFilter('+91 (98765) 43210', 4);
  assert.equal(filter.sql, ' AND u.phone_lookup_hash = $4');
  assert.deepEqual(filter.values, [phoneLookupHash('+919876543210')]);
  assert.doesNotMatch(filter.sql, /ILIKE|phone_number/);
});

test('numeric phone fragments do not search audit metadata or stored ciphertext', () => {
  const filter = createSecurityEventSearchFilter('9876', 1);
  assert.match(filter.sql, /aa\.user_id::text ILIKE \$1/);
  assert.doesNotMatch(filter.sql, /aa\.meta::text|phone_number|phone_lookup_hash/);
  assert.deepEqual(filter.values, ['%9876%']);
  assert.equal(maskAuditPhoneText('+919876543210'), '+********3210');
  assert.equal(maskAuditPhoneText('opaque:encrypted:metadata'), null);
});
