const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');

const {
  proposeCandidates,
  evaluateCandidates,
  advanceCandidatePipelines,
  publishActiveBundle,
  rollbackRegressedBundle,
} = require('../src/sms_autonomous_worker');
const {
  recordLearningExample,
  recordReviewDismissal,
  deleteLearningExamplesForUser,
  senderFingerprint,
} = require('../src/sms_learning');
const {
  compileTemplate,
  deriveIssuerPrefix,
  deriveSenderPattern,
  synthesizeTemplate,
} = require('../src/sms_template_compiler');
const { evaluateCandidate, ACTION_THRESHOLDS } = require('../src/sms_evaluator');
const { validateRule, computeBundleHash } = require('../src/sms_rule_bundle');

process.env.SMS_LEARNING_HMAC_KEY = 'test_learning_secret_key_32_characters_long';

/**
 * In-memory Postgres double supporting RLS-like schemas, queries, and advisory locks.
 */
function createMockDb() {
  const learningExamples = [];
  const candidates = [];
  const bundles = [];
  const profiles = new Map([
    ['user-opted-in-1', { contributions_opt_in: true }],
    ['user-opted-in-2', { contributions_opt_in: true }],
    ['user-opted-in-3', { contributions_opt_in: true }],
    ['user-opted-in-4', { contributions_opt_in: true }],
    ['user-opted-in-5', { contributions_opt_in: true }],
    ['user-opted-in-6', { contributions_opt_in: true }],
    ['user-opted-in-7', { contributions_opt_in: true }],
    ['user-opted-in-8', { contributions_opt_in: true }],
    ['user-opted-in-9', { contributions_opt_in: true }],
    ['user-opted-in-10', { contributions_opt_in: true }],
    ['user-opted-out', { contributions_opt_in: false }],
  ]);

  let advisoryLockHeld = false;
  let nextId = 1;

  return {
    learningExamples,
    candidates,
    bundles,
    profiles,
    async query(sql, params) {
      // 1. Advisory Lock
      if (sql.includes('pg_try_advisory_lock')) {
        if (advisoryLockHeld) {
          return { rows: [{ locked: false }] };
        }
        advisoryLockHeld = true;
        return { rows: [{ locked: true }] };
      }
      if (sql.includes('pg_advisory_unlock')) {
        advisoryLockHeld = false;
        return { rows: [{ unlocked: true }] };
      }

      // 2. Profiles Consent
      if (sql.includes('SELECT contributions_opt_in FROM profiles WHERE id = $1')) {
        const prof = profiles.get(params[0]);
        return { rows: prof ? [{ contributions_opt_in: prof.contributions_opt_in }] : [] };
      }

      // 3. Learning Examples Insert
      if (sql.includes('INSERT INTO public.sms_learning_examples')) {
        const [profileId, senderFingerprint, issuerPrefix, factFamily, templateText, sampleBody, extractedFieldsJson, isNegative, negativeReason, userHash] = params;
        const id = `ex-${nextId++}`;
        const row = {
          id,
          profile_id: profileId,
          sender_fingerprint: senderFingerprint,
          issuer_prefix: issuerPrefix,
          fact_family: factFamily,
          template_text: templateText,
          sample_body: sampleBody,
          extracted_fields: typeof extractedFieldsJson === 'string' ? JSON.parse(extractedFieldsJson) : extractedFieldsJson,
          is_negative: isNegative,
          negative_reason: negativeReason,
          user_hash: userHash,
          created_at: new Date().toISOString(),
        };
        learningExamples.push(row);
        return { rows: [{ id }], rowCount: 1 };
      }

      // 4. Learning Examples Deletion Lineage
      if (sql.includes('pandapay.sms_delete_learning_examples_for_user')) {
        const userId = params[0];
        const hmacKey = params[1] || process.env.SMS_LEARNING_HMAC_KEY;
        const expectedUserHash = crypto.createHmac('sha256', hmacKey).update(String(userId)).digest('hex');
        const before = learningExamples.length;
        const kept = learningExamples.filter((e) => e.user_hash !== expectedUserHash);
        learningExamples.length = 0;
        learningExamples.push(...kept);
        const deleted = before - kept.length;
        return { rows: [{ deleted }] };
      }

      // 5. Cluster Query for ProposeCandidates
      if (sql.includes('FROM public.sms_learning_examples') && sql.includes('GROUP BY')) {
        const minUsers = params?.[0] || 5;
        const groups = new Map();
        for (const e of learningExamples) {
          if (e.is_negative) continue;
          if (!['posted_movement', 'balance_snapshot', 'bill_obligation', 'mandate_lifecycle', 'ignore_noise'].includes(e.fact_family)) continue;
          const key = `${e.sender_fingerprint}|${e.fact_family}|${e.template_text}|${e.issuer_prefix || 'UNKNOWN'}`;
          if (!groups.has(key)) {
            groups.set(key, {
              sender_fingerprint: e.sender_fingerprint,
              fact_family: e.fact_family,
              template_text: e.template_text,
              issuer: e.issuer_prefix || 'UNKNOWN',
              users: new Set(),
              count: 0,
            });
          }
          const g = groups.get(key);
          g.users.add(e.user_hash);
          g.count += 1;
        }

        const rows = [];
        for (const g of groups.values()) {
          if (g.users.size >= minUsers) {
            rows.push({
              sender_fingerprint: g.sender_fingerprint,
              fact_family: g.fact_family,
              template_text: g.template_text,
              issuer: g.issuer,
              distinct_users: g.users.size,
              example_count: g.count,
            });
          }
        }
        return { rows };
      }

      // 6. Insert into sms_rule_candidates
      if (sql.includes('INSERT INTO public.sms_rule_candidates')) {
        const [candidateId, family, issuer, senderPattern, template, compiledRegex, fieldMapJson, defaultFieldsJson, confidence, stageMetricsJson] = params;
        const row = {
          candidate_id: candidateId,
          family,
          issuer,
          sender_pattern: senderPattern,
          template,
          compiled_regex: compiledRegex,
          field_map: typeof fieldMapJson === 'string' ? JSON.parse(fieldMapJson) : fieldMapJson,
          default_fields: typeof defaultFieldsJson === 'string' ? JSON.parse(defaultFieldsJson) : defaultFieldsJson,
          confidence,
          state: 'proposed',
          stage_metrics: typeof stageMetricsJson === 'string' ? JSON.parse(stageMetricsJson) : stageMetricsJson,
          created_at: new Date().toISOString(),
          updated_at: new Date().toISOString(),
        };
        candidates.push(row);
        return { rows: [{ candidate_id: candidateId }], rowCount: 1 };
      }

      // 7. Select Candidates for Evaluate
      if (sql.includes('FROM public.sms_rule_candidates') && sql.includes("state = 'proposed'")) {
        const rows = candidates.filter((c) => c.state === 'proposed');
        return { rows };
      }

      // 8. Select Candidates for Advance Pipelines
      if (sql.includes('FROM public.sms_rule_candidates') && sql.includes("WHERE state IN ('evaluated'")) {
        const rows = candidates.filter((c) => ['evaluated', 'shadow', 'limited', 'expanded'].includes(c.state));
        return { rows };
      }

      // 9. Update Candidate State
      if (sql.includes('UPDATE public.sms_rule_candidates') && sql.includes('SET state = $1')) {
        const [newState, metricsJson, candidateId] = params;
        const c = candidates.find((cand) => cand.candidate_id === candidateId);
        if (c) {
          c.state = newState;
          c.stage_metrics = typeof metricsJson === 'string' ? JSON.parse(metricsJson) : metricsJson;
          c.updated_at = new Date().toISOString();
          return { rowCount: 1 };
        }
        return { rowCount: 0 };
      }

      // 10. Query Positives/Negatives for candidate evaluation
      if (sql.includes('FROM public.sms_learning_examples') && sql.includes('is_negative = false')) {
        const [templateText, factFamily] = params;
        const rows = learningExamples.filter((e) => !e.is_negative && e.template_text === templateText && e.fact_family === factFamily);
        return { rows };
      }
      if (sql.includes('FROM public.sms_learning_examples') && sql.includes('is_negative = true')) {
        const rows = learningExamples.filter((e) => e.is_negative);
        return { rows };
      }

      // 11. Select active candidates for publish
      if (sql.includes('FROM public.sms_rule_candidates') && sql.includes("WHERE state = 'active'")) {
        const rows = candidates.filter((c) => c.state === 'active');
        return { rows };
      }

      // 12. Bundle Version Query
      if (sql.includes('SELECT coalesce(max(bundle_version), 0) + 1 AS next_version')) {
        const activeBundles = bundles.filter((b) => b.is_active);
        const latest = activeBundles.sort((a, b) => b.bundle_version - a.bundle_version)[0];
        const nextVersion = bundles.length > 0 ? Math.max(...bundles.map((b) => b.bundle_version)) + 1 : 1;
        return {
          rows: [{
            next_version: nextVersion,
            latest_rules: latest?.rules || null,
            latest_sha256: latest?.sha256 || null,
            latest_version: latest?.bundle_version || null,
          }],
        };
      }

      // 13. Publish Bundle Function
      if (sql.includes('pandapay.sms_publish_bundle')) {
        const [version, rulesJson, sha256, minClientVer] = params;
        bundles.push({
          bundle_version: version,
          rules: typeof rulesJson === 'string' ? JSON.parse(rulesJson) : rulesJson,
          sha256,
          is_active: true,
          min_client_ver: minClientVer,
          published_at: new Date().toISOString(),
        });
        return { rows: [{ published: true }] };
      }

      // 14. Update Candidates with bundle_version
      if (sql.includes('UPDATE public.sms_rule_candidates') && sql.includes('SET bundle_version = $1')) {
        const [bundleVer, candidateIds] = params;
        for (const c of candidates) {
          if (candidateIds.includes(c.candidate_id)) {
            c.bundle_version = bundleVer;
            c.state = 'active';
          }
        }
        return { rowCount: candidateIds.length };
      }

      // 15. Rollback Bundle Function
      if (sql.includes('pandapay.sms_rollback_bundle')) {
        const [version] = params;
        const b = bundles.find((bundle) => bundle.bundle_version === version);
        if (b) {
          b.is_active = false;
          return { rows: [{ rolled_back: true }] };
        }
        return { rows: [{ rolled_back: false }] };
      }

      // 16. Update Candidates on Rollback
      if (sql.includes('UPDATE public.sms_rule_candidates') && sql.includes("SET state = 'rolled_back'")) {
        const [version] = params;
        let updated = 0;
        for (const c of candidates) {
          if (c.bundle_version === version) {
            c.state = 'rolled_back';
            updated += 1;
          }
        }
        return { rowCount: updated };
      }

      return { rows: [], rowCount: 0 };
    },
  };
}

test('sms_learning_pipeline: consent check rejects un-opted user from writing learning examples', async () => {
  const db = createMockDb();
  const res = await recordLearningExample(db, {
    profileId: 'user-opted-out',
    sender: 'AD-HDFCBK',
    factFamily: 'posted_movement',
    sampleBody: 'debited by Rs. 500 on card 1234',
  });
  assert.equal(res.recorded, 0);
  assert.equal(res.disabled, true);
  assert.equal(db.learningExamples.length, 0);
});

test('sms_learning_pipeline: consent opt-in records redacted template and user_hash without raw PII', async () => {
  const db = createMockDb();
  const res = await recordLearningExample(db, {
    profileId: 'user-opted-in-1',
    sender: 'AD-HDFCBK',
    factFamily: 'posted_movement',
    sampleBody: 'debited by Rs. 2,499.00 on card 5678 at Zomato on 22-10-2026 ref 123456789. Avail Bal Rs. 15000',
    extractedFields: {
      amount: '2,499.00',
      last4: '5678',
      merchant: 'Zomato',
      asOf: '22-10-2026',
      reference: '123456789',
      availableBalance: '15000',
    },
  });

  assert.equal(res.recorded, 1);
  assert.equal(res.disabled, false);
  assert.equal(res.issuerPrefix, 'HDFC');
  assert.ok(/^[0-9a-f]{64}$/.test(res.userHash));
  assert.equal(db.learningExamples.length, 1);

  const stored = db.learningExamples[0];
  assert.equal(stored.fact_family, 'posted_movement');
  assert.equal(stored.issuer_prefix, 'HDFC');
  assert.ok(stored.template_text.includes('{AMOUNT}'));
  assert.ok(stored.template_text.includes('{LAST4}'));
  assert.ok(stored.template_text.includes('{MERCHANT}'));
});

test('sms_learning_pipeline: deletion lineage scrubs user examples when account is deleted', async () => {
  const db = createMockDb();

  // Seed examples for two users
  await recordLearningExample(db, {
    profileId: 'user-opted-in-1',
    sender: 'AD-HDFCBK',
    factFamily: 'posted_movement',
    sampleBody: 'debited by Rs. 500 on card 1234',
  });
  await recordLearningExample(db, {
    profileId: 'user-opted-in-2',
    sender: 'AD-HDFCBK',
    factFamily: 'posted_movement',
    sampleBody: 'debited by Rs. 800 on card 5678',
  });

  assert.equal(db.learningExamples.length, 2);

  // User 1 requests deletion
  const deletedCount = await deleteLearningExamplesForUser(db, 'user-opted-in-1');
  assert.equal(deletedCount, 1);
  assert.equal(db.learningExamples.length, 1);

  // Verify only user 2 remains
  const remainingHash = crypto.createHmac('sha256', process.env.SMS_LEARNING_HMAC_KEY).update('user-opted-in-2').digest('hex');
  assert.equal(db.learningExamples[0].user_hash, remainingHash);
});

test('sms_learning_pipeline: worker refuses wildcard sender patterns when issuer is unknown', async () => {
  const db = createMockDb();

  // Add examples with an unidentifiable sender that cannot yield an issuer
  for (let i = 1; i <= 6; i++) {
    await recordLearningExample(db, {
      profileId: `user-opted-in-${i}`,
      sender: '!', // invalid / unidentifiable
      factFamily: 'posted_movement',
      sampleBody: 'debited by Rs. 500 on card 1234',
    });
  }

  // Attempt candidate proposal without specifying senderPattern
  const outcome = await proposeCandidates(db, { minDistinctUsers: 5 });
  // Must skip candidates because wildcard .* is strictly forbidden
  assert.equal(outcome.proposed, 0);
  assert.equal(db.candidates.length, 0);
});

test('sms_learning_pipeline: a dismissal teaches ignore_noise and penalizes the suspected family', async () => {
  const db = createMockDb();
  const outcome = await recordReviewDismissal(db, {
    profileId: 'user-opted-in-1',
    sender: 'VM-HDFCBK-S',
    body: 'Your card ending 8708 was checked for a transaction. Call support if this was not you.',
    family: 'posted_movement',
    reason: 'not_a_transaction',
  });

  assert.equal(outcome.recorded, 2);
  assert.deepEqual(db.learningExamples.map((example) => ({
    family: example.fact_family,
    negative: example.is_negative,
    reason: example.negative_reason,
  })), [
    { family: 'posted_movement', negative: true, reason: 'not_a_transaction' },
    { family: 'ignore_noise', negative: false, reason: null },
  ]);
});

test('sms_learning_pipeline: complete connected loop from review to local execution with changed values', async () => {
  const db = createMockDb();

  // 1. Seed 10 independent users confirming the unfamiliar HDFC template in Needs Review
  const sampleTemplate = 'debited by {AMOUNT} on card {LAST4} at {MERCHANT} on {DATE} ref {REF}. Avail Bal {BAL}';

  for (let i = 1; i <= 10; i++) {
    const amount = (100 * i).toFixed(2);
    const amountPaise = 10000 * i;
    const last4 = `100${i % 10}`;
    const body = `debited by Rs. ${amount} on card ${last4} at Amazon on 22-10-2026 ref 123456789. Avail Bal Rs. 50000`;

    await recordLearningExample(db, {
      profileId: `user-opted-in-${i}`,
      sender: 'AD-HDFCBK',
      factFamily: 'posted_movement',
      templateText: sampleTemplate,
      sampleBody: body,
      extractedFields: {
        amount,
        amountPaise,
        last4,
        merchant: 'Amazon',
        asOf: '22-10-2026',
        reference: '123456789',
        availableBalance: '50000',
        availableBalancePaise: 5000000,
      },
    });
  }

  // 2. Autonomous worker proposes candidate
  const proposeRes = await proposeCandidates(db, { minDistinctUsers: 5 });
  assert.equal(proposeRes.proposed, 1);
  assert.equal(db.candidates.length, 1);
  assert.equal(db.candidates[0].state, 'proposed');
  assert.equal(db.candidates[0].sender_pattern, 'HDFC');

  // Verify rule does NOT use wildcard
  assert.notEqual(db.candidates[0].sender_pattern, '.*');
  assert.notEqual(db.candidates[0].sender_pattern, '*');

  // 3. Autonomous worker evaluates candidate against positive examples & hard negatives
  const evalRes = await evaluateCandidates(db);
  assert.equal(evalRes.evaluated, 1);
  assert.equal(evalRes.passed, 1);
  // Evaluated state must NOT be active directly!
  assert.equal(db.candidates[0].state, 'evaluated');

  // 4. Advance through canary cohorts (shadow -> limited -> expanded -> active)
  // Stage 1: evaluated -> shadow
  let advanceRes = await advanceCandidatePipelines(db, { minObservationMs: 0, minExposures: 0 });
  assert.equal(advanceRes.advanced, 1);
  assert.equal(db.candidates[0].state, 'shadow');

  // Stage 2: shadow -> limited
  advanceRes = await advanceCandidatePipelines(db, { minObservationMs: 0, minExposures: 0 });
  assert.equal(advanceRes.advanced, 1);
  assert.equal(db.candidates[0].state, 'limited');

  // Stage 3: limited -> expanded
  advanceRes = await advanceCandidatePipelines(db, { minObservationMs: 0, minExposures: 0 });
  assert.equal(advanceRes.advanced, 1);
  assert.equal(db.candidates[0].state, 'expanded');

  // Stage 4: expanded -> active (since distinct_users = 10 meets threshold)
  advanceRes = await advanceCandidatePipelines(db, { minObservationMs: 0, minExposures: 0 });
  assert.equal(advanceRes.advanced, 1);
  assert.equal(db.candidates[0].state, 'active');

  // 5. Publish validated bundle
  const publishRes = await publishActiveBundle(db);
  assert.equal(publishRes.published, true);
  assert.equal(publishRes.bundleVersion, 1);
  assert.equal(db.bundles.length, 1);

  // 6. Device download & local extraction with CHANGED values
  const downloadedBundle = db.bundles[0];
  assert.equal(downloadedBundle.rules.length, 1);

  const downloadedRule = downloadedBundle.rules[0];
  assert.equal(downloadedRule.senderPattern, 'HDFC');

  // New incoming SMS for a DIFFERENT user with completely different values:
  // - Amount: ₹120.50 (was ₹100.00-1000.00)
  // - Card: 9999 (was 100x)
  // - Merchant: Swiggy (was Amazon)
  // - Date: 23-10-2026 (was 22-10-2026)
  // - Ref: 987654321 (was 123456789)
  // - Balance: ₹8,500.00 (was ₹50,000)
  const incomingSender = 'VM-HDFCBK-S';
  const incomingBody = 'debited by Rs. 120.50 on card 9999 at Swiggy on 23-10-2026 ref 987654321. Avail Bal Rs. 8,500.00';

  // Device checks sender
  assert.ok(incomingSender.toUpperCase().includes(downloadedRule.senderPattern.toUpperCase()));

  // Device runs compiled regex locally
  const localRegex = new RegExp(downloadedRule.regex, 'i');
  const match = incomingBody.match(localRegex);
  assert.ok(match, 'Regex must match incoming SMS locally');

  // Device extracts fields using fieldMap
  const { fieldMap } = downloadedRule;
  const extractedAmount = match[fieldMap.amount];
  const extractedLast4 = match[fieldMap.last4];
  const extractedMerchant = match[fieldMap.merchant];
  const extractedDate = match[fieldMap.asOf];
  const extractedRef = match[fieldMap.reference];
  const extractedBal = match[fieldMap.availableBalance];

  assert.equal(extractedAmount, '120.50');
  assert.equal(extractedLast4, '9999');
  assert.equal(extractedMerchant, 'Swiggy');
  assert.equal(extractedDate, '23-10-2026');
  assert.equal(extractedRef, '987654321');
  assert.equal(extractedBal, '8,500.00');
});

test('sms_learning_pipeline: advisory lock ensures concurrent promotion safety and idempotency', async () => {
  const db = createMockDb();

  // Create an active candidate
  db.candidates.push({
    candidate_id: 'cand_test123',
    family: 'posted_movement',
    issuer: 'ICICI',
    sender_pattern: 'ICICI',
    template: 'debited by {AMOUNT}',
    compiled_regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
    field_map: { amount: 1 },
    default_fields: {},
    confidence: 0.98,
    state: 'active',
  });

  // First publish succeeds
  const pub1 = await publishActiveBundle(db);
  assert.equal(pub1.published, true);
  assert.equal(pub1.bundleVersion, 1);

  // Second immediate publish is idempotent (returns upToDate: true without creating redundant bundle)
  const pub2 = await publishActiveBundle(db);
  assert.equal(pub2.published, false);
  assert.equal(pub2.upToDate, true);
  assert.equal(pub2.bundleVersion, 1);
  assert.equal(db.bundles.length, 1);
});

test('sms_learning_pipeline: rollback bundle immediately inactivates bundle and reverts candidates', async () => {
  const db = createMockDb();

  db.candidates.push({
    candidate_id: 'cand_regressed',
    family: 'posted_movement',
    issuer: 'AXIS',
    sender_pattern: 'AXIS',
    template: 'debited by {AMOUNT}',
    compiled_regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
    field_map: { amount: 1 },
    default_fields: {},
    confidence: 0.98,
    state: 'active',
  });

  const pub = await publishActiveBundle(db);
  assert.equal(pub.published, true);
  assert.equal(db.bundles[0].is_active, true);

  // Trigger automatic rollback on detected regression
  const rollbackRes = await rollbackRegressedBundle(db, pub.bundleVersion, 'false_positive_spike');
  assert.equal(rollbackRes.rolledBack, true);
  assert.equal(db.bundles[0].is_active, false);
  assert.equal(db.candidates[0].state, 'rolled_back');
});
