const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsLearningFeedbackRoute } = require('../src/sms_learning_feedback_route');

const PROFILE = '11111111-1111-4111-8111-111111111111';
const EVENT = '22222222-2222-4222-8222-222222222222';
const SOURCE_KEY = 'a'.repeat(64);
const GRANTED_AT = '2026-10-26T10:00:00.000Z';
const POLICY_V2 = 'sms-shared-learning-v2';

/**
 * Minimal stateful stand-in for the feedback transaction. It records the order
 * of issued statements so the test can prove the supersede runs before the
 * insert, and stores the exact column values the route writes.
 */
function createDb() {
  const state = { events: [], examples: [], order: [], supersededFacts: [], dismissals: [] };
  const client = {
    async query(sql, params = []) {
      const q = sql.replace(/\s+/g, ' ').trim();
      state.order.push(q);

      if (q.includes('pg_advisory_xact_lock')) return { rows: [{ lock: null }], rowCount: 1 };
      if (q.includes('AS matches')) {
        return { rows: [{ matches: new Date(params[0]).getTime() === new Date(params[1]).getTime() }], rowCount: 1 };
      }
      if (q.includes('FROM public.user_consents')) {
        return { rows: [{ granted: true, policy_version: POLICY_V2, granted_at: GRANTED_AT }], rowCount: 1 };
      }
      if (q.startsWith('SELECT 1 FROM public.sms_learning_feedback_events')) {
        const [profileId, sourceKeyHash] = params;
        const hit = state.events.some((row) => row.profile_id === profileId &&
          row.source_key_hash === sourceKeyHash);
        return { rows: hit ? [{ exists: 1 }] : [], rowCount: hit ? 1 : 0 };
      }
      if (q.includes('SELECT learned, learning_reason FROM public.sms_learning_feedback_events')) {
        const [profileId, eventId] = params;
        const hit = state.events.find((row) => row.profile_id === profileId && row.event_id === eventId);
        return {
          rows: hit ? [{ learned: hit.learned, learning_reason: hit.learning_reason }] : [],
          rowCount: hit ? 1 : 0,
        };
      }
      if (q.includes('SELECT id FROM public.sms_learning_examples')) return { rows: [], rowCount: 0 };
      if (q.includes('INSERT INTO public.sms_learning_examples')) {
        state.examples.push({ profile_id: params[0], fact_family: params[3], is_negative: params[7] });
        return { rows: [{ id: `example-${state.examples.length}` }], rowCount: 1 };
      }
      if (q.includes('pandapay.sms_supersede_corrections')) {
        state.supersededFacts.push({ sourceKeyHash: params[0], factKey: params[1], eventId: params[2] });
        return { rows: [{ superseded_count: 0 }], rowCount: 1 };
      }
      if (q.includes('INSERT INTO public.sms_learning_feedback_events')) {
        state.events.push({
          profile_id: params[0], event_id: params[1], source_key_hash: params[2],
          action: params[4], merchant_key: params[8], category_slug: params[9],
          original_category_slug: params[10], original_decision: params[12],
          corrected_fields: params[13], learned: params[15], learning_reason: params[16],
          correction_kind: params[18], decision_origin: params[19],
          decision_rule_id: params[20], fact_key: params[21], message_at: params[22],
          commitment_category: params[23],
        });
        return { rows: [], rowCount: 1 };
      }
      if (q.includes('pandapay.sms_supersede_ai_proposals')) return { rows: [{ superseded_count: 0 }], rowCount: 1 };
      if (q.includes('admin_audit_log')) return { rows: [], rowCount: 1 };
      throw new Error(`unexpected statement: ${q.slice(0, 120)}`);
    },
  };
  return { state, client };
}

function harness() {
  const db = createDb();
  const handlers = new Map();
  const app = {
    post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
  };
  registerSmsLearningFeedbackRoute(app, {
    requireAuth: (req, res, next) => next(),
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_userId, work) => work(db.client),
  });
  async function call(body) {
    const chain = handlers.get('POST /sms/learning-feedback');
    const req = { userId: PROFILE, body };
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

function base(overrides = {}) {
  return {
    eventId: EVENT,
    sourceKey: SOURCE_KEY,
    action: 'category_changed',
    sender: 'AD-HDFCBK',
    sampleBody: 'Rs.500 spent at AMAZON on your HDFC Bank Card.',
    resolvedKind: 'transaction',
    occurredAt: '2026-10-26T09:00:00.000Z',
    consentPurpose: 'sms_shared_learning',
    consentPolicyVersion: POLICY_V2,
    consentGrantedAt: GRANTED_AT,
    originalDecision: { kind: 'posted_movement', fields: { merchant: 'AMAZON', category: 'travel' } },
    correctedFields: { categorySlug: 'dining' },
    ...overrides,
  };
}

let restoreKey;
test.before(() => {
  restoreKey = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
});
test.after(() => {
  if (restoreKey === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
  else process.env.SMS_LEARNING_HMAC_KEY = restoreKey;
});

test('rejects an unknown correction taxonomy or decision provenance', async () => {
  const { call, state } = harness();
  const cases = [
    [{ correctionKind: 'totally_wrong' }, 'invalid correctionKind'],
    [{ decisionOrigin: 'gemini' }, 'invalid decisionOrigin'],
    [{ factIndex: 32 }, 'factIndex must be 0 to 31'],
    [{ factIndex: 1.5 }, 'factIndex must be 0 to 31'],
    [{ decisionRuleId: 'rule with spaces' }, 'invalid decisionRuleId'],
    [{ messageAt: 'not-a-date' }, 'messageAt must be a valid timestamp'],
  ];
  for (const [override, message] of cases) {
    const result = await call(base(override));
    assert.equal(result.status, 400, `expected 400 for ${JSON.stringify(override)}`);
    assert.equal(result.body.error, message);
  }
  assert.equal(state.events.length, 0);
});

test('stores one typed correction and supersedes the earlier fact first', async () => {
  const { call, state } = harness();
  const result = await call(base({
    correctionKind: 'misclassified_category',
    decisionOrigin: 'shared_rule',
    decisionRuleId: 'bundle-2026-10-21:r4',
    factIndex: 2,
    messageAt: '2026-10-26T08:59:30.000Z',
  }));
  assert.equal(result.status, 200);
  assert.equal(result.body.learningReason, 'category_feedback_stored');
  assert.equal(state.events.length, 1);
  const row = state.events[0];
  assert.equal(row.correction_kind, 'misclassified_category');
  assert.equal(row.decision_origin, 'shared_rule');
  assert.equal(row.decision_rule_id, 'bundle-2026-10-21:r4');
  assert.equal(row.fact_key, `${SOURCE_KEY}:2`);
  assert.equal(row.message_at.toISOString(), '2026-10-26T08:59:30.000Z');
  assert.equal(row.category_slug, 'dining');
  // Legacy originalDecision.fields.category is still read as the prior label,
  // which the previous implementation dropped on the floor.
  assert.equal(row.original_category_slug, 'travel');

  const supersedeAt = state.order.findIndex((q) => q.includes('sms_supersede_corrections'));
  const insertAt = state.order.findIndex((q) => q.includes('INSERT INTO public.sms_learning_feedback_events'));
  assert.ok(supersedeAt >= 0, 'the fact was not superseded');
  assert.ok(supersedeAt < insertAt, 'the supersede must run before the new current row is inserted');
  assert.deepEqual(state.supersededFacts[0], {
    sourceKeyHash: SOURCE_KEY, factKey: `${SOURCE_KEY}:2`, eventId: EVENT,
  });
});

test('defaults the fact index to the first fact in the message', async () => {
  const { call, state } = harness();
  await call(base({ correctionKind: 'misclassified_category' }));
  assert.equal(state.events[0].fact_key, `${SOURCE_KEY}:0`);
});

test('a cosmetic edit trains nothing and supersedes nothing', async () => {
  const { call, state } = harness();
  const result = await call(base({ correctionKind: 'cosmetic' }));
  assert.equal(result.status, 200);
  assert.equal(result.body.learningReason, 'cosmetic_no_training');
  assert.equal(result.body.recorded, false);
  assert.equal(state.events.length, 0);
  assert.equal(state.examples.length, 0);
  assert.equal(state.supersededFacts.length, 0);
});

test('a preference-only dismissal is stored but trains no ignore rule', async () => {
  const { call, state } = harness();
  const result = await call(base({
    action: 'dismissed',
    resolvedKind: 'dismissed',
    correctedFields: {},
    correctionKind: 'preference_only',
  }));
  assert.equal(result.status, 200);
  assert.equal(result.body.learned, false);
  assert.equal(result.body.learningReason, 'preference_only_no_training');
  assert.equal(state.events.length, 1);
  assert.equal(state.events[0].correction_kind, 'preference_only');
  assert.equal(state.examples.length, 0);
  assert.equal(state.dismissals.length, 0);
});

test('an unsupported spend slug abstains instead of being stored', async () => {
  const { call, state } = harness();
  const result = await call(base({
    correctionKind: 'misclassified_category',
    correctedFields: { categorySlug: 'cash' },
  }));
  assert.equal(result.status, 200);
  assert.equal(result.body.learningReason, 'category_feedback_unsupported_slug');
  assert.equal(state.events[0].category_slug, null);
  assert.equal(JSON.parse(state.events[0].corrected_fields).categorySlug, undefined);
});

test('a canonical spend category the SQL allowlist used to omit is accepted', async () => {
  const { call, state } = harness();
  await call(base({ correctionKind: 'misclassified_category', correctedFields: { categorySlug: 'government' } }));
  assert.equal(state.events[0].category_slug, 'government');
  assert.equal(JSON.parse(state.events[0].corrected_fields).categorySlug, 'government');
});

test('a subscription stays a commitment kind and never becomes a spend slug', async () => {
  const { call, state } = harness();
  const result = await call(base({
    action: 'edited',
    resolvedKind: 'bill',
    correctionKind: 'wrong_bill_fields',
    originalDecision: {
      kind: 'bill_obligation',
      fields: { billerName: 'NETFLIX', amountDueInr: 799, category: 'subscription' },
    },
    correctedFields: { billerName: 'NETFLIX', amountDueInr: 649, categorySlug: 'subscription' },
  }));
  assert.equal(result.status, 200);
  const row = state.events[0];
  assert.equal(row.category_slug, null, 'subscription must not enter the spend category column');
  assert.equal(row.commitment_category, 'subscription');
  assert.equal(row.original_category_slug, 'subscription');
  const corrected = JSON.parse(row.corrected_fields);
  assert.equal(corrected.categorySlug, undefined);
  assert.equal(corrected.commitmentCategory, 'subscription');
  assert.equal(corrected.billerName, 'NETFLIX');
});

test('a commitment category sent for a spend fact is refused', async () => {
  const { call, state } = harness();
  await call(base({ correctionKind: 'misclassified_category', correctedFields: { categorySlug: 'subscription' } }));
  assert.equal(state.events[0].category_slug, null);
  assert.equal(state.events[0].commitment_category, null);
});

test('a duplicate retry returns the first stored result and inserts once', async () => {
  const { call, state } = harness();
  const first = await call(base({ correctionKind: 'misclassified_category' }));
  const second = await call(base({ correctionKind: 'misclassified_category' }));
  assert.equal(first.body.recorded, true);
  assert.equal(second.status, 200);
  assert.equal(second.body.recorded, false);
  assert.equal(second.body.learningReason, first.body.learningReason);
  assert.equal(state.events.length, 1);
  assert.equal(state.supersededFacts.length, 1, 'a retry must not supersede again');
});

test('a training edit still records one example and keeps the corrected amount', async () => {
  const { call, state } = harness();
  const result = await call(base({
    action: 'edited',
    resolvedKind: 'transaction',
    correctionKind: 'wrong_amount',
    correctedFields: { amountInr: 649, merchant: 'BIGBASKET' },
  }));
  assert.equal(result.status, 200);
  assert.equal(result.body.learned, true);
  assert.equal(state.examples.length, 1);
  const stored = JSON.parse(state.events[0].corrected_fields);
  assert.equal(stored.amountInr, 649);
});
