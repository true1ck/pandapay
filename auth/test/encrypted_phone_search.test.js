const test = require('node:test');
const assert = require('node:assert/strict');

process.env.PHONE_LOOKUP_HMAC_KEY = 'test-phone-lookup-hmac-key-0123456789abcdef';
const {
  canonicalizePhone,
  phoneLookupHash,
  preparePhoneSearchParams,
  buildPhoneLookupWhereClause,
} = require('../src/utils/encryptedPhoneSearch');

test('phone lookup hashes canonicalize common India input formats', () => {
  assert.equal(canonicalizePhone('98765 43210'), '+919876543210');
  assert.equal(phoneLookupHash('98765-43210'), phoneLookupHash('+91 (98765) 43210'));
  assert.equal(preparePhoneSearchParams('+919876543210').length, 1);
  assert.match(preparePhoneSearchParams('+919876543210')[0], /^[a-f0-9]{64}$/);
  assert.equal(buildPhoneLookupWhereClause('$2'), '(phone_lookup_hash = $2)');
});

test('phone lookup refuses invalid input and weak/missing digest keys', () => {
  assert.throws(() => canonicalizePhone('1234'), /valid E.164/);
  const key = process.env.PHONE_LOOKUP_HMAC_KEY;
  try {
    process.env.PHONE_LOOKUP_HMAC_KEY = 'too-short';
    assert.throws(() => phoneLookupHash('+919876543210'), /at least 32 bytes/);
    delete process.env.PHONE_LOOKUP_HMAC_KEY;
    assert.throws(() => phoneLookupHash('+919876543210'), /at least 32 bytes/);
  } finally {
    process.env.PHONE_LOOKUP_HMAC_KEY = key;
  }
});
