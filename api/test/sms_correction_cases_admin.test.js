const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsLearningAdminRoutes } = require('../src/sms_learning');

const PROFILE = '32111111-1111-4111-8111-111111111111';

function harness(rows, { captured } = {}) {
  const handlers = new Map();
  const app = {
    post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
  };
  const db = {
    async query(sql, params = []) {
      if (captured) captured.push({ sql: sql.replace(/\s+/g, ' ').trim(), params });
      return { rows };
    },
  };
  registerSmsLearningAdminRoutes(app, {
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, work) => work(db),
  });
  async function call(path) {
    const [route, queryString] = path.split('?');
    const chain = handlers.get(`GET ${route}`);
    const req = { userId: PROFILE, query: Object.fromEntries(new URLSearchParams(queryString || '')), params: {} };
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
  return { call };
}

function caseRow(overrides = {}) {
  return {
    event_id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    source_key_hash: 'c'.repeat(64),
    fact_key: `${'c'.repeat(64)}:0`,
    action: 'edited',
    resolved_kind: 'transaction',
    correction_kind: 'misclassified_category',
    decision_origin: 'ai',
    decision_rule_id: null,
    message_at: '2026-10-28T10:00:00.000Z',
    created_at: '2026-10-28T11:00:00.000Z',
    original_decision: {
      kind: 'posted_movement',
      origin: 'ai',
      fields: { amountInr: 420.5, merchant: 'Swiggy', categorySlug: 'travel' },
    },
    corrected_fields: { categorySlug: 'dining' },
    category_slug: 'dining',
    original_category_slug: 'travel',
    commitment_category: null,
    superseded_at: null,
    superseded_by_event_id: null,
    merchant_key: 'SWIGGY',
    support_users: 4,
    support_messages: 9,
    disagree_users: 1,
    ai_redacted_pattern: 'debited rs.{n} to {MERCHANT}',
    ai_proposed_fields: { categorySlug: 'travel' },
    ai_score: 0.87,
    ai_status: 'pending',
    ...overrides,
  };
}

test('a training-eligible correction case maps to the console contract with advisory AI diagnosis', async () => {
  const { call } = harness([caseRow()]);
  const { status, body } = await call('/admin/sms-learning/feedback-events?limit=100');
  assert.equal(status, 200);
  const c = body.correctionCases[0];
  assert.equal(c.eventId, 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  assert.equal(c.action, 'edited');
  assert.equal(c.correctionKind, 'misclassified_category');
  assert.equal(c.decisionOrigin, 'ai');
  assert.deepEqual(c.originalDecision, {
    kind: 'posted_movement',
    origin: 'ai',
    ruleId: null,
    fields: { amountInr: 420.5, merchant: 'Swiggy', categorySlug: 'travel' },
  });
  assert.deepEqual(c.correctedFields, { categorySlug: 'dining' });
  assert.equal(c.categorySlug, 'dining');
  assert.equal(c.originalCategorySlug, 'travel');
  assert.deepEqual(c.support, { users: 4, messages: 9 });
  assert.deepEqual(c.disagreement, { users: 1 });
  assert.equal(c.supersededAt, null);
  assert.equal(c.redactedPattern, 'debited rs.{n} to {MERCHANT}');
  assert.equal(c.aiDiagnosis.advisory, true, 'AI diagnosis must be advisory only');
  assert.equal(c.aiDiagnosis.score, 0.87);
});

test('non-training kinds contribute no support or disagreement', async () => {
  const { call } = harness([
    caseRow({ correction_kind: 'preference_only' }),
    caseRow({ correction_kind: 'cosmetic' }),
    caseRow({ correction_kind: 'duplicate' }),
  ]);
  const { body } = await call('/admin/sms-learning/feedback-events');
  for (const c of body.correctionCases) {
    assert.deepEqual(c.support, { users: 0, messages: 0 });
    assert.deepEqual(c.disagreement, { users: 0 });
  }
});

test('a superseded case keeps its audit linkage', async () => {
  const supersededBy = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const { call } = harness([caseRow({
    superseded_at: '2026-10-28T12:00:00.000Z',
    superseded_by_event_id: supersededBy,
  })]);
  const { body } = await call('/admin/sms-learning/feedback-events');
  assert.equal(body.correctionCases[0].supersededAt, '2026-10-28T12:00:00.000Z');
  assert.equal(body.correctionCases[0].supersededByEventId, supersededBy);
});

test('limit is clamped and commitment categories pass through', async () => {
  const captured = [];
  const { call } = harness([caseRow({ commitment_category: 'subscription' })], { captured });
  const { body } = await call('/admin/sms-learning/feedback-events?limit=5000');
  assert.equal(captured[0].params[0], 200, 'the requested limit must clamp to 200');
  assert.equal(body.correctionCases[0].commitmentCategory, 'subscription');
  const second = harness([], { captured });
  await second.call('/admin/sms-learning/feedback-events?limit=nonsense');
  assert.equal(captured[1].params[0], 100, 'an unparseable limit falls back to 100');
});

test('no raw message evidence leaves the route', async () => {
  const { call } = harness([caseRow()]);
  const { body } = await call('/admin/sms-learning/feedback-events');
  const serialized = JSON.stringify(body).toLowerCase();
  for (const banned of ['smsbody', 'samplebody', 'template_text', 'accountnumber', 'referencenumber', '"otp"']) {
    assert.equal(serialized.includes(banned), false, `response leaked ${banned}`);
  }
});
