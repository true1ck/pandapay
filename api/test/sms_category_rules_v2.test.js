const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('crypto');
const {
  registerSmsRuleBundleRoutes,
  compareOrdinal,
  compareCategoryRulesV2,
} = require('../src/sms_rule_bundle');
const {
  institutionalSenderKey,
  categoryContextKey,
  validCategoryContextKey,
} = require('../src/sms_learning_feedback_route');

function response() {
  return {
    statusCode: 200,
    status(code) { this.statusCode = code; return this; },
    json(payload) { this.payload = payload; return this; },
  };
}

test('v2 shared category scope accepts institutional sender keys only', () => {
  assert.equal(institutionalSenderKey('TX-MNTPRO-S'), 'TX-MNTPRO-S');
  assert.equal(institutionalSenderKey('VM-RELGEN-S'), 'VM-RELGEN-S');
  assert.equal(institutionalSenderKey('tx-mntpro-s'), 'TX-MNTPRO-S');
  assert.equal(institutionalSenderKey('+919876543210'), null);
  assert.equal(institutionalSenderKey('Ravi Kumar'), null);
  assert.equal(institutionalSenderKey('A-HDFCBK'), null);
});

test('v2 canonical rule sorting is ordinal and matches the tuple field order', () => {
  const zebra = {
    merchantKey: 'ZEBRA', senderKey: 'TX-MERCH-S', contextKey: 'GROCERY',
    factFamily: 'posted_movement', categorySlug: 'groceries',
  };
  const eclair = { ...zebra, merchantKey: 'ÉCLAIR' };
  assert.equal(compareOrdinal('ZEBRA', 'ÉCLAIR'), -1);
  assert.ok(compareCategoryRulesV2(zebra, eclair) < 0);
});

test('v2 context uses sorted whole-word tokens and abstains on overbroad or merchant-only contexts', () => {
  assert.equal(categoryContextKey(
    'Payment at Travel World for a FLIGHT booking and HOTEL renewal',
    'Travel World',
  ), 'FLIGHT|HOTEL|RENEWAL');
  assert.equal(categoryContextKey('TRAVELWORLD payment completed', 'Travel World'), null);
  assert.equal(categoryContextKey('UPI POS debit at merchant', 'merchant'), null);
  assert.equal(validCategoryContextKey('FLIGHT|TRAVEL'), true);
  assert.equal(validCategoryContextKey('TRAVEL|FLIGHT'), false);
  assert.equal(validCategoryContextKey('PERSONALNAME'), false);
  assert.equal(categoryContextKey(
    'cab ride flight train hotel rent fuel insurance grocery', 'Merchant',
  ), null);
  assert.equal(categoryContextKey(
    'cab ride flight hotel rent fuel insurance grocery', 'Merchant',
  ), 'CAB|FLIGHT|FUEL|GROCERY|HOTEL|INSURANCE|RENT|RIDE');
  assert.equal(categoryContextKey('FLIGHT123 at merchant', 'merchant'), null);
});

test('admin category proposal evidence and approval are joined on the exact scope tuple', async () => {
  const handlers = new Map();
  const app = {
    get: (path, ...middleware) => handlers.set(`GET ${path}`, middleware.at(-1)),
    post() {},
  };
  const client = {
    query: async (sql) => {
      assert.match(sql, /evidence\.sender_key = c\.sender_key/);
      assert.match(sql, /evidence\.context_key = c\.context_key/);
      assert.match(sql, /evidence\.fact_family = c\.fact_family/);
      return { rows: [{
        merchant_key: 'TRAVEL WORLD', sender_key: 'TX-MNTPRO-S',
        context_key: 'FLIGHT|TRAVEL', fact_family: 'posted_movement',
        category_slug: 'travel', support_count: 10, agreement_rate: 0.9,
        redacted_pattern: 'Flight booking at {MERCHANT}',
      }] };
    },
  };
  registerSmsRuleBundleRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    requireAdmin: (_req, _res, next) => next(),
    withUserClient: async (_userId, callback) => callback(client),
  });
  const res = response();
  await handlers.get('GET /admin/sms-rules/category-proposals')({ userId: 'admin' }, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.payload.proposals[0].redacted_pattern, 'Flight booking at {MERCHANT}');
  assert.deepEqual(res.payload.proposals[0].proposed_rule, {
    merchantKey: 'TRAVEL WORLD', senderKey: 'TX-MNTPRO-S',
    contextKey: 'FLIGHT|TRAVEL', factFamily: 'posted_movement',
    categorySlug: 'travel',
  });
});

test('active rules API clears v1 merchant-only cache and emits the canonical v2 hash', async () => {
  const handlers = new Map();
  const app = { get: (path, ...middleware) => handlers.set(`GET ${path}`, middleware.at(-1)), post() {} };
  const calls = [];
  const client = {
    query: async (sql) => {
      calls.push(sql);
      if (sql.includes('FROM public.user_consents')) return { rows: [{ granted: true }] };
      if (sql.includes('FROM public.sms_rule_bundles')) return { rows: [] };
      if (sql.includes('FROM public.sms_rule_candidates')) return { rows: [] };
      if (sql.includes('sms_approved_category_rules_v2')) return { rows: [{
        merchant_key: 'TRAVEL WORLD', sender_key: 'TX-MNTPRO-S',
        context_key: 'FLIGHT|TRAVEL', fact_family: 'posted_movement',
        category_slug: 'travel', support_count: 10, agreement_rate: 0.9,
      }] };
      if (sql.includes('sms_rule_negative_evidence')) return { rows: [] };
      if (sql.includes('sms_rule_candidate_assignments')) return { rows: [] };
      return { rows: [] };
    },
  };
  registerSmsRuleBundleRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    requireAdmin: (_req, _res, next) => next(),
    withUserClient: async (_userId, callback) => callback(client),
  });
  const res = response();
  await handlers.get('GET /sms/rules/active')({ userId: 'profile' }, res);

  assert.equal(res.statusCode, 200);
  assert.deepEqual(res.payload.categoryRules, []);
  assert.equal(res.payload.categoryRulesVersion, 1);
  const v1Hash = crypto.createHash('sha256').update(JSON.stringify({
    categoryRulesVersion: 1,
    minClientVersion: '1.0.0',
    categoryRules: [],
  })).digest('hex');
  assert.equal(res.payload.categoryRulesSha256, v1Hash);
  assert.equal(res.payload.categoryRulesV2Version, 2);
  assert.deepEqual(res.payload.categoryRulesV2, [{
    merchantKey: 'TRAVEL WORLD', senderKey: 'TX-MNTPRO-S',
    contextKey: 'FLIGHT|TRAVEL', factFamily: 'posted_movement',
    categorySlug: 'travel', supportCount: 10, agreementBp: 9000,
  }]);
  const v2Hash = crypto.createHash('sha256').update(JSON.stringify({
    categoryRulesV2Version: 2,
    minClientVersion: '1.0.0',
    categoryRulesV2: res.payload.categoryRulesV2,
  })).digest('hex');
  assert.equal(res.payload.categoryRulesV2Sha256, v2Hash);
  assert.ok(calls.some((sql) => sql.includes('sms_approved_category_rules_v2')));
  assert.ok(calls.every((sql) => !sql.includes('sms_approved_category_rules()')));
});

test('v2 admin review requires exact tuple and rechecks current aggregate before approval', async () => {
  const handlers = new Map();
  const app = {
    get() {},
    post: (path, ...middleware) => handlers.set(`POST ${path}`, middleware.at(-1)),
  };
  const calls = [];
  const client = {
    query: async (sql, params) => {
      calls.push({ sql, params });
      if (sql.includes('sms_shared_category_rules_v2')) return { rows: [{
        merchant_key: 'TRAVEL WORLD', sender_key: 'TX-MNTPRO-S',
        context_key: 'FLIGHT|TRAVEL', fact_family: 'posted_movement',
        category_slug: 'travel', support_count: 11, agreement_rate: 0.91,
      }] };
      return { rows: [] };
    },
  };
  registerSmsRuleBundleRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    requireAdmin: (_req, _res, next) => next(),
    withUserClient: async (_userId, callback) => callback(client),
  });
  const request = {
    userId: 'admin',
    body: {
      merchantKey: 'TRAVEL WORLD', senderKey: 'TX-MNTPRO-S',
      contextKey: 'FLIGHT|TRAVEL', factFamily: 'posted_movement',
      categorySlug: 'travel', decision: 'approved', reason: 'verified context',
    },
  };
  const res = response();
  await handlers.get('POST /admin/sms-rules/category-proposals/review')(request, res);
  assert.equal(res.statusCode, 200);
  assert.ok(calls.some(({ sql, params }) => sql.includes('sms_shared_category_rules_v2') &&
    params?.includes('FLIGHT|TRAVEL')));
  const insert = calls.find(({ sql }) => sql.includes('INSERT INTO public.sms_category_rule_v2_approvals'));
  assert.ok(insert);
  assert.deepEqual(insert.params.slice(0, 7), [
    'TRAVEL WORLD', 'TX-MNTPRO-S', 'FLIGHT|TRAVEL', 'posted_movement',
    'travel', 'approved', 'admin',
  ]);
  const audit = calls.find(({ sql }) => sql.includes("'review_sms_category_rule_v2'"));
  assert.ok(audit.params[1].includes('FLIGHT|TRAVEL'));
});

test('v2 admin review rejects noncanonical or unknown context tokens before database access', async () => {
  const handlers = new Map();
  const app = { get() {}, post: (path, ...middleware) => handlers.set(`POST ${path}`, middleware.at(-1)) };
  let databaseCalls = 0;
  registerSmsRuleBundleRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    requireAdmin: (_req, _res, next) => next(),
    withUserClient: async (_userId, callback) => callback({
      query: async () => { databaseCalls++; return { rows: [] }; },
    }),
  });
  const res = response();
  await handlers.get('POST /admin/sms-rules/category-proposals/review')({
    userId: 'admin',
    body: {
      merchantKey: 'TRAVEL WORLD', senderKey: 'TX-MNTPRO-S',
      contextKey: 'PERSONALNAME', factFamily: 'posted_movement',
      categorySlug: 'travel', decision: 'approved', reason: 'verified context',
    },
  }, res);
  assert.equal(res.statusCode, 400);
  assert.equal(databaseCalls, 0);
});
