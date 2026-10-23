const test = require('node:test');
const assert = require('node:assert/strict');

const {
  resolveUserCardForImport,
  resolveCategoryAssignmentForImport,
  resolveCategoryForImport,
  resolveUserMerchantRule,
  resolveUserMerchantRuleForImport,
  isUnsafeUserMerchantName,
  syncDueDayFromSms,
  syncStatementDayFromSms,
} = require('../src/import_resolvers');

const activeRule = (overrides = {}) => ({
  id: 'rule-1',
  match_basis: 'vpa',
  match_value: 'shop@upi',
  category_id: 'rule-category',
  user_category_id: null,
  is_active: true,
  version: 1,
  ...overrides,
});

test('future merchant rule matches exact VPA across display-name changes', () => {
  const result = resolveUserMerchantRule([activeRule()], {
    merchantVpa: ' SHOP@UPI ',
    merchantName: 'Different Display Name',
    entryKind: 'spend',
    status: 'active',
  });
  assert.equal(result.categoryId, 'rule-category');
  assert.equal(result.matchBasis, 'vpa');
});

test('future merchant rule does not fall back to name when a different VPA is present', () => {
  const result = resolveUserMerchantRule([
    activeRule({ match_value: 'other@upi' }),
    activeRule({ id: 'rule-name', match_basis: 'strict_name', match_value: 'same shop' }),
  ], {
    merchantVpa: 'different@upi',
    merchantName: 'Same Shop',
    entryKind: 'spend',
    status: 'active',
  });
  assert.equal(result, null);
});

test('future merchant rule uses strict normalized name only without a VPA', () => {
  const result = resolveUserMerchantRule([
    activeRule({ match_basis: 'strict_name', match_value: 'same shop' }),
  ], {
    merchantName: '  Same   Shop ',
    entryKind: 'spend',
    status: 'active',
  });
  assert.equal(result.categoryId, 'rule-category');
  assert.equal(result.matchBasis, 'strict_name');
});

test('generic and gateway labels cannot match a name rule', () => {
  assert.equal(isUnsafeUserMerchantName('UPI Payment'), true);
  assert.equal(isUnsafeUserMerchantName('Razorpay'), true);
  assert.equal(resolveUserMerchantRule([
    activeRule({ match_basis: 'strict_name', match_value: 'razorpay' }),
  ], { merchantName: 'Razorpay', entryKind: 'spend' }), null);
});

test('explicit category stays above a rule at the assignment boundary', async () => {
  const client = fakeClient([[{ id: 'dining-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'Same Shop',
    categoryHint: 'Dining',
    userMerchantRules: [activeRule({ match_basis: 'strict_name', match_value: 'same shop' })],
  });
  assert.equal(result, 'dining-category');
});

test('a user merchant rule outranks inferred private match terms', async () => {
  const client = fakeClient([]);
  const result = await resolveCategoryAssignmentForImport(client, 'user-1', {
    merchantName: 'Same Shop',
    messageText: 'payment for office supplies',
    userMerchantRules: [activeRule({ match_basis: 'strict_name', match_value: 'same shop' })],
  });
  assert.deepEqual(result, { categoryId: 'rule-category', userCategoryId: null });
  assert.equal(client.calls.length, 0);
});

test('category resolution ignores flag-only merchant rules', () => {
  const result = resolveUserMerchantRule([
    activeRule({
      id: 'flag-rule',
      action: 'flag',
      category_id: null,
      flag: 'needs_review',
    }),
    activeRule({
      id: 'category-rule',
      action: 'category',
      category_id: 'food-category',
      version: 2,
    }),
  ], { merchantVpa: 'shop@upi', entryKind: 'spend', status: 'active' });

  assert.equal(result.id, 'category-rule');
  assert.equal(result.categoryId, 'food-category');
  assert.equal(result.action, 'category');
});

test('a flag-only merchant rule never becomes a category assignment', async () => {
  const client = fakeClient([[], [], [], [], [], [{ id: 'other-category' }]]);
  const result = await resolveCategoryAssignmentForImport(client, 'user-1', {
    merchantName: 'Same Shop',
    vpa: 'shop@upi',
    userMerchantRules: [{
      id: 'flag-rule',
      action: 'flag',
      match_basis: 'vpa',
      match_value: 'shop@upi',
      category_id: null,
      is_active: true,
      flag: 'needs_review',
    }],
  });

  assert.equal(result.categoryId, 'other-category');
  assert.equal(result.userCategoryId, null);
});

test('future category rules remain opt-out at import boundary', async () => {
  const client = fakeClient([[{ id: 'explicit-category' }]]);
  const rule = activeRule({ category_id: 'remembered-category' });

  assert.equal(
    await resolveUserMerchantRuleForImport(client, 'user-1', {
      vpa: 'shop@upi',
      entryKind: 'spend',
      status: 'active',
      userMerchantRules: [rule],
      applyUserMerchantRule: false,
    }),
    null,
  );
  const explicit = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'Same Shop',
    vpa: 'shop@upi',
    categoryHint: 'Dining',
    userMerchantRules: [rule],
  });
  assert.equal(explicit, 'explicit-category');
});

test('inactive, non-spend, split, refund and reversal rows are ineligible', () => {
  const rule = activeRule();
  for (const transaction of [
    { merchantVpa: 'shop@upi', status: 'ignored' },
    { merchantVpa: 'shop@upi', entryKind: 'income' },
    { merchantVpa: 'shop@upi', isSplitParent: true },
    { merchantVpa: 'shop@upi', isRefund: true },
    { merchantVpa: 'shop@upi', isReversal: true },
  ]) {
    assert.equal(resolveUserMerchantRule([rule], transaction), null);
  }
});

test('conflicting active rules resolve deterministically to the newest version', () => {
  const result = resolveUserMerchantRule([
    activeRule({ id: 'old', version: 1, category_id: 'old-category' }),
    activeRule({ id: 'new', version: 2, category_id: 'new-category' }),
  ], { merchantVpa: 'shop@upi' });
  assert.equal(result.categoryId, 'new-category');
});

test('active merchant rules resolve nested private-category parents before applying', async () => {
  const client = {
    async query(sql) {
      if (sql.includes('FROM user_merchant_category_rules')) {
        return {
          rows: [{
            id: 'rule-nested', match_basis: 'vpa', match_value: 'shop@upi',
            category_id: 'food', user_category_id: 'child', is_active: true,
            version: 1, updated_at: '2026-10-23T00:00:00Z',
          }],
        };
      }
      if (sql.includes('FROM user_categories')) {
        return {
          rows: [
            { id: 'child', parent_category_id: null, parent_user_category_id: 'parent' },
            { id: 'parent', parent_category_id: 'food', parent_user_category_id: null },
          ],
        };
      }
      throw new Error(`unexpected query: ${sql}`);
    },
  };
  const result = await resolveUserMerchantRuleForImport(client, 'user-1', {
    vpa: 'shop@upi', entryKind: 'spend', status: 'active',
  });
  assert.equal(result.categoryId, 'food');
  assert.equal(result.userCategoryId, 'child');
});

function fakeClient(rowsByCall) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      return { rows: rowsByCall[calls.length - 1] || [] };
    },
  };
}

test('card import matching uses issuer plus last4 when both are available', async () => {
  const client = fakeClient([[{ id: 'card-hdfc-9080' }]]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    last4: '9080',
    patternIssuerId: 'issuer-hdfc',
  });

  assert.deepEqual(result, {
    userCardId: 'card-hdfc-9080',
    basis: 'issuer+last4:9080',
  });
  assert.deepEqual(client.calls[0].params, ['user-1', '9080', 'issuer-hdfc', null]);
});

test('card import matching does not attach a known issuer SMS to another bank', async () => {
  const client = fakeClient([[]]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    last4: '9080',
    patternIssuerId: 'issuer-hdfc',
  });

  assert.equal(result, null);
  assert.equal(client.calls.length, 1);
});

test('card import matching keeps a shared last4 on the correct card type', async () => {
  const client = fakeClient([[{ id: 'debit-9080' }]]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    last4: '9080',
    patternIssuerId: 'issuer-hdfc',
    instrument: 'debit_card',
  });

  assert.deepEqual(result, {
    userCardId: 'debit-9080',
    basis: 'issuer+last4:9080',
  });
  assert.deepEqual(client.calls[0].params, ['user-1', '9080', 'issuer-hdfc', 'debit']);
  assert.match(client.calls[0].sql, /cp\.card_type::text = \$4::text/);
});

test('issuer-only matching also filters by physical card type', async () => {
  const client = fakeClient([[{ id: 'credit-hdfc' }]]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    patternIssuerId: 'issuer-hdfc',
    instrument: 'credit_card',
  });

  assert.deepEqual(result, { userCardId: 'credit-hdfc', basis: 'sole-card-for-issuer' });
  assert.deepEqual(client.calls[0].params, ['user-1', 'issuer-hdfc', 'credit']);
});

test('syncs the due day from an Axis statement to the matched active card', async () => {
  const body = [
    'Your statement for Axis Bank Credit Card no. XX7105 is generated.',
    'Due on: 02-11-26',
    'Total amt: INR Dr. 2147.00',
    'Min amt due: INR Dr. 100.00',
  ].join(' ');
  const client = fakeClient([[{ id: 'axis-7105' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    if (client.calls.length === 1) return { rows: [{ id: 'axis-7105' }] };
    return { rows: [{ id: 'axis-7105' }], rowCount: 1 };
  };

  const result = await syncDueDayFromSms(client, 'user-1', {
    body,
    patternIssuerId: null,
  });

  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 2);
  assert.equal(result.userCardId, 'axis-7105');
  assert.equal(client.calls.length, 2);
  assert.deepEqual(client.calls[1].params, [2, 'axis-7105', 'user-1']);
  assert.match(client.calls[1].sql, /SET due_day = \$1/);
});

test('uses a distinctive MoneyBack product name when a historical alert has no suffix', async () => {
  const body = 'HDFC Bank MoneyBack+ Credit Card statement. Payment due date is 16/10/2026.';
  const client = fakeClient([[{ id: 'moneyback-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    if (client.calls.length === 1) return { rows: [{ id: 'moneyback-card' }] };
    return { rows: [{ id: 'moneyback-card' }], rowCount: 1 };
  };

  const result = await syncDueDayFromSms(client, 'user-1', {
    body,
    patternIssuerId: 'issuer-hdfc',
  });

  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 16);
  assert.equal(result.userCardId, 'moneyback-card');
  assert.equal(result.basis, 'product-name');
  assert.deepEqual(client.calls[0].params, [
    'user-1',
    'credit',
    'issuer-hdfc',
    body,
  ]);
  assert.deepEqual(client.calls[1].params, [16, 'moneyback-card', 'user-1']);
});

test('syncs statement day from the historical statement alert date', async () => {
  const body = 'Your statement for HDFC Bank Credit Card ending XX8708 is generated. Due on: 20/10/2026.';
  const client = fakeClient([[{ id: 'hdfc-8708' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    if (client.calls.length === 1) return { rows: [{ id: 'hdfc-8708' }] };
    return { rows: [{ id: 'hdfc-8708' }], rowCount: 1 };
  };

  const result = await syncStatementDayFromSms(client, 'user-1', {
    body,
    observedAt: new Date('2026-09-05T10:00:00.000Z'),
    patternIssuerId: null,
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });

  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 5);
  assert.deepEqual(client.calls[1].params, [5, 'hdfc-8708', 'user-1', false]);
  assert.match(client.calls[1].sql, /SET statement_day = \$1/);
});

test('does not learn statement day from a purchase SMS', async () => {
  const result = await syncStatementDayFromSms({ query: async () => { throw new Error('should not query'); } }, 'user-1', {
    body: 'INR 500 spent on your credit card ending 8708 at SHOP on 05/09/2026.',
    observedAt: new Date('2026-09-05T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result, null);
});

test('does not lock the billing day from current or older-than-two-month alerts', async () => {
  for (const observedAt of ['2026-10-05T10:00:00Z', '2026-07-05T10:00:00Z']) {
    const result = await syncStatementDayFromSms({ query: async () => { throw new Error('should not query'); } }, 'user-1', {
      body: 'Your credit card ending 8708 statement is generated.',
      observedAt,
      asOf: new Date('2026-10-20T10:00:00Z'),
    });
    assert.equal(result, null);
  }
});

test('uses a printed prior-cycle statement date even when SMS arrives in the current month', async () => {
  const client = fakeClient([[{ id: 'axis-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'axis-card' }] }
      : { rows: [{ id: 'axis-card' }], rowCount: 1 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your Axis credit card ending 7105 statement was generated on 15-Sep-2026. Due on 02-Oct-2026.',
    observedAt: new Date('2026-10-01T10:00:00Z'),
    asOf: new Date('2026-10-20T10:00:00Z'),
  });
  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 15);
});

test('accepts a current-month statement only when the generation date is printed', async () => {
  const client = fakeClient([[{ id: 'axis-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'axis-card' }] }
      : { rows: [{ id: 'axis-card' }], rowCount: 1 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your Axis credit card ending 7105 statement generated on 15-Oct-2026. Due on 02-Nov-2026.',
    observedAt: new Date('2026-10-16T10:00:00Z'),
    asOf: new Date('2026-10-20T10:00:00Z'),
  });
  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 15);
});

test('learns a printed billing day no matter how old the SMS is', async () => {
  const client = fakeClient([[{ id: 'axis-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'axis-card' }] }
      : { rows: [{ id: 'axis-card' }], rowCount: 1 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your Axis credit card ending 7105 statement was generated on 15-May-2026. Due on 02-Jun-2026.',
    observedAt: new Date('2026-10-18T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 15);
});

test('keeps the printed period end preferred over the receive fallback', async () => {
  const client = fakeClient([[{ id: 'hdfc-8708' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'hdfc-8708' }] }
      : { rows: [{ id: 'hdfc-8708' }], rowCount: 1 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your statement for HDFC Bank Credit Card ending XX8708 for the period 04-Sep-2026 to 03-Oct-2026 is ready.',
    observedAt: new Date('2026-10-05T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 3);
});

test('learns a due day from an older bill alert', async () => {
  const body = 'HDFC Bank Credit Card ending XX8708. Payment due date: 20/04/2026.';
  const client = fakeClient([[{ id: 'hdfc-8708' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    if (client.calls.length === 1) return { rows: [{ id: 'hdfc-8708' }] };
    return { rows: [{ id: 'hdfc-8708' }], rowCount: 1 };
  };

  const result = await syncDueDayFromSms(client, 'user-1', {
    body,
    observedAt: new Date('2026-09-05T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });

  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 20);
  assert.deepEqual(client.calls[1].params, [20, 'hdfc-8708', 'user-1']);
});

test('a newer printed billing day heals a previously SMS-learned one', async () => {
  const client = fakeClient([[{ id: 'axis-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'axis-card' }] }
      : { rows: [], rowCount: 1 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your Axis credit card ending 7105 statement was generated on 05-Jun-2026.',
    observedAt: new Date('2026-09-18T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, true);
  assert.equal(result.detected.day, 5);
  assert.match(client.calls[1].sql, /statement_day_source = 'sms'/);
  // explicit flag as the last parameter drives the heal/keep decision
  assert.deepEqual(client.calls[1].params[3], true);
  assert.match(client.calls[1].sql, /statement_day IS DISTINCT FROM \$1/);
});

test('a receive-date fallback never overwrites an existing billing day', async () => {
  const body = 'Your credit card ending 8708 statement is generated. Due on: 20/10/2026.';
  const client = fakeClient([[{ id: 'hdfc-8708' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'hdfc-8708' }] }
      : { rows: [], rowCount: 0 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body,
    observedAt: new Date('2026-09-20T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, false);
  assert.equal(result.detected.day, 20);
  // fallback tier cannot replace an existing value
  assert.deepEqual(client.calls[1].params[3], false);
});

test('a user-saved billing day is never overwritten by an SMS heal', async () => {
  const client = fakeClient([[{ id: 'axis-card' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'axis-card' }] }
      : { rows: [], rowCount: 0 };
  };
  const result = await syncStatementDayFromSms(client, 'user-1', {
    body: 'Your Axis credit card ending 7105 statement was generated on 05-Jun-2026.',
    observedAt: new Date('2026-09-18T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, false);
});

test('a user-saved due day is never overwritten by an SMS heal', async () => {
  const body = 'Your statement for HDFC Bank Credit Card ending XX8708 is generated. Due on: 20/10/2026.';
  const client = fakeClient([[{ id: 'hdfc-8708' }]]);
  client.query = async (sql, params) => {
    client.calls.push({ sql, params });
    return client.calls.length === 1
      ? { rows: [{ id: 'hdfc-8708' }] }
      : { rows: [], rowCount: 0 };
  };
  const result = await syncDueDayFromSms(client, 'user-1', {
    body,
    observedAt: new Date('2026-09-05T10:00:00.000Z'),
    asOf: new Date('2026-10-20T10:00:00.000Z'),
  });
  assert.equal(result.updated, false);
});

test('category fallback recognises a fuel-station merchant when no rule exists', async () => {
  const client = fakeClient([[], [], [{ id: 'fuel-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
    userMerchantRules: [],
  });

  assert.equal(result, 'fuel-category');
  assert.deepEqual(client.calls[2].params, ['fuel']);
});

test('exact reviewed category hint is kept instead of reclassifying by merchant', async () => {
  const client = fakeClient([[{ id: 'dining-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'A merchant normally classified as groceries',
    categoryHint: 'Dining',
  });

  assert.equal(result, 'dining-category');
  assert.deepEqual(client.calls[0].params, ['dining']);
  assert.match(client.calls[0].sql, /spend_categories/);
});

test('published VPA category outranks local history and keyword fallback', async () => {
  const client = fakeClient([[{ category_id: 'vpa-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'FOODHUB@upi',
    vpa: 'foodhub@upi',
    userMerchantRules: [],
  });

  assert.equal(result, 'vpa-category');
  assert.deepEqual(client.calls[0].params, ['foodhub@upi']);
});

test('MCC category is used when no published VPA is available', async () => {
  const client = fakeClient([[], [{ category_id: 'mcc-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'FOODHUB@upi',
    vpa: 'foodhub@upi',
    mcc: '5812',
    userMerchantRules: [],
  });

  assert.equal(result, 'mcc-category');
  assert.deepEqual(client.calls[1].params, ['5812']);
});

test('personal VPA history stabilizes a merchant when the public directory has no row', async () => {
  const client = fakeClient([[], [{ category_id: 'personal-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'FOODHUB STORE',
    vpa: 'foodhub@upi',
    userMerchantRules: [],
  });

  assert.equal(result, 'personal-category');
  assert.match(client.calls[1].sql, /t\.merchant_vpa = \$2/);
  assert.deepEqual(client.calls[1].params, ['user-1', 'foodhub@upi']);
});

test('explicit merchant history still outranks built-in category hints', async () => {
  const client = fakeClient([[{ category_id: 'custom-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
    userMerchantRules: [],
  });

  assert.equal(result, 'custom-category');
  assert.equal(client.calls.length, 1);
  assert.match(client.calls[0].sql, /prior_category\.slug <> 'other'/);
});

test('an unknown merchant is assigned the explicit Other bucket instead of NULL', async () => {
  const client = fakeClient([[], [], [{ id: 'other-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'A SMALL LOCAL SHOP 123',
    userMerchantRules: [],
  });

  assert.equal(result, 'other-category');
  assert.match(client.calls[2].sql, /slug = 'other'/);
});

test('a merchant still present in the SMS body is classified when the parser omitted the merchant field', async () => {
  const client = fakeClient([[], [{ id: 'fuel-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: undefined,
    messageText: 'Spent Rs.210 at QUALITY FUEL STATION on 2026-10-02',
    userMerchantRules: [],
  });

  assert.equal(result, 'fuel-category');
  assert.match(client.calls[0].sql, /slug = \$1/);
  assert.deepEqual(client.calls[0].params, ['fuel']);
});
test('placeholder merchant names never inherit a category from unrelated unknown purchases', async () => {
  const client = fakeClient([[{ id: 'other-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {merchantName:'Unknown merchant', userMerchantRules: []});
  assert.equal(result, 'other-category');
  assert.equal(client.calls.length, 1);
  assert.match(client.calls[0].sql, /slug = 'other'/);
});

test('private subcategory terms win over built-in import classification', async () => {
  const client = fakeClient([[
    {
      id: 'subcategory-office',
      name: 'Office',
      slug: 'office',
      parent_category_id: 'travel-category',
      parent_user_category_id: null,
      match_terms: ['cab', 'uber'],
      parent_category_name: 'Travel',
      parent_user_category_name: null,
    },
  ]]);
  const result = await resolveCategoryAssignmentForImport(client, 'user-1', {
    merchantName: 'Uber trip to office',
    messageText: 'UPI payment to Uber',
    userMerchantRules: [],
  });

  assert.deepEqual(result, {
    categoryId: 'travel-category',
    userCategoryId: 'subcategory-office',
    categoryName: 'Travel',
    userCategoryName: 'Office',
  });
  assert.deepEqual(client.calls[0].params, ['user-1']);
});

test('a suffix printed straight after "Credit Card" resolves the card', async () => {
  // "Credit Card 8708 bill" has no marker word ("ending", "XX"), so the
  // strict text rule read it as no card at all — and the card's own due day
  // could never be learned from the message that states it.
  const client = fakeClient([[], [{ id: 'card-hdfc-8708' }]]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    last4: null,
    patternIssuerId: null,
    instrument: 'credit_card',
    messageText:
      'AutoPay Reminder: Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill.',
  });

  assert.deepEqual(result, {
    userCardId: 'card-hdfc-8708',
    basis: 'card-suffix:8708',
  });
});

test('a card limit is never read as a card number', async () => {
  const client = fakeClient([[], []]);
  const result = await resolveUserCardForImport(client, 'user-1', {
    last4: null,
    patternIssuerId: null,
    instrument: 'credit_card',
    messageText: 'Your Credit Card limit is 5000 and is available now.',
  });

  assert.equal(result, null);
});
