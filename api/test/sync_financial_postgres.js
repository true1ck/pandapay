'use strict';

// Explicit loopback-only PostgreSQL fixture for typed sync transaction state.
// The product schema is expected to be migrated already; every seeded row is
// synthetic and the enclosing transaction rolls back by default.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const vm = require('node:vm');
const { Client } = require('pg');
const rewardMath = require('../src/reward_math');
const { periodBounds } = require('../src/cycles');
const { userCardMatchesInstrument } = require('../src/import_resolvers');
const { createSyncTransactionApplier } = require('../src/sync_transaction_state');
const { routeFixture, requireCleanFixture } = require('./sync_transport_postgres');

function fixtureUrl() {
  const raw = process.env.PANDAPAY_SYNC_FINANCIAL_TEST_URL;
  if (!raw) throw new Error('explicit financial fixture URL required');
  const url = new URL(raw);
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['postgres:', 'postgresql:'].includes(url.protocol) ||
      !['127.0.0.1', 'localhost', '::1'].includes(host) ||
      url.pathname !== '/sync_transport_test' || !url.username || !url.password ||
      url.search || url.hash) {
    throw new Error('loopback sync_transport_test URL required');
  }
  return url;
}

function extractTransactionStateFunctions() {
  const source = fs.readFileSync(require.resolve('../src/index'), 'utf8');
  const start = source.indexOf('async function loadUserCardForState(client');
  const end = source.indexOf('/** Mirrors the txn_instrument / txn_entry_kind enums', start);
  assert.ok(start >= 0 && end > start, 'actual transaction state functions must be present');
  const context = { rewardMath, periodBounds };
  vm.runInNewContext(source.slice(start, end), context, { filename: 'api/src/index.js' });
  return {
    loadUserCardForState: context.loadUserCardForState,
    reverseTransactionState: context.reverseTransactionState,
    applyTransactionState: context.applyTransactionState,
  };
}

function transactionApplier() {
  return createSyncTransactionApplier({
    ...extractTransactionStateFunctions(),
    userCardMatchesInstrument,
  });
}

function financialFixtureIds() {
  return {
    profileId: crypto.randomUUID(),
    otherProfileId: crypto.randomUUID(),
    deviceId: crypto.randomUUID(),
    otherDeviceId: crypto.randomUUID(),
    transactionId: crypto.randomUUID(),
    otherTransactionId: crypto.randomUUID(),
    userCardId: crypto.randomUUID(),
    otherUserCardId: crypto.randomUUID(),
    issuerId: crypto.randomUUID(),
    productId: crypto.randomUUID(),
    rewardRuleId: crypto.randomUUID(),
    capRuleId: crypto.randomUUID(),
    milestoneRuleId: crypto.randomUUID(),
    feeWaiverRuleId: crypto.randomUUID(),
    categoryId: crypto.randomUUID(),
    secondCategoryId: crypto.randomUUID(),
    userCategoryId: crypto.randomUUID(),
    nestedUserCategoryId: crypto.randomUUID(),
  };
}

async function snapshotSynthetic(client, ids) {
  const profileId = ids.profileId;
  const transactionId = ids.transactionId;
  const userCardId = ids.userCardId;
  const reads = [
    () => client.query(`SELECT id::text, amount_inr::text, occurred_at::text, user_card_id::text,
                         category_id::text, user_category_id::text, merchant_name,
                         rail::text, instrument::text, entry_kind::text, status::text,
                         expected_points::text, expected_value_inr::text, state_applied, is_backfill
                    FROM transactions WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, transaction_id::text, delta_points::text, reason, state::text,
                         occurred_at::text FROM points_ledger WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, user_card_id::text, cap_rule_id::text, period_start::text,
                         period_end::text, consumed::text, cap_value_snapshot::text
                    FROM cap_states WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, user_card_id::text, milestone_rule_id::text, period_start::text,
                         period_end::text, qualified_spend::text, achieved_at::text
                    FROM milestone_states WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, user_card_id::text, fee_waiver_rule_id::text, period_start::text,
                         period_end::text, qualified_spend::text, waived_at::text
                    FROM fee_waiver_states WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, device_id::text, entity, entity_id::text, op::text,
                         payload::text, field_clocks::text, client_seq::text, server_seq::text
                    FROM change_log WHERE profile_id=$1 ORDER BY server_seq`, [profileId]),
    () => client.query(`SELECT id::text, entity, entity_id::text, field, local_value::text,
                         server_value::text, chosen_value::text, user_acknowledged
                    FROM sync_conflicts WHERE profile_id=$1 ORDER BY id`, [profileId]),
    () => client.query(`SELECT id::text, transaction_id::text, user_card_id::text, category_id::text,
                         amount_inr::text, note FROM transaction_splits WHERE transaction_id=$1 ORDER BY id`, [transactionId]),
    () => client.query(`SELECT id::text, profile_id::text, parent_category_id::text,
                         parent_user_category_id::text, name, slug
                    FROM user_categories WHERE profile_id=$1 ORDER BY id`, [profileId]),
  ];
  const results = [];
  for (const read of reads) results.push(await read());
  const [transaction, points, caps, milestones, feeWaivers, changes, conflicts, splits, categories] = results;
  // Keep this serializable shape deterministic for fixture assertions.
  return {
    profileId,
    userCardId,
    transactionId,
    transaction: transaction.rows,
    points: points.rows,
    caps: caps.rows,
    milestones: milestones.rows,
    feeWaivers: feeWaivers.rows,
    changeLog: changes.rows,
    conflicts: conflicts.rows,
    splits: splits.rows,
    userCategories: categories.rows,
  };
}

function fieldClock(field, value = Date.now()) {
  return { [field]: value };
}

function updateChange(ids, clientSeq, payload, fieldClocks) {
  return {
    entity: 'transactions',
    entityId: ids.transactionId,
    op: 'update',
    payload,
    fieldClocks,
    clientSeq,
  };
}

async function setAppUser(client, profileId, query) {
  await client.query('SAVEPOINT sync_financial_core');
  try {
    await client.query('SET LOCAL ROLE app_user');
    await client.query("SELECT set_config('app.user_id',$1,true)", [profileId]);
    const result = await query(client);
    await client.query('RESET ROLE');
    await client.query('RELEASE SAVEPOINT sync_financial_core');
    return result;
  } catch (error) {
    await client.query('ROLLBACK TO SAVEPOINT sync_financial_core');
    await client.query('RESET ROLE');
    await client.query('RELEASE SAVEPOINT sync_financial_core');
    throw error;
  }
}

async function readFinancialState(client, ids) {
  const reads = [
    () => client.query(`SELECT amount_inr::text, user_card_id::text, category_id::text,
                         user_category_id::text, instrument::text, entry_kind::text,
                         status::text, expected_points::text, expected_value_inr::text,
                         state_applied, is_backfill
                    FROM transactions WHERE id=$1 AND profile_id=$2`, [ids.transactionId, ids.profileId]),
    () => client.query(`SELECT consumed::text FROM cap_states WHERE profile_id=$1 AND user_card_id=$2 AND cap_rule_id=$3 ORDER BY period_start`, [ids.profileId, ids.userCardId, ids.capRuleId]),
    () => client.query(`SELECT qualified_spend::text FROM milestone_states WHERE profile_id=$1 AND user_card_id=$2 AND milestone_rule_id=$3 ORDER BY period_start`, [ids.profileId, ids.userCardId, ids.milestoneRuleId]),
    () => client.query(`SELECT qualified_spend::text FROM fee_waiver_states WHERE profile_id=$1 AND user_card_id=$2 AND fee_waiver_rule_id=$3 ORDER BY period_start`, [ids.profileId, ids.userCardId, ids.feeWaiverRuleId]),
    () => client.query(`SELECT id::text, delta_points::text FROM points_ledger WHERE profile_id=$1 AND transaction_id=$2 ORDER BY id`, [ids.profileId, ids.transactionId]),
  ];
  const results = [];
  for (const read of reads) results.push(await read());
  const [transaction, caps, milestones, feeWaivers, points] = results;
  return {
    transaction: transaction.rows[0],
    caps: caps.rows.map((row) => row.consumed),
    milestones: milestones.rows.map((row) => row.qualified_spend),
    feeWaivers: feeWaivers.rows.map((row) => row.qualified_spend),
    points: points.rows,
  };
}

async function main() {
  let stage = 'validate_url';
  const url = fixtureUrl();
  const client = new Client({
    connectionString: url.toString(),
    ssl: false,
    connectionTimeoutMillis: 3000,
    application_name: 'pandapay-sync-financial-fixture',
  });
  let inTransaction = false;
  try {
    stage = 'connect';
    await client.connect();
    await requireCleanFixture(client, (value) => { stage = value; });
    stage = 'begin_fixture';
    await client.query('BEGIN');
    inTransaction = true;

    const ids = financialFixtureIds();
    stage = 'seed_profiles';
    await client.query('INSERT INTO profiles(id) VALUES($1),($2)', [ids.profileId, ids.otherProfileId]);
    stage = 'seed_devices';
    for (const [deviceId, profileId] of [[ids.deviceId, ids.profileId], [ids.otherDeviceId, ids.otherProfileId]]) {
      await client.query("INSERT INTO user_devices(id,profile_id,platform) VALUES($1,$2,'android')", [deviceId, profileId]);
      await client.query('INSERT INTO sync_cursors(device_id,profile_id) VALUES($1,$2)', [deviceId, profileId]);
    }
    stage = 'seed_catalogue';
    const suffix = ids.productId.replaceAll('-', '');
    await client.query('INSERT INTO issuers(id,slug,name) VALUES($1,$2,$3)', [ids.issuerId, `sync-fin-${suffix}`, 'Synthetic Sync Financial Issuer']);
    await client.query(`INSERT INTO card_products
      (id,issuer_id,slug,name,network,card_type,status,verified_at,point_value_inr,base_reward_unit,base_reward_rate)
      VALUES($1,$2,$3,'Synthetic Sync Financial Card','visa','credit','published',now(),0.25,'points_per_100',1)`,
    [ids.productId, ids.issuerId, `sync-fin-card-${suffix}`]);
    await client.query(`INSERT INTO spend_categories(id,slug,name)
      VALUES($1,$2,'Synthetic Sync Category'),($3,$4,'Synthetic Sync Alternate Category')`,
    [ids.categoryId, `sync-fin-cat-${suffix}`, ids.secondCategoryId, `sync-fin-alt-${suffix}`]);
    await client.query(`INSERT INTO reward_rules(id,card_product_id,category_id,unit,rate,priority)
      VALUES($1,$2,$3,'points_per_100',5,1)`, [ids.rewardRuleId, ids.productId, ids.categoryId]);
    await client.query(`INSERT INTO cap_rules
      (id,card_product_id,reward_rule_id,label,measure,period,cap_value,post_cap_unit,post_cap_rate)
      VALUES($1,$2,$3,'Synthetic spend cap','spend_amount','calendar_month',5000,'points_per_100',1)`,
    [ids.capRuleId, ids.productId, ids.rewardRuleId]);
    await client.query(`INSERT INTO milestone_rules
      (id,card_product_id,label,period,threshold_spend_inr,reward_description,reward_value_inr,anchor)
      VALUES($1,$2,'Synthetic spend milestone','calendar_month',5000,'Synthetic fixture milestone',25,'calendar_year')`,
    [ids.milestoneRuleId, ids.productId]);
    await client.query(`INSERT INTO fee_waiver_rules
      (id,card_product_id,threshold_spend_inr,period,waives_fee_inr)
      VALUES($1,$2,5000,'calendar_month',500)`, [ids.feeWaiverRuleId, ids.productId]);
    await client.query(`INSERT INTO user_cards(id,profile_id,card_product_id,statement_day,opened_on)
      VALUES($1,$2,$3,10,'2024-01-01'),($4,$5,$3,10,'2024-01-01')`,
    [ids.userCardId, ids.profileId, ids.productId, ids.otherUserCardId, ids.otherProfileId]);

    stage = 'seed_transactions';
    await client.query(`INSERT INTO transactions
      (id,profile_id,user_card_id,amount_inr,occurred_at,merchant_name,category_id,rail,source,status,
       instrument,entry_kind,state_applied,is_backfill,note)
      VALUES($1,$2,$3,1000,'2026-05-15T12:00:00Z','Fixture Store',$4,'swipe','manual','active',
       'credit_card','spend',false,false,'baseline')`,
    [ids.transactionId, ids.profileId, ids.userCardId, ids.categoryId]);
    await client.query(`INSERT INTO transactions
      (id,profile_id,amount_inr,occurred_at,merchant_name,rail,source,status,instrument,entry_kind,note)
      VALUES($1,$2,5,'2026-05-15T12:00:00Z','Other Profile Store','unknown','manual','active','cash','spend','other profile')`,
    [ids.otherTransactionId, ids.otherProfileId]);

    stage = 'baseline_apply_state';
    const core = extractTransactionStateFunctions();
    await setAppUser(client, ids.profileId, async (runtime) => {
      const card = await core.loadUserCardForState(runtime, ids.profileId, ids.userCardId);
      assert.ok(card, 'fixture card must load through app_user');
      await core.applyTransactionState(runtime, ids.profileId, card, {
        txnId: ids.transactionId,
        userCardId: ids.userCardId,
        amount: 1000,
        occurred: new Date('2026-05-15T12:00:00Z'),
        categoryId: ids.categoryId,
        merchantName: 'Fixture Store',
        rail: 'swipe',
        sign: 1,
      });
      await runtime.query('UPDATE transactions SET state_applied=true WHERE id=$1 AND profile_id=$2', [ids.transactionId, ids.profileId]);
    });

    const routes = routeFixture(client, {
      typed: true,
      transactionApplier: createSyncTransactionApplier({
        ...core,
        userCardMatchesInstrument,
      }),
    });
    let state = await readFinancialState(client, ids);
    stage = 'baseline_state_assertions';
    assert.equal(state.transaction.amount_inr, '1000.00');
    assert.equal(state.transaction.expected_points, '50.0000');
    assert.equal(state.transaction.expected_value_inr, '12.50');
    assert.deepEqual(state.caps, ['1000.00']);
    assert.deepEqual(state.milestones, ['1000.00']);
    assert.deepEqual(state.feeWaivers, ['1000.00']);
    assert.deepEqual(state.points.map((row) => row.delta_points), ['50.0000']);

    const push = (changes, inspect, retainWrites = true) => routes.invoke(
      'post', '/sync/push',
      { userId: ids.profileId, body: { deviceId: ids.deviceId, changes } },
      inspect,
      { retainWrites },
    );

    stage = 'amount_edit_reconciles_state';
    let response = await push([updateChange(ids, 1, { amount_inr: 1200 }, fieldClock('amount_inr', 1000))]);
    assert.equal(response.code, 200);
    assert.equal(response.body.appliedCount, 1);
    state = await readFinancialState(client, ids);
    assert.equal(state.transaction.amount_inr, '1200.00');
    assert.equal(state.transaction.expected_points, '60.0000');
    assert.equal(state.transaction.expected_value_inr, '15.00');
    assert.deepEqual(state.caps, ['1200.00']);
    assert.deepEqual(state.milestones, ['1200.00']);
    assert.deepEqual(state.feeWaivers, ['1200.00']);
    assert.deepEqual(state.points.map((row) => row.delta_points), ['60.0000']);
    assert.equal(state.points.length, 1, 'reverse and reapply must leave exactly one transaction-keyed points row');

    stage = 'same_value_new_clock_noop';
    const snapshotBeforeRetry = await snapshotSynthetic(client, ids);
    response = await push([updateChange(ids, 2, { amount_inr: 1200 }, fieldClock('amount_inr', 2000))]);
    assert.equal(response.body.appliedCount, 1);
    const snapshotAfterRetry = await snapshotSynthetic(client, ids);
    assert.deepEqual(
      { ...snapshotAfterRetry, changeLog: snapshotBeforeRetry.changeLog },
      snapshotBeforeRetry,
      'same-value clock retry may append a log row but must not mutate rewards, points, or transaction state',
    );

    stage = 'stale_amount_clock_noop';
    const financialBeforeStale = await readFinancialState(client, ids);
    response = await push([updateChange(ids, 3, { amount_inr: 900 }, fieldClock('amount_inr', 1500))]);
    assert.equal(response.body.results[0].applied, true);
    assert.equal(response.body.results[0].conflicts, 1);
    assert.deepEqual(await readFinancialState(client, ids), financialBeforeStale);

    stage = 'invalid_numeric_then_valid_ordered_item';
    response = await push([
      updateChange(ids, 4, { amount_inr: 'not-a-number' }, fieldClock('amount_inr', 3000)),
      updateChange(ids, 5, { note: 'fixture-valid-note-after-numeric-reject' }, fieldClock('note', 3000)),
    ]);
    assert.equal(response.code, 200);
    assert.deepEqual(response.body.results.map((item) => [item.clientSeq, item.applied, item.reason]), [
      [4, false, 'rejected'], [5, true, null],
    ]);
    assert.equal(JSON.stringify(response.body).includes('not-a-number'), false);
    assert.equal((await client.query('SELECT note FROM transactions WHERE id=$1', [ids.transactionId])).rows[0].note,
      'fixture-valid-note-after-numeric-reject');
    assert.equal((await readFinancialState(client, ids)).transaction.amount_inr, '1200.00');
    assert.equal(routes.takeItemSqlStates().includes('22P02'), true);

    stage = 'split_underflow_rolls_back_rpc_log_and_state';
    await client.query('INSERT INTO transaction_splits(transaction_id,amount_inr,note) VALUES($1,1100.00,$2)', [ids.transactionId, 'synthetic split']);
    const beforeSplitFailure = await snapshotSynthetic(client, ids);
    response = await push([updateChange(ids, 6, { amount_inr: 1000 }, fieldClock('amount_inr', 4000))]);
    assert.equal(response.body.results[0].applied, false);
    assert.equal(response.body.results[0].reason, 'rejected');
    assert.equal(response.body.results[0].detail, 'amount is less than saved split shares; edit or clear the split first');
    const afterSplitFailure = await snapshotSynthetic(client, ids);
    assert.deepEqual(afterSplitFailure, beforeSplitFailure, 'over-split rejection must roll back both change log and reward state');

    stage = 'foreign_card_and_transaction_rejected';
    const beforeForeignCard = await snapshotSynthetic(client, ids);
    response = await push([updateChange(ids, 7, { user_card_id: ids.otherUserCardId }, fieldClock('user_card_id', 5000))]);
    assert.equal(response.body.results[0].applied, false);
    assert.equal(response.body.results[0].reason, 'rejected');
    assert.deepEqual(await snapshotSynthetic(client, ids), beforeForeignCard);
    response = await push([{
      entity: 'transactions', entityId: ids.otherTransactionId, op: 'update',
      payload: { note: 'cross-profile-denied' }, fieldClocks: { note: 6000 }, clientSeq: 8,
    }]);
    assert.equal(response.body.results[0].reason, 'not_found');
    assert.equal((await client.query('SELECT note FROM transactions WHERE id=$1', [ids.otherTransactionId])).rows[0].note,
      'other profile');

    stage = 'nested_private_category_parent';
    await client.query(`INSERT INTO user_categories
      (id,profile_id,name,slug,parent_category_id,parent_user_category_id)
      VALUES($1,$2,'Fixture parent','fixture-parent',$3,NULL),
            ($4,$2,'Fixture nested','fixture-nested',NULL,$1)`,
    [ids.userCategoryId, ids.profileId, ids.categoryId, ids.nestedUserCategoryId]);
    response = await push([updateChange(ids, 9, {
      category_id: null,
      user_category_id: ids.nestedUserCategoryId,
    }, { category_id: 7000, user_category_id: 7000 })]);
    assert.equal(response.body.results[0].applied, true);
    const categorized = await readFinancialState(client, ids);
    assert.equal(categorized.transaction.category_id, null, 'nested user category keeps the stored public category null');
    assert.equal(categorized.transaction.user_category_id, ids.nestedUserCategoryId);
    assert.equal(categorized.transaction.expected_points, '60.0000', 'state core resolves the owned ancestor public category');

    stage = 'inactive_status_delete_domain_guards';
    await client.query("UPDATE transactions SET status='ignored' WHERE id=$1", [ids.transactionId]);
    const beforeInactive = await snapshotSynthetic(client, ids);
    response = await push([updateChange(ids, 10, { amount_inr: 1300 }, fieldClock('amount_inr', 8000))]);
    assert.equal(response.body.results[0].applied, false);
    assert.equal(response.body.results[0].reason, 'rejected');
    assert.deepEqual(await snapshotSynthetic(client, ids), beforeInactive);
    response = await push([updateChange(ids, 11, { status: 'active' }, fieldClock('status', 9000))]);
    assert.equal(response.body.results[0].detail, 'Use the transaction status route for status changes or deletion.');
    response = await push([{
      entity: 'transactions', entityId: ids.transactionId, op: 'delete', payload: {},
      fieldClocks: {}, clientSeq: 12,
    }]);
    assert.equal(response.body.results[0].reason, 'rejected');
    assert.deepEqual(await snapshotSynthetic(client, ids), beforeInactive);

    stage = 'instrument_cash_transition';
    await client.query("UPDATE transactions SET status='active' WHERE id=$1", [ids.transactionId]);
    response = await push([updateChange(ids, 13, {
      instrument: 'cash', entry_kind: 'transfer', user_card_id: null,
    }, {
      instrument: 10000, entry_kind: 10000, user_card_id: 10000,
    })]);
    assert.equal(response.body.results[0].applied, true);
    state = await readFinancialState(client, ids);
    assert.equal(state.transaction.instrument, 'cash');
    assert.equal(state.transaction.entry_kind, 'transfer');
    assert.equal(state.transaction.user_card_id, null);
    assert.equal(state.transaction.expected_points, '0.0000');
    assert.equal(state.transaction.expected_value_inr, '0.00');
    assert.equal(state.points.length, 0);
    assert.deepEqual(state.caps, ['0.00']);
    assert.deepEqual(state.milestones, ['0.00']);
    assert.deepEqual(state.feeWaivers, ['0.00']);

    stage = 'final_synthetic_snapshot';
    const snapshot = await snapshotSynthetic(client, ids);
    const hash = crypto.createHash('sha256').update(JSON.stringify(snapshot)).digest('hex');
    await client.query('ROLLBACK');
    inTransaction = false;
    process.stdout.write(`PASS sync financial PostgreSQL fixture rolled back snapshot=${hash}\n`);
  } catch (error) {
    const failure = new Error('sync financial PostgreSQL fixture failed');
    failure.syncFixtureStage = error?.syncFixtureStage || stage;
    failure.syncFixtureCode = /^[A-Z0-9_]{2,48}$/.test(error?.code || '') ? error.code : 'check_failed';
    throw failure;
  } finally {
    if (inTransaction) await client.query('ROLLBACK').catch(() => {});
    if (client._connected) await client.end();
  }
}

if (require.main === module) {
  main().catch((error) => {
    const stage = /^[a-z_]+$/.test(error?.syncFixtureStage || '') ? error.syncFixtureStage : 'startup';
    const code = /^[A-Z0-9_]{2,48}$/.test(error?.syncFixtureCode || '') ? error.syncFixtureCode : 'check_failed';
    process.stderr.write(`FAIL sync financial PostgreSQL fixture stage=${stage} code=${code}\n`);
    process.exitCode = 1;
  });
}

module.exports = { main, fixtureUrl };
