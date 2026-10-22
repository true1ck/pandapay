const test = require('node:test');
const assert = require('node:assert/strict');
const smsRuleBundle = require('../src/sms_rule_bundle');

test('validateRule: accepts well-formed rules across supported families', () => {
  const validSpend = {
    id: 'rule_spend_01',
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'debited by Rs\\.?\\s*([0-9.]+) for ([A-Za-z0-9 ]+) on card (\\d{4})',
    fieldMap: { amount: 1, merchant: 2, last4: 3 },
    confidence: 0.99,
  };
  assert.equal(smsRuleBundle.validateRule(validSpend).valid, true);

  const validBalance = {
    id: 'rule_bal_01',
    family: 'balance_snapshot',
    senderPattern: 'SBIN',
    regex: 'A/c (\\d{4}) Avail Bal Rs\\.?\\s*([0-9.]+)',
    fieldMap: { accountLast4: 1, availableBalance: 2 },
    confidence: 0.98,
  };
  assert.equal(smsRuleBundle.validateRule(validBalance).valid, true);

  const validBill = {
    id: 'rule_bill_01',
    family: 'bill_obligation',
    senderPattern: 'AIRTEL',
    regex: 'Bill due date is ([0-9]{2}-[0-9]{2}-[0-9]{4}) for Rs\\.?\\s*([0-9.]+)',
    fieldMap: { dueDate: 1, amountDue: 2 },
    confidence: 0.95,
  };
  assert.equal(smsRuleBundle.validateRule(validBill).valid, true);

  const validNoise = {
    id: 'rule_noise_01',
    family: 'ignore_noise',
    senderPattern: 'HDFCOF',
    regex: 'Special offer just for you get 10% off',
    confidence: 1.0,
  };
  assert.equal(smsRuleBundle.validateRule(validNoise).valid, true);
});

test('validateRule: ignore_noise cannot match financial keywords', () => {
  const badNoise = {
    id: 'bad_noise_01',
    family: 'ignore_noise',
    senderPattern: 'HDFC',
    regex: 'Your account was debited with Rs 500 offer',
    confidence: 1.0,
  };
  const res = smsRuleBundle.validateRule(badNoise);
  assert.equal(res.valid, false);
  assert.match(res.reason, /ignore_noise_cannot_match_financial_keywords/);
});

test('validateRule: evaluation cases must pass', () => {
  const ruleWithEval = {
    id: 'eval_rule_01',
    family: 'posted_movement',
    senderPattern: 'HDFCBK',
    regex: 'spent Rs\\.?\\s*([0-9.]+)',
    fieldMap: { amount: 1 },
    confidence: 0.99,
    evalCases: [
      { text: 'spent Rs. 500 at Store', expectedMatch: true },
      { text: 'nothing here', expectedMatch: false },
    ],
  };
  assert.equal(smsRuleBundle.validateRule(ruleWithEval).valid, true);

  const ruleFailingEval = {
    ...ruleWithEval,
    evalCases: [
      { text: 'spent Rs. 500 at Store', expectedMatch: false }, // expects failure, but regex matches!
    ],
  };
  const res = smsRuleBundle.validateRule(ruleFailingEval);
  assert.equal(res.valid, false);
  assert.match(res.reason, /evaluation_case_0_failed/);
});

test('validateRule: ReDoS safety checks reject catastrophic backtracking', () => {
  const nestedPlus = {
    id: 'bad_redos_01',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: '(a+)+',
    fieldMap: { amount: 1 },
  };
  assert.equal(smsRuleBundle.validateRule(nestedPlus).valid, false);

  const nestedStar = {
    id: 'bad_redos_02',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: '([a-z]*)*',
    fieldMap: { amount: 1 },
  };
  assert.equal(smsRuleBundle.validateRule(nestedStar).valid, false);

  const doubleWildcard = {
    id: 'bad_redos_03',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'start .* middle .* end',
    fieldMap: { amount: 1 },
  };
  assert.equal(smsRuleBundle.validateRule(doubleWildcard).valid, false);
});

test('validateRule: rejects out-of-range capture groups and forbidden fields', () => {
  const outOfRange = {
    id: 'bad_group_01',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'debited by Rs\\.?\\s*([0-9.]+)',
    fieldMap: { amount: 1, merchant: 2 }, // only 1 group exists!
  };
  const resGroup = smsRuleBundle.validateRule(outOfRange);
  assert.equal(resGroup.valid, false);
  assert.match(resGroup.reason, /invalid_capture_group_index_2/);

  const forbiddenField = {
    id: 'bad_field_01',
    family: 'posted_movement',
    senderPattern: 'BANK',
    regex: 'debited by Rs\\.?\\s*([0-9.]+)',
    fieldMap: { userPassword: 1 },
  };
  const resField = smsRuleBundle.validateRule(forbiddenField);
  assert.equal(resField.valid, false);
  assert.match(resField.reason, /forbidden_field_mapping/);
});

test('computeBundleHash: returns deterministic SHA-256 checksum', () => {
  const bundle = {
    bundleVersion: 1,
    minClientVersion: '1.0.0',
    rules: [
      {
        id: 'rule_1',
        family: 'posted_movement',
        senderPattern: 'HDFC',
        regex: 'spent ([0-9]+)',
        fieldMap: { amount: 1 },
        confidence: 0.99,
      },
    ],
  };
  const hash1 = smsRuleBundle.computeBundleHash(bundle);
  const hash2 = smsRuleBundle.computeBundleHash(bundle);
  assert.equal(hash1, hash2);
  assert.match(hash1, /^[0-9a-f]{64}$/);
});

test('candidate delivery carries the stage epoch and hashes the advertised client version', () => {
  const delivery = smsRuleBundle.candidateDelivery({
    candidate_id: 'candidate_hdfc_01',
    state: 'active',
    stage_version: 7,
    bundle_version: 12,
    min_client_ver: '2.4.0',
    family: 'posted_movement',
    sender_pattern: 'HDFCBK',
    compiled_regex: 'spent Rs\\.?\\s*([0-9.]+)',
    field_map: { amount: 1 },
    default_fields: {},
    confidence: 0.99,
  }, 'profile-1');
  assert.equal(delivery.stageVersion, 7);
  assert.equal(delivery.minClientVersion, '2.4.0');
  assert.equal(delivery.bundleVersion, 12);
  assert.equal(delivery.sha256, smsRuleBundle.computeBundleHash({
    bundleVersion: 12,
    minClientVersion: '2.4.0',
    rules: delivery.rules,
  }));
});

test('routes: GET /sms/rules/active, publish, immutability, and rollback', async () => {
  const handlers = new Map();
  const app = {
    get: (path, ...middleware) => handlers.set(`GET ${path}`, middleware[middleware.length - 1]),
    post: (path, ...middleware) => handlers.set(`POST ${path}`, middleware[middleware.length - 1]),
  };

  const dbRows = [];
  const fakeClient = {
    query: async (sql, params) => {
      if (sql.includes('SELECT bundle_version')) {
        const active = dbRows.filter((r) => r.is_active).sort((a, b) => b.bundle_version - a.bundle_version)[0];
        return { rows: active ? [active] : [] };
      }
      if (sql.includes('INSERT INTO public.sms_rule_bundles')) {
        const [bundle_version, rules, sha256, published_by, min_client_ver] = params;
        const existing = dbRows.find((r) => r.bundle_version === bundle_version);
        if (existing) {
          // ON CONFLICT DO NOTHING: rowCount 0!
          return { rowCount: 0 };
        }
        dbRows.push({
          bundle_version,
          rules: JSON.parse(rules),
          sha256,
          published_by,
          is_active: true,
          published_at: new Date().toISOString(),
          min_client_ver,
        });
        return { rowCount: 1 };
      }
      if (sql.includes('UPDATE public.sms_rule_bundles')) {
        const [version] = params;
        const target = dbRows.find((r) => r.bundle_version === version);
        if (target) {
          target.is_active = false;
          return { rowCount: 1 };
        }
        return { rowCount: 0 };
      }
      return { rows: [] };
    },
  };

  smsRuleBundle.registerSmsRuleBundleRoutes(app, {
    requireAuth: (req, res, next) => next(),
    requireAdmin: (req, res, next) => next(),
    withUserClient: async (_uid, fn) => fn(fakeClient),
  });

  function makeRes() {
    return {
      statusReceived: 200,
      payload: null,
      status(s) {
        this.statusReceived = s;
        return this;
      },
      json(p) {
        this.payload = p;
        return this;
      },
    };
  }

  // 1. Initial state: no active bundle
  const res1 = makeRes();
  await handlers.get('GET /sms/rules/active')({ userId: 'u1', query: {} }, res1);
  assert.equal(res1.statusReceived, 200);
  assert.equal(res1.payload.bundleVersion, 0);
  assert.deepEqual(res1.payload.rules, []);

  // 2. Publish a valid bundle
  const publishPayload = {
    bundleVersion: 1,
    minClientVersion: '1.0.0',
    rules: [
      {
        id: 'rule_hdfc_01',
        family: 'posted_movement',
        senderPattern: 'HDFCBK',
        regex: 'spent Rs\\.?\\s*([0-9.]+)',
        fieldMap: { amount: 1 },
        confidence: 0.99,
      },
    ],
  };
  const resPublish = makeRes();
  await handlers.get('POST /admin/sms-rules/publish')({ userId: 'u1', body: publishPayload }, resPublish);
  assert.equal(resPublish.statusReceived, 200);
  assert.equal(resPublish.payload.bundleVersion, 1);
  assert.match(resPublish.payload.sha256, /^[0-9a-f]{64}$/);

  // 3. Duplicate version publish returns 409 Conflict
  const resDup = makeRes();
  await handlers.get('POST /admin/sms-rules/publish')({ userId: 'u1', body: publishPayload }, resDup);
  assert.equal(resDup.statusReceived, 409);
  assert.equal(resDup.payload.error, 'bundle_version_already_exists');

  // 4. Active fetch returns the published bundle
  const resActive = makeRes();
  await handlers.get('GET /sms/rules/active')({ userId: 'u1', query: {} }, resActive);
  assert.equal(resActive.statusReceived, 200);
  assert.equal(resActive.payload.bundleVersion, 1);
  assert.equal(resActive.payload.rules.length, 1);
  assert.equal(resActive.payload.rules[0].id, 'rule_hdfc_01');

  // 5. Conditional fetch with since_version=1 returns upToDate: true
  const resUpToDate = makeRes();
  await handlers.get('GET /sms/rules/active')({ userId: 'u1', query: { since_version: '1' } }, resUpToDate);
  assert.equal(resUpToDate.statusReceived, 200);
  assert.equal(resUpToDate.payload.upToDate, true);

  // 6. Rollback
  const resRollback = makeRes();
  await handlers.get('POST /admin/sms-rules/:bundleVersion/rollback')(
    { userId: 'u1', params: { bundleVersion: '1' } },
    resRollback,
  );
  assert.equal(resRollback.statusReceived, 200);
  assert.equal(resRollback.payload.rolledBack, true);

  // 7. After rollback, GET /sms/rules/active tells client that had version 1 that a rollback occurred
  const resAfterRollback = makeRes();
  await handlers.get('GET /sms/rules/active')({ userId: 'u1', query: { since_version: '1' } }, resAfterRollback);
  assert.equal(resAfterRollback.statusReceived, 200);
  assert.equal(resAfterRollback.payload.bundleVersion, 0);
  assert.equal(resAfterRollback.payload.rolledBack, true);
});
