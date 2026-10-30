const test = require('node:test');
const assert = require('node:assert/strict');
const { validateDecision } = require('../src/sms_decision');

const positive = {
  topic: 'upi_debit',
  shouldConsider: true,
  rejectionReason: 'none',
};

test('accepts a supported positive decision with no extracted facts', () => {
  assert.deepEqual(validateDecision(positive, []), { valid: true, errors: [] });
});

test('accepts an explicit negative decision only with a reason and no facts', () => {
  const decision = {
    topic: 'generic_promotional_spam',
    shouldConsider: false,
    rejectionReason: 'promotional_spam',
  };
  assert.equal(validateDecision(decision, []).valid, true);
  assert.equal(validateDecision(decision, [{ factType: 'promotion' }]).valid, false);
});

test('rejects malformed, unsupported, or internally inconsistent decisions', () => {
  assert.equal(validateDecision(null).valid, false);
  assert.equal(validateDecision({ ...positive, topic: 'unknown' }).valid, false);
  assert.equal(validateDecision({ ...positive, rejectionReason: 'non_financial' }).valid, false);
  assert.equal(validateDecision({ ...positive, unexpected: 'summary' }).valid, false);
  assert.equal(validateDecision({
    ...positive,
    shouldConsider: false,
    rejectionReason: 'none',
  }).valid, false);
});
