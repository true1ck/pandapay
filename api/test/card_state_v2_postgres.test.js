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
const crypto = require('node:crypto');

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

/** Today, this month and last month in India calendar days (v2 windows are IST, C8 D23c). */
async function dates(client) {
  const r = await client.query(
    `WITH d AS (SELECT (now() AT TIME ZONE 'Asia/Kolkata')::date AS today)
     SELECT today::text AS today,
            date_trunc('month', today)::date::text AS month_start,
            (date_trunc('month', today) - interval '1 month')::date::text AS prev_month_start
       FROM d`,
  );
  return { today: r.rows[0].today, monthStart: r.rows[0].month_start, prevMonthStart: r.rows[0].prev_month_start };
}

/**
 * The same for v1 cards, from the "today" the v1 code itself uses: the
 * database's CURRENT_DATE (GET /user-cards' v1 rows, reconcile). Spends are
 * placed at 06:30 UTC on these days, so their UTC day (v1's periodBounds)
 * is the day named, whatever the session time zone (±11:59 of UTC).
 */
async function v1Dates(client) {
  const r = await client.query(
    `SELECT CURRENT_DATE::text AS today, date_trunc('month', CURRENT_DATE)::date::text AS month_start`,
  );
  return { today: r.rows[0].today, monthStart: r.rows[0].month_start };
}

async function categoryIds(client) {
  const r = await client.query(`SELECT slug, id FROM spend_categories`);
  return Object.fromEntries(r.rows.map((row) => [row.slug, row.id]));
}

const FIXTURE_CATEGORY_SLUG = { [F.CATEGORY.dining]: 'dining', [F.CATEGORY.rent]: 'rent', [F.CATEGORY.wallet]: 'wallet' };

/**
 * The synthetic fixture card as real catalogue rows (published), one profile,
 * one user card. `unique` gives every row a fresh id and slug (for tests that
 * commit); `ids.id(fixtureId)` maps a fixture id to the row's id.
 */
async function seedSyntheticCard(client, { openedOn, statementDay = null, unique = false }) {
  const cats = await categoryIds(client);
  const realCategory = (id) => (id == null ? null : cats[FIXTURE_CATEGORY_SLUG[id]]);
  const remap = new Map();
  const id = (fixtureId) => {
    if (fixtureId == null || !unique) return fixtureId;
    if (!remap.has(fixtureId)) remap.set(fixtureId, crypto.randomUUID());
    return remap.get(fixtureId);
  };
  const suffix = unique ? `-${crypto.randomUUID().slice(0, 8)}` : '';
  const issuer = (await client.query(
    `INSERT INTO issuers (slug, name) VALUES ($1, 'WP8 Synthetic Bank') RETURNING id`, [`wp8-synthetic-bank${suffix}`],
  )).rows[0].id;
  const product = (await client.query(
    `INSERT INTO card_products (issuer_id, slug, name, network, status, verified_at, base_reward_unit,
                                base_reward_rate, point_value_inr, accrual_rounding, accrual_block_inr)
     VALUES ($1, $2, 'WP8 Synthetic Card', 'visa', 'published', now(), 'points_per_100',
             1, 0.25, 'floor', 100) RETURNING id`,
    [issuer, `wp8-synthetic-card${suffix}`],
  )).rows[0].id;
  for (const r of F.RULES) {
    await client.query(
      `INSERT INTO reward_rules (id, card_product_id, category_id, unit, rate, priority, rule_role,
                                 merchant_slugs, min_engine_version, display_note, max_txn_inr)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)`,
      [id(r.id), product, realCategory(r.category_id), r.unit, r.rate, r.priority, r.rule_role,
        r.merchant_slugs, r.min_engine_version, r.display_note, r.max_txn_inr],
    );
  }
  for (const c of F.CAPS) {
    await client.query(
      `INSERT INTO cap_rules (id, card_product_id, label, measure, period, cap_value, post_cap_rate,
                              cap_kind, cap_amount, scope, parent_cap_id, post_cap_behavior, anchor,
                              min_engine_version)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)`,
      [id(c.id), product, c.label, c.measure, c.period, c.cap_value, c.post_cap_rate, c.cap_kind, c.cap_amount,
        c.scope, id(c.parent_cap_id), c.post_cap_behavior, c.anchor, c.min_engine_version],
    );
    for (const target of c.targets) {
      await client.query(`INSERT INTO cap_rule_targets (cap_rule_id, reward_rule_id) VALUES ($1, $2)`, [id(c.id), id(target)]);
    }
  }
  for (const m of F.MILESTONES) {
    await client.query(
      `INSERT INTO milestone_rules (id, card_product_id, label, period, anchor, threshold_spend_inr,
                                    reward_description, reward_value_inr, window_days, excluded_category_ids)
       VALUES ($1, $2, $3, $4, $5, $6, $3, 500, $7, $8)`,
      [id(m.id), product, m.label, m.period, m.anchor, m.threshold_spend_inr, m.window_days,
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
  return { cats, issuer, product, feeWaiver, profileId, userCardId, id };
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
    `SELECT id, expected_points::float8 AS points, expected_value_inr::float8 AS value,
            expected_cashback_inr::float8 AS cashback, card_state_v2
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
    // C8 D22a: the excluded ₹500 wallet load makes no milestone or fee-waiver progress.
    let milestones = await milestoneRows(client, ids.userCardId);
    const welcome = milestones.find((m) => m.milestone_rule_id === F.MILESTONE.welcome);
    assert.deepEqual([welcome.qualified, welcome.period_start, welcome.period_end, welcome.approximate_window],
      [64000, prevMonthStart, addDays(prevMonthStart, 89), false]);
    assert.equal(milestones.find((m) => m.milestone_rule_id === F.MILESTONE.annual).qualified, 64000);
    let feeWaiver = await client.query(`SELECT qualified_spend::float8 AS q FROM fee_waiver_states WHERE user_card_id = $1`, [ids.userCardId]);
    assert.deepEqual(feeWaiver.rows.map((r) => r.q), [64000]);

    // GET /user-cards mapping (C8 D22c): `consumed` in the v1 measure (points
    // × ₹0.25), consumed_native in points, plus kind, amount, window and flag.
    const wallet = await cardStateV2.currentCapStates(client, ids.userCardId);
    const parentState = wallet.find((r) => r.cap_rule_id === F.CAP.parent);
    assert.deepEqual(
      [Number(parentState.consumed), Number(parentState.consumed_native), parentState.cap_kind, Number(parentState.cap_amount),
        parentState.period_start, parentState.period_end, parentState.approximate_window],
      [625, 2500, 'total_points', 2500, monthStart, rows.find((r) => r.cap_rule_id === F.CAP.parent).period_end, false],
    );
    const spendState = wallet.find((r) => r.cap_rule_id === F.CAP.spend);
    assert.deepEqual([Number(spendState.consumed), Number(spendState.consumed_native)], [20000, 20000]);
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
    assert.equal(milestones.find((m) => m.milestone_rule_id === F.MILESTONE.welcome).qualified, 34000);
    feeWaiver = await client.query(`SELECT qualified_spend::float8 AS q FROM fee_waiver_states WHERE user_card_id = $1`, [ids.userCardId]);
    assert.deepEqual(feeWaiver.rows.map((r) => r.q), [34000]);

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

/** index.js's real insertTransactionAndUpdateState, with only its observation/duplicate/tag helpers stubbed. */
function insertFunction(fns) {
  const source = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  const start = source.indexOf('async function insertTransactionAndUpdateState(client');
  const end = source.indexOf('async function importParsedMessage(client', start);
  assert.ok(start >= 0 && end > start);
  return new Function(
    'recordTransactionObservation', 'detectDuplicates', 'loadUserCardForState', 'applyTransactionState',
    'reverseTransactionState', 'transactionTags',
    `${source.slice(start, end)} return insertTransactionAndUpdateState;`,
  )(
    async () => {}, async () => ({ candidateId: null }), fns.loadUserCardForState, fns.applyTransactionState,
    fns.reverseTransactionState, { mergeTransactionTags: async () => {} },
  );
}

/** index.js's real POST /transactions/:id/ignore handler, on `client`. */
function ignoreRoute(client, fns) {
  const source = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  const start = source.indexOf("app.post('/transactions/:id/ignore'");
  const end = source.indexOf('/**\n * POST /transactions/:id/restore', start);
  assert.ok(start >= 0 && end > start);
  let handler;
  new Function('app', 'requireAuth', 'withUserClient', 'IGNORE_REASONS', 'loadUserCardForState',
    'reverseTransactionState', 'safeErrorCode', source.slice(start, end))(
    { post: (_route, ...handlers) => { handler = handlers.at(-1); } }, null, (_userId, fn) => fn(client),
    ['refund', 'reversal', 'transfer', 'wrong_transaction'], fns.loadUserCardForState, fns.reverseTransactionState,
    (e) => String(e && e.code),
  );
  return async (userId, txnId) => {
    const res = { code: 200, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await handler({ userId, params: { id: txnId }, body: { reason: 'refund' } }, res);
    return res;
  };
}

test('C8 D33c: a card-state failure never fails ingest or ignore; nothing half-applied, rebuilt later', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await asUser(client, ids.profileId);
    const { txnId: first } = await recordSpend(client, fns, ids, { amount: 2000, day: monthStart, category: 'dining' });
    const rowsBefore = await capRows(client, ids.userCardId);
    const milestonesBefore = await milestoneRows(client, ids.userCardId);

    // Inject a SQL failure into every cap_states write (rolled back with the test).
    await asOwner(client);
    await client.query(`CREATE FUNCTION public.wp8_injected_failure() RETURNS trigger LANGUAGE plpgsql AS
      $$ BEGIN RAISE EXCEPTION 'wp8 injected failure' USING ERRCODE = 'P0001'; END $$`);
    await client.query(`CREATE TRIGGER wp8_injected_failure BEFORE INSERT OR UPDATE ON cap_states
      FOR EACH ROW EXECUTE FUNCTION public.wp8_injected_failure()`);
    await asUser(client, ids.profileId);
    const warnings = [];
    const warn = console.warn;
    console.warn = (...args) => warnings.push(args.join(' '));
    try {
      // Ingest (the POST /transactions and /sms path): stored, 201, no card state, no partial writes.
      const insert = insertFunction(fns);
      const stored = await insert(client, ids.profileId, {
        userCardId: ids.userCardId, amount: 1000, occurred: new Date(`${addDays(monthStart, 1)}T06:30:00Z`),
        categoryId: ids.cats.dining, rail: 'unknown', merchantName: null, source: 'manual',
      });
      assert.equal(stored.status, 201);
      const second = stored.transaction.id;
      const [row] = (await client.query(`SELECT status, state_applied, card_state_v2 FROM transactions WHERE id = $1`, [second])).rows;
      assert.deepEqual([row.status, row.card_state_v2], ['active', null]);
      assert.deepEqual(await capRows(client, ids.userCardId), rowsBefore, 'no partial cap writes');
      assert.deepEqual(await milestoneRows(client, ids.userCardId), milestonesBefore, 'no partial milestone writes');

      // Ignore (a reversal): 200, never half-reversed; the record is cleared, expected values zeroed.
      const res = await ignoreRoute(client, fns)(ids.profileId, first);
      assert.equal(res.code, 200);
      assert.equal(res.body.transaction.status, 'ignored');
      assert.deepEqual(await capRows(client, ids.userCardId), rowsBefore, 'not half-reversed');
      const [ignored] = await expectedOf(client, [first]);
      assert.deepEqual([ignored.points, ignored.card_state_v2], [0, null]);
      assert.equal((await client.query(`SELECT count(*)::int AS n FROM points_ledger WHERE transaction_id = $1`, [first])).rows[0].n, 0);
      // Only a safe error code is logged, never row data.
      assert.ok(warnings.length >= 2 && warnings.every((w) => w.includes('P0001') && !w.includes('2000')), warnings.join('\n'));
    } finally {
      console.warn = warn;
    }

    // Once writes work again, the wallet's reconcile rebuilds the caps from the ledger.
    await asOwner(client);
    await client.query(`DROP TRIGGER wp8_injected_failure ON cap_states`);
    await asUser(client, ids.profileId);
    await fns.reconcileCurrentCapStates(client, ids.profileId);
    assert.deepEqual(consumedById(await capRows(client, ids.userCardId)), {
      [F.CAP.parent]: 50, [F.CAP.bonus]: 40, [F.CAP.cardYear]: 50,
    });
  });
});

test('C8 D23c: the wallet\'s "current" v2 cap and milestone rows follow the India day across 18:30 UTC', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const ids = await seedSyntheticCard(client, { openedOn: '2026-10-01' });
    // Two adjacent monthly windows for one cap and one milestone (fixed dates,
    // independent of the clock; the reads take `now` explicitly).
    for (const [start, end, consumed] of [['2026-11-01', '2026-11-30', 10], ['2026-12-01', '2026-12-31', 20]]) {
      await client.query(
        `INSERT INTO cap_states (profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed,
                                 cap_value_snapshot, cap_kind, cap_amount)
         VALUES ($1, $2, $3, $4, $5, $6, 625, 'total_points', 2500)`,
        [ids.profileId, ids.userCardId, F.CAP.parent, start, end, consumed],
      );
      await client.query(
        `INSERT INTO milestone_states (profile_id, user_card_id, milestone_rule_id, period_start, period_end, qualified_spend)
         VALUES ($1, $2, $3, $4, $5, $6)`,
        [ids.profileId, ids.userCardId, F.MILESTONE.annual, start, end, consumed * 100],
      );
    }
    await asUser(client, ids.profileId);
    const at = async (iso) => {
      const now = new Date(iso);
      const caps = await cardStateV2.currentCapStates(client, ids.userCardId, { now });
      const milestones = await cardStateV2.currentMilestoneStates(client, ids.userCardId, { now });
      return [caps.map((r) => r.period_start), milestones.map((r) => r.period_start)];
    };
    // 18:15 UTC on 30 Nov is 23:45 IST, still November; 18:45 UTC is 00:15 IST on 1 Dec.
    assert.deepEqual(await at('2026-11-30T18:15:00Z'), [['2026-11-01'], ['2026-11-01']]);
    assert.deepEqual(await at('2026-11-30T18:45:00Z'), [['2026-12-01'], ['2026-12-01']]);
    // Another profile reads nothing (profile_id filter + RLS).
    await client.query(`SELECT set_config('app.user_id', $1, true)`, [crypto.randomUUID()]);
    assert.deepEqual(await at('2026-11-30T18:45:00Z'), [[], []]);
  });
});

test('v1-shaped card: today\'s path, v1 measure, no kind, no record', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    // v1 windows run on the database's date, so the test does too (never IST):
    // deterministic at any hour, including 18:30–24:00 UTC on a month's last day.
    const { monthStart } = await v1Dates(client);
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

    // Both on the month's first day: never after today, so v1's reconcile
    // (which replays up to CURRENT_DATE) sees both, even on the 1st.
    const spends = [{ amount: 2000, day: monthStart, category: 'dining' }, { amount: 2000, day: monthStart, category: 'dining' }];
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
    assert.deepEqual(
      [Number(wallet[0].consumed), wallet[0].consumed_native, wallet[0].cap_kind, wallet[0].cap_amount, wallet[0].approximate_window],
      [150, null, null, null, false],
    );
    await fns.reconcileCurrentCapStates(client, profileId);
    assert.deepEqual(await capRows(client, userCardId), rows);
  });
});

/** index.js's real GET .../points-ledger and POST .../points-adjustment handlers, on `client`. */
function ledgerRoutes(client) {
  const source = fs.readFileSync(path.join(__dirname, '../src/index.js'), 'utf8');
  const start = source.indexOf("app.get('/user-cards/:id/points-ledger'");
  const end = source.indexOf('/**\n * POST /transactions — UA-3+', start);
  assert.ok(start >= 0 && end > start);
  const routes = {};
  const app = {
    get: (route, ...handlers) => { routes[`GET ${route}`] = handlers.at(-1); },
    post: (route, ...handlers) => { routes[`POST ${route}`] = handlers.at(-1); },
  };
  new Function('app', 'requireAuth', 'withUserClient', 'safeErrorCode', source.slice(start, end))(
    app, null, (_userId, fn) => fn(client), (e) => String(e && e.code),
  );
  const call = async (key, req) => {
    const res = { code: 200, body: null, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } };
    await routes[key](req, res);
    return res;
  };
  return {
    ledger: (userId, cardId) => call('GET /user-cards/:id/points-ledger', { userId, params: { id: cardId } }),
    adjust: (userId, cardId, newBalance) => call('POST /user-cards/:id/points-adjustment', {
      userId, params: { id: cardId }, body: { newBalance },
    }),
  };
}

test('points+cashback card: cashback never enters the points ledger (record, edit, rebuild); ledger routes total points only', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { today, monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await client.query(
      `INSERT INTO reward_rules (card_product_id, category_id, unit, rate, rule_role, min_engine_version, display_note)
       VALUES ($1, $2, 'cashback_percent', 5, 'earn', 2, '5% cashback on other')`,
      [ids.product, ids.cats.other],
    );
    await asUser(client, ids.profileId);
    const { txnId: cashbackTxn } = await recordSpend(client, fns, ids, { amount: 1000, day: monthStart, category: 'other' });
    const { txnId: pointsTxn } = await recordSpend(client, fns, ids, { amount: 1000, day: addDays(monthStart, 1), category: 'dining' });
    let [cb, pts] = await expectedOf(client, [cashbackTxn, pointsTxn]);
    assert.deepEqual([cb.points, cb.cashback, cb.value], [0, 50, 50]);
    assert.deepEqual([pts.points, pts.cashback, pts.value], [50, null, 12.5]);

    const routes = ledgerRoutes(client);
    const ledgerTotal = async () => {
      const res = await routes.ledger(ids.profileId, ids.userCardId);
      assert.equal(res.code, 200);
      return res.body.pointsLedger.reduce((s, r) => s + Number(r.delta_points), 0);
    };
    assert.equal(await ledgerTotal(), 50, 'record: points only');

    // Edit the cashback spend (PATCH's reverse → update → apply): still no ledger row.
    const old = (await client.query(`SELECT * FROM transactions WHERE id = $1`, [cashbackTxn])).rows[0];
    const card = await fns.loadUserCardForState(client, ids.profileId, ids.userCardId);
    await fns.reverseTransactionState(client, ids.profileId, card, old);
    await client.query(`UPDATE transactions SET amount_inr = 2000 WHERE id = $1`, [cashbackTxn]);
    await fns.applyTransactionState(client, ids.profileId, card, {
      txnId: cashbackTxn, userCardId: ids.userCardId, amount: 2000, occurred: old.occurred_at,
      categoryId: old.category_id, sign: 1, merchantName: null, rail: 'unknown',
    });
    [cb] = await expectedOf(client, [cashbackTxn]);
    assert.deepEqual([cb.points, cb.cashback], [0, 100]);
    assert.equal(await ledgerTotal(), 50, 'edit: points only');

    // Rebuild (recompute) rewrites expected values but adds no cashback row.
    await client.query(`UPDATE transactions SET expected_cashback_inr = NULL WHERE id = $1`, [cashbackTxn]);
    await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
    [cb] = await expectedOf(client, [cashbackTxn]);
    assert.equal(cb.cashback, 100);
    assert.equal(await ledgerTotal(), 50, 'rebuild: points only');

    // A manual correction to 80 points adds 30, not 30 minus the cashback.
    const adjusted = await routes.adjust(ids.profileId, ids.userCardId, 80);
    assert.equal(adjusted.code, 201);
    assert.equal(Number(adjusted.body.pointsLedgerEntry.delta_points), 30);
    assert.equal(await ledgerTotal(), 80);

    // Reversing the cashback spend zeroes its cashback field.
    await ignoreSpend(client, fns, ids, cashbackTxn);
    [cb] = await expectedOf(client, [cashbackTxn]);
    assert.deepEqual([cb.points, cb.cashback, cb.value], [0, 0, 0]);
    assert.equal(await ledgerTotal(), 80);
  });
});

// ---------------------------------------------------------------------------
// C8 D23d: an edit and a rebuild in two connections. This one commits (two
// sessions can't share a transaction), so it seeds unique ids and deletes
// everything it created in `finally`.

const INGEST_LOCK_SQL = `SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`;

async function connect() {
  const { Client } = require('pg');
  const client = new Client({ connectionString: connectionString(), ssl: false });
  await client.connect();
  return client;
}

test('C8 D23d: an edit holding the ingest lock and a concurrent reconcile lose no increment', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  const fns = extractIndexFunctions();
  const owner = await connect();
  const editor = await connect();
  const rebuilder = await connect();
  let ids = null;
  try {
    const { monthStart, prevMonthStart } = await dates(owner);
    await owner.query('BEGIN');
    ids = await seedSyntheticCard(owner, { openedOn: prevMonthStart, unique: true });
    await asUser(owner, ids.profileId);
    const { txnId } = await recordSpend(owner, fns, ids, { amount: 2000, day: monthStart, category: 'dining' });
    await owner.query('COMMIT');
    const cap = (fixtureId) => ids.id(fixtureId);

    // Editor: PATCH /transactions/:id's order — ingest lock, row lock, reverse, update, apply — then waits.
    await editor.query('BEGIN');
    await asUser(editor, ids.profileId);
    await editor.query(INGEST_LOCK_SQL, [`transaction-ingest:${ids.profileId}`]);
    const old = (await editor.query(
      `SELECT * FROM transactions WHERE id = $1 AND profile_id = $2 FOR UPDATE`, [txnId, ids.profileId])).rows[0];
    const card = await fns.loadUserCardForState(editor, ids.profileId, ids.userCardId);
    await fns.reverseTransactionState(editor, ids.profileId, card, old);
    await editor.query(`UPDATE transactions SET amount_inr = 4000 WHERE id = $1`, [txnId]);
    await fns.applyTransactionState(editor, ids.profileId, card, {
      txnId, userCardId: ids.userCardId, amount: 4000, occurred: old.occurred_at, categoryId: old.category_id,
      sign: 1, merchantName: null, rail: 'unknown',
    });

    // Rebuilder: GET /user-cards' reconcile, started while the edit is open.
    await rebuilder.query('BEGIN');
    await asUser(rebuilder, ids.profileId);
    let rebuilt = false;
    const rebuild = fns.reconcileCurrentCapStates(rebuilder, ids.profileId).then(() => { rebuilt = true; });
    await new Promise((resolve) => setTimeout(resolve, 400));
    assert.equal(rebuilt, false, 'the rebuild waits for the edit');
    await editor.query('COMMIT');
    await rebuild;
    await rebuilder.query('COMMIT');

    // The rebuild replayed the committed edit: nothing lost, nothing doubled.
    const rows = await capRows(owner, ids.userCardId);
    assert.deepEqual(consumedById(rows), {
      [cap(F.CAP.parent)]: 200, [cap(F.CAP.bonus)]: 160, [cap(F.CAP.cardYear)]: 200,
    });
    const [txn] = await expectedOf(owner, [txnId]);
    assert.deepEqual([txn.points, txn.card_state_v2.caps.length], [200, 3]);
  } finally {
    await editor.query('ROLLBACK').catch(() => {});
    await rebuilder.query('ROLLBACK').catch(() => {});
    await owner.query('ROLLBACK').catch(() => {});
    if (ids) {
      await owner.query('DELETE FROM profiles WHERE id = $1', [ids.profileId]);
      await owner.query('DELETE FROM card_products WHERE id = $1', [ids.product]);
      await owner.query('DELETE FROM issuers WHERE id = $1', [ids.issuer]);
    }
    await Promise.all([owner.end(), editor.end(), rebuilder.end()]);
  }
});

// ---------------------------------------------------------------------------
// C8 D33b: a forced re-import cascades fee_waiver_states away; the recompute
// replays each rule's current period with the live path's (v1) maths.

async function feeWaiverRows(client, userCardId) {
  const r = await client.query(
    `SELECT fee_waiver_rule_id, to_char(period_start, 'YYYY-MM-DD') AS period_start,
            to_char(period_end, 'YYYY-MM-DD') AS period_end, qualified_spend::float8 AS qualified,
            waived_at IS NOT NULL AS waived
       FROM fee_waiver_states WHERE user_card_id = $1 ORDER BY fee_waiver_rule_id, period_start`,
    [userCardId],
  );
  return r.rows;
}

test('C8 D33b: recompute rebuilds a v1 card\'s current fee-waiver progress exactly as the live path left it', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { today, monthStart } = await v1Dates(client);
    const cats = await categoryIds(client);
    const issuer = (await client.query(`INSERT INTO issuers (slug, name) VALUES ('wp8-fw-bank', 'WP8 FW Bank') RETURNING id`)).rows[0].id;
    const product = (await client.query(
      `INSERT INTO card_products (issuer_id, slug, name, network, status, verified_at, base_reward_unit, base_reward_rate, point_value_inr)
       VALUES ($1, 'wp8-fw-card', 'WP8 FW Card', 'visa', 'published', now(), 'cashback_percent', 1, 1) RETURNING id`,
      [issuer],
    )).rows[0].id;
    await client.query(
      `INSERT INTO fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr, excluded_categories)
       VALUES ($1, 3000, 'annual', 500, '{}'), ($1, 50000, 'quarter', 999, ARRAY[$2]::uuid[])`,
      [product, cats.rent],
    );
    const profileId = (await client.query(`INSERT INTO profiles (id) VALUES (gen_random_uuid()) RETURNING id`)).rows[0].id;
    const userCardId = (await client.query(
      `INSERT INTO user_cards (profile_id, card_product_id) VALUES ($1, $2) RETURNING id`, [profileId, product])).rows[0].id;
    const ids = { cats, product, profileId, userCardId };
    await asUser(client, profileId);
    assert.equal(await cardStateV2.loadV2Card(client, userCardId), null, 'v1-shaped');
    for (const s of [
      { amount: 2000, day: monthStart, category: 'dining' },
      { amount: 2000, day: monthStart, category: 'dining' },
      { amount: 1000, day: monthStart, category: 'rent' },
    ]) await recordSpend(client, fns, ids, s);

    const live = await feeWaiverRows(client, userCardId);
    assert.deepEqual(live.map((r) => [r.qualified, r.waived]).sort(), [[4000, false], [5000, true]]);

    // A forced import cascades the rows away.
    await client.query(`DELETE FROM fee_waiver_states WHERE user_card_id = $1`, [userCardId]);
    const dry = await recompute(client, { nested: true, asOf: today, userCardId, log: quietLog });
    assert.deepEqual([dry.changedCards, dry.feeWaiverRows], [1, 2]);
    assert.deepEqual(await feeWaiverRows(client, userCardId), [], 'dry run writes nothing');
    await recompute(client, { nested: true, apply: true, asOf: today, userCardId, log: quietLog });
    assert.deepEqual(await feeWaiverRows(client, userCardId), live, 'identical to the live v1 path');
    const again = await recompute(client, { nested: true, apply: true, asOf: today, userCardId, log: quietLog });
    assert.deepEqual([again.changedCards, again.feeWaiverRows], [0, 0]);
  });
});

test('C8 D33b: after a forced re-import of a v2 card\'s fee-waiver rules, recompute restores progress and the waiver', { skip }, async () => {
  cardStateV2.clearDirectoryCache();
  await withRollback(async (client) => {
    const fns = extractIndexFunctions();
    const { today, monthStart, prevMonthStart } = await dates(client);
    const ids = await seedSyntheticCard(client, { openedOn: prevMonthStart });
    await asUser(client, ids.profileId);
    const spends = [
      { amount: 2000, day: monthStart, category: 'dining' },
      { amount: 30000, day: addDays(monthStart, 1), merchant: 'BUNDL TECHNOLOGIES BLR' },
      { amount: 30000, day: addDays(monthStart, 2), category: 'dining' },
      { amount: 500, day: addDays(monthStart, 2), category: 'wallet' }, // excluded: no progress (D22a)
    ];
    const txnIds = [];
    for (const s of spends) txnIds.push((await recordSpend(client, fns, ids, s)).txnId);
    const live = await feeWaiverRows(client, ids.userCardId);
    assert.deepEqual(live.map((r) => [r.qualified, r.waived]), [[62000, true]]);

    // Forced re-import: the rule is deleted and re-created (new id); its state cascades away.
    await asOwner(client);
    await client.query(`DELETE FROM fee_waiver_rules WHERE card_product_id = $1`, [ids.product]);
    const newRule = (await client.query(
      `INSERT INTO fee_waiver_rules (card_product_id, threshold_spend_inr, period, waives_fee_inr)
       VALUES ($1, 50000, 'annual', 500) RETURNING id`, [ids.product])).rows[0].id;
    await asUser(client, ids.profileId);
    assert.deepEqual(await feeWaiverRows(client, ids.userCardId), []);

    await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
    const rebuilt = await feeWaiverRows(client, ids.userCardId);
    assert.deepEqual(rebuilt.map((r) => [r.fee_waiver_rule_id, r.period_start, r.period_end, r.qualified, r.waived]),
      [[newRule, live[0].period_start, live[0].period_end, 62000, true]]);
    const [record] = await expectedOf(client, [txnIds[1]]);
    assert.ok(record.card_state_v2.fee_waivers.some((e) => e.id === newRule && e.delta === 30000), 'records carry the new rule');

    // A reversal now subtracts exactly from the rebuilt row, and un-waives below the threshold.
    await ignoreSpend(client, fns, ids, txnIds[1]);
    assert.deepEqual((await feeWaiverRows(client, ids.userCardId)).map((r) => [r.qualified, r.waived]), [[32000, false]]);
    const again = await recompute(client, { nested: true, apply: true, asOf: today, userCardId: ids.userCardId, log: quietLog });
    assert.equal(again.feeWaiverRows, 0);
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
      assert.deepEqual([expected[0].value, expected[0].cashback], [1200, 1200]); // 10% on Swiggy, in the cashback field too
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
