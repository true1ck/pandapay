const test = require('node:test');
const assert = require('node:assert/strict');
const {
  proposeCandidates,
  evaluateCandidates,
  publishActiveBundle,
  rollbackRegressedBundle,
  verifyWorkerCapabilities,
} = require('../src/sms_autonomous_worker');
const { computeBundleHash } = require('../src/sms_rule_bundle');

test('sms_autonomous_worker: proposeCandidates clusters with >= 5 distinct users and proposes valid candidate', async () => {
  const learningExamples = [
    {
      sender_fingerprint: 'a'.repeat(64),
      fact_family: 'posted_movement',
      template_text: 'debited by {AMOUNT} on card {LAST4} at {MERCHANT}.',
      issuer: 'HDFCBK',
      distinct_users: 6,
      example_count: 12,
    },
  ];

  const candidatesTable = [];

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('FROM public.sms_learning_examples') && sql.includes('GROUP BY')) {
        const minUsers = params?.[0] || 5;
        const rows = learningExamples.filter((e) => e.distinct_users >= minUsers);
        return { rows };
      }
      if (sql.includes('INSERT INTO public.sms_rule_candidates')) {
        const [candidateId, family, issuer, senderPattern, template, compiledRegex, fieldMapJson, defaultFieldsJson, confidence, stageMetricsJson] = params;
        candidatesTable.push({
          candidate_id: candidateId,
          family,
          issuer,
          sender_pattern: senderPattern,
          template,
          compiled_regex: compiledRegex,
          field_map: JSON.parse(fieldMapJson),
          default_fields: JSON.parse(defaultFieldsJson),
          confidence,
          state: 'proposed',
          stage_metrics: JSON.parse(stageMetricsJson),
        });
        return { rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const outcome = await proposeCandidates(mockDb, { minDistinctUsers: 5 });
  assert.equal(outcome.proposed, 1);
  assert.equal(outcome.totalClusters, 1);
  assert.equal(candidatesTable.length, 1);
  assert.equal(candidatesTable[0].state, 'proposed');
  assert.equal(candidatesTable[0].family, 'posted_movement');
  assert.ok(candidatesTable[0].compiled_regex.includes('([0-9]{4})'));
});

test('sms_autonomous_worker: proposeCandidates skips clusters with < 5 distinct users or invalid templates', async () => {
  const learningExamples = [
    {
      sender_fingerprint: 'b'.repeat(64),
      fact_family: 'posted_movement',
      template_text: 'Spent {UNKNOWN_SLOT} at store',
      issuer: 'SBIN',
      distinct_users: 7, // >= 5 users, but invalid slot
      example_count: 8,
    },
  ];

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('FROM public.sms_learning_examples')) {
        return { rows: learningExamples };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const outcome = await proposeCandidates(mockDb);
  assert.equal(outcome.proposed, 0);
  assert.equal(outcome.totalClusters, 1);
});

test('sms_autonomous_worker: evaluateCandidates advances valid candidate to evaluated (never active directly)', async () => {
  const { compileTemplate } = require('../src/sms_template_compiler');
  const compiled = compileTemplate('debited by {AMOUNT} on card {LAST4} at {MERCHANT}.', 'posted_movement');

  const candidates = [
    {
      candidate_id: 'cand_123',
      family: 'posted_movement',
      issuer: 'HDFCBK',
      sender_pattern: 'HDFCBK',
      template: 'debited by {AMOUNT} on card {LAST4} at {MERCHANT}.',
      compiled_regex: compiled.compiledRegex,
      field_map: compiled.fieldMap,
      default_fields: {},
      confidence: 0.98,
      state: 'proposed',
      stage_metrics: {},
    },
  ];

  const updates = [];

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('SELECT') && sql.includes("WHERE state = 'proposed'")) {
        return { rows: candidates };
      }
      if (sql.includes('SELECT e.sample_body') && sql.includes('e.is_negative = false')) {
        return {
          rows: [
            {
              sample_body: 'debited by Rs. 500.00 on card 1234 at Amazon Pay.',
              extracted_fields: { amountPaise: 50000, last4: '1234' },
            },
          ],
        };
      }
      if (sql.includes('SELECT sample_body') && sql.includes('is_negative = true')) {
        return { rows: [] };
      }
      if (sql.includes('UPDATE public.sms_rule_candidates')) {
        updates.push({ sql, params });
        return { rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const outcome = await evaluateCandidates(mockDb);
  assert.equal(outcome.evaluated, 1);
  assert.equal(outcome.passed, 1);
  assert.equal(outcome.rejected, 0);
  assert.equal(updates.length, 1);
  assert.equal(updates[0].params[0], 'evaluated');
  assert.equal(updates[0].params[2], 'cand_123');
});

test('sms_autonomous_worker: evaluateCandidates marks candidate rejected on negative collision', async () => {
  const leakyCandidate = {
    candidate_id: 'cand_leaky',
    family: 'posted_movement',
    issuer: 'BANK',
    sender_pattern: 'BANK',
    template: 'code {REF}',
    compiled_regex: 'code ([A-Za-z0-9]{6,25})',
    field_map: { reference: 1 },
    default_fields: {},
    confidence: 0.98,
    state: 'proposed',
    stage_metrics: {},
  };

  const updates = [];

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('SELECT') && sql.includes("WHERE state = 'proposed'")) {
        return { rows: [leakyCandidate] };
      }
      if (sql.includes('SELECT e.sample_body') && sql.includes('e.is_negative = false')) {
        return {
          rows: [{ sample_body: 'code 987654', extracted_fields: {} }],
        };
      }
      if (sql.includes('SELECT sample_body') && sql.includes('is_negative = true')) {
        return {
          rows: [{ sample_body: 'Your secret OTP code 123456 do not share', is_negative: true }],
        };
      }
      if (sql.includes('UPDATE public.sms_rule_candidates')) {
        updates.push({ sql, params });
        return { rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const outcome = await evaluateCandidates(mockDb);
  assert.equal(outcome.evaluated, 1);
  assert.equal(outcome.passed, 0);
  assert.equal(outcome.rejected, 1);
  assert.equal(updates[0].params[1], 'cand_leaky');
});

test('a candidate waits for post-creation holdout examples instead of being rejected', async () => {
  const candidate = {
    candidate_id: 'cand_waiting', family: 'posted_movement',
    sender_pattern: 'HDFC', template: 'debited by {AMOUNT}',
    compiled_regex: 'debited by Rs\\.?\\s*([0-9]+)', field_map: { amount: 1 },
    stage_metrics: {}, created_at: new Date().toISOString(), state: 'proposed',
  };
  const updates = [];
  const db = { async query(sql) {
    if (sql.includes("WHERE state = 'proposed'")) return { rows: [candidate] };
    if (sql.includes('UPDATE public.sms_rule_candidates')) updates.push(sql);
    return { rows: [], rowCount: 0 };
  } };
  const result = await evaluateCandidates(db, { isProduction: true });
  assert.equal(result.pending, 1);
  assert.equal(result.rejected, 0);
  assert.equal(updates.length, 0);
});

test('sms_autonomous_worker: publishActiveBundle compiles hash and publishes bundle', async () => {
  const activeCandidates = [
    {
      candidate_id: 'cand_active_01',
      family: 'posted_movement',
      issuer: 'HDFCBK',
      sender_pattern: 'HDFCBK',
      template: 'debited by {AMOUNT}',
      compiled_regex: 'debited by (?:(?:₹|Rs\\.?|INR)\\s*([0-9,]+(?:\\.[0-9]{1,2})?))',
      field_map: { amount: 1 },
      default_fields: {},
      confidence: 0.99,
    },
  ];

  let publishedCall = null;
  let candidateUpdate = null;

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ locked: true }] };
      if (sql.includes('SELECT') && sql.includes("WHERE state = 'active'")) {
        return { rows: activeCandidates };
      }
      if (sql.includes('coalesce(max(bundle_version), 0) + 1')) {
        return { rows: [{ next_version: 4 }] };
      }
      if (sql.includes('pandapay.sms_publish_bundle')) {
        publishedCall = params;
        return { rows: [{ published: true }] };
      }
      if (sql.includes('UPDATE public.sms_rule_candidates') && sql.includes('SET bundle_version = $1')) {
        candidateUpdate = params;
        return { rowCount: 1 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const result = await publishActiveBundle(mockDb, '1.2.0');
  assert.equal(result.published, true);
  assert.equal(result.bundleVersion, 4);
  assert.equal(result.ruleCount, 1);
  assert.ok(result.sha256);

  assert.equal(publishedCall[0], 4);
  assert.equal(publishedCall[2], result.sha256);
  assert.equal(publishedCall[3], '1.2.0');

  assert.equal(candidateUpdate[0], 4);
  assert.deepEqual(candidateUpdate[1], ['cand_active_01']);
});

test('sms_autonomous_worker: publishActiveBundle returns early if no active candidates', async () => {
  const mockDb = {
    async query(sql) {
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ locked: true }] };
      return { rows: [] };
    },
  };

  const result = await publishActiveBundle(mockDb);
  assert.equal(result.published, false);
  assert.equal(result.reason, 'no_active_candidates');
});

test('sms_autonomous_worker: rollbackRegressedBundle calls pandapay.sms_rollback_bundle and marks rolled_back', async () => {
  let rollbackCall = null;
  let updateCall = null;

  const mockDb = {
    async query(sql, params) {
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ locked: true }] };
      if (sql.includes('pandapay.sms_rollback_bundle')) {
        rollbackCall = params;
        return { rows: [{ rolled_back: true }] };
      }
      if (sql.includes('UPDATE public.sms_rule_candidates') && sql.includes("SET state = 'rolled_back'")) {
        updateCall = params;
        return { rowCount: 2 };
      }
      return { rows: [], rowCount: 0 };
    },
  };

  const result = await rollbackRegressedBundle(mockDb, 4);
  assert.equal(result.rolledBack, true);
  assert.equal(result.bundleVersion, 4);
  assert.equal(rollbackCall[0], 4);
  assert.equal(updateCall[0], 4);
});

test('sms_autonomous_worker: rollbackRegressedBundle handles invalid version or inactive bundle', async () => {
  const mockDb = {
    async query(sql) {
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ locked: true }] };
      return { rows: [{ rolled_back: false }] };
    },
  };

  const invalidRes = await rollbackRegressedBundle(mockDb, -1);
  assert.equal(invalidRes.rolledBack, false);
  assert.equal(invalidRes.reason, 'invalid_bundle_version');

  const notFoundRes = await rollbackRegressedBundle(mockDb, 999);
  assert.equal(notFoundRes.rolledBack, false);
  assert.equal(notFoundRes.reason, 'bundle_not_found_or_already_inactive');
});

test('sms_autonomous_worker: startAutonomousWorker and stopAutonomousWorker lifecycle', async () => {
  const { startAutonomousWorker, stopAutonomousWorker } = require('../src/sms_autonomous_worker');
  const mockDb = {
    async query() {
      return { rows: [] };
    },
  };

  const handle = startAutonomousWorker(mockDb, { intervalMs: 100000 });
  assert.ok(handle);
  assert.equal(typeof handle.stop, 'function');
  stopAutonomousWorker();
});

test('sms_autonomous_worker: capability check requires the dedicated role and complete grants', async () => {
  const capableWorker = {
    async query(sql) {
      assert.match(sql, /sms_rule_bundles/);
      return { rows: [{
        role: 'sms_learning_worker',
        is_superuser: false,
        bypasses_rls: false,
        can_read_examples: true,
        can_write_candidates: true,
        can_read_exposures: true,
        can_read_bundles: true,
        can_write_worker_runs: true,
        can_publish: true,
        can_rollback: true,
      }] };
    },
  };

  assert.equal(await verifyWorkerCapabilities(capableWorker), 'sms_learning_worker');

  const appUser = {
    async query() {
      return { rows: [{
        role: 'app_user',
        is_superuser: false,
        bypasses_rls: false,
        can_read_examples: true,
        can_write_candidates: true,
        can_read_exposures: true,
        can_read_bundles: true,
        can_write_worker_runs: true,
        can_publish: true,
        can_rollback: true,
      }] };
    },
  };
  await assert.rejects(
    verifyWorkerCapabilities(appUser),
    /lacks required capabilities/,
  );

  const incompleteWorker = {
    async query() {
      return { rows: [{
        role: 'sms_learning_worker',
        is_superuser: false,
        bypasses_rls: false,
        can_read_examples: true,
        can_write_candidates: true,
        can_read_exposures: true,
        can_read_bundles: false,
        can_write_worker_runs: true,
        can_publish: true,
        can_rollback: true,
      }] };
    },
  };
  await assert.rejects(
    verifyWorkerCapabilities(incompleteWorker),
    /lacks required capabilities/,
  );
});
