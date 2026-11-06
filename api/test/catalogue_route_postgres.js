'use strict';

// Coordinator-invoked integration check for the /catalogue ETag fingerprint
// against a real, migrated Postgres. Not matched by test/*.test.js on purpose.
//   CATALOGUE_ETAG_TEST_URL=postgres://postgres:pg@127.0.0.1:55432/postgres node api/test/catalogue_route_postgres.js
// It commits its own fixtures and removes them at the end. Use a throwaway DB.
const assert = require('node:assert/strict');
const { Client } = require('pg');
const { FINGERPRINT_SQL } = require(process.env.CATALOGUE_ROUTE_MODULE || '../src/catalogue_route');

async function main() {
  const url = process.env.CATALOGUE_ETAG_TEST_URL;
  if (!url) throw new Error('CATALOGUE_ETAG_TEST_URL is required');
  const host = new URL(url).hostname;
  if (!['127.0.0.1', 'localhost', '::1'].includes(host)) throw new Error('loopback database only');
  const db = new Client({ connectionString: url });
  await db.connect();
  const q = (sql, params) => db.query(sql, params);
  const fp = async () => JSON.stringify((await q(FINGERPRINT_SQL)).rows[0]);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  let last = await fp();
  const changes = async (label, fn) => {
    await fn();
    const now = await fp();
    assert.notEqual(now, last, `${label}: fingerprint must change`);
    last = now;
  };

  const issuer = (await q("INSERT INTO issuers (slug, name) VALUES ('etag-test-bank', 'Etag Bank') RETURNING id")).rows[0].id;
  const mk = async (slug, status) => (await q(
    `INSERT INTO card_products (issuer_id, slug, name, network, status, verified_at)
     VALUES ($1, $2, $2, 'visa', $3, now()) RETURNING id`, [issuer, slug, status])).rows[0].id;
  const a = await mk('etag-a', 'published');
  const b = await mk('etag-b', 'published');
  const c = await mk('etag-c', 'draft');
  try {
    // make B hold the maximum data_version, then edit A (which does not)
    for (let i = 0; i < 4; i += 1) {
      await q("INSERT INTO reward_rules (card_product_id, unit, rate, notes) VALUES ($1, 'points_per_100', 1, $2)", [b, `b${i}`]);
    }
    last = await fp();
    assert.equal(await fp(), last, 'no change: same fingerprint');
    await sleep(5);
    await changes('edit a rule on a card that is NOT the max version', () =>
      q("INSERT INTO reward_rules (card_product_id, unit, rate, notes) VALUES ($1, 'points_per_100', 1, 'a-rule')", [a]));
    await changes('card column edit (name)', () => q("UPDATE card_products SET name = 'renamed' WHERE id = $1", [a]));
    await changes('card column edit (point value)', () => q('UPDATE card_products SET point_value_inr = 0.5 WHERE id = $1', [b]));
    await changes('redemption option insert', () =>
      q("INSERT INTO redemption_options (card_product_id, program_name, method, value_per_point_inr) VALUES ($1, 'p', 'statement_credit', 0.25)", [a]));
    await changes('redemption option update', () => q('UPDATE redemption_options SET value_per_point_inr = 0.3 WHERE card_product_id = $1', [a]));
    await changes('issuer rename', () => q("UPDATE issuers SET name = 'Etag Bank Renamed' WHERE id = $1", [issuer]));
    await q("INSERT INTO payment_platforms (slug, name, kind, aliases) VALUES ('etag_test_app', 'Etag App', 'payment_app', ARRAY['one'])");
    last = await fp();
    await changes('platform alias edit', () => q("UPDATE payment_platforms SET aliases = ARRAY['one','two'] WHERE slug = 'etag_test_app'"));
    await q("INSERT INTO merchant_brands (slug, name, aliases) VALUES ('etag_test_brand', 'Etag Brand', ARRAY['x'])");
    last = await fp();
    await changes('merchant alias edit', () => q("UPDATE merchant_brands SET aliases = ARRAY['x','y'] WHERE slug = 'etag_test_brand'"));
    await changes('unpublish A and publish C (count unchanged)', async () => {
      await q("UPDATE card_products SET status = 'draft' WHERE id = $1", [a]);
      await q("UPDATE card_products SET status = 'published' WHERE id = $1", [c]);
    });
    assert.equal(await fp(), last, 'no change: same fingerprint again');

    // cheap: plan has no view or jsonb aggregation
    const plan = (await q(`EXPLAIN (ANALYZE) ${FINGERPRINT_SQL}`)).rows.map((r) => r['QUERY PLAN']).join('\n');
    const ms = Number(/Execution Time: ([\d.]+)/.exec(plan)[1]);
    console.log(`fingerprint execution time ${ms} ms`);
    assert.ok(ms < 100, 'fingerprint query must stay cheap');
    console.log('catalogue ETag fingerprint postgres checks passed');
  } finally {
    await q("DELETE FROM payment_platforms WHERE slug = 'etag_test_app'");
    await q("DELETE FROM merchant_brands WHERE slug = 'etag_test_brand'");
    await q('DELETE FROM card_products WHERE id = ANY($1)', [[a, b, c]]);
    await q('DELETE FROM issuers WHERE id = $1', [issuer]);
    await db.end();
  }
}
main().catch((err) => { console.error(err.message); process.exit(1); });
