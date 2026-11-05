'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const { signalError, createSignalsHandler } = require('../src/sms_v2/learning_signals');

const base = { kind: 'category_choice', senderBrand: 'HDFCBK', merchantKey: 'SWIGGY', value: 'dining', eventType: 'purchase', taxonomyVersion: 1 };

function fakeResponse() {
  return {
    statusCode: 200, headers: {}, body: null,
    status(code) { this.statusCode = code; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = body; return this; },
  };
}
function handler(overrides = {}) {
  const calls = { submit: [] };
  const store = overrides.store || { submit: async (...args) => { calls.submit.push(args); return args[1].length; } };
  const security = {
    verifyAttestation: async (req) => { req.smsV2Security = { sharedLearningEligible: req.verified !== false }; return true; },
    checkRate: async () => true,
    storedSettings: async () => ({}),
    ...(overrides.security || {}),
  };
  return { run: createSignalsHandler({ store, security }), calls };
}
const post = (run, items, extra = {}) => {
  const res = fakeResponse();
  return run({ body: { items }, userId: 'u1', headers: {}, ...extra }, res).then(() => res);
};

test('keys with four or more digits, an @, or lower case are refused', () => {
  assert.equal(signalError({ ...base, merchantKey: 'PAYTMQR2810050501' }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'SHOP 1234' }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'RAHUL@OKAXIS' }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'swiggy' }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'A'.repeat(61) }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: "SWIGGY'; DROP TABLE X;--" }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'SHOP\nNAME' }), 'signal_merchant_key_invalid');
  assert.equal(signalError({ ...base, merchantKey: 'SHOP 123' }), null, 'three digits are allowed');
  assert.equal(signalError(base), null);
});

test('a category must be a canonical spend category', () => {
  assert.equal(signalError({ ...base, value: 'my_custom_category' }), 'signal_category_invalid');
  assert.equal(signalError({ ...base, value: '' }), 'signal_category_invalid');
  assert.equal(signalError({ ...base, value: 'groceries' }), null);
});

test('a shop name has no digits and differs from its key', () => {
  const name = { ...base, kind: 'merchant_name', merchantKey: 'PAYU SWIGGY', value: 'SWIGGY' };
  assert.equal(signalError(name), null);
  assert.equal(signalError({ ...name, value: 'SWIGGY 2' }), 'signal_name_invalid');
  assert.equal(signalError({ ...name, value: 'PAYU SWIGGY' }), 'signal_name_invalid');
  assert.equal(signalError({ ...name, value: 'swiggy' }), 'signal_name_invalid');
  assert.equal(signalError({ ...name, value: 'A'.repeat(41) }), 'signal_name_invalid');
});

test('an uncategorised signal carries no value', () => {
  assert.equal(signalError({ ...base, kind: 'uncategorised', value: '' }), null);
  assert.equal(signalError({ ...base, kind: 'uncategorised', value: 'dining' }), 'signal_value_invalid');
});

test('the contract refuses other event types and more than 50 items', async () => {
  const { run, calls } = handler();
  assert.equal((await post(run, [{ ...base, eventType: 'income' }])).statusCode, 400);
  assert.equal((await post(run, [{ ...base, eventType: 'income' }])).body.error, 'request.learning_signals.event_type_invalid');
  assert.equal((await post(run, Array.from({ length: 51 }, () => base))).body.error, 'request.learning_signals.items_too_many');
  assert.equal((await post(run, [])).statusCode, 400);
  assert.equal((await post(run, [{ ...base, kind: 'unknown' }])).statusCode, 400);
  assert.equal(calls.submit.length, 0);
});

test('a bad item is refused before anything is stored', async () => {
  const { run, calls } = handler();
  const res = await post(run, [base, { ...base, merchantKey: 'PAYTMQR2810050501' }]);
  assert.equal(res.statusCode, 400);
  assert.equal(res.body.error, 'signal_merchant_key_invalid');
  assert.equal(calls.submit.length, 0);
});

test('an accepted batch is stored with the attestation result', async () => {
  const { run, calls } = handler();
  const res = await post(run, [base]);
  assert.equal(res.statusCode, 202);
  assert.deepEqual(res.body, { accepted: 1 });
  assert.equal(calls.submit[0][2], true);
  const unattested = await post(run, [base], { verified: false });
  assert.equal(unattested.statusCode, 202);
  assert.equal(calls.submit[1][2], false, 'stored with eligible = false');
});

test('missing consent, a spent daily cap and failures answer as documented', async () => {
  const failing = (code) => handler({ store: { submit: async () => { throw Object.assign(new Error('x'), { code }); } } }).run;
  const noConsent = await post(failing('42501'), [base]);
  assert.equal(noConsent.statusCode, 403);
  assert.equal(noConsent.body.error, 'sms_shared_learning_consent_required');
  const capped = await post(failing('P0050'), [base]);
  assert.equal(capped.statusCode, 429);
  assert.equal(capped.headers['Retry-After'], '86400');
  assert.equal((await post(failing('XX000'), [base])).statusCode, 503);
});

test('enforce mode refuses an unattested request, and the rate limit answers 429', async () => {
  const enforce = handler({ security: { verifyAttestation: async () => false } });
  const res = await post(enforce.run, [base]);
  assert.equal(res.statusCode, 403);
  assert.equal(res.body.error, 'attestation_required');
  const limited = handler({ security: { checkRate: async () => false } });
  assert.equal((await post(limited.run, [base])).statusCode, 429);
});

test('with intake paused the route answers 503 learning_paused with a one hour retry', async () => {
  const { run, calls } = handler({ security: { storedSettings: async () => ({ intake_enabled: false }) } });
  const res = await post(run, [base]);
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'learning_paused' });
  assert.equal(res.headers['Retry-After'], '3600');
  assert.equal(calls.submit.length, 0);
});
