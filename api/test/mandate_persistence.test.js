const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { merchantSeriesKey } = require('../src/recurring');
const importResolvers = require('../src/import_resolvers');
const { extractVpa, extractMcc } = require('../src/merchant_category');

// index.js starts the API server when required, so extract the pure writer in
// the same way as the existing index.js focused tests do.
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
const start = source.indexOf('async function persistSubscriptionMandate(');
const end = source.indexOf('const app = express();', start);
const persistSubscriptionMandate = new Function(
  'merchantSeriesKey',
  'importResolvers',
  'extractVpa',
  'extractMcc',
  `${source.slice(start, end)}\nreturn persistSubscriptionMandate;`,
)(merchantSeriesKey, importResolvers, extractVpa, extractMcc);

test('mandate ceiling is never written as a recurring price or expected payment', async () => {
  const calls = [];
  const client = {
    async query(sql, params) {
      calls.push({ sql, params });
      return { rows: [{ id: 'series-1', detection_source: 'mandate' }] };
    },
  };

  const result = await persistSubscriptionMandate(client, 'profile-1', {
    parsed: {
      ok: true,
      lifecycle: 'active',
      fields: {
        merchant: 'NETFLIX',
        amountInr: 2000,
        cadenceDays: 30,
        cadenceExplicit: true,
        instrument: 'upi_bank',
      },
    },
    body: 'AutoPay mandate registered for NETFLIX with maximum limit INR 2,000',
    occurred: new Date('2026-10-16T10:00:00.000Z'),
    patternIssuerId: null,
  });

  assert.equal(result.id, 'series-1');
  assert.ok(calls.length >= 3); // card lookup, category lookup, recurring write
  const insert = calls.at(-1);
  assert.match(insert.sql, /typical_amount_inr/);
  assert.equal(insert.params[7], 0);
  assert.equal(insert.params[10], null);
  assert.equal(insert.params[12], false);
  assert.match(insert.sql, /WHEN recurring_series\.detection_source = 'mandate' THEN 0/);
});
