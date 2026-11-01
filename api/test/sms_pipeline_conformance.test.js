'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { runSmsPipelineConformance } = require('../../scripts/sms_pipeline_conformance');

test('synthetic SMS conformance harness produces one privacy-safe report per gap fixture', async () => {
  const report = await runSmsPipelineConformance();

  assert.equal(report.event, 'sms_pipeline_conformance');
  assert.equal(report.fixtureVersion, 'sms-pipeline-conformance-v1');
  assert.deepEqual(report.cases.map((entry) => entry.id), [
    'merchant_role_confusion',
    'category_drift_substring',
    'unicode_merchant_loss',
    'duplicate_identity_collision',
    'ai_merge_conflict',
    'ambiguous_negative',
  ]);
  assert.ok(report.cases.every((entry) => ['gap', 'resolved'].includes(entry.status)));
  assert.ok(report.cases.every((entry) => !Object.hasOwn(entry, 'body')));
  assert.ok(report.cases.every((entry) => !Object.hasOwn(entry, 'rawSms')));
});

test('tracked conformance cases keep resolved guards and remaining gaps explicit', async () => {
  const report = await runSmsPipelineConformance();
  const byId = new Map(report.cases.map((entry) => [entry.id, entry]));

  assert.equal(byId.get('merchant_role_confusion').reasonCode, 'model_merchant_not_payee_role');
  assert.equal(byId.get('category_drift_substring').reasonCode, 'substring_category_collision');
  assert.equal(byId.get('unicode_merchant_loss').reasonCode, 'unicode_payee_not_extracted');
  assert.equal(byId.get('duplicate_identity_collision').reasonCode, 'content_key_reused_without_occurrence_state');
  assert.equal(byId.get('ai_merge_conflict').reasonCode, 'semantic_merge_omits_amount_and_merchant');
  assert.equal(byId.get('ambiguous_negative').reasonCode, 'negative_decision_lacks_source_semantics');

  // Current baseline: role, category, Unicode extraction, and merge conflict
  // guards resolve; occurrence identity and negative-decision grounding remain.
  assert.deepEqual(report.cases.map((entry) => entry.status), [
    'resolved', 'resolved', 'resolved', 'gap', 'resolved', 'gap',
  ]);
});
