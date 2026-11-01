'use strict';

/**
 * Synthetic, read-only SMS pipeline conformance diagnostics.
 *
 * This module deliberately does not change classifier behavior. It runs the
 * real server-side boundaries against a checked-in privacy-safe fixture and
 * returns structured records for six tracked cases. Each case stays explicit
 * about whether its current guard is resolved or still needs a contract
 * change.
 */

const fs = require('node:fs');
const path = require('node:path');

const fixturePath = path.join(__dirname, '..', 'app', 'test', 'fixtures', 'sms_pipeline_conformance.json');
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));

const { importSourceKey } = require('../api/src/import_source_key');
const { inferBuiltinCategory } = require('../api/src/merchant_category');
const { parseSmsAgainstPatterns } = require('../api/src/sms_parser');
const { redactBodyForAi, completeJobWithResult } = require('../api/src/gemini_queue');
const { verifyModelFacts } = require('../api/src/ai_fact_evidence');
const { assessFacts } = require('../api/src/ai_fact_scoring');
const { validateDecision } = require('../api/src/sms_decision');
const smsFacts = require('../api/src/sms_facts');

function finding(id, reasonCode, observed, status = 'gap') {
  return { id, status, reasonCode, observed };
}

function fixtureCase(id) {
  const item = fixture.cases.find((candidate) => candidate.id === id);
  if (!item) throw new Error(`missing conformance fixture: ${id}`);
  return item;
}

function diagnoseMerchantRole() {
  const item = fixtureCase('merchant_role_confusion');
  const verification = verifyModelFacts([item.candidateFact], {
    body: item.body,
    occurredAt: item.candidateFact.payload.occurredAt,
  });
  const assessment = assessFacts(
    [item.candidateFact],
    item.body,
    item.candidateFact.payload.occurredAt,
  );
  const parser = parseSmsAgainstPatterns([], { sender: item.sender, body: item.body });
  const candidateMerchantMatchesCardProduct = item.body.toLowerCase().includes('swiggy');
  const candidateMerchantMatchesPayee = item.body.toLowerCase().includes(
    item.expected.merchant.toLowerCase(),
  );

  const roleGuarded = verification.valid &&
    assessment.reviewRequired === item.expected.requiresReview &&
    assessment.semanticReviewRequired === true;
  return finding(item.id, 'model_merchant_not_payee_role', {
    parserOk: parser.ok,
    parserMerchant: parser.fields?.merchant || null,
    candidateMerchantMatchesCardProduct,
    candidateMerchantMatchesPayee,
    modelFactsValid: verification.valid,
    reviewRequired: assessment.reviewRequired,
    semanticReviewRequired: assessment.semanticReviewRequired,
    semanticReviewReasons: assessment.semanticReviewReasons,
    compositeScore: assessment.composite,
  }, roleGuarded ? 'resolved' : 'gap');
}

function diagnoseCategoryDrift() {
  const item = fixtureCase('category_drift_substring');
  const variants = item.variants.map((variant) => {
    const result = inferBuiltinCategory(variant.merchant);
    return {
      expectedCategory: variant.expectedCategory,
      observedCategory: result?.slug || null,
      observedPattern: result?.pattern || null,
      mismatch: (result?.slug || null) !== variant.expectedCategory,
    };
  });
  const mismatchCount = variants.filter((variant) => variant.mismatch).length;
  return finding(item.id, 'substring_category_collision', {
    mismatchCount,
    variants,
  }, mismatchCount === 0 ? 'resolved' : 'gap');
}

function diagnoseUnicodeMerchant() {
  const item = fixtureCase('unicode_merchant_loss');
  const parser = parseSmsAgainstPatterns([], { sender: item.sender, body: item.body });
  const merchantPresent = Boolean(parser.fields?.merchant || parser.fields?.transferParty);
  return finding(item.id, 'unicode_payee_not_extracted', {
    parserOk: parser.ok,
    amountInr: parser.fields?.amountInr || null,
    entryKind: parser.fields?.entryKind || null,
    instrument: parser.fields?.instrument || null,
    merchantPresent,
  }, merchantPresent ? 'resolved' : 'gap');
}

function diagnoseDuplicateIdentity() {
  const item = fixtureCase('duplicate_identity_collision');
  const [first, second] = item.events;
  const firstKey = importSourceKey(fixture.namespace, item.sender, item.body, first.receivedAt);
  const secondKey = importSourceKey(fixture.namespace, item.sender, item.body, second.receivedAt);
  return finding(item.id, 'content_key_reused_without_occurrence_state', {
    sameSourceKey: firstKey === secondKey,
    receivedAtDeltaMs: Math.abs(new Date(second.receivedAt) - new Date(first.receivedAt)),
    sourceKeyIncludesDeliveryTime: false,
  });
}

async function diagnoseAiMergeConflict() {
  const item = fixtureCase('ai_merge_conflict');
  const originalLoad = smsFacts.loadSmsSourceFacts;
  const originalUpsert = smsFacts.upsertSmsSourceFacts;
  let upsertCalls = 0;
  try {
    smsFacts.loadSmsSourceFacts = async () => ({
      facts: [item.existingFact],
    });
    smsFacts.upsertSmsSourceFacts = async () => {
      upsertCalls += 1;
      return { factIds: ['unexpected-insert'] };
    };
    const completion = await completeJobWithResult(
      { query: async () => ({ rows: [], rowCount: 1 }) },
      {
        job: {
          id: 'synthetic-ai-conflict-job',
          profile_id: 'synthetic-profile',
          source_key: 'a'.repeat(64),
          payload: {
            sender: item.sender,
            body: item.body,
            occurredAt: item.proposedFact.payload.occurredAt,
          },
        },
        facts: [item.proposedFact],
      },
    );
    const conflictGuarded = completion.reviewRequired === true &&
      Array.isArray(completion.conflicts) && completion.conflicts.length > 0 &&
      completion.landed.length === 0;
    return finding(item.id, 'semantic_merge_omits_amount_and_merchant', {
      proposedAmountInr: item.proposedFact.payload.amountInr,
      existingAmountInr: item.existingFact.payload.amountInr,
      proposedMerchantPresent: true,
      existingMerchantPresent: true,
      landedCount: completion.landed.length,
      reviewRequired: completion.reviewRequired,
      conflictCount: completion.conflicts?.length || 0,
      upsertCalls,
    }, conflictGuarded ? 'resolved' : 'gap');
  } finally {
    smsFacts.loadSmsSourceFacts = originalLoad;
    smsFacts.upsertSmsSourceFacts = originalUpsert;
  }
}

async function diagnoseNegative() {
  const item = fixtureCase('ambiguous_negative');
  const parsed = parseSmsAgainstPatterns([], { sender: item.sender, body: item.body });
  const decision = validateDecision(item.negativeDecision, []);
  const completion = await completeJobWithResult(
    { query: async () => ({ rows: [], rowCount: 1 }) },
    {
      job: {
        id: 'synthetic-negative-job',
        profile_id: 'synthetic-profile',
        source_key: 'b'.repeat(64),
        payload: { sender: item.sender, body: item.body },
      },
      decision: item.negativeDecision,
      facts: [],
    },
  );
  const dismissalGuarded = completion.reviewRequired === true &&
    completion.decision === null && completion.dismissalConflict?.reason === 'financial_evidence_present';
  return finding(item.id, 'negative_decision_lacks_source_semantics', {
    parserOk: parsed.ok,
    amountInr: parsed.fields?.amountInr || null,
    merchantPresent: Boolean(parsed.fields?.merchant || parsed.fields?.transferParty),
    decisionValid: decision.valid,
    shouldConsider: item.negativeDecision.shouldConsider,
    validatorAcceptsWithoutBody: decision.valid,
    pipelineReviewRequired: completion.reviewRequired,
    pipelineDecisionAccepted: completion.decision,
    dismissalConflict: completion.dismissalConflict,
  }, dismissalGuarded ? 'resolved' : 'gap');
}

async function runSmsPipelineConformance() {
  return {
    event: 'sms_pipeline_conformance',
    fixtureVersion: fixture.fixtureVersion,
    cases: [
      diagnoseMerchantRole(),
      diagnoseCategoryDrift(),
      diagnoseUnicodeMerchant(),
      diagnoseDuplicateIdentity(),
      await diagnoseAiMergeConflict(),
      await diagnoseNegative(),
    ],
  };
}

if (require.main === module) {
  runSmsPipelineConformance()
    .then((report) => process.stdout.write(`${JSON.stringify(report, null, 2)}\n`))
    .catch((error) => {
      process.stderr.write(`${error.stack || error}\n`);
      process.exitCode = 1;
    });
}

module.exports = { runSmsPipelineConformance };
