'use strict';

const TEST_IDENTIFIERS = new Set([
  '1234567890',
  '+911234567890',
  'test@example.com',
  'newuser4@example.com',
]);
const TEST_OTP_CODE = '1234';

function isTestOtpEnabled(env = process.env) {
  return env.NODE_ENV !== 'production' && env.ALLOW_TEST_OTP === 'true';
}

function isTestOtpIdentifier(identifier, env = process.env) {
  return isTestOtpEnabled(env)
    && TEST_IDENTIFIERS.has(String(identifier || '').trim().toLowerCase());
}

module.exports = { TEST_OTP_CODE, isTestOtpEnabled, isTestOtpIdentifier };
