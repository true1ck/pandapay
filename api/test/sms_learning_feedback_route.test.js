const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsLearningFeedbackRoute } = require('../src/sms_learning_feedback_route');

const uuid = '11111111-1111-4111-8111-111111111111';
const sourceKey = 'a'.repeat(64);

function setup({ consent = true, duplicate = null, consentGrantedAt = '2026-10-26T10:00:00.000Z',
  policyVersion = 'sms-shared-learning-v1' } = {}) {
  const handlers = new Map();
  const queries = [];
  const app = {
    post: (path, _auth, handler) => handlers.set(path, handler),
    get: (path, _auth, handler) => handlers.set(path, handler),
  };
  const client = {
    async query(sql, params = []) {
      const normalized = sql.replace(/\s+/g, ' ').trim();
      queries.push({ sql: normalized, params });
      if (normalized.includes("purpose = 'sms_shared_learning'")) {
        return { rows: [{ granted: consent, policy_version: policyVersion, granted_at: consentGrantedAt }], rowCount: 1 };
      }
      if (normalized.includes('AS matches')) {
        return { rows: [{ matches: new Date(params[0]).getTime() === new Date(params[1]).getTime() }], rowCount: 1 };
      }
      if (normalized.includes('SELECT learned, learning_reason FROM public.sms_learning_feedback_events')) {
        return { rows: duplicate ? [duplicate] : [], rowCount: duplicate ? 1 : 0 };
      }
      if (normalized.includes('SELECT id FROM public.sms_learning_examples')) {
        return { rows: [], rowCount: 0 };
      }
      if (normalized.includes('INSERT INTO public.sms_learning_examples')) {
        return { rows: [{ id: 'example-1' }], rowCount: 1 };
      }
      return { rows: [], rowCount: 1 };
    },
  };
  registerSmsLearningFeedbackRoute(app, {
    requireAuth: () => true,
    requireAdmin: () => true,
    withUserClient: (_userId, run) => run(client),
  });
  return {
    queries,
    call: async (payload) => {
      let resultBody;
      let status;
      const res = {
        status(code) { status = code; return this; },
        json(value) { resultBody = value; return this; },
      };
      await handlers.get('/sms/learning-feedback')({ userId: 'profile-1', body: payload }, res);
      return { status, body: resultBody };
    },
  };
}

const event = (overrides = {}) => ({
  eventId: uuid,
  sourceKey,
  action: 'confirmed',
  sender: 'AD-HDFCBK',
  sampleBody: 'Rs. 250 paid at Cafe on 25-10-2026',
  resolvedKind: 'transaction',
  originalDecision: {
    kind: 'posted_movement',
    fields: { amountInr: 250, merchant: 'Cafe', occurredAt: '2026-10-25T10:00:00Z' },
  },
  correctedFields: {},
  occurredAt: '2026-10-25T10:00:00Z',
  consentPurpose: 'sms_shared_learning',
  consentPolicyVersion: 'sms-shared-learning-v1',
  consentGrantedAt: '2026-10-26T10:00:00.000Z',
  ...overrides,
});

test('confirmed decision writes an idempotent event and a typed example', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup();
    const response = await ctx.call(event());
    assert.equal(response.status, 200);
    assert.deepEqual(response.body, {
      acknowledged: true, recorded: true, learned: true, learningReason: 'recorded',
    });
    assert.ok(ctx.queries.some(({ sql }) => sql.includes('INSERT INTO public.sms_learning_examples')));
    const storedEvent = ctx.queries.find(({ sql }) => sql.includes('INSERT INTO public.sms_learning_feedback_events'));
    assert.ok(storedEvent);
    assert.equal(storedEvent.params[5], 'sms_shared_learning');
    assert.equal(storedEvent.params[6], 'sms-shared-learning-v1');
    assert.equal(storedEvent.params[7], '2026-10-26T10:00:00.000Z');
    assert.equal(JSON.stringify(storedEvent.params).includes('Rs. 250 paid'), false);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('stale feedback from an earlier consent grant is acknowledged but not stored', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup({ consentGrantedAt: '2026-10-27T10:00:00.000Z' });
    const response = await ctx.call(event({ consentGrantedAt: '2026-10-26T10:00:00.000Z' }));
    assert.deepEqual(response.body, {
      acknowledged: true, recorded: false, learned: false,
      learningReason: 'consent_grant_mismatch',
    });
    assert.equal(ctx.queries.some(({ sql }) => sql.includes('INSERT INTO')), false);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('missing explicit SMS learning consent acknowledges without storing or training', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup({ consent: false });
    const response = await ctx.call(event());
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'consent_disabled');
    assert.equal(ctx.queries.some(({ sql }) => sql.includes('INSERT INTO')), false);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('sensitive messages are acknowledged and never persisted', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup();
    const response = await ctx.call(event({ sampleBody: 'Your OTP verification code is 123456' }));
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'sensitive_sms');
    assert.equal(ctx.queries.length, 0);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('duplicate event retry returns the original learning status without reinserting', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup({ duplicate: { learned: true, learning_reason: 'recorded' } });
    const response = await ctx.call(event());
    assert.equal(response.body.learningReason, 'recorded');
    assert.equal(ctx.queries.some(({ sql }) => sql.includes('INSERT INTO')), false);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('category correction stores a normalized merchant/category event for shared rule evaluation', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup();
    const response = await ctx.call(event({
      action: 'category_changed',
      correctedFields: { categorySlug: 'Dining', merchant: 'Cafe  Central' },
    }));
    assert.equal(response.body.learned, false);
    const storedEvent = ctx.queries.find(({ sql }) => sql.includes('INSERT INTO public.sms_learning_feedback_events'));
    assert.ok(storedEvent);
    assert.equal(storedEvent.params[8], 'CAFE CENTRAL');
    assert.equal(storedEvent.params[9], 'dining');
    assert.equal(ctx.queries.some(({ sql }) => sql.includes('INSERT INTO public.sms_learning_examples')), false);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('a spend category outside the canonical taxonomy abstains instead of being stored', async () => {
  const prior = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const ctx = setup();
    const response = await ctx.call(event({
      action: 'category_changed',
      correctedFields: { categorySlug: 'Food_Dining', merchant: 'Cafe  Central' },
    }));
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'category_feedback_unsupported_slug');
    const storedEvent = ctx.queries.find(({ sql }) => sql.includes('INSERT INTO public.sms_learning_feedback_events'));
    assert.equal(storedEvent.params[9], null);
  } finally {
    if (prior === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = prior;
  }
});

test('AI auto-resolution creates only an admin proposal under v2 consent', async () => {
  const previous = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const api = setup({ policyVersion: 'sms-shared-learning-v2' });
    const response = await api.call(event({
      action: 'ai_auto_resolved',
      consentPolicyVersion: 'sms-shared-learning-v2',
      sampleBody: 'Rs. {n} paid at Cafe restaurant on {n}-{n}-{n}',
      originalDecision: {
        kind: 'posted_movement',
        fields: { merchant: 'Cafe', categorySlug: 'dining' },
      },
      aiConfidenceScore: 0.96,
    }));
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'admin_review_pending');
    const proposal = api.queries.find(({ sql }) => sql.includes('INSERT INTO public.sms_ai_learning_proposals'));
    assert.ok(proposal);
    assert.equal(proposal.params[7], 'Rs. {n} paid at {MERCHANT} restaurant on {n}-{n}-{n}');
    assert.equal(proposal.params[8], '{AMOUNT} paid at {MERCHANT} restaurant on {DATE}');
    assert.equal(proposal.params[16], 'AD-HDFCBK');
    assert.equal(proposal.params[17], 'RESTAURANT');
    assert.equal(api.queries.some(({ sql }) => sql.includes('INSERT INTO public.sms_learning_examples')), false);
  } finally {
    if (previous === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = previous;
  }
});

test('AI admin evidence masks personal names outside greetings', async () => {
  const previous = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  try {
    const api = setup({ policyVersion: 'sms-shared-learning-v2' });
    const response = await api.call(event({
      action: 'ai_auto_resolved',
      consentPolicyVersion: 'sms-shared-learning-v2',
      sampleBody: 'Sujay Shantaram Kurtigkar paid Rs. {n} to Swiggy',
      originalDecision: { kind: 'posted_movement', fields: { merchant: 'Swiggy' } },
      aiConfidenceScore: 0.96,
    }));
    assert.equal(response.status, 200);
    const proposal = api.queries.find(({ sql }) => sql.includes('INSERT INTO public.sms_ai_learning_proposals'));
    assert.ok(proposal);
    assert.equal(proposal.params[7].includes('Sujay'), false);
    assert.equal(proposal.params[7].includes('Shantaram'), false);
    assert.equal(proposal.params[7].includes('Kurtigkar'), false);
  } finally {
    if (previous === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
    else process.env.SMS_LEARNING_HMAC_KEY = previous;
  }
});

function setupAdminRoutes() {
  const handlers = new Map();
  const queries = [];
  const proposalId = '22222222-2222-4222-8222-222222222222';
  const app = {
    post: (path, _auth, handler) => handlers.set(`POST ${path}`, handler),
    get: (path, _auth, handler) => handlers.set(`GET ${path}`, handler),
  };
  const client = {
    async query(sql, params = []) {
      const normalized = sql.replace(/\s+/g, ' ').trim();
      queries.push({ sql: normalized, params });
      if (normalized.includes('SELECT p.proposal_id')) {
        return { rows: [{
          proposal_id: proposalId,
          redacted_pattern: '{AMOUNT} paid at {MERCHANT}',
          template_text: '{AMOUNT} paid at {MERCHANT}',
          fact_family: 'posted_movement',
          resolved_kind: 'transaction',
          proposed_fields: { merchant: 'TEST SHOP' },
          ai_score: 0.96,
          status: 'pending',
          created_at: '2026-10-27T10:00:00Z',
          reviewed_at: null,
          review_reason: null,
        }], rowCount: 1 };
      }
      if (normalized.includes('SELECT profile_id FROM public.sms_ai_learning_proposals')) {
        return { rows: [{ profile_id: '33333333-3333-4333-8333-333333333333' }], rowCount: 1 };
      }
      if (normalized.includes('SELECT status, template_text, proposed_fields')) {
        return { rows: [{
          status: 'pending',
          template_text: '{AMOUNT} paid at {MERCHANT}',
          proposed_fields: { merchant: 'TEST SHOP' },
        }], rowCount: 1 };
      }
      if (normalized.includes('FROM public.user_consents')) {
        return { rows: [{
          granted: true,
          policy_version: 'sms-shared-learning-v2',
          granted_at: '2026-10-27T09:00:00Z',
        }], rowCount: 1 };
      }
      return { rows: [], rowCount: 1 };
    },
  };
  registerSmsLearningFeedbackRoute(app, {
    requireAuth: (_req, _res, next) => next(),
    requireAdmin: (_req, _res, next) => next(),
    withUserClient: (_userId, run) => run(client),
  });
  const call = async (method, path, body = {}) => {
    let status;
    let resultBody;
    const res = {
      status(code) { status = code; return this; },
      json(value) { resultBody = value; return this; },
    };
    await handlers.get(`${method} ${path}`)({ userId: 'admin-1', body }, res);
    return { status, body: resultBody };
  };
  return { call, queries, proposalId };
}

test('admin AI proposal list returns redacted evidence only', async () => {
  const api = setupAdminRoutes();
  const response = await api.call('GET', '/admin/sms-learning/ai-proposals');
  assert.equal(response.status, 200);
  assert.equal(response.body.proposals[0].redactedPattern, '{AMOUNT} paid at {MERCHANT}');
  assert.equal(response.body.proposals[0].proposedRule.fields.merchant, 'TEST SHOP');
});

test('admin AI proposal review records the exact proposal id in the audit log', async () => {
  const api = setupAdminRoutes();
  const response = await api.call('POST', '/admin/sms-learning/ai-proposals/review', {
    proposalId: api.proposalId,
    decision: 'approved',
    reason: 'Reviewed evidence and approved',
  });
  assert.equal(response.status, 200);
  const audit = api.queries.find(({ sql }) => sql.includes('INSERT INTO admin_audit_log'));
  assert.ok(audit);
  assert.equal(audit.params[1], api.proposalId);
  assert.equal(audit.params[3], 'Reviewed evidence and approved');
});
