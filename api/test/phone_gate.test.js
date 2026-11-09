'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'test';
process.env.API_DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'legacy-access-secret';
process.env.JWT_KEYS_JSON = JSON.stringify({ current: 'current-access-secret' });
process.env.JWT_ACTIVE_KEY_ID = 'current';
process.env.JWT_ISSUER = 'pandapay-auth';
process.env.JWT_AUDIENCE = 'mobile-app';
process.env.AUTH_INTERNAL_BASE_URL = 'http://auth.test';
process.env.AUTH_INTERNAL_SERVICE_SECRET = 'test-auth-internal-secret-which-is-over-32-bytes';
process.env.REFERRAL_IDENTITY_HMAC_KEY = 'test-referral-identity-hmac-key-over-32-bytes';
process.env.REFERRAL_IDENTITY_HMAC_KEY_VERSION = 'test-v3';

const { fetchCurrentSession, requirePhoneIfLocked, SessionVerificationError, _sessionCache } = require('../src/auth');
const { buildEligibilityClaims } = require('../src/referral_routes');

function authReply(extra = {}) {
  return {
    ok: true,
    async json() {
      return {
        token_valid: true, valid: true, subject: 'user-1', session: { active: true, revoked: false },
        verified_contacts: { email: { verified: true, value: 'person@example.com' }, phone: { verified: false, value: null } },
        ...extra,
      };
    },
  };
}

async function session(extra) {
  _sessionCache.clear();
  return fetchCurrentSession(`synthetic-token-${Math.random()}`, async () => authReply(extra));
}

test('the session carries the typed phone apart from verified contacts, and the gate state', async () => {
  const s = await session({
    claimed_contacts: { phone: { claimed: true, value: '+919876543210' } },
    phone_gate: { required: true, satisfied: true },
  });
  assert.deepEqual(s.claimedContacts, { phone: { claimed: true, value: '+919876543210' } });
  assert.deepEqual(s.phoneGate, { required: true, satisfied: true });
  assert.equal(s.verifiedContacts.phone.verified, false, 'a typed phone is never a verified contact');
});

test('an auth service that sends nothing about the phone means the lock is not required', async () => {
  const s = await session();
  assert.deepEqual(s.claimedContacts, { phone: { claimed: false, value: null } });
  assert.deepEqual(s.phoneGate, { required: false, satisfied: false });
  assert.doesNotThrow(() => requirePhoneIfLocked(s));
});

test('malformed phone fields are ignored rather than trusted', async () => {
  const s = await session({ claimed_contacts: { phone: { claimed: 'yes', value: 5 } }, phone_gate: { required: 'true', satisfied: 1 } });
  assert.deepEqual(s.claimedContacts, { phone: { claimed: false, value: null } });
  assert.deepEqual(s.phoneGate, { required: false, satisfied: false });
});

test('with the lock on, an account without a phone gets 403 phone_required', () => {
  assert.throws(() => requirePhoneIfLocked({ phoneGate: { required: true, satisfied: false } }),
    error => error instanceof SessionVerificationError && error.code === 'phone_required' && error.status === 403);
  assert.doesNotThrow(() => requirePhoneIfLocked({ phoneGate: { required: true, satisfied: true } }));
  assert.doesNotThrow(() => requirePhoneIfLocked({ phoneGate: { required: false, satisfied: false } }));
  assert.doesNotThrow(() => requirePhoneIfLocked({}));
});

test('a typed phone gives the same reward fingerprint as the same number verified', () => {
  const verified = buildEligibilityClaims({
    email: { verified: true, value: 'person@example.com' },
    phone: { verified: true, value: '+919876543210' },
  });
  const typed = buildEligibilityClaims(
    { email: { verified: true, value: 'person@example.com' }, phone: { verified: false, value: null } },
    undefined, undefined,
    { phone: { claimed: true, value: '+919876543210' } },
  );
  assert.deepEqual(typed.map(c => c.kind), ['email', 'phone']);
  assert.deepEqual(typed, verified);
  assert.equal(JSON.stringify(typed).includes('9876543210'), false);
});

test('a verified phone wins over a typed one, and no phone at all gives an email-only claim', () => {
  const both = buildEligibilityClaims(
    { phone: { verified: true, value: '+919876543210' } }, undefined, undefined,
    { phone: { claimed: true, value: '+919123456780' } },
  );
  const verifiedOnly = buildEligibilityClaims({ phone: { verified: true, value: '+919876543210' } });
  assert.deepEqual(both, verifiedOnly);
  const none = buildEligibilityClaims({ email: { verified: true, value: 'person@example.com' } }, undefined, undefined,
    { phone: { claimed: false, value: null } });
  assert.deepEqual(none.map(c => c.kind), ['email']);
  assert.deepEqual(buildEligibilityClaims({}, undefined, undefined, { phone: { claimed: true, value: 12345 } }), []);
});
