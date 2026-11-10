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

// PHONE_GATE_NEW_ACCOUNTS_FROM (an ISO date or time) narrows the lock to accounts created on or
// after that moment, so turning it on never locks out people who signed up before. Empty means
// the lock applies to every account, as before. An account whose age is unknown is not locked.
function phoneGateRequiredFor(createdAt, env = process.env) {
  if (!phoneGateRequired(env)) return false;
  const from = env.PHONE_GATE_NEW_ACCOUNTS_FROM;
  if (from === undefined || from === '') return true;
  const cutoff = Date.parse(from);
  if (Number.isNaN(cutoff)) throw new Error('PHONE_GATE_NEW_ACCOUNTS_FROM must be an ISO date');
  const created = createdAt ? new Date(createdAt).getTime() : NaN;
  return Number.isNaN(created) ? false : created >= cutoff;
}

module.exports = { phoneGateRequired, phoneGateRequiredFor };
