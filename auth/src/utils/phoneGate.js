'use strict';

// REQUIRE_PHONE_AT_SIGNUP switches the phone lock on. Off (the default) means
// nothing changes for anyone. On means an account without a phone number can
// do nothing except add one. Kept apart from config.js so session checks and
// tests can read it without loading every required secret.
function phoneGateRequired(env = process.env) {
  const value = env.REQUIRE_PHONE_AT_SIGNUP;
  if (value === undefined || value === '') return false;
  if (value !== 'true' && value !== 'false') throw new Error('REQUIRE_PHONE_AT_SIGNUP must be true or false');
  return value === 'true';
}

module.exports = { phoneGateRequired };
