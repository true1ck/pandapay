const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const { Client } = require('pg');

// End-to-end verification against a real PostgreSQL instance. The request path
// runs through the production `withUserClient`, so the API connects as app_user
// and every row-level security policy, SECURITY DEFINER helper and trigger added
// for L13 is exercised for real rather than emulated.
//
//   PANDAPAY_E2E_ADMIN_DATABASE_URL  superuser, used only to stage and clean up
//   PANDAPAY_E2E_APP_DATABASE_URL    app_user, the role the API actually uses
//
// Both must point at a disposable database. Without them the test is skipped,
// so `npm test` never touches a database that was not explicitly provided.
const adminUrl = process.env.PANDAPAY_E2E_ADMIN_DATABASE_URL;
const appUrl = process.env.PANDAPAY_E2E_APP_DATABASE_URL;

const MERCHANT = 'Supersede Grocers';
const MERCHANT_KEY = 'SUPERSEDE GROCERS';
const UNAPPROVED_KEY = 'E2E UNAPPROVED SHOP';
const CATEGORY = 'groceries';
const POLICY = 'sms-shared-learning-v2';
const GRANTED_AT = '2026-10-26T10:00:00.000Z';
const HMAC_KEY = 'e2e_shared_learning_key_0123456789abcdef';
const hex64 = (seed) => crypto.createHash('sha256').update(seed).digest('hex');

test('end-to-end: AI evidence, explicit correction, and device delivery gates',
  { skip: !adminUrl || !appUrl ? 'set PANDAPAY_E2E_ADMIN_DATABASE_URL and PANDAPAY_E2E_APP_DATABASE_URL' : false },
  async (t) => {
    let admin;
    try {
      admin = new Client({ connectionString: adminUrl, connectionTimeoutMillis: 5000 });
      await admin.connect();
    } catch (err) {
      t.skip(`staging connection failed: ${err.message}`);
      return;
    }
    const role = await admin.query('SELECT current_user AS role');
    assert.notEqual(role.rows[0].role, 'app_user',
      'staging must not run as app_user; it needs superuser to write fixtures');

    // The API modules read their connection string at require time, so the
    // app_user URL has to be in the environment before they are loaded.
    // src/config.js also loads dotenv, whose banner goes to stdout — which is
    // the test runner's IPC channel. Under a parallel `node --test test/*.js`
    // run that stray line corrupts the parent's deserialization and fails this
    // file before it does any work, so silence it.
    process.env.DOTENV_CONFIG_QUIET = 'true';
    process.env.API_DATABASE_URL = appUrl;
    process.env.SMS_LEARNING_HMAC_KEY = HMAC_KEY;
    const { withUserClient, pool } = require('../src/db');
    const { registerSmsLearningFeedbackRoute } = require('../src/sms_learning_feedback_route');
    const { registerSmsRuleBundleRoutes } = require('../src/sms_rule_bundle');

    const appRole = await withUserClient(null, async (client) => (
      await client.query('SELECT current_user AS role')).rows[0].role);
    assert.equal(appRole, 'app_user', 'the request path must run as app_user for RLS to apply');

    const userA = crypto.randomUUID();
    const userB = crypto.randomUUID();
    const adminUser = crypto.randomUUID();
    const fillers = Array.from({ length: 9 }, () => crypto.randomUUID());
    const allProfiles = [userA, userB, adminUser, ...fillers];
    const sourceA = hex64(`e2e-source-a-${userA}`);
    const sourceUnapproved = hex64(`e2e-source-unapproved-${fillers[0]}`);

    const handlers = new Map();
    const app = {
      get: (path, ...chain) => handlers.set(`GET ${path}`, chain),
      post: (path, ...chain) => handlers.set(`POST ${path}`, chain),
    };
    // requireAuth in index.js validates a bearer session before setting
    // req.userId. Session validation is auth infrastructure, not part of the
    // learning pipeline under test, so the identity is supplied directly.
    const requireAuth = (_req, _res, next) => next();
    // requireAdmin is reproduced exactly: index.js:474 asks the database, under
    // the caller's own RLS context, whether that identity is an active admin.
    const requireAdmin = async (req, res, next) => {
      const isAdmin = await withUserClient(req.userId, async (client) => (
        await client.query('SELECT pandapay.is_admin() AS is_admin')).rows[0].is_admin);
      if (!isAdmin) return res.status(403).json({ error: 'Admin access required' });
      return next();
    };
    registerSmsLearningFeedbackRoute(app, { requireAuth, requireAdmin, withUserClient });
    registerSmsRuleBundleRoutes(app, { requireAuth, requireAdmin, withUserClient });

    const call = async (method, path, userId, body = {}, query = {}) => {
      const chain = handlers.get(`${method} ${path}`);
      assert.ok(chain, `route ${method} ${path} was registered`);
      let status = 200;
      let responseBody;
      let responded = false;
      const res = {
        status(code) { status = code; return this; },
        json(value) { responseBody = value; responded = true; return this; },
      };
      const req = { userId, body, query };
      // Walk the chain the way Express does. A guard that answers the request
      // never calls next(), so the handler below it must not run.
      for (const middleware of chain.slice(0, -1)) {
        await middleware(req, res, () => {});
        if (responded) return { status, body: responseBody, handled: false };
      }
      await chain[chain.length - 1](req, res);
      return { status, body: responseBody, handled: true };
    };
    const feedback = (userId, payload) => call('POST', '/sms/learning-feedback', userId, payload);
    const deviceSync = (userId) => call('GET', '/sms/rules/active', userId, {}, {});
    const consentBlock = {
      consentPurpose: 'sms_shared_learning',
      consentPolicyVersion: POLICY,
      consentGrantedAt: GRANTED_AT,
    };

    const cleanup = async () => {
      // Fixture rows must not outlive the run, even on assertion failure.
      await admin.query(
        `DELETE FROM public.sms_rule_candidate_assignments WHERE profile_id = ANY($1::uuid[])`,
        [allProfiles]);
      for (const table of ['sms_learning_examples', 'sms_learning_feedback_events',
        'sms_ai_learning_proposals']) {
        await admin.query(`DELETE FROM public.${table} WHERE profile_id = ANY($1::uuid[])`,
          [allProfiles]);
      }
      await admin.query(
        `DELETE FROM public.admin_audit_log WHERE admin_id = ANY($1::uuid[])`, [allProfiles]);
      await admin.query(
        `DELETE FROM public.sms_category_rule_approvals WHERE merchant_key = ANY($1::text[])`,
        [[MERCHANT_KEY, UNAPPROVED_KEY]]);
      await admin.query(`DELETE FROM public.user_consents WHERE profile_id = ANY($1::uuid[])`,
        [allProfiles]);
      await admin.query(`DELETE FROM public.admin_users WHERE id = ANY($1::uuid[])`, [allProfiles]);
      await admin.query(`DELETE FROM public.profiles WHERE id = ANY($1::uuid[])`, [allProfiles]);
    };

    try {
      // ---- staging -------------------------------------------------------
      for (const id of allProfiles) {
        await admin.query(
          `INSERT INTO public.profiles (id, contributions_opt_in) VALUES ($1, false)`, [id]);
        await admin.query(
          `INSERT INTO public.user_consents
             (profile_id, purpose, policy_version, granted, granted_at, source_screen)
           VALUES ($1, 'sms_shared_learning', $2, true, $3, 'e2e')`,
          [id, POLICY, GRANTED_AT]);
      }
      await admin.query(
        `INSERT INTO public.admin_users (id, email, role, is_active)
         VALUES ($1, $2, 'owner', true)`,
        [adminUser, `e2e-${adminUser}@example.com`]);

      // ---- 1. AI auto-resolution becomes pending admin evidence ----------
      const aiEventId = crypto.randomUUID();
      const aiUpload = await feedback(userA, {
        eventId: aiEventId,
        sourceKey: sourceA,
        action: 'ai_auto_resolved',
        sender: 'AD-E2EBNK',
        sampleBody: `Rs. 250 paid at ${MERCHANT} on 25-10-2026`,
        resolvedKind: 'transaction',
        originalDecision: {
          kind: 'posted_movement',
          fields: {
            amountInr: 250, merchant: MERCHANT, categorySlug: CATEGORY,
            occurredAt: '2026-10-25T10:00:00Z',
          },
        },
        correctedFields: {},
        occurredAt: '2026-10-25T10:00:00Z',
        aiConfidenceScore: 0.96,
        ...consentBlock,
      });
      assert.equal(aiUpload.status, 200);
      assert.equal(aiUpload.body.learningReason, 'admin_review_pending',
        'a consented v2 AI auto-resolution must create admin review evidence');

      const listed = await call('GET', '/admin/sms-learning/ai-proposals', adminUser);
      assert.equal(listed.status, 200);
      const proposalRow = await admin.query(
        `SELECT proposal_id, status, proposed_fields FROM public.sms_ai_learning_proposals
          WHERE profile_id = $1 AND source_key_hash = $2`, [userA, sourceA]);
      assert.equal(proposalRow.rowCount, 1);
      const proposalId = proposalRow.rows[0].proposal_id;
      const listedIds = listed.body.proposals.map((p) => p.proposalId);
      assert.ok(listedIds.includes(proposalId), 'the admin sees the proposal just uploaded');
      const proposal = listed.body.proposals.find((p) => p.proposalId === proposalId);
      assert.equal(proposal.status, 'pending');
      assert.equal(proposal.proposedRule.fields.merchant, MERCHANT);
      assert.equal(proposal.proposedRule.fields.categorySlug, CATEGORY);
      assert.ok(!JSON.stringify(proposal).includes('250'),
        'the amount in admin-visible evidence is generalized, not the real value');

      // Non-admins must not reach the review handler at all.
      const forbidden = await call('POST', '/admin/sms-learning/ai-proposals/review', userB, {
        proposalId, decision: 'approved', reason: 'not an admin trying to approve',
      });
      assert.equal(forbidden.status, 403);
      assert.equal(forbidden.handled, false, 'requireAdmin answered before the handler ran');

      // ---- 2. approving evidence reaches devices only with a rule approval
      const approve = await call('POST', '/admin/sms-learning/ai-proposals/review', adminUser, {
        proposalId, decision: 'approved', reason: 'E2E: evidence looks correct',
      });
      assert.equal(approve.status, 200, `approve failed: ${JSON.stringify(approve.body)}`);

      // Nine more approved proposals from other users reach the ten-user,
      // ninety-percent agreement floor that sms_shared_category_rules() enforces.
      for (const filler of fillers) {
        await admin.query(
          `INSERT INTO public.sms_ai_learning_proposals
             (profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
              issuer_prefix, sender_pattern, redacted_pattern, template_text,
              fact_family, resolved_kind, proposed_fields, ai_score, status,
              reviewed_by, reviewed_at, consent_policy_version, consent_granted_at)
           VALUES ($1,$2,$3,$4,$5,'E2E','AD-E2EBNK',$6,$7,'posted_movement','transaction',
                   $8::jsonb,0.95,'approved',$9,now(),$10,$11)`,
          [filler, crypto.randomUUID(), hex64(`e2e-filler-${filler}`), hex64('e2e-fp'),
            hex64(`e2e-user-${filler}`), 'Rs. {n} paid at {MERCHANT}',
            '{AMOUNT} paid at {MERCHANT}',
            JSON.stringify({ merchant: MERCHANT, categorySlug: CATEGORY, amountInr: 123.45 }),
            adminUser, POLICY, GRANTED_AT]);
      }
      // A second merchant whose proposals stay pending: no rule approval, no
      // ten-user support. It must never reach a device.
      await admin.query(
        `INSERT INTO public.sms_ai_learning_proposals
           (profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
            issuer_prefix, sender_pattern, redacted_pattern, template_text,
            fact_family, resolved_kind, proposed_fields, ai_score, status,
            consent_policy_version, consent_granted_at)
         VALUES ($1,$2,$3,$4,$5,'E2E','AD-E2EBNK','Rs. {n} paid at {MERCHANT}',
                 '{AMOUNT} paid at {MERCHANT}','posted_movement','transaction',$6::jsonb,
                 0.95,'pending',$7,$8)`,
        [fillers[0], crypto.randomUUID(), sourceUnapproved, hex64('e2e-fp'),
          hex64(`e2e-user-${fillers[0]}`),
          JSON.stringify({ merchant: UNAPPROVED_KEY, categorySlug: CATEGORY, amountInr: 123.45 }),
          POLICY, GRANTED_AT]);
      await admin.query(
        `INSERT INTO public.sms_category_rule_approvals
           (merchant_key, category_slug, status, reviewed_by, reason,
            support_count_at_review, agreement_rate_at_review)
         VALUES ($1, $2, 'approved', $3, 'E2E fixture', 10, 1.0)`,
        [MERCHANT_KEY, CATEGORY, adminUser]);

      const before = await deviceSync(userB);
      assert.equal(before.status, 200);
      const beforeKeys = before.body.categoryRules.map((rule) => rule.merchantKey);
      assert.ok(beforeKeys.includes(MERCHANT_KEY),
        'an approved, threshold-meeting category rule is delivered to a second account');
      assert.ok(!beforeKeys.includes(UNAPPROVED_KEY),
        'a pending proposal with no rule approval must never reach a device');
      assert.deepEqual(before.body.candidateRules, [],
        'approving AI evidence alone must not publish a parser rule to devices');

      // ---- 3. the user edits the transaction, outranking the AI -----------
      const editEventId = crypto.randomUUID();
      const edit = await feedback(userA, {
        eventId: editEventId,
        sourceKey: sourceA,
        action: 'edited',
        sender: 'AD-E2EBNK',
        sampleBody: `Rs. 250 paid at ${MERCHANT} on 25-10-2026`,
        resolvedKind: 'transaction',
        originalDecision: {
          kind: 'posted_movement',
          fields: {
            amountInr: 250, merchant: MERCHANT, categorySlug: CATEGORY,
            occurredAt: '2026-10-25T10:00:00Z',
          },
        },
        correctedFields: { amountInr: 750, merchant: MERCHANT },
        occurredAt: '2026-10-25T10:00:00Z',
        ...consentBlock,
      });
      assert.equal(edit.status, 200);
      assert.equal(edit.body.recorded, true);
      assert.equal(edit.body.learned, true, 'the explicit correction must still train locally');

      const afterEdit = await admin.query(
        `SELECT status, superseded_reason, superseded_by_event_id, review_reason
           FROM public.sms_ai_learning_proposals WHERE proposal_id = $1`, [proposalId]);
      assert.equal(afterEdit.rows[0].status, 'superseded',
        'explicit feedback demotes the earlier AI-only proposal');
      assert.equal(afterEdit.rows[0].superseded_by_event_id, editEventId);
      assert.equal(afterEdit.rows[0].review_reason, 'E2E: evidence looks correct',
        'the audit trail keeps the earlier admin decision instead of deleting the row');

      const stored = await withUserClient(userA, async (client) => (
        await client.query(
          `SELECT corrected_fields, learned, learning_reason, redacted_pattern
             FROM public.sms_learning_feedback_events
            WHERE profile_id = $1 AND event_id = $2`, [userA, editEventId])));
      assert.equal(stored.rowCount, 1);
      assert.equal(stored.rows[0].corrected_fields.amountInr, 750,
        'the correction the user made is retained server-side');
      assert.equal(stored.rows[0].learned, true);

      const example = await withUserClient(userA, async (client) => (
        await client.query(
          `SELECT extracted_fields, template_text FROM public.sms_learning_examples
            WHERE profile_id = $1 ORDER BY created_at DESC LIMIT 1`, [userA])));
      assert.equal(example.rowCount, 1, 'the correction still produces a training example');
      assert.equal(example.rows[0].extracted_fields.amountInr, 123.45,
        'shared training evidence generalizes the amount instead of storing 750');

      // ---- 4. a late AI retry cannot resurrect the evidence --------------
      const retry = await feedback(userA, {
        eventId: crypto.randomUUID(),
        sourceKey: sourceA,
        action: 'ai_auto_resolved',
        sender: 'AD-E2EBNK',
        sampleBody: `Rs. 250 paid at ${MERCHANT} on 25-10-2026`,
        resolvedKind: 'transaction',
        originalDecision: {
          kind: 'posted_movement',
          fields: { amountInr: 250, merchant: MERCHANT, categorySlug: CATEGORY },
        },
        correctedFields: {},
        aiConfidenceScore: 0.96,
        ...consentBlock,
      });
      assert.equal(retry.body.learningReason, 'superseded_by_user_feedback');
      const proposalCount = await admin.query(
        `SELECT count(*)::int AS n FROM public.sms_ai_learning_proposals
          WHERE profile_id = $1 AND source_key_hash = $2`, [userA, sourceA]);
      assert.equal(proposalCount.rows[0].n, 1, 'no second proposal row was created');

      // ---- 5. the admin can no longer approve or reject it ---------------
      const staleApprove = await call('POST', '/admin/sms-learning/ai-proposals/review',
        adminUser, {
          proposalId, decision: 'approved', reason: 'E2E: approving stale evidence',
        });
      assert.equal(staleApprove.status, 409);
      assert.equal(staleApprove.body.error, 'proposal_superseded_by_user_feedback');
      const staleReject = await call('POST', '/admin/sms-learning/ai-proposals/review',
        adminUser, {
          proposalId, decision: 'rejected', reason: 'E2E: rejecting stale evidence',
        });
      assert.equal(staleReject.status, 409);
      const stillSuperseded = await admin.query(
        `SELECT status FROM public.sms_ai_learning_proposals WHERE proposal_id = $1`,
        [proposalId]);
      assert.equal(stillSuperseded.rows[0].status, 'superseded');
      const auditCount = await admin.query(
        `SELECT count(*)::int AS n FROM public.admin_audit_log
          WHERE entity_id = $1 AND reason LIKE 'E2E: %stale%'`, [proposalId]);
      assert.equal(auditCount.rows[0].n, 0, 'denied reviews write no audit entry');

      // ---- 6. the shared rule disappears for every device ----------------
      const after = await deviceSync(userB);
      assert.equal(after.status, 200);
      const afterKeys = after.body.categoryRules.map((rule) => rule.merchantKey);
      assert.ok(!afterKeys.includes(MERCHANT_KEY),
        'a superseded proposal stops voting, so the rule leaves device delivery');
      assert.ok(!afterKeys.includes(UNAPPROVED_KEY));

      const workerView = await admin.query(
        `SELECT count(*)::int AS n FROM public.sms_ai_learning_proposals
          WHERE status = 'approved'
            AND proposed_fields->>'merchant' = $1`, [MERCHANT]);
      assert.equal(workerView.rows[0].n, 9,
        'candidate synthesis sees nine approved proposals, not ten');

      // ---- 7. opt-out removes both pending and approved evidence ---------
      await withUserClient(fillers[1], async (client) => {
        await client.query(
          `INSERT INTO public.user_consents
             (profile_id, purpose, policy_version, granted, source_screen)
           VALUES ($1, 'sms_shared_learning', $2, false, 'e2e')`, [fillers[1], POLICY]);
      });
      const optedOut = await admin.query(
        `SELECT count(*)::int AS n FROM public.sms_ai_learning_proposals
          WHERE profile_id = $1`, [fillers[1]]);
      assert.equal(optedOut.rows[0].n, 0,
        'withdrawing consent purges that AI evidence regardless of status');

      // ---- 8. cross-user isolation under RLS -----------------------------
      const otherList = await call('GET', '/admin/sms-learning/ai-proposals', userB);
      assert.equal(otherList.status, 403, 'a non-admin cannot list AI evidence');
      const crossConsent = await withUserClient(userB, async (client) => client.query(
        `SELECT count(*)::int AS n FROM public.user_consents
          WHERE profile_id = $1 AND purpose = 'sms_shared_learning'`, [userA]));
      assert.equal(crossConsent.rows[0].n, 0,
        'an ordinary user cannot read the learning consent of another profile');
    } finally {
      await cleanup().catch(() => {});
      await pool.end().catch(() => {});
      await admin.end().catch(() => {});
    }
  });
