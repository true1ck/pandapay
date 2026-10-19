'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { TEST_OTP_CODE, isTestOtpEnabled, isTestOtpIdentifier } = require('../src/utils/testOtp');

test('test OTP requires explicit opt-in and is always disabled in production', () => {
  assert.equal(isTestOtpEnabled({ NODE_ENV: 'development' }), false);
  assert.equal(isTestOtpEnabled({ NODE_ENV: 'development', ALLOW_TEST_OTP: 'true' }), true);
  assert.equal(isTestOtpEnabled({ NODE_ENV: 'production', ALLOW_TEST_OTP: 'true' }), false);
});

test('test OTP bypass is limited to the explicit identifier allowlist', () => {
  const env = { NODE_ENV: 'development', ALLOW_TEST_OTP: 'true' };
  assert.equal(isTestOtpIdentifier('+911234567890', env), true);
  assert.equal(isTestOtpIdentifier(' +911234567890 ', env), true);
  assert.equal(isTestOtpIdentifier('+919876543210', env), false);
  assert.equal(isTestOtpIdentifier('+911234567890', { NODE_ENV: 'production', ALLOW_TEST_OTP: 'true' }), false);
  assert.equal(TEST_OTP_CODE, '1234');
});
