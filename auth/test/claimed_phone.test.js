const test = require('node:test');
const assert = require('node:assert/strict');
const { parseClaimedPhone, canonicalizeClaimedPhone, parseAllowedCountries } = require('../src/utils/claimedPhone');
const { phoneGateRequired } = require('../src/utils/phoneGate');

test('every way of writing the same Indian mobile number gives one canonical form', () => {
  const same = [
    '9876543210', '98765 43210', '98765-43210', '(98765) 43210', '09876543210',
    '919876543210', '+919876543210', '+91 98765 43210', '+91-98765-43210', '+91 (98765) 43210',
    '0091 98765 43210', '  +91 9876543210  ',
  ];
  for (const value of same) assert.equal(canonicalizeClaimedPhone(value), '+919876543210', value);
});

test('only Indian mobile numbers are accepted, starting 6 to 9', () => {
  for (const value of ['5876543210', '1234567890', '0123456789', '987654321', '98765432100', '+91 5876543210']) {
    assert.equal(canonicalizeClaimedPhone(value), null, value);
  }
  for (const value of ['6000000001', '7000000001', '8000000001', '9000000001']) {
    assert.equal(canonicalizeClaimedPhone(value), `+91${value}`, value);
  }
});

test('obviously made-up numbers and non-numbers are refused', () => {
  for (const value of ['9999999999', '6666666666', 'abcdefghij', '98765abcde', '', '   ', '+', '++919876543210', '9876543210; DROP', null, undefined, 9876543210, {}, []]) {
    assert.equal(canonicalizeClaimedPhone(value), null, String(value));
  }
  assert.equal(canonicalizeClaimedPhone('9'.repeat(40)), null);
});

test('a number from a country that is not allowed says so', () => {
  assert.deepEqual(parseClaimedPhone('+44 7911 123456'), { ok: false, reason: 'unsupported_country' });
  assert.deepEqual(parseClaimedPhone('+1 415 555 2671'), { ok: false, reason: 'unsupported_country' });
  assert.deepEqual(parseClaimedPhone('abc'), { ok: false, reason: 'invalid' });
  assert.deepEqual(parseClaimedPhone('+91 12345'), { ok: false, reason: 'invalid' });
});

test('the allowed country list is read from configuration and rejects unknown countries', () => {
  assert.deepEqual(parseAllowedCountries(undefined), ['IN']);
  assert.deepEqual(parseAllowedCountries(''), ['IN']);
  assert.deepEqual(parseAllowedCountries('in, IN'), ['IN']);
  assert.throws(() => parseAllowedCountries('IN,GB'), /unsupported country: GB/);
});

test('the phone lock switch is off by default and only accepts true or false', () => {
  assert.equal(phoneGateRequired({}), false);
  assert.equal(phoneGateRequired({ REQUIRE_PHONE_AT_SIGNUP: '' }), false);
  assert.equal(phoneGateRequired({ REQUIRE_PHONE_AT_SIGNUP: 'false' }), false);
  assert.equal(phoneGateRequired({ REQUIRE_PHONE_AT_SIGNUP: 'true' }), true);
  assert.throws(() => phoneGateRequired({ REQUIRE_PHONE_AT_SIGNUP: 'yes' }), /must be true or false/);
});
