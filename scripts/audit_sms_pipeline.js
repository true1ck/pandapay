'use strict';

// Read-only synthetic diagnostic. Makes no network requests or database writes.
// It records fixed regressions and remaining gaps; it is not an acceptance
// suite for the desired product behavior.
const assert = require('node:assert/strict');
const { importSourceKey } = require('../api/src/import_source_key');
const { inferBuiltinCategory } = require('../api/src/merchant_category');
const facts = require('../api/src/sms_facts');
const { redactBodyForAi, completeJobWithResult } = require('../api/src/gemini_queue');
const {
  verifyModelFacts,
  normalizeModelFacts,
  validateNegativeDecisionEvidence,
} = require('../api/src/ai_fact_evidence');
const { assessFacts } = require('../api/src/ai_fact_scoring');
const { validateDecision } = require('../api/src/sms_decision');
const { parseSmsAgainstPatterns } = require('../api/src/sms_parser');
const { extractFactsFromObservation } = require('../api/src/sms_observation_migration');
const { buildProjectionDecisions } = require('../api/src/central_financial_projection');
const { ruleApplies } = require('../api/src/reward_math');

const at = '2026-11-01T09:00:00Z';
const unicodePayee = String.fromCodePoint(
  0x092c, 0x093e, 0x0932, 0x093e, 0x091c, 0x0940, 0x0020,
  0x0938, 0x094d, 0x092a, 0x094b, 0x0930, 0x094d, 0x091f, 0x094d, 0x0938,
);
const body = 'Rs.200.00 spent on HDFC Swiggy Credit Card xx1234 at BALAJI SPORTS on 01-11-26. Avl Bal Rs.5000.00';
const result = [];
function record(id, observed) { result.push({ id, observed }); }
function movement(patch = {}) {
  return { factType: 'posted_movement', payload: {
    amountRole: 'posted', entryKind: 'spend', amountInr: 200,
    occurredAt: at, instrument: 'credit_card', last4: '1234',
    merchant: 'BALAJI SPORTS', category: 'other', isComplete: true,
    confidence: 0.99, ...patch,
  } };
}

async function run() {
  const text = 'Rs 200 debited to LOCAL SHOP via UPI.';
  const sameKey = importSourceKey('audit', 'VM-HDFCBK', text, '2026-11-01') ===
    importSourceKey('audit', 'VM-HDFCBK', text, '2026-11-02');
  assert.equal(sameKey, true);
  record('identity_identical_text_different_days', { sameKey });

  const collisions = ['KUBER HARDWARE', 'SPARK ELECTRICALS', 'SHELLY BOOK STORE']
    .map(name => ({ name, match: inferBuiltinCategory(name) }));
  assert.deepEqual(collisions.map(x => x.match?.slug || null), [null, null, null]);
  record('category_substring_collisions_fixed', collisions);

  const wrongRole = movement({ merchant: 'Swiggy', category: 'dining' });
  assert.equal(verifyModelFacts([wrongRole], { body, occurredAt: at }).valid, true);
  const roleAssessment = assessFacts([wrongRole], body, at);
  assert.equal(roleAssessment.reviewRequired, true);
  record('ai_wrong_entity_role_gated', { score: roleAssessment.composite, reviewRequired: roleAssessment.reviewRequired, reasons: roleAssessment.semanticReviewReasons });

  const wrongCategory = movement({ category: 'travel' });
  const categoryAssessment = assessFacts([wrongCategory], body, at);
  assert.equal(categoryAssessment.composite, roleAssessment.composite);
  assert.equal(categoryAssessment.reviewRequired, true);
  record('ai_category_requires_semantic_review', { score: categoryAssessment.composite, reviewRequired: categoryAssessment.reviewRequired, reasons: categoryAssessment.semanticReviewReasons });

  const incomplete = movement({ merchant: 'Swiggy', category: 'travel' });
  delete incomplete.payload.confidence;
  delete incomplete.payload.isComplete;
  const normalized = normalizeModelFacts([incomplete], { body, occurredAt: at });
  assert.equal(normalized[0].payload.confidence, 0.9);
  const normalizedAssessment = assessFacts(normalized, body, at);
  assert.equal(normalizedAssessment.reviewRequired, true);
  record('normalizer_confidence_does_not_bypass_review', { assignedConfidence: normalized[0].payload.confidence, score: normalizedAssessment.composite, reviewRequired: normalizedAssessment.reviewRequired });

  const redacted = redactBodyForAi('Rs 200 debited to balajisports@upi via UPI.');
  assert.equal(redacted.includes('balajisports'), false);
  record('redaction_removes_only_payee', { redacted });

  const unicodeBody = `Rs.200 debited from A/c XX1234 to ${unicodePayee} via UPI on 01-11-26.`;
  const unicode = parseSmsAgainstPatterns([], { sender: 'VM-HDFCBK-S', body: unicodeBody });
  assert.equal(unicode.ok, true);
  assert.equal(unicode.fields.merchant, unicodePayee);
  record('unicode_payee_retained_after_successful_parse', unicode);

  const missingCategories = ['sports', 'fitness', 'pets', 'personal_care', 'shopping', 'investments']
    .map(category => ({ category, valid: facts.validateFact(movement({ category })).valid }));
  assert.ok(missingCategories.every(x => !x.valid));
  record('category_contract_rejects_new_categories', missingCategories);

  const negativeDecision = { topic: 'generic_promotional_spam', shouldConsider: false, rejectionReason: 'promotional_spam' };
  const dismissed = validateDecision(negativeDecision, []);
  assert.equal(dismissed.valid, true);
  const dismissalEvidence = validateNegativeDecisionEvidence(negativeDecision, '');
  assert.equal(dismissalEvidence.valid, false);
  record('negative_decision_requires_source_semantics', dismissalEvidence);

  const investmentFacts = extractFactsFromObservation({ occurredAt: at, parsed: {
    amountInr: 500, entryKind: 'investment', merchant: 'BROKER', instrument: 'upi_bank',
  } });
  const mandateFacts = extractFactsFromObservation({ occurredAt: at, parsed: {
    mandateStatus: 'registered', merchant: 'SERVICE', instrument: 'upi_bank',
  } });
  assert.equal(investmentFacts.length, 1);
  assert.equal(mandateFacts.length, 1);
  record('migration_preserves_supported_fact_shapes', { investmentFacts, mandateWithoutCeilingFacts: mandateFacts });

  const balances = ['BANK A', 'BANK B'].map((issuerName, factIndex) => ({
    id: `audit-fact-${factIndex}`, factIndex, factType: 'balance_snapshot',
    payload: { availableBalanceInr: 1000 + factIndex * 9000, issuerName,
      accountLast4: '1234', instrument: 'upi_bank', asOfAt: at },
    provenance: { channel: 'sms' },
  }));
  const projections = buildProjectionDecisions({ facts: balances, sourceId: 'audit-source' });
  assert.notEqual(projections[0].projectionKey, projections[1].projectionKey);
  record('projection_same_suffix_cross_issuer_separated', projections.map(x => ({ key: x.projectionKey, balance: x.data.availableBalanceInr })));

  const rewardMatch = ruleApplies({ category_id: 'legacy-online' }, {
    categoryId: 'new-sports', amount: 200, merchantName: 'BALAJI SPORTS', rail: 'unknown',
  });
  assert.equal(rewardMatch, false);
  record('new_categories_do_not_inherit_old_reward_rules', { rewardMatch });

  const oldLoad = facts.loadSmsSourceFacts;
  const oldUpsert = facts.upsertSmsSourceFacts;
  let inserted = 0;
  try {
    facts.loadSmsSourceFacts = async () => ({ facts: [{ ...movement(), factIndex: 0, provenance: { channel: 'sms' } }] });
    facts.upsertSmsSourceFacts = async (_client, _profile, input) => { inserted += input.facts.length; return { factIds: [] }; };
    const client = { query: async () => ({ rows: [], rowCount: 1 }) };
    const proposed = movement({ amountInr: 300, merchant: 'REAL SHOP' });
    const completion = await completeJobWithResult(client, {
      job: { id: 'audit-job', profile_id: 'audit-profile', source_key: 'a'.repeat(64),
        payload: { body: 'Rs.300 spent on credit card xx1234 at REAL SHOP on 01-11-26.', occurredAt: at } },
      facts: [proposed],
    });
    assert.equal(inserted, 0);
    assert.equal(completion.reviewRequired, true);
    record('existing_fact_conflict_skipped_with_review', { inserted, landed: completion.landed, reviewRequired: completion.reviewRequired, score: completion.confidenceScore, conflicts: completion.conflicts });
  } finally {
    facts.loadSmsSourceFacts = oldLoad;
    facts.upsertSmsSourceFacts = oldUpsert;
  }
  console.log(JSON.stringify({ diagnostic: 'Current SMS pipeline gap reproductions; no live provider or database used', count: result.length, findings: result }, null, 2));
}

run().catch(error => { console.error(error.message); process.exitCode = 1; });
