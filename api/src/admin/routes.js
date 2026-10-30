'use strict';

const { registerInlineAdminRoutes } = require('./inline_routes');
const { registerRuleFamilyRoutes } = require('../admin_rule_families');
const { registerAdminReferralOperationsRoutes } = require('../admin_referral_operations');
const aiQueueRoute = require('../ai_queue_route');
const smsLearning = require('../sms_learning');
const smsLearningFeedbackRoute = require('../sms_learning_feedback_route');
const smsRuleBundle = require('../sms_rule_bundle');

function registerAdminRoutes(api) {
  const { legacyApp, legacyDependencies } = api;
  registerInlineAdminRoutes(legacyApp, legacyDependencies);
  registerAdminReferralOperationsRoutes(legacyApp, legacyDependencies);
const REWARD_UNITS = [
  'cashback_percent', 'points_per_100', 'points_per_150', 'points_per_200',
  'miles_per_100', 'flat_points', 'discount_percent',
];
const CAP_PERIODS = ['statement_cycle', 'calendar_month', 'quarter', 'half_year', 'annual', 'lifetime'];
const CAP_MEASURES = ['reward_value', 'spend_amount', 'txn_count'];
const BENEFIT_KINDS = [
  'lounge_domestic', 'lounge_international', 'golf', 'concierge', 'insurance_travel',
  'insurance_purchase', 'extended_warranty', 'dining_program', 'movie', 'fuel_surcharge',
  'roadside_assistance', 'other',
];
const MILESTONE_ANCHORS = ['card_anniversary', 'calendar_year', 'fiscal_year', 'statement_cycle'];

const adminRouteDeps = api.legacyDependencies;

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'cap-rules',
  tableName: 'cap_rules',
  auditEntity: 'cap_rule',
  fields: [
    { name: 'categoryId', column: 'category_id', type: 'string' },
    { name: 'benefitKind', column: 'benefit_kind', type: 'enum', values: BENEFIT_KINDS },
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'measure', column: 'measure', type: 'enum', values: CAP_MEASURES, required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS, required: true },
    { name: 'capValue', column: 'cap_value', type: 'number', min: 0, required: true },
    { name: 'postCapUnit', column: 'post_cap_unit', type: 'enum', values: REWARD_UNITS },
    { name: 'postCapRate', column: 'post_cap_rate', type: 'number', min: 0 },
    { name: 'resetsOnDay', column: 'resets_on_day', type: 'integer', min: 1, max: 31 },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'milestone-rules',
  tableName: 'milestone_rules',
  auditEntity: 'milestone_rule',
  fields: [
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS },
    { name: 'thresholdSpendInr', column: 'threshold_spend_inr', type: 'number', min: 0, required: true },
    { name: 'rewardDescription', column: 'reward_description', type: 'string', required: true },
    { name: 'rewardValueInr', column: 'reward_value_inr', type: 'number', min: 0, required: true },
    { name: 'isRepeatable', column: 'is_repeatable', type: 'boolean' },
    { name: 'maxRepeats', column: 'max_repeats', type: 'integer', min: 0 },
    { name: 'anchor', column: 'anchor', type: 'enum', values: MILESTONE_ANCHORS },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'fee-waiver-rules',
  tableName: 'fee_waiver_rules',
  auditEntity: 'fee_waiver_rule',
  fields: [
    { name: 'thresholdSpendInr', column: 'threshold_spend_inr', type: 'number', min: 0, required: true },
    { name: 'period', column: 'period', type: 'enum', values: CAP_PERIODS },
    { name: 'waivesFeeInr', column: 'waives_fee_inr', type: 'number', min: 0, required: true },
    { name: 'notes', column: 'notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'card-benefits',
  tableName: 'card_benefits',
  auditEntity: 'card_benefit',
  fields: [
    { name: 'kind', column: 'kind', type: 'enum', values: BENEFIT_KINDS, required: true },
    { name: 'label', column: 'label', type: 'string', required: true },
    { name: 'description', column: 'description', type: 'string' },
    { name: 'quotaCount', column: 'quota_count', type: 'integer', min: 0 },
    { name: 'quotaPeriod', column: 'quota_period', type: 'enum', values: CAP_PERIODS },
    { name: 'networkProgram', column: 'network_program', type: 'string' },
    { name: 'valueEstimateInr', column: 'value_estimate_inr', type: 'number', min: 0 },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'redemption-options',
  tableName: 'redemption_options',
  auditEntity: 'redemption_option',
  fields: [
    { name: 'programName', column: 'program_name', type: 'string', required: true },
    { name: 'method', column: 'method', type: 'string', required: true },
    { name: 'valuePerPointInr', column: 'value_per_point_inr', type: 'number', min: 0, required: true },
    { name: 'minPoints', column: 'min_points', type: 'integer', min: 0 },
    { name: 'notes', column: 'notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'forex-rules',
  tableName: 'forex_rules',
  auditEntity: 'forex_rule',
  singlePerCard: true,
  fields: [
    { name: 'markupPercent', column: 'markup_percent', type: 'number', min: 0, required: true },
    { name: 'gstOnMarkup', column: 'gst_on_markup', type: 'boolean' },
    { name: 'waiverNotes', column: 'waiver_notes', type: 'string' },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'fuel-surcharge-rules',
  tableName: 'fuel_surcharge_rules',
  auditEntity: 'fuel_surcharge_rule',
  singlePerCard: true,
  fields: [
    { name: 'surchargePercent', column: 'surcharge_percent', type: 'number', min: 0 },
    { name: 'waiverPercent', column: 'waiver_percent', type: 'number', min: 0 },
    { name: 'minTxnInr', column: 'min_txn_inr', type: 'number', min: 0 },
    { name: 'maxTxnInr', column: 'max_txn_inr', type: 'number', min: 0 },
    { name: 'monthlyWaiverCap', column: 'monthly_waiver_cap', type: 'number', min: 0 },
  ],
});

registerRuleFamilyRoutes(api.legacyApp, adminRouteDeps, {
  urlSegment: 'billing-cycle-rules',
  tableName: 'billing_cycle_rules',
  auditEntity: 'billing_cycle_rule',
  singlePerCard: true,
  fields: [
    { name: 'gracePeriodDays', column: 'grace_period_days', type: 'integer', min: 0 },
    { name: 'cycleNotes', column: 'cycle_notes', type: 'string' },
  ],
});


  aiQueueRoute.registerAiQueueRoutes(legacyApp, legacyDependencies);
  smsLearning.registerSmsLearningAdminRoutes(legacyApp, legacyDependencies);
  smsLearningFeedbackRoute.registerSmsLearningFeedbackRoute(legacyApp, legacyDependencies);
  smsRuleBundle.registerSmsRuleBundleRoutes(legacyApp, legacyDependencies);

  api.route('GET', '/admin/reference/categories', async (_req, res, ctx) => {
    try {
      const result = await ctx.withAdminClient(client => client.query('SELECT id, slug, name FROM spend_categories ORDER BY sort_order'));
      return res.json({ categories: result.rows });
    } catch {
      return res.status(500).json({ error: 'internal_error' });
    }
  });
  api.route('POST', '/admin/sms-learning/cycle', async (_req, res) =>
    res.status(409).json({ error: 'autonomous_cycle_is_worker_only' }));
}

module.exports = { registerAdminRoutes };
