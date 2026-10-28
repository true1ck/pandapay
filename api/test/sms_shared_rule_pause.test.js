const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsRuleBundleRoutes, computeBundleHash } = require('../src/sms_rule_bundle');
const { registerSmsLearningAdminRoutes } = require('../src/sms_learning');

const PROFILE = '12111111-1111-4111-8111-111111111111';
const PAUSED_ID = 'paused-shared-rule-1';
const PAUSED_ASSIGNED_ID = 'paused-shared-rule-2';
const HEALTHY_ID = 'healthy-shared-rule-3';

function candidateRow(candidateId, { approvedSha } = {}) {
  const row = {
    candidate_id: candidateId,
    family: 'posted_movement',
    sender_pattern: 'HDFCBK',
    template: 'debited Rs.{n} on card {n}',
    compiled_regex: 'debited Rs\\.?\\s*([0-9.]+) on card (\\d{4})',
    field_map: { amount: 1, last4: 2 },
    default_fields: {},
    confidence: 0.98,
    state: 'active',
    bundle_version: 7,
    min_client_ver: '1.0.0',
    stage_version: 2,
  };
  row.approved_sha256 = approvedSha || computeBundleHash({
    bundleVersion: row.bundle_version,
    rules: [{
      id: row.candidate_id, family: row.family, senderPattern: row.sender_pattern,
      regex: row.compiled_regex, fieldMap: row.field_map,
      defaultFields: row.default_fields, confidence: row.confidence,
    }],
    minClientVersion: row.min_client_ver,
  });
  return row;
}

/**
 * Stateful stand-in for the /sms/rules/active transaction. priorAssignments
 * models which rules this profile already received; anything it contains keeps
 * being served even after the rule pauses.
 */
function createDb({ priorAssignments = [], pausedRules = [PAUSED_ID, PAUSED_ASSIGNED_ID], failPauseLookup = false } = {}) {
  const state = {
    order: [], assignments: [], priorAssignments,
    pausedRules, failPauseLookup, activeBundleQueries: 0,
  };
  const client = {
    async query(sql, params = []) {
      const q = sql.replace(/\s+/g, ' ').trim();
      state.order.push(q);

      if (q.includes('FROM public.user_consents')) {
        return { rows: [{ granted: true }], rowCount: 1 };
      }
      if (q.includes('FROM public.sms_rule_bundles')) {
        state.activeBundleQueries += 1;
        return { rows: [], rowCount: 0 };
      }
      if (q.includes('FROM public.sms_rule_candidates')) {
        return {
          rows: [
            candidateRow(PAUSED_ID),
            candidateRow(PAUSED_ASSIGNED_ID),
            candidateRow(HEALTHY_ID),
          ],
          rowCount: 3,
        };
      }
      if (q.includes('pandapay.sms_rule_negative_evidence()')) {
        if (state.failPauseLookup) throw new Error('pause source not deployed yet');
        return { rows: state.pausedRules.map((id) => ({ decision_rule_id: id })), rowCount: state.pausedRules.length };
      }
      if (q.includes('INSERT INTO public.sms_rule_candidate_assignments')) {
        const [candidateId] = params;
        state.assignments.push({ candidateId, profileId: params[1] });
        return { rows: [{ assignment_id: `assignment-${state.assignments.length}` }], rowCount: 1 };
      }
      if (q.includes('FROM public.sms_rule_candidate_assignments')) {
        const rows = state.priorAssignments.map((candidateId) => ({ candidate_id: candidateId }));
        return { rows, rowCount: rows.length };
      }
      if (q.includes('pandapay.sms_approved_category_rules()')) {
        return { rows: [], rowCount: 0 };
      }
      throw new Error(`unexpected statement: ${q.slice(0, 140)}`);
    },
  };
  return { state, client };
}

function harness(db) {
  const handlers = new Map();
  const app = {
    post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
  };
  registerSmsRuleBundleRoutes(app, {
    requireAuth: (req, res, next) => next(),
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, work) => work(db.client),
  });
  async function call(path) {
    const chain = handlers.get(`GET ${path}`);
    const req = { userId: PROFILE, query: {}, params: {} };
    let status = 200;
    let payload = null;
    const res = {
      status(code) { status = code; return this; },
      json(value) { payload = value; return this; },
    };
    for (const middleware of chain.slice(0, -1)) await middleware(req, res, () => {});
    await chain[chain.length - 1](req, res);
    return { status, body: payload };
  }
  return { call, state: db.state };
}

test('a paused shared rule is withheld from a user who never received it', async () => {
  const { call, state } = harness(createDb({ priorAssignments: [] }));
  const result = await call('/sms/rules/active');
  assert.equal(result.status, 200);
  const ids = result.body.candidateRules.map((rule) => rule.candidateId);
  assert.ok(state.order.some((q) => q.includes('pandapay.sms_rule_negative_evidence()')),
    'the serving path never consulted the pause status');
  assert.equal(ids.includes(PAUSED_ID), false, 'a paused rule was served to a new user');
  assert.equal(ids.includes(PAUSED_ASSIGNED_ID), false,
    'a paused rule without a prior assignment is equally withheld');
  assert.deepEqual(ids, [HEALTHY_ID]);
  assert.equal(state.assignments.some((a) => a.candidateId === PAUSED_ID), false,
    'a paused rule must not create a new assignment');
});

test('a paused rule keeps being served to a user who already received it', async () => {
  const { call, state } = harness(createDb({ priorAssignments: [PAUSED_ASSIGNED_ID] }));
  const result = await call('/sms/rules/active');
  assert.equal(result.status, 200);
  const ids = result.body.candidateRules.map((rule) => rule.candidateId);
  assert.ok(ids.includes(PAUSED_ASSIGNED_ID),
    'the existing correcting user must keep their rule so the local override keeps winning');
  assert.equal(ids.includes(PAUSED_ID), false);
  assert.equal(result.body.revokedCandidateIds.includes(PAUSED_ASSIGNED_ID), false,
    'a kept rule must not be revoked for its existing user');
});

test('a pause-lookup outage keeps the previous serving behavior', async () => {
  const { call } = harness(createDb({ failPauseLookup: true }));
  const result = await call('/sms/rules/active');
  assert.equal(result.status, 200);
  const ids = result.body.candidateRules.map((rule) => rule.candidateId);
  assert.deepEqual(ids.sort(), [PAUSED_ID, PAUSED_ASSIGNED_ID, HEALTHY_ID].sort());
});

test('a healthy rule is unaffected by another rule reaching the threshold', async () => {
  const { call } = harness(createDb({ pausedRules: ['some-other-rule'] }));
  const result = await call('/sms/rules/active');
  const ids = result.body.candidateRules.map((rule) => rule.candidateId);
  assert.deepEqual(ids, [PAUSED_ID, PAUSED_ASSIGNED_ID, HEALTHY_ID]);
});

test('admin negative-evidence rollup exposes counts, pause verdicts and the threshold', async () => {
  const handlers = new Map();
  const app = {
    post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
  };
  const db = {
    async query(sql) {
      const q = sql.replace(/\s+/g, ' ').trim();
      if (q.includes('FROM pandapay.sms_rule_negative_evidence()')) {
        return { rows: [
          { decision_rule_id: PAUSED_ID, negative_evidence_count: 4,
            distinct_reporting_profiles: 3, paused: true },
          { decision_rule_id: HEALTHY_ID, negative_evidence_count: 1,
            distinct_reporting_profiles: 1, paused: false },
        ] };
      }
      if (q.includes('pandapay.sms_shared_rule_pause_threshold()')) {
        return { rows: [{ threshold: 3 }] };
      }
      throw new Error(`unexpected statement: ${q.slice(0, 140)}`);
    },
  };
  registerSmsLearningAdminRoutes(app, {
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, work) => work(db),
  });
  const chain = handlers.get('GET /admin/sms-learning/rule-negative-evidence');
  const req = { userId: PROFILE, query: {} };
  let status = 200;
  let payload = null;
  const res = {
    status(code) { status = code; return this; },
    json(value) { payload = value; return this; },
  };
  for (const middleware of chain.slice(0, -1)) await middleware(req, res, () => {});
  await chain[chain.length - 1](req, res);
  assert.equal(status, 200);
  assert.equal(payload.pauseThreshold, 3);
  assert.deepEqual(payload.rules, [
    { decisionRuleId: PAUSED_ID, negativeEvidenceCount: 4,
      distinctReportingProfiles: 3, paused: true },
    { decisionRuleId: HEALTHY_ID, negativeEvidenceCount: 1,
      distinctReportingProfiles: 1, paused: false },
  ]);
});
