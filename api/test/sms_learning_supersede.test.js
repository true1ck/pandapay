const test = require('node:test');
const assert = require('node:assert/strict');
const { registerSmsLearningFeedbackRoute } = require('../src/sms_learning_feedback_route');

const PROFILE = '11111111-1111-4111-8111-111111111111';
const ADMIN = '99999999-9999-4999-8999-999999999999';
const AI_EVENT = '22222222-2222-4222-8222-222222222222';
const USER_EVENT = '33333333-3333-4333-8333-333333333333';
const PROPOSAL_ID = '44444444-4444-4444-8444-444444444444';
const SOURCE_KEY = 'a'.repeat(64);
const GRANTED_AT = '2026-10-26T10:00:00.000Z';
const POLICY_V2 = 'sms-shared-learning-v2';

/**
 * Stateful stand-in for the two tables L13 couples. It emulates the three DB
 * guarantees the migration adds: the before-insert trigger that drops an AI
 * proposal once explicit feedback exists, the idempotent (profile, event)
 * conflict target, and pandapay.sms_supersede_ai_proposals() demoting only
 * pending/approved rows. Ordering of issued statements is recorded so the
 * tests can assert the supersede happens inside the same transaction, after
 * the user's correction was persisted.
 */
function createDatabase({ consentGranted = true, policyVersion = POLICY_V2,
  adminIds = new Set([ADMIN]) } = {}) {
  const state = {
    proposals: [],
    feedbackEvents: [],
    examples: [],
    audit: [],
    order: [],
  };

  const client = {
    async query(sql, params = []) {
      const q = sql.replace(/\s+/g, ' ').trim();
      state.order.push(q);

      if (q.includes('pg_advisory_xact_lock')) return { rows: [{ lock: null }], rowCount: 1 };

      if (q.includes('AS matches')) {
        const same = new Date(params[0]).getTime() === new Date(params[1]).getTime();
        return { rows: [{ matches: same }], rowCount: 1 };
      }

      if (q.includes('FROM public.user_consents')) {
        if (!consentGranted) return { rows: [], rowCount: 0 };
        return {
          rows: [{ granted: true, policy_version: policyVersion, granted_at: GRANTED_AT }],
          rowCount: 1,
        };
      }

      if (q.startsWith('SELECT 1 FROM public.sms_learning_feedback_events')) {
        const [profileId, sourceKeyHash] = params;
        const hit = state.feedbackEvents.some((row) => row.profile_id === profileId &&
          row.source_key_hash === sourceKeyHash);
        return { rows: hit ? [{ exists: 1 }] : [], rowCount: hit ? 1 : 0 };
      }

      if (q.includes('SELECT learned, learning_reason FROM public.sms_learning_feedback_events')) {
        const [profileId, eventId] = params;
        const hit = state.feedbackEvents.find((row) => row.profile_id === profileId &&
          row.event_id === eventId);
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

      if (q.includes('INSERT INTO public.sms_learning_feedback_events')) {
        state.feedbackEvents.push({
          profile_id: params[0], event_id: params[1], source_key_hash: params[2],
          action: params[4], merchant_key: params[8], category_slug: params[9],
          corrected_fields: params[13], learned: params[15],
          learning_reason: params[16], redacted_pattern: params[17],
        });
        return { rows: [], rowCount: 1 };
      }

      if (q.includes('pandapay.sms_supersede_ai_proposals')) {
        const [sourceKeyHash, eventId] = params;
        let superseded = 0;
        for (const proposal of state.proposals) {
          if (proposal.source_key_hash === sourceKeyHash &&
              ['pending', 'approved'].includes(proposal.status)) {
            proposal.status = 'superseded';
            proposal.superseded_reason = 'explicit_user_feedback';
            proposal.superseded_by_event_id = eventId;
            superseded += 1;
          }
        }
        return { rows: [{ superseded_count: superseded }], rowCount: 1 };
      }

      if (q.includes('INSERT INTO public.sms_ai_learning_proposals')) {
        const proposal = {
          proposal_id: PROPOSAL_ID,
          profile_id: params[0], event_id: params[1], source_key_hash: params[2],
          sender_fingerprint: params[3], redacted_pattern: params[7],
          template_text: params[8], fact_family: params[10], resolved_kind: params[11],
          proposed_fields: JSON.parse(params[12]), status: 'pending',
        };
        // before-insert trigger: explicit feedback for this source wins.
        if (state.feedbackEvents.some((row) => row.profile_id === proposal.profile_id &&
            row.source_key_hash === proposal.source_key_hash)) {
          return { rows: [], rowCount: 0 };
        }
        if (state.proposals.some((row) => row.profile_id === proposal.profile_id &&
            row.event_id === proposal.event_id)) {
          return { rows: [], rowCount: 0 };
        }
        state.proposals.push(proposal);
        return { rows: [{ event_id: proposal.event_id }], rowCount: 1 };
      }

      if (q.includes('SELECT profile_id FROM public.sms_ai_learning_proposals')) {
        const hit = state.proposals.find((row) => row.proposal_id === params[0]);
        return { rows: hit ? [{ profile_id: hit.profile_id }] : [], rowCount: hit ? 1 : 0 };
      }

      if (q.includes('SELECT status, template_text, proposed_fields')) {
        const hit = state.proposals.find((row) => row.proposal_id === params[0]);
        return {
          rows: hit ? [{
            status: hit.status, template_text: hit.template_text,
            proposed_fields: hit.proposed_fields, source_key_hash: hit.source_key_hash,
            profile_id: hit.profile_id,
          }] : [],
          rowCount: hit ? 1 : 0,
        };
      }

      if (q.includes('UPDATE public.sms_ai_learning_proposals')) {
        const [proposalId, decision] = params;
        const hit = state.proposals.find((row) => row.proposal_id === proposalId);
        if (hit) hit.status = decision;
        return { rows: [], rowCount: hit ? 1 : 0 };
      }

      if (q.includes('INSERT INTO admin_audit_log')) {
        state.audit.push({ entity_id: params[1], reason: params[3] });
        return { rows: [], rowCount: 1 };
      }

      return { rows: [], rowCount: 0 };
    },
  };

  const handlers = new Map();
  const middleware = new Map();
  const app = {
    post: (path, auth, handler) => { handlers.set(`POST ${path}`, handler); middleware.set(`POST ${path}`, auth); },
    get: (path, auth, handler) => { handlers.set(`GET ${path}`, handler); middleware.set(`GET ${path}`, auth); },
  };
  // Real middleware behaviour: Express runs the guard before the handler and
  // a denial short-circuits, so the handler must never see the request.
  const requireAuth = (_req, _res, next) => next();
  const requireAdmin = (req, res, next) => (adminIds.has(req.userId)
    ? next()
    : res.status(403).json({ error: 'admin_required' }));
  registerSmsLearningFeedbackRoute(app, {
    requireAuth,
    requireAdmin,
    withUserClient: (_userId, run) => run(client),
  });

  const call = async (method, path, userId, body = {}) => {
    let status;
    let responseBody;
    const res = {
      status(code) { status = code; return this; },
      json(value) { responseBody = value; return this; },
    };
    // Resolve on either next() or a denial response, since a rejecting guard
    // never calls next().
    let proceeded = false;
    await new Promise((resolve) => {
      const respond = res.json.bind(res);
      res.json = (value) => { const out = respond(value); resolve(); return out; };
      middleware.get(`${method} ${path}`)({ userId, body }, res, () => {
        proceeded = true;
        resolve();
      });
    });
    if (proceeded) await handlers.get(`${method} ${path}`)({ userId, body }, res);
    return { status, body: responseBody, handled: proceeded };
  };

  return { state, call, middleware, requireAdmin, requireAuth };
}

const aiEvent = (overrides = {}) => ({
  eventId: AI_EVENT,
  sourceKey: SOURCE_KEY,
  action: 'ai_auto_resolved',
  sender: 'AD-HDFCBK',
  sampleBody: 'Rs. {n} paid at Swiggy on {n}-{n}-{n}',
  resolvedKind: 'transaction',
  originalDecision: {
    kind: 'posted_movement',
    fields: { amountInr: 250, merchant: 'Swiggy', categorySlug: 'dining' },
  },
  consentPurpose: 'sms_shared_learning',
  consentPolicyVersion: POLICY_V2,
  consentGrantedAt: GRANTED_AT,
  aiConfidenceScore: 0.96,
  ...overrides,
});

const explicitEvent = (overrides = {}) => ({
  eventId: USER_EVENT,
  sourceKey: SOURCE_KEY,
  action: 'edited',
  sender: 'AD-HDFCBK',
  sampleBody: 'Rs. {n} paid at Swiggy on {n}-{n}-{n}',
  resolvedKind: 'transaction',
  originalDecision: {
    kind: 'posted_movement',
    fields: { amountInr: 250, merchant: 'Swiggy', occurredAt: '2026-10-25T10:00:00Z' },
  },
  correctedFields: { amountInr: 750, merchant: 'Swiggy' },
  occurredAt: '2026-10-25T10:00:00Z',
  consentPurpose: 'sms_shared_learning',
  consentPolicyVersion: POLICY_V2,
  consentGrantedAt: GRANTED_AT,
  ...overrides,
});

const uploadAi = (db, overrides) => db.call('POST', '/sms/learning-feedback', PROFILE, aiEvent(overrides));
const uploadExplicit = (db, overrides) =>
  db.call('POST', '/sms/learning-feedback', PROFILE, explicitEvent(overrides));
const approveProposal = (db, decision = 'approved') =>
  db.call('POST', '/admin/sms-learning/ai-proposals/review', ADMIN, {
    proposalId: PROPOSAL_ID, decision, reason: 'Evidence reviewed against redacted sample',
  });

function withHmacKey(run) {
  const previous = process.env.SMS_LEARNING_HMAC_KEY;
  process.env.SMS_LEARNING_HMAC_KEY = 'x'.repeat(48);
  return Promise.resolve()
    .then(run)
    .finally(() => {
      if (previous === undefined) delete process.env.SMS_LEARNING_HMAC_KEY;
      else process.env.SMS_LEARNING_HMAC_KEY = previous;
    });
}

test('L13: explicit edit after an AI upload supersedes the pending proposal', () => withHmacKey(async () => {
  const db = createDatabase();
  assert.equal((await uploadAi(db)).body.learningReason, 'admin_review_pending');
  assert.equal(db.state.proposals[0].status, 'pending');

  const edited = await uploadExplicit(db);
  assert.equal(edited.status, 200);
  assert.equal(edited.body.recorded, true);
  assert.equal(db.state.proposals[0].status, 'superseded');
  assert.equal(db.state.proposals[0].superseded_by_event_id, USER_EVENT);
  // The row is retained for audit rather than deleted.
  assert.equal(db.state.proposals.length, 1);
}));

test('L13: the corrected transaction is persisted before the proposal is demoted', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  await uploadExplicit(db);

  const insertedExample = db.state.order.findIndex((sql) => sql.includes('INSERT INTO public.sms_learning_examples'));
  const insertedEvent = db.state.order.findIndex((sql) => sql.includes('INSERT INTO public.sms_learning_feedback_events'));
  const superseded = db.state.order.findIndex((sql) => sql.includes('pandapay.sms_supersede_ai_proposals'));
  assert.ok(insertedExample > -1, 'user correction must still produce a learning example');
  assert.ok(insertedEvent > insertedExample, 'feedback event is stored after the example');
  assert.ok(superseded > insertedEvent, 'supersede runs last, inside the same transaction');
  assert.equal(db.state.examples[0].fact_family, 'posted_movement');
  assert.equal(JSON.parse(db.state.feedbackEvents[0].corrected_fields).amountInr, 750);
}));

test('L13: every explicit action supersedes an approved AI proposal', () => withHmacKey(async () => {
  for (const action of ['confirmed', 'edited', 'category_changed', 'dismissed', 'moved_to_review']) {
    const db = createDatabase();
    await uploadAi(db);
    assert.equal((await approveProposal(db)).status, 200);
    assert.equal(db.state.proposals[0].status, 'approved');

    const overrides = action === 'category_changed'
      ? { action, correctedFields: { categorySlug: 'groceries', merchant: 'Swiggy' } }
      : { action };
    const response = await uploadExplicit(db, overrides);
    assert.equal(response.status, 200, `${action} should be acknowledged`);
    assert.equal(db.state.proposals[0].status, 'superseded',
      `${action} must demote an already-approved AI proposal`);
  }
}));

test('L13: a delayed AI upload cannot recreate a proposal after explicit feedback', () => withHmacKey(async () => {
  const db = createDatabase();
  const edited = await uploadExplicit(db);
  assert.equal(edited.body.recorded, true);

  const late = await uploadAi(db);
  assert.equal(late.status, 200);
  assert.deepEqual(late.body, {
    acknowledged: true, recorded: false, learned: false,
    learningReason: 'superseded_by_user_feedback',
  });
  assert.equal(db.state.proposals.length, 0);
}));

test('L13: a retried AI upload stays idempotent and never votes twice', () => withHmacKey(async () => {
  const db = createDatabase();
  assert.equal((await uploadAi(db)).body.learningReason, 'admin_review_pending');
  const retry = await uploadAi(db);
  assert.equal(retry.body.learningReason, 'duplicate');
  assert.equal(retry.body.recorded, false);
  assert.equal(db.state.proposals.length, 1);
}));

test('L13: a retried explicit upload neither duplicates the correction nor re-demotes', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  await uploadExplicit(db);
  const supersedeCallsBefore = db.state.order.filter((sql) => sql.includes('sms_supersede_ai_proposals')).length;

  const retry = await uploadExplicit(db);
  assert.equal(retry.body.recorded, false);
  assert.equal(retry.body.learningReason, 'recorded');
  assert.equal(db.state.feedbackEvents.length, 1);
  assert.equal(db.state.examples.length, 1);
  const supersedeCallsAfter = db.state.order.filter((sql) => sql.includes('sms_supersede_ai_proposals')).length;
  assert.equal(supersedeCallsAfter, supersedeCallsBefore, 'a duplicate retry returns before superseding');
}));

test('L13: either arrival order ends with the AI proposal ineligible', () => withHmacKey(async () => {
  // The device outbox has no total order (backoff can overtake, dismissals ride
  // a separate queue), so both orders must converge on the same end state.
  const aiFirst = createDatabase();
  await uploadAi(aiFirst);
  await uploadExplicit(aiFirst);

  const userFirst = createDatabase();
  await uploadExplicit(userFirst);
  await uploadAi(userFirst);

  for (const [label, db] of [['ai-first', aiFirst], ['user-first', userFirst]]) {
    const eligible = db.state.proposals.filter((row) => ['pending', 'approved'].includes(row.status));
    assert.equal(eligible.length, 0, `${label} left an eligible AI proposal`);
    assert.equal(db.state.feedbackEvents.length, 1, `${label} lost the explicit correction`);
  }
  assert.equal(aiFirst.state.proposals.length, 1);
  assert.equal(userFirst.state.proposals.length, 0);
}));

test('L13: both uploads serialize on the per-profile advisory lock before any read', () => withHmacKey(async () => {
  for (const payload of [aiEvent(), explicitEvent()]) {
    const db = createDatabase();
    await db.call('POST', '/sms/learning-feedback', PROFILE, payload);
    const consentLock = db.state.order.findIndex((sql) => sql.includes('pg_advisory_xact_lock'));
    const firstRead = db.state.order.findIndex((sql) => sql.includes('FROM public.user_consents'));
    assert.equal(consentLock, 0, 'the profile lock must be the first statement');
    assert.ok(firstRead > consentLock, 'consent is read only after the lock is held');
  }
}));

test('L13: admin cannot approve a proposal the user already superseded', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  await uploadExplicit(db);

  const review = await approveProposal(db);
  assert.equal(review.status, 409);
  assert.equal(review.body.error, 'proposal_superseded_by_user_feedback');
  assert.equal(db.state.proposals[0].status, 'superseded');
  assert.equal(db.state.audit.length, 0, 'a denied review must not write an approval audit row');
}));

test('L13: admin cannot approve a superseded row even if its status was never demoted', () => withHmacKey(async () => {
  // Pre-backfill rows: the review route re-checks explicit feedback directly.
  const db = createDatabase();
  await uploadAi(db);
  db.state.feedbackEvents.push({
    profile_id: PROFILE, event_id: USER_EVENT, source_key_hash: SOURCE_KEY, action: 'edited',
  });

  const review = await approveProposal(db);
  assert.equal(review.status, 409);
  assert.equal(review.body.error, 'proposal_superseded_by_user_feedback');
  assert.equal(db.state.audit.length, 0);
}));

test('L13: a superseded proposal keeps no approved status an admin review can restore', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  await uploadExplicit(db);
  for (const decision of ['approved', 'rejected']) {
    const review = await approveProposal(db, decision);
    assert.equal(review.status, 409);
    assert.equal(db.state.proposals[0].status, 'superseded');
  }
}));

test('L13: consent revocation stops both explicit feedback and AI proposals', () => withHmacKey(async () => {
  for (const payload of [explicitEvent(), aiEvent()]) {
    const db = createDatabase({ consentGranted: false });
    const response = await db.call('POST', '/sms/learning-feedback', PROFILE, payload);
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'consent_disabled');
    assert.equal(db.state.feedbackEvents.length, 0);
    assert.equal(db.state.proposals.length, 0);
    assert.equal(db.state.examples.length, 0);
  }
}));

test('L13: admin AI proposal routes are guarded by requireAdmin, not requireAuth', () => withHmacKey(async () => {
  const db = createDatabase();
  assert.equal(db.middleware.get('GET /admin/sms-learning/ai-proposals'), db.requireAdmin);
  assert.equal(db.middleware.get('POST /admin/sms-learning/ai-proposals/review'), db.requireAdmin);
  assert.equal(db.middleware.get('POST /sms/learning-feedback'), db.requireAuth);
}));

test('L13: a non-admin identity cannot reach the review handler', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  await approveProposal(db);
  assert.equal(db.state.proposals[0].status, 'approved');

  // The proposal owner is an ordinary user: they must not be able to review
  // their own AI proposal, approve it, or reverse an approval.
  for (const decision of ['approved', 'rejected']) {
    const response = await db.call('POST', '/admin/sms-learning/ai-proposals/review', PROFILE, {
      proposalId: PROPOSAL_ID, decision, reason: 'self-approving my own AI evidence',
    });
    assert.equal(response.status, 403);
    assert.equal(response.body.error, 'admin_required');
    assert.equal(response.handled, false, 'the guard must short-circuit before the handler');
  }
  const list = await db.call('GET', '/admin/sms-learning/ai-proposals', PROFILE);
  assert.equal(list.status, 403);
  assert.equal(list.handled, false);

  assert.equal(db.state.proposals[0].status, 'approved');
  assert.equal(db.state.audit.length, 1, 'only the real admin review is audited');
  assert.equal(db.state.audit[0].entity_id, PROPOSAL_ID);
}));

test('L13: review input validation rejects a malformed proposal review', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  const short = await db.call('POST', '/admin/sms-learning/ai-proposals/review', ADMIN, {
    proposalId: PROPOSAL_ID, decision: 'approved', reason: 'ok',
  });
  assert.equal(short.status, 400);
  const badDecision = await db.call('POST', '/admin/sms-learning/ai-proposals/review', ADMIN, {
    proposalId: PROPOSAL_ID, decision: 'published', reason: 'Evidence reviewed against redacted sample',
  });
  assert.equal(badDecision.status, 400);
  assert.equal(db.state.proposals[0].status, 'pending');
}));

test('L13: evidence approval never publishes a rule to devices', () => withHmacKey(async () => {
  const db = createDatabase();
  await uploadAi(db);
  assert.equal((await approveProposal(db)).status, 200);
  // Approval only flips the evidence row; no bundle, candidate or category
  // approval record is written by this route.
  assert.equal(db.state.proposals[0].status, 'approved');
  assert.equal(db.state.order.some((sql) => sql.includes('sms_rule_bundles')), false);
  assert.equal(db.state.order.some((sql) => sql.includes('sms_rule_candidates')), false);
  assert.equal(db.state.order.some((sql) => sql.includes('sms_category_rule_approvals')), false);
  assert.equal(db.state.order.some((sql) => sql.includes('sms_parser_candidate_approvals')), false);
}));

test('privacy: a residual all-caps name blocks the AI proposal instead of leaking it', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadAi(db, {
    sampleBody: 'Rs. {n} credited RAJESH KUMAR acct {n} on {n}-{n}-{n}',
    originalDecision: { kind: 'posted_movement', fields: { amountInr: 250 } },
  });
  assert.equal(response.status, 200);
  assert.deepEqual(response.body, {
    acknowledged: true, recorded: false, learned: false, learningReason: 'unsafe_evidence',
  });
  assert.equal(db.state.proposals.length, 0);
}));

test('privacy: a surviving UPI handle blocks the AI proposal', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadAi(db, {
    sampleBody: 'Rs. {n} sent to sujay.k@okaxis on {n}-{n}-{n}',
    originalDecision: { kind: 'posted_movement', fields: { amountInr: 250 } },
  });
  assert.equal(response.body.learningReason, 'unsafe_evidence');
  assert.equal(db.state.proposals.length, 0);
}));

test('privacy: a peer-to-peer sender that reads as a personal name is blocked', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadAi(db, { sender: 'Ramesh Iyer' });
  assert.equal(response.body.learningReason, 'unsafe_evidence');
  assert.equal(db.state.proposals.length, 0);
}));

test('privacy: an all-caps bank alert is not over-blocked by the name guard', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadAi(db, {
    sampleBody: 'HDFC BANK ALERT RS {n} DEBITED FROM YOUR ACCOUNT ON {n}-{n}-{n}',
    originalDecision: { kind: 'posted_movement', fields: { amountInr: 250 } },
  });
  assert.equal(response.status, 200);
  assert.equal(response.body.learningReason, 'admin_review_pending');
  assert.equal(db.state.proposals.length, 1);
}));

test('privacy: explicit feedback keeps its correction but withholds an unsafe sample', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadExplicit(db, {
    sampleBody: 'Rs. {n} credited RAJESH KUMAR on {n}-{n}-{n}',
  });
  assert.equal(response.status, 200);
  assert.equal(response.body.recorded, true);
  assert.equal(response.body.learned, true, 'the correction still trains locally-shared evidence');
  assert.equal(db.state.feedbackEvents[0].redacted_pattern, null);
  assert.equal(JSON.parse(db.state.feedbackEvents[0].corrected_fields).amountInr, 750);
}));

test('privacy: a safe sample still produces admin-visible redacted evidence', () => withHmacKey(async () => {
  const db = createDatabase();
  const response = await uploadExplicit(db, {
    action: 'category_changed',
    correctedFields: { categorySlug: 'groceries', merchant: 'Swiggy' },
  });
  assert.equal(response.status, 200);
  // The explicit path keeps the classified merchant literal: it is the category
  // evidence the admin reviews, and it is business data, not personal data.
  assert.equal(db.state.feedbackEvents[0].redacted_pattern,
    'Rs. {n} paid at Swiggy on {n}-{n}-{n}');
  assert.equal(db.state.feedbackEvents[0].merchant_key, 'SWIGGY');
  assert.equal(db.state.feedbackEvents[0].category_slug, 'groceries');
}));

test('privacy: OTP-bearing messages stay excluded from every shared table', () => withHmacKey(async () => {
  for (const action of ['edited', 'ai_auto_resolved']) {
    const db = createDatabase();
    const response = await db.call('POST', '/sms/learning-feedback', PROFILE, {
      ...(action === 'ai_auto_resolved' ? aiEvent() : explicitEvent()),
      action,
      sampleBody: 'Your OTP verification code is 482913, valid for {n} minutes',
    });
    assert.equal(response.status, 200);
    assert.equal(response.body.learningReason, 'sensitive_sms');
    assert.equal(db.state.feedbackEvents.length, 0);
    assert.equal(db.state.proposals.length, 0);
    assert.equal(db.state.order.length, 0, 'sensitive content must not touch the database');
  }
}));
