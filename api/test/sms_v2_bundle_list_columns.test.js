'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createPgStore } = require('../src/sms_v2/rules_store');

// Each bundle row holds its whole rule set twice (`body` and `served_body`, about 2.8 MB each). The admin bundle list
// only returns a summary, so its query must not read them: with a few bundles that took over 5 s and the page failed.
test('the bundle list query reads summary columns only, never the whole rule sets', async () => {
  const queries = [];
  const client = {
    async query(sql, params) {
      queries.push({ sql, params });
      return { rows: [{ bundle_version: 3, manifest: { rules: 1084 }, sha256: 'ab', signature: 'sig', key_id: 'prod-2026-11-a', cohort: 'all', golden_report: null, status: 'active', published_by: 'import', created_at: '2026-11-06T18:28:54Z' }] };
    },
  };
  const store = createPgStore({ withUserClient: async (_userId, operation) => operation(client) });

  const rows = await store.tx('actor-1', (s) => s.listBundles(100));

  assert.equal(queries.length, 1);
  const { sql, params } = queries[0];
  assert.match(sql, /FROM sms_v2_bundles ORDER BY bundle_version DESC LIMIT \$1/);
  assert.doesNotMatch(sql, /\*/, 'no SELECT *');
  assert.doesNotMatch(sql, /\bbody\b/);
  assert.doesNotMatch(sql, /served_body/);
  assert.deepEqual(params, [100]);
  assert.equal(rows[0].bundleVersion, 3);
  assert.equal(rows[0].cohort, 'all');
  assert.equal(rows[0].keyId, 'prod-2026-11-a');
  assert.equal(rows[0].body, undefined);
});
