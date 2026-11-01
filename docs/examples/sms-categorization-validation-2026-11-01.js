'use strict';

// Documentation probe. Synthetic text only; no DB, network or live model call.
// Run from any directory: node docs/examples/sms-categorization-validation-2026-11-01.js
const { parseSmsAgainstPatterns } = require('../../api/src/sms_parser');
const { verifyModelFacts } = require('../../api/src/ai_fact_evidence');
const { assessFacts } = require('../../api/src/ai_fact_scoring');
const { validateFactSet } = require('../../api/src/sms_facts');

const message = {
  sender: 'VM-HDFCBK-S',
  body: 'INR 499.00 spent on HDFC Bank Credit Card XX1234 at SWIGGY on 01-11-2026. Available limit INR 45000.00.',
  occurredAt: '2026-11-01T07:00:00.000Z',
};
const base = {
  amountRole: 'posted', entryKind: 'spend', amountInr: 499,
  occurredAt: message.occurredAt, instrument: 'credit_card', last4: '1234',
  merchant: 'SWIGGY', category: 'dining', isComplete: true, confidence: 0.98,
};
const variants = [
  ['correct_charge', {}],
  ['limit_as_charge', { amountInr: 45000 }],
  ['different_category', { category: 'groceries' }],
].map(([variant, patch]) => {
  const fact = { factType: 'posted_movement', payload: { ...base, ...patch } };
  return {
    variant, fact,
    schema: validateFactSet([fact]),
    evidence: verifyModelFacts([fact], message),
    assessment: assessFacts([fact], message.body, message.occurredAt),
  };
});
process.stdout.write(JSON.stringify({
  auditDate: '2026-11-01',
  scope: 'Synthetic local code probe; no live AI response or production transaction.',
  message,
  parserWithoutConfiguredPatterns: parseSmsAgainstPatterns([], message),
  variants,
}, null, 2) + '\n');
