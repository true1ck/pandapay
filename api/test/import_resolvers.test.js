const test = require('node:test');
const assert = require('node:assert/strict');

const {
  resolveUserCardForImport,
  resolveCategoryForImport,
  syncDueDayFromSms,
} = require('../src/import_resolvers');

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

test('category fallback recognises a fuel-station merchant when no rule exists', async () => {
  const client = fakeClient([[], [], [{ id: 'fuel-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
  });

  assert.equal(result, 'fuel-category');
  assert.deepEqual(client.calls[2].params, ['fuel']);
});

test('published VPA category outranks local history and keyword fallback', async () => {
  const client = fakeClient([[{ category_id: 'vpa-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'FOODHUB@upi',
    vpa: 'foodhub@upi',
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
  });

  assert.equal(result, 'mcc-category');
  assert.deepEqual(client.calls[1].params, ['5812']);
});

test('personal VPA history stabilizes a merchant when the public directory has no row', async () => {
  const client = fakeClient([[], [{ category_id: 'personal-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'FOODHUB STORE',
    vpa: 'foodhub@upi',
  });

  assert.equal(result, 'personal-category');
  assert.match(client.calls[1].sql, /t\.merchant_vpa = \$2/);
  assert.deepEqual(client.calls[1].params, ['user-1', 'foodhub@upi']);
});

test('explicit merchant history still outranks built-in category hints', async () => {
  const client = fakeClient([[{ category_id: 'custom-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
  });

  assert.equal(result, 'custom-category');
  assert.equal(client.calls.length, 1);
  assert.match(client.calls[0].sql, /prior_category\.slug <> 'other'/);
});

test('an unknown merchant is assigned the explicit Other bucket instead of NULL', async () => {
  const client = fakeClient([[], [], [{ id: 'other-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'A SMALL LOCAL SHOP 123',
  });

  assert.equal(result, 'other-category');
  assert.match(client.calls[2].sql, /slug = 'other'/);
});

test('a merchant still present in the SMS body is classified when the parser omitted the merchant field', async () => {
  const client = fakeClient([[], [{ id: 'fuel-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: undefined,
    messageText: 'Spent Rs.210 at QUALITY FUEL STATION on 2026-10-02',
  });

  assert.equal(result, 'fuel-category');
  assert.match(client.calls[0].sql, /slug = \$1/);
  assert.deepEqual(client.calls[0].params, ['fuel']);
});
