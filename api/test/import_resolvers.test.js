const test = require('node:test');
const assert = require('node:assert/strict');

const { resolveUserCardForImport, resolveCategoryForImport } = require('../src/import_resolvers');

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
  assert.deepEqual(client.calls[0].params, ['user-1', '9080', 'issuer-hdfc']);
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

test('category fallback recognises a fuel-station merchant when no rule exists', async () => {
  const client = fakeClient([[], [], [{ id: 'fuel-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
  });

  assert.equal(result, 'fuel-category');
  assert.deepEqual(client.calls[2].params, ['fuel']);
});

test('explicit merchant history still outranks built-in category hints', async () => {
  const client = fakeClient([[{ category_id: 'custom-category' }]]);
  const result = await resolveCategoryForImport(client, 'user-1', {
    merchantName: 'QUALITY FUEL STATION',
  });

  assert.equal(result, 'custom-category');
  assert.equal(client.calls.length, 1);
});
