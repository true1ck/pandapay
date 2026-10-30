const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsLearningAdminRoutes } = require('../src/sms_learning');

const PROFILE = '32111111-1111-4111-8111-111111111111';

function harness(rows, { captured, reviewOutcome = { ok: true, decision: 'approved' } } = {}) {
  const handlers = new Map();
  const app = {
    post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
  };
  const db = {
    async query(sql, params = []) {
      if (captured) captured.push({ sql: sql.replace(/\s+/g, ' ').trim(), params });
      if (sql.includes('sms_review_correction_case')) return { rows: [{ outcome: reviewOutcome }] };
      return { rows };
    },
  };
  registerSmsLearningAdminRoutes(app, {
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, work) => work(db),
  });
  async function call(path, body = {}) {
    const [route, queryString] = path.split('?');
    const method = path.startsWith('POST ') ? 'POST' : 'GET';
    const actualPath = method === 'POST' ? path.slice(5) : path;
    const [postRoute] = actualPath.split('?');
    const chain = handlers.get(`${method} ${method === 'POST' ? postRoute.replace(/\/[^/]+\/review$/, '/:eventId/review') : route}`);
    const eventId = method === 'POST' ? postRoute.split('/').at(-2) : undefined;
    const req = { userId: PROFILE, query: Object.fromEntries(new URLSearchParams(queryString || '')),
      params: method === 'POST' ? { eventId } : {}, body };
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
    review_status: 'pending',
    reviewed_at: null,
    review_reason: null,
    merchant_key: 'SWIGGY',
    support_users: 4,
    support_messages: 9,
    disagree_users: 1,
    ai_redacted_pattern: 'debited rs.{n} to {MERCHANT}',
    redacted_pattern: null,
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
  assert.equal(c.reviewStatus, 'pending');
  assert.equal(c.redactedPattern, 'debited rs.{n} to {MERCHANT}');
  assert.equal(c.aiDiagnosis.advisory, true, 'AI diagnosis must be advisory only');
  assert.equal(c.aiDiagnosis.score, 0.87);
});

test('admin correction review calls the durable review helper and never a publish route', async () => {
  const captured = [];
  const eventId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const { call } = harness([], { captured, reviewOutcome: { ok: true, decision: 'approved' } });
  const result = await call(`POST /admin/sms-learning/feedback-events/${eventId}/review`, {
    decision: 'approved', reason: 'Evidence matches the user correction',
  });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { ok: true, eventId, decision: 'approved' });
  assert.match(captured[0].sql, /sms_review_correction_case/);
  assert.deepEqual(captured[0].params, [eventId, 'approved', PROFILE, 'Evidence matches the user correction']);
  assert.doesNotMatch(captured[0].sql, /publish|bundle/i);
});

test('admin correction review validates the decision, reason and event id', async () => {
  const captured = [];
  const { call } = harness([], { captured });
  for (const [eventId, body] of [
    ['not-a-uuid', { decision: 'approved', reason: 'enough text' }],
    ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', { decision: 'publish', reason: 'enough text' }],
    ['aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', { decision: 'rejected', reason: 'no' }],
  ]) {
    const result = await call(`POST /admin/sms-learning/feedback-events/${eventId}/review`, body);
    assert.equal(result.status, 400);
  }
  assert.equal(captured.length, 0);
});

test('admin correction review reports stale and consent-changed cases as conflicts', async () => {
  const eventId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  for (const reason of ['case_no_longer_reviewable', 'consent_changed']) {
    const { call } = harness([], { reviewOutcome: { ok: false, reason } });
    const result = await call(`POST /admin/sms-learning/feedback-events/${eventId}/review`, {
      decision: 'rejected', reason: 'Insufficient evidence for this correction',
    });
    assert.equal(result.status, 409);
    assert.equal(result.body.error, reason);
  }
});

test('admin may revoke only an already approved correction and the decision is audited by the DB helper', async () => {
  const captured = [];
  const eventId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const { call } = harness([], { captured, reviewOutcome: { ok: true, decision: 'revoked' } });
  const result = await call(`POST /admin/sms-learning/feedback-events/${eventId}/review`, {
    decision: 'revoked', reason: 'Later evidence invalidates this correction',
  });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { ok: true, eventId, decision: 'revoked' });
  assert.deepEqual(captured[0].params, [eventId, 'revoked', PROFILE, 'Later evidence invalidates this correction']);
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

test('correction cases prefer their safe generalized pattern and withhold residual identifiers', async () => {
  const { call } = harness([
    caseRow({ redacted_pattern: 'Debited {AMOUNT} at {MERCHANT}', ai_redacted_pattern: 'AI fallback' }),
    caseRow({ event_id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
      redacted_pattern: 'Paid to payer@upi', ai_redacted_pattern: 'safe fallback' }),
    caseRow({ event_id: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      redacted_pattern: 'Credited RAJESH KUMAR to {MERCHANT}', ai_redacted_pattern: null }),
  ]);
  const { body } = await call('/admin/sms-learning/feedback-events');
  assert.equal(body.correctionCases[0].redactedPattern, 'Debited {AMOUNT} at {MERCHANT}');
  assert.equal(body.correctionCases[1].redactedPattern, 'safe fallback');
  assert.equal(body.correctionCases[2].redactedPattern, null);
});
