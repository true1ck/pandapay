'use strict';

// Card Rewards Phase 1, WP8 — server recording v2 against a real Postgres.
//
// Skipped unless CARD_STATE_V2_TEST_URL names a DISPOSABLE loopback database
// with every migration applied (db/scripts/product_migrate.js) and the
// directory seeded (api/scripts/seed_merchant_directory.js). The real-card
// tests also need the CardPipeline catalogue imported
// (api/scripts/import_card_pipeline.js); they skip a card that isn't there.
// Never point this at production: each test runs in one transaction that is
// rolled back, and the URL must be loopback.
//
// The recording code under test is the real index.js applyTransactionState /
// reverseTransactionState / reconcileCurrentCapStates (extracted the way
// sync_financial_postgres.js does), so the v2 dispatch in index.js is what runs.
// Recording runs as app_user with app.user_id set, so RLS applies as in the API.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const rewardMath = require('../src/reward_math');
const rewardV2 = require('../src/reward_math_v2');
const { periodBounds, addDays } = require('../src/cycles');
const { replayCurrentCapConsumption } = require('../src/card_state_reconciliation');
const { loadDirectory } = require('../src/merchant_directory');
const cardStateV2 = require('../src/card_state_v2');
const { recompute } = require('../scripts/recompute_card_state');
const F = require('./card_state_v2_fixture');

const RAW_URL = process.env.CARD_STATE_V2_TEST_URL;
const skip = RAW_URL ? false : 'CARD_STATE_V2_TEST_URL not set (disposable loopback Postgres, all migrations applied)';

function connectionString() {
  const url = new URL(RAW_URL);
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '::1'].includes(host)) {
    throw new Error('CARD_STATE_V2_TEST_URL must be a loopback postgres URL');
  }
  return url.toString();
}

async function withRollback(fn) {
  const { Client } = require('pg');
  const client = new Client({ connectionString: connectionString(), ssl: false });
  await client.connect();
  try {
    await client.query('BEGIN');
    await fn(client);
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    await client.end();
  }
}

/** index.js's real state functions, run in a sandbox with exactly their module dependencies. */
function extractIndexFunctions() {
  const source = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  const stateStart = source.indexOf('async function loadUserCardForState(client');
  const stateEnd = source.indexOf('/** Mirrors the txn_instrument / txn_entry_kind enums', stateStart);
  const reconcileStart = source.indexOf('async function reconcileCurrentCapStates(client, userId)');
  const reconcileEnd = source.lastIndexOf('/**', source.indexOf('async function detectDuplicates(client'));
  assert.ok(stateStart >= 0 && stateEnd > stateStart && reconcileStart >= 0 && reconcileEnd > reconcileStart);
  const context = { rewardMath, periodBounds, cardStateV2, replayCurrentCapConsumption };
  vm.runInNewContext(source.slice(stateStart, stateEnd), context, { filename: 'api/src/index.js' });
  vm.runInNewContext(source.slice(reconcileStart, reconcileEnd), context, { filename: 'api/src/index.js' });
  return context;
}

async function asUser(client, profileId) {
  await client.query('SET LOCAL ROLE app_user');
  await client.query(`SELECT set_config('app.user_id', $1, true)`, [profileId]);
}

async function asOwner(client) {
  await client.query('RESET ROLE');
}

async function dates(client) {
  const r = await client.query(
    `SELECT CURRENT_DATE::text AS today,
            date_trunc('month', CURRENT_DATE)::date::text AS month_start,
            (date_trunc('month', CURRENT_DATE) - interval '1 month')::date::text AS prev_month_start`,
  );
  return { today: r.rows[0].today, monthStart: r.rows[0].month_start, prevMonthStart: r.rows[0].prev_month_start };
}

async function categoryIds(client) {
  const r = await client.query(`SELECT slug, id FROM spend_categories`);
  return Object.fromEntries(r.rows.map((row) => [row.slug, row.id]));
}

const FIXTURE_CATEGORY_SLUG = { [F.CATEGORY.dining]: 'dining', [F.CATEGORY.rent]: 'rent', [F.CATEGORY.wallet]: 'wallet' };

/** The synthetic fixture card as real catalogue rows (published), one profile, one user card. */
async function seedSyntheticCard(client, { openedOn, statementDay = null }) {
  const cats = await categoryIds(client);
  const realCategory = (id) => (id == null ? null : cats[FIXTURE_CATEGORY_SLUG[id]]);
  const issuer = (await client.query(
    `INSERT INTO issuers (slug, name) VALUES ('wp8-synthetic-bank', 'WP8 Synthetic Bank') RETURNING id`,
  )).rows[0].id;
  const product = (await client.query(
    `INSERT INTO card_products (issuer_id, slug, name, network, status, verified_at, base_reward_unit,
                                base_reward_rate, point_value_inr, accrual_rounding, accrual_block_inr)
     VALUES ($1, 'wp8-synthetic-card', 'WP8 Synthetic Card', 'visa', 'published', now(), 'points_per_100',
             1, 0.25, 'floor', 100) RETURNING id`,
    [issuer],
  )).rows[0].id;
  for (const r of F.RULES) {
    await client.query(
      `INSERT INTO reward_rules (id, card_product_id, category_id, unit, rate, priority, rule_role,
                                 merchant_slugs, min_engine_version, display_note)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)`,
      [r.id, product, realCategory(r.category_id), r.unit, r.rate, r.priority, r.rule_role,
        r.merchant_slugs, r.min_engine_version, r.display_note],
    );
  }
  for (const c of F.CAPS) {
    await client.query(
      `INSERT INTO cap_rules (id, card_product_id, label, measure, period, cap_value, post_cap_rate,
                              cap_kind, cap_amount, scope, parent_cap_id, post_cap_behavior, anchor,
                              min_engine_version)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
      [c.id, product, c.label, c.measure, c.period, c.cap_value, c.post_cap_rate, c.cap_kind, c.cap_amount,
        c.scope, c.parent_cap_id, c.post_cap_behavior, c.anchor, c.min_engine_version],
    );
    for (const target of c.targets) {
      await client.query(`INSERT INTO cap_rule_targets (cap_rule_id, reward_rule_id) VALUES ($1, $2)`, [c.id, target]);
    }
  }
  for (const m of F.MILESTONES) {
    await client.query(
      `INSERT INTO milestone_rules (id, card_product_id, label, period, anchor, threshold_spend_inr,
                                    reward_description, reward_value_inr, window_days, excluded_category_ids)
       VALUES ($1, $2, $3, $4, $5, $6, $3, 500, $7, $8)`,
      [m.id, product, m.label, m.period, m.anchor, m.threshold_spend_inr, m.window_days,
        m.excluded_category_ids.map(realCategory)],
    );
  }
  const feeWaiver = (await client.query(
    `INSERT INTO fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr)
     VALUES ($1, 50000, 'annual', 500) RETURNING id`,
    [product],
  )).rows[0].id;
  const profileId = (await client.query(`INSERT INTO profiles (id) VALUES (gen_random_uuid()) RETURNING id`)).rows[0].id;
  const userCardId = (await client.query(
    `INSERT INTO user_cards (profile_id, card_product_id, opened_on, statement_day) VALUES ($1, $2, $3, $4) RETURNING id`,
    [profileId, product, openedOn, statementDay],
  )).rows[0].id;
  return { cats, product, feeWaiver, profileId, userCardId };
}

/** A real catalogue card, published for this transaction only, with one user card. */
async function seedCatalogueCard(client, slug, { openedOn }) {
  const product = (await client.query(`SELECT id FROM card_products WHERE slug = $1`, [slug])).rows[0];
  if (!product) return null;
  await client.query(`UPDATE card_products SET status = 'published', verified_at = now() WHERE id = $1`, [product.id]);
  const profileId = (await client.query(`INSERT INTO profiles (id) VALUES (gen_random_uuid()) RETURNING id`)).rows[0].id;
  const userCardId = (await client.query(
    `INSERT INTO user_cards (profile_id, card_product_id, opened_on) VALUES ($1, $2, $3) RETURNING id`,
    [profileId, product.id, openedOn],
  )).rows[0].id;
  return { cats: await categoryIds(client), product: product.id, profileId, userCardId };
}

/** POST /transactions' state half: insert the row, then the real applyTransactionState. */
async function recordSpend(client, fns, ids, spend) {
  const occurred = new Date(`${spend.day}T06:30:00Z`);
  const categoryId = spend.category ? ids.cats[spend.category] : null;
  const rail = spend.rail || 'unknown';
  const txnId = (await client.query(
    `INSERT INTO transactions (profile_id, user_card_id, amount_inr, occurred_at, merchant_name, mcc,
                               category_id, rail, source, instrument, entry_kind)
     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'manual', 'credit_card', 'spend') RETURNING id`,
    [ids.profileId, ids.userCardId, spend.amount, occurred, spend.merchant || null, spend.mcc || null, categoryId, rail],
  )).rows[0].id;
  const userCard = await fns.loadUserCardForState(client, ids.profileId, ids.userCardId);
  const state = await fns.applyTransactionState(client, ids.profileId, userCard, {
    txnId, userCardId: ids.userCardId, amount: spend.amount, occurred, categoryId, sign: 1,
    merchantName: spend.merchant || null, rail,
  });
  await client.query(`UPDATE transactions SET state_applied = true WHERE id = $1`, [txnId]);
  return { txnId, state };
}

/** POST /transactions/:id/ignore's state half: the real reverseTransactionState, then the status. */
async function ignoreSpend(client, fns, ids, txnId) {
  const old = (await client.query(`SELECT * FROM transactions WHERE id = $1`, [txnId])).rows[0];
  const userCard = await fns.loadUserCardForState(client, ids.profileId, old.user_card_id);
  const state = await fns.reverseTransactionState(client, ids.profileId, userCard, old);
  await client.query(`UPDATE transactions SET status = 'ignored' WHERE id = $1`, [txnId]);
  return state;
}

async function capRows(client, userCardId) {
  const r = await client.query(
    `SELECT cap_rule_id, consumed::float8 AS consumed, cap_kind, cap_amount::float8 AS cap_amount,
            approximate_window, to_char(period_start, 'YYYY-MM-DD') AS period_start,
            to_char(period_end, 'YYYY-MM-DD') AS period_end
       FROM cap_states WHERE user_card_id = $1 ORDER BY cap_rule_id, period_start`,
    [userCardId],
  );
  return r.rows;
}

const consumedById = (rows) => Object.fromEntries(rows.map((r) => [r.cap_rule_id, r.consumed]));

async function expectedOf(client, txnIds) {
  const r = await client.query(
    `SELECT id, expected_points::float8 AS points, expected_value_inr::float8 AS value, card_state_v2
       FROM transactions WHERE id = ANY($1::uuid[])`,
    [txnIds],
  );
  const byId = new Map(r.rows.map((row) => [row.id, row]));
  return txnIds.map((id) => byId.get(id));
}

async function milestoneRows(client, userCardId) {
  const r = await client.query(
    `SELECT milestone_rule_id, qualified_spend::float8 AS qualified, approximate_window,
            to_char(period_start, 'YYYY-MM-DD') AS period_start, to_char(period_end, 'YYYY-MM-DD') AS period_end
       FROM milestone_states WHERE user_card_id = $1 ORDER BY milestone_rule_id, period_start`,
    [userCardId],
  );
  return r.rows;
}

async function dbDirectory(client) {
  const merchants = await client.query(`SELECT slug, name, parent_slug, aliases, vpa_prefixes, mcc, is_active FROM merchant_brands`);
  const platforms = await client.query(`SELECT slug, name, kind, aliases, is_active FROM payment_platforms`);
  return loadDirectory({ merchants: merchants.rows, platforms: platforms.rows });
}

/**
 * The engine's own answer for a sequence of spends: the v2 wire card from
 * v_card_catalogue_export_v2 (what the app downloads), consumption carried by
 * cap id. Valid when every spend falls in the same period of every cap.
 */
async function engineSequence(client, productId, ids, spends) {
  const card = (await client.query(`SELECT * FROM v_card_catalogue_export_v2 WHERE id = $1`, [productId])).rows[0];
  assert.ok(card, 'published card visible in the v2 view');
  assert.equal(rewardV2.isV2Card(card), true, 'the card is v2-shaped');
  const directory = await dbDirectory(client);
  const consumed = {};
  const results = spends.map((s) => {
    const ctx = {
      amount: s.amount, occurred: `${s.day}T06:30:00Z`, category_id: s.category ? ids.cats[s.category] : null,
      merchant_name: s.merchant || null, mcc: s.mcc || null, rail: s.rail || 'unknown', platform: null,
    };
    const r = rewardV2.computeTransactionRewardV2({ card, capConsumedBefore: { ...consumed }, ctx, directory });
    for (const [id, d] of Object.entries(r.capDeltas)) consumed[id] = Math.round(((consumed[id] || 0) + d) * 100) / 100;
    return r;
  });
  return { card, results, consumed };
}

function assertMatchesEngine(rowsNow, expectedNow, engine, label) {
  assert.deepEqual(
    expectedNow.map((t) => [t.points, t.value]),
    engine.results.map((r) => [cardStateV2.nativeAmount(r), r.valueInr]),
    `${label}: expected_points / expected_value_inr match the engine`,
  );
  const nonZero = Object.fromEntries(Object.entries(engine.consumed).filter(([, v]) => v > 0));
  const stored = Object.fromEntries(rowsNow.filter((r) => r.consumed > 0).map((r) => [r.cap_rule_id, r.consumed]));
  assert.deepEqual(stored, nonZero, `${label}: cap_states match the engine's native consumption`);
}

const quietLog = () => {};

// ---------------------------------------------------------------------------

test('v2 card: record → reverse → recompute keeps native cap, milestone and expected state exact', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { today, monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await asUser(client, ids.profileId);
    const day = (n) => addDays(monthStart, n);
    const spends = [
      { amount: 2000, day: day(0), category: 'dining' },
      { amount: 30000, day: day(1), merchant: 'BUNDL TECHNOLOGIES BLR' },
      { amount: 30000, day: day(2), category: 'dining' },
      { amount: 500, day: day(2), category: 'wallet' },
      { amount: 1000, day: day(3), merchant: 'SWIGGY' },
      { amount: 1000, day: day(4), merchant: 'SWIGGY INSTAMART' },
    ];
    const recorded = [];
    for (const s of spends) recorded.push(await recordSpend(client, fns, ids, s));
    const txnIds = recorded.map((r) => r.txnId);

    // Record: every cap in native units, with its kind.
    let rows = await capRows(client, ids.userCardId);
    assert.deepEqual(
      Object.fromEntries(rows.map((r) => [r.cap_rule_id, [r.consumed, r.cap_kind, r.cap_amount]])),
      {
        [F.CAP.parent]: [2500, 'total_points', 2500],
        [F.CAP.bonus]: [80, 'bonus_points', 1000],
        [F.CAP.spend]: [20000, 'eligible_spend', 20000],
        [F.CAP.cardYear]: [2500, 'total_points', 6000],
        [F.CAP.count]: [2, 'txn_count', 2],
      },
    );
    const cardYear = rows.find((r) => r.cap_rule_id === F.CAP.cardYear);
    assert.deepEqual([cardYear.period_start, cardYear.approximate_window], [prevMonthStart, false]);
    assert.ok(rows.filter((r) => r.cap_rule_id !== F.CAP.cardYear).every((r) => r.period_start === monthStart));
    let expected = await expectedOf(client, txnIds);
    assert.deepEqual(expected.map((t) => t.points), [100, 2100, 300, 0, 0, 0]);
    assert.deepEqual(expected.map((t) => t.value), [25, 525, 75, 0, 0, 0]);
    assertMatchesEngine(rows, expected, await engineSequence(client, ids.product, ids, spends), 'after record');
    assert.equal(expected[1].card_state_v2.caps.length, 4);
    const ledger = await client.query(
      `SELECT delta_points::float8 AS points FROM points_ledger WHERE user_card_id = $1 ORDER BY occurred_at`, [ids.userCardId]);
    assert.deepEqual(ledger.rows.map((r) => r.points), [100, 2100, 300]);
    let milestones = await milestoneRows(client, ids.userCardId);
    const welcome = milestones.find((m) => m.milestone_rule_id === F.MILESTONE.welcome);
    assert.deepEqual([welcome.qualified, welcome.period_start, welcome.period_end, welcome.approximate_window],
      [64500, prevMonthStart, addDays(prevMonthStart, 89), false]);
    assert.equal(milestones.find((m) => m.milestone_rule_id === F.MILESTONE.annual).qualified, 64500);

    // GET /user-cards mapping: native consumed plus kind, amount, window and the approximate flag.
    const wallet = await cardStateV2.currentCapStates(client, ids.userCardId);
    const parentState = wallet.find((r) => r.cap_rule_id === F.CAP.parent);
    assert.deepEqual(
      [Number(parentState.consumed), parentState.cap_kind, Number(parentState.cap_amount), parentState.period_start, parentState.period_end, parentState.approximate_window],
      [2500, 'total_points', 2500, monthStart, rows.find((r) => r.cap_rule_id === F.CAP.parent).period_end, false],
    );
    assert.ok('cap_value_snapshot' in parentState, 'existing keys stay');
    const walletMilestones = await cardStateV2.currentMilestoneStates(client, ids.userCardId);
    assert.ok(walletMilestones.every((m) => 'period_end' in m && 'approximate_window' in m && 'period_start' in m));

    // The wallet's reconcile replays the ledger: a v2 card must come out unchanged.
    await fns.reconcileCurrentCapStates(client, ids.profileId);
    assert.deepEqual(await capRows(client, ids.userCardId), rows);

    // Reverse the ₹30,000 Swiggy spend: exactly its record comes off.
    await ignoreSpend(client, fns, ids, txnIds[1]);
    rows = await capRows(client, ids.userCardId);
    assert.deepEqual(consumedById(rows), {
      [F.CAP.parent]: 400, [F.CAP.bonus]: 80, [F.CAP.spend]: 0, [F.CAP.cardYear]: 400, [F.CAP.count]: 1,
    });
    expected = await expectedOf(client, txnIds);
    assert.deepEqual([expected[1].points, expected[1].value, expected[1].card_state_v2], [0, 0, null]);
    assert.equal((await client.query(`SELECT count(*)::int AS n FROM points_ledger WHERE transaction_id = $1`, [txnIds[1]])).rows[0].n, 0);
    milestones = await milestoneRows(client, ids.userCardId);
    assert.equal(milestones.find((m) => m.milestone_rule_id === F.MILESTONE.welcome).qualified, 34500);
    const feeWaiver = await client.query(`SELECT qualified_spend::float8 AS q FROM fee_waiver_states WHERE user_card_id = $1`, [ids.userCardId]);
    assert.deepEqual(feeWaiver.rows.map((r) => r.q), [34500]);

    // Recompute, dry run: the later spends would now earn more; nothing is written.
    const lines = [];
    const dry = await recompute(client, { nested: true, asOf: today, userCardId: ids.userCardId, verbose: true, log: (l) => lines.push(l) });
    assert.deepEqual([dry.v2Cards, dry.changedCards, dry.transactions], [1, 1, 3]);
    assert.ok(lines.some((l) => l.includes(`txn ${txnIds[2]}: points 300 → 1220`)), lines.join('\n'));
    assert.deepEqual(consumedById(await capRows(client, ids.userCardId)), consumedById(rows));

    // Apply, then a second run changes nothing.
    const applied = await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
    assert.equal(applied.changedCards, 1);
    rows = await capRows(client, ids.userCardId);
    expected = await expectedOf(client, txnIds);
    assert.deepEqual(expected.map((t) => t.points), [100, 0, 1220, 0, 100, 100]);
    const remaining = spends.filter((_, i) => i !== 1);
    const engine = await engineSequence(client, ids.product, ids, remaining);
    assertMatchesEngine(rows, expected.filter((_, i) => i !== 1), engine, 'after recompute');
    const again = await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
    assert.deepEqual([again.changedCards, again.capRows, again.transactions, again.records], [0, 0, 0, 0]);
    const ledgerAfter = await client.query(
      `SELECT transaction_id, delta_points::float8 AS points FROM points_ledger WHERE user_card_id = $1`, [ids.userCardId]);
    assert.deepEqual(
      Object.fromEntries(ledgerAfter.rows.map((r) => [r.transaction_id, r.points])),
      { [txnIds[0]]: 100, [txnIds[2]]: 1220, [txnIds[4]]: 100, [txnIds[5]]: 100 },
    );

    // A recomputed spend still reverses exactly (its record was rewritten).
    await ignoreSpend(client, fns, ids, txnIds[2]);
    assert.deepEqual(consumedById(await capRows(client, ids.userCardId)), {
      [F.CAP.parent]: 300, [F.CAP.bonus]: 80, [F.CAP.spend]: 2000, [F.CAP.cardYear]: 300, [F.CAP.count]: 2,
    });
  });
});

test('v2 card: an edit reverses the old values and records the new ones', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await asUser(client, ids.profileId);
    const { txnId } = await recordSpend(client, fns, ids, { amount: 2000, day: monthStart, category: 'dining' });
    // PATCH /transactions/:id: reverse the stored row, update it, apply the new values.
    const old = (await client.query(`SELECT * FROM transactions WHERE id = $1`, [txnId])).rows[0];
    const card = await fns.loadUserCardForState(client, ids.profileId, ids.userCardId);
    await fns.reverseTransactionState(client, ids.profileId, card, old);
    await client.query(`UPDATE transactions SET amount_inr = 4000 WHERE id = $1`, [txnId]);
    await fns.applyTransactionState(client, ids.profileId, card, {
      txnId, userCardId: ids.userCardId, amount: 4000, occurred: old.occurred_at, categoryId: old.category_id,
      sign: 1, merchantName: null, rail: 'unknown',
    });
    assert.deepEqual(consumedById(await capRows(client, ids.userCardId)), {
      [F.CAP.parent]: 200, [F.CAP.bonus]: 160, [F.CAP.cardYear]: 200,
    });
    const [txn] = await expectedOf(client, [txnId]);
    assert.deepEqual([txn.points, txn.value], [200, 50]);
    // Applying the same values again (a retried write) does not double count.
    await fns.applyTransactionState(client, ids.profileId, card, {
      txnId, userCardId: ids.userCardId, amount: 4000, occurred: old.occurred_at, categoryId: old.category_id,
      sign: 1, merchantName: null, rail: 'unknown',
    });
    assert.deepEqual(consumedById(await capRows(client, ids.userCardId)), {
      [F.CAP.parent]: 200, [F.CAP.bonus]: 160, [F.CAP.cardYear]: 200,
    });
    assert.equal((await client.query(`SELECT count(*)::int AS n FROM points_ledger WHERE transaction_id = $1`, [txnId])).rows[0].n, 1);
  });
});

test('v2 card: a cap row written in v1 units is rebuilt in native units before pricing', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await asUser(client, ids.profileId);
    await recordSpend(client, fns, ids, { amount: 2000, day: monthStart, category: 'dining' });
    // Simulate a row left by the v1 path (₹ value, no kind) for the parent cap.
    await client.query(
      `UPDATE cap_states SET cap_kind = NULL, cap_amount = NULL, consumed = 25 WHERE user_card_id = $1 AND cap_rule_id = $2`,
      [ids.userCardId, F.CAP.parent],
    );
    await recordSpend(client, fns, ids, { amount: 2000, day: addDays(monthStart, 1), category: 'dining' });
    const parent = (await capRows(client, ids.userCardId)).find((r) => r.cap_rule_id === F.CAP.parent);
    assert.deepEqual([parent.consumed, parent.cap_kind], [200, 'total_points']);
  });
});

test('v1-shaped card: today\'s path, v1 measure, no kind, no record', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { monthStart } = await dates(client);
    const cats = await categoryIds(client);
    const issuer = (await client.query(`INSERT INTO issuers (slug, name) VALUES ('wp8-v1-bank', 'WP8 V1 Bank') RETURNING id`)).rows[0].id;
    const product = (await client.query(
      `INSERT INTO card_products (issuer_id, slug, name, network, status, verified_at, base_reward_unit, base_reward_rate, point_value_inr)
       VALUES ($1, 'wp8-v1-card', 'WP8 V1 Card', 'visa', 'published', now(), 'cashback_percent', 1, 1) RETURNING id`,
      [issuer],
    )).rows[0].id;
    const rule = (await client.query(
      `INSERT INTO reward_rules (card_product_id, category_id, unit, rate) VALUES ($1, $2, 'cashback_percent', 5) RETURNING id`,
      [product, cats.dining],
    )).rows[0].id;
    const cap = (await client.query(
      `INSERT INTO cap_rules (card_product_id, reward_rule_id, label, measure, period, cap_value)
       VALUES ($1, $2, 'v1 dining cap', 'reward_value', 'calendar_month', 150) RETURNING id`,
      [product, rule],
    )).rows[0].id;
    const profileId = (await client.query(`INSERT INTO profiles (id) VALUES (gen_random_uuid()) RETURNING id`)).rows[0].id;
    const userCardId = (await client.query(
      `INSERT INTO user_cards (profile_id, card_product_id) VALUES ($1, $2) RETURNING id`, [profileId, product])).rows[0].id;
    const ids = { cats, product, profileId, userCardId };
    await asUser(client, profileId);
    assert.equal(await cardStateV2.loadV2Card(client, userCardId), null, 'v1-shaped');

    const spends = [{ amount: 2000, day: monthStart, category: 'dining' }, { amount: 2000, day: addDays(monthStart, 1), category: 'dining' }];
    const txnIds = [];
    for (const s of spends) txnIds.push((await recordSpend(client, fns, ids, s)).txnId);
    const rows = await capRows(client, userCardId);
    assert.deepEqual(rows.map((r) => [r.cap_rule_id, r.consumed, r.cap_kind, r.cap_amount, r.approximate_window]),
      [[cap, 150, null, null, false]]);
    const expected = await expectedOf(client, txnIds);
    // Same numbers reward_math.js (v1) gives on the stored rows: ₹100, then
    // ₹50 left under the ₹150 cap plus base rate on the rest (post_cap_rate null).
    const v1Rules = (await client.query(
      `SELECT id, category_id, merchant_pattern, rail, unit, rate, min_txn_inr, max_txn_inr, excluded_categories,
              effective_from, effective_to, priority FROM reward_rules WHERE card_product_id = $1`, [product])).rows;
    const v1Caps = (await client.query(
      `SELECT id, reward_rule_id, category_id, period, cap_value, measure, post_cap_unit, post_cap_rate
         FROM cap_rules WHERE card_product_id = $1`, [product])).rows;
    const v1 = rewardMath.computeTransactionReward({
      card: { point_value_inr: 1, base_reward_unit: 'cashback_percent', base_reward_rate: 1, excluded_categories: [] },
      rewardRules: v1Rules,
      capRules: v1Caps,
      capConsumedBefore: 100,
      ctx: { amount: 2000, categoryId: cats.dining, rail: 'unknown', occurred: new Date(`${spends[1].day}T06:30:00Z`) },
    });
    assert.equal(v1.valueInr, 60);
    assert.deepEqual(expected.map((t) => [t.value, t.card_state_v2]), [[100, null], [v1.valueInr, null]]);
    const wallet = await cardStateV2.currentCapStates(client, userCardId);
    assert.deepEqual([wallet[0].cap_kind, wallet[0].cap_amount, wallet[0].approximate_window], [null, null, false]);
    await fns.reconcileCurrentCapStates(client, profileId);
    assert.deepEqual(await capRows(client, userCardId), rows);
  });
});

// ---------------------------------------------------------------------------
// Real catalogue cards (imported from CardPipeline); skipped when absent.

async function realCardScenario(client, slug, spends, reverseIndex, check) {
  const fns = extractIndexFunctions();
  const { today, monthStart, prevMonthStart } = await dates(client);
  const ids = await seedCatalogueCard(client, slug, { openedOn: prevMonthStart });
  if (!ids) return false;
  const dated = spends.map((s, i) => ({ ...s, day: addDays(monthStart, Math.min(i, 5)) }));
  await asUser(client, ids.profileId);
  const txnIds = [];
  for (const s of dated) txnIds.push((await recordSpend(client, fns, ids, s)).txnId);
  let rows = await capRows(client, ids.userCardId);
  let expected = await expectedOf(client, txnIds);
  assertMatchesEngine(rows, expected, await engineSequence(client, ids.product, ids, dated), `${slug} record`);  await check({ client, ids, rows, expected, monthStart, prevMonthStart });

  await ignoreSpend(client, fns, ids, txnIds[reverseIndex]);
  await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
  rows = await capRows(client, ids.userCardId);
  expected = (await expectedOf(client, txnIds)).filter((_, i) => i !== reverseIndex);
  const kept = dated.filter((_, i) => i !== reverseIndex);
  assertMatchesEngine(rows, expected, await engineSequence(client, ids.product, ids, kept), `${slug} reverse + recompute`);
  const again = await recompute(client, { nested: true, apply: false, asOf: today, userCardId: ids.userCardId, log: quietLog });
  assert.equal(again.changedCards, 0, `${slug}: recompute is idempotent`);
  return true;
}

test('real card (Swiggy HDFC): cashback caps in ₹, statement cycle without a statement day is approximate', { skip }, async (t) => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const ran = await realCardScenario(client, 'swiggy-hdfc-bank-credit-card', [
      { amount: 12000, merchant: 'SWIGGY BANGALORE', category: 'dining' },
      { amount: 8000, merchant: 'SWIGGY INSTAMART', category: 'groceries' },
      { amount: 2000, merchant: 'NEIGHBOURHOOD KIRANA', category: 'groceries' },
      { amount: 50, merchant: 'TEA STALL', category: 'dining' },
      { amount: 3000, merchant: 'MONTHLY RENT', category: 'rent' },
      { amount: 1500, merchant: 'SWIGGY', category: 'dining' },
    ], 1, async ({ rows, expected }) => {
      assert.ok(rows.length > 0 && rows.every((r) => r.cap_kind === 'total_cashback'), 'cashback caps in ₹');
      assert.ok(rows.every((r) => r.approximate_window === true), 'statement cycle with no statement day');
      assert.equal(expected[0].value, 1200); // 10% on Swiggy
      assert.deepEqual([expected[3].value, expected[4].value], [0, 0]); // below ₹100, rent
    });
    if (!ran) t.skip('swiggy-hdfc-bank-credit-card is not in this database');
  });
});

test('real card (PhonePe SBI Select Black): points caps stored in points, not rupees', { skip }, async (t) => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const ran = await realCardScenario(client, 'phonepe-sbi-select-black', [
      { amount: 10000, merchant: 'AMAZON', category: 'online', rail: 'online' },
      { amount: 15000, merchant: 'FLIPKART', category: 'online', rail: 'online' },
      { amount: 4000, merchant: 'ELECTRICITY BOARD', category: 'bills', mcc: '4900' },
      { amount: 2000, merchant: 'RESTAURANT', category: 'dining' },
    ], 0, async ({ client: c, ids, rows, expected, prevMonthStart }) => {
      assert.ok(rows.length >= 2 && rows.every((r) => r.cap_kind === 'total_points'), 'points caps');
      // Online 5 pts/₹100 under a 1,000-point monthly total cap: 500, then the
      // 500 points left (not ₹1,000 / ₹0.25 of headroom).
      assert.deepEqual(expected.slice(0, 2).map((e) => e.points), [500, 500]);
      assert.ok(rows.some((r) => r.consumed === 1000 && r.cap_amount === 1000), 'the online cap is full, in points');
      const card = (await c.query(`SELECT point_value_inr::float8 AS pv FROM card_products WHERE id = $1`, [ids.product])).rows[0];
      const capAmounts = (await c.query(
        `SELECT id, cap_amount::float8 AS amount FROM cap_rules WHERE card_product_id = $1`, [ids.product])).rows;
      for (const r of rows) {
        assert.equal(r.cap_amount, capAmounts.find((k) => k.id === r.cap_rule_id).amount, 'cap_amount is the native cap');
        assert.ok(r.consumed <= r.cap_amount, 'native consumption never exceeds the native cap');
      }
      assert.ok(card.pv > 0);
      const milestones = await milestoneRows(c, ids.userCardId);
      for (const m of milestones) assert.deepEqual([m.period_start, m.approximate_window], [prevMonthStart, false]);
    });
    if (!ran) t.skip('phonepe-sbi-select-black is not in this database');
  });
});
