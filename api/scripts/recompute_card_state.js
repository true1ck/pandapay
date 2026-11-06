#!/usr/bin/env node
/**
 * Rebuilds derived card state for v2-shaped user cards after a catalogue
 * publish (Card Rewards Phase 1, WP8; plan §9 step 5):
 *   - current-period cap_states, in native units with cap_kind (C3.6, D15f);
 *   - current milestone_states windows (C3.7);
 *   - expected_points / expected_value_inr (and the estimated points-ledger
 *     row) for every spend the cap replay covers, at least this month;
 *   - each replayed transaction's card_state_v2 record, so later edits
 *     reverse exactly;
 *   - on EVERY user card whose product has fee-waiver rules (v1 or v2), the
 *     current period's fee_waiver_states (C8 D33b): qualified spend replayed
 *     with the live path's (v1) maths, then waived_at settled. Earlier
 *     periods' fee-waiver history is not rebuilt.
 *
 * A forced catalogue re-import deletes and re-creates a card's rules, so
 * their state rows cascade away; this replays the ledger against the new
 * rules. v1-shaped cards get only the fee-waiver rebuild (the rest of their
 * state keeps today's behaviour).
 *
 * After `seed_merchant_directory.js --apply`, a running API server keeps its
 * cached merchant directory for up to 5 minutes (C8 D33f, M4); this script
 * loads the directory fresh each run.
 *
 * Usage:
 *   node api/scripts/recompute_card_state.js                 # dry run: prints diffs, writes nothing
 *   node api/scripts/recompute_card_state.js --apply
 *   Options:
 *     --as-of YYYY-MM-DD      the "current" day (default: now — India day for v2
 *                             windows, the UTC day for fee-waiver periods, as live)
 *     --since YYYY-MM-DD      also replay from this day (wider rebuild)
 *     --card-slug <slug>      only user cards of this card product
 *     --user-card <uuid>      only this user card
 *     --verbose               print every changed row, not just per-card counts
 *
 * Connects with ADMIN_DATABASE_URL (preferred), else DATABASE_URL /
 * API_DATABASE_URL: it must be able to read every user's cards. Only cards
 * whose product is published are touched. Each user card is its own
 * transaction, serialised with transaction writes by the same advisory lock
 * the API uses. Idempotent: a second --apply run reports no changes.
 * Output carries ids and numbers only — no merchant names or SMS text.
 */
'use strict';

const cardStateV2 = require('../src/card_state_v2');
const { istDay } = require('../src/cycles');

const DATE = /^\d{4}-\d{2}-\d{2}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function parseArgs(argv) {
  const opts = { apply: false, asOf: null, since: null, cardSlug: null, userCardId: null, verbose: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const value = () => {
      const v = argv[i + 1];
      if (v === undefined || v.startsWith('--')) throw new Error(`${arg} needs a value`);
      i += 1;
      return v;
    };
    if (arg === '--apply') opts.apply = true;
    else if (arg === '--dry-run') opts.apply = false;
    else if (arg === '--verbose') opts.verbose = true;
    else if (arg === '--as-of') opts.asOf = value();
    else if (arg === '--since') opts.since = value();
    else if (arg === '--card-slug') opts.cardSlug = value();
    else if (arg === '--user-card') opts.userCardId = value();
    else throw new Error(`unknown argument ${arg}`);
  }
  if (opts.asOf && !DATE.test(opts.asOf)) throw new Error('--as-of must be YYYY-MM-DD');
  if (opts.since && !DATE.test(opts.since)) throw new Error('--since must be YYYY-MM-DD');
  if (opts.userCardId && !UUID.test(opts.userCardId)) throw new Error('--user-card must be a uuid');
  return opts;
}

function fmt(n) {
  return n == null ? '–' : String(n);
}

function describe(plan, verbose, log) {
  const { caps, milestones, transactions } = plan.diff;
  if (!verbose) return;
  for (const d of caps) {
    log(`    cap ${d.cap_rule_id} ${d.period_start}: ${d.before ? `${fmt(d.before.consumed)} ${d.before.cap_kind || 'v1'}` : '–'}`
      + ` → ${d.after ? `${fmt(d.after.consumed)} ${d.after.cap_kind}` : 'deleted'}`);
  }
  for (const d of milestones) {
    log(`    milestone ${d.milestone_rule_id} ${d.period_start}: ${d.before ? fmt(d.before.qualified_spend) : '–'}`
      + ` → ${d.after ? fmt(d.after.qualified_spend) : 'deleted'}`);
  }
  for (const d of transactions) {
    log(`    txn ${d.id}: points ${fmt(d.before.native)} → ${fmt(d.after.native)}, ₹ ${fmt(d.before.value)} → ${fmt(d.after.value)}`);
  }
}

function describeFeeWaivers(feePlan, verbose, log) {
  if (!verbose || !feePlan) return;
  for (const d of feePlan.diff) {
    log(`    fee waiver ${d.fee_waiver_rule_id} ${d.period_start}: `
      + `${d.before ? `${fmt(d.before.qualified_spend)}${d.before.waived ? ' waived' : ''}` : '–'}`
      + ` → ${fmt(d.after.qualified_spend)}${d.after.waived ? ' waived' : ''}`);
  }
}

/**
 * Recomputes every matching user card. `nested` runs each card in a
 * savepoint of the caller's transaction (tests) instead of its own
 * transaction. Returns the summary it prints.
 */
async function recompute(client, opts = {}) {
  const log = opts.log || console.log;
  const tx = opts.nested
    ? { begin: 'SAVEPOINT recompute_card', commit: 'RELEASE SAVEPOINT recompute_card', rollback: 'ROLLBACK TO SAVEPOINT recompute_card' }
    : { begin: 'BEGIN', commit: 'COMMIT', rollback: 'ROLLBACK' };
  // An explicit day is taken at noon UTC (the same day in UTC and India);
  // otherwise "now": v2 windows read its India day (C8 D23c) and fee-waiver
  // periods its UTC day, exactly as the live path keys each.
  const asOf = opts.asOf
    ? new Date(`${opts.asOf}T12:00:00.000Z`)
    : new Date((await client.query(`SELECT now() AS now`)).rows[0].now);
  const asOfDay = opts.asOf || istDay(asOf);

  const candidates = await client.query(
    `SELECT uc.id, uc.profile_id, uc.card_product_id, uc.statement_day, cp.slug
       FROM user_cards uc
       JOIN card_products cp ON cp.id = uc.card_product_id
      WHERE uc.is_archived = false AND cp.status = 'published'
        AND ($1::text IS NULL OR cp.slug = $1)
        AND ($2::uuid IS NULL OR uc.id = $2)
      ORDER BY cp.slug, uc.id`,
    [opts.cardSlug || null, opts.userCardId || null],
  );

  const summary = {
    mode: opts.apply ? 'apply' : 'dry-run', asOf: asOfDay, scanned: 0, v2Cards: 0, changedCards: 0,
    capRows: 0, milestoneRows: 0, transactions: 0, records: 0, feeWaiverRows: 0, feeWaiverRecords: 0, failed: 0,
  };
  for (const row of candidates.rows) {
    summary.scanned += 1;
    await client.query(tx.begin);
    try {
      // Act as the card's owner, so the owner-only RLS policies apply even
      // when the connection role is subject to them.
      await client.query(`SELECT set_config('app.user_id', $1, true)`, [row.profile_id]);
      await client.query(`SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, [`transaction-ingest:${row.profile_id}`]);
      const v2 = await cardStateV2.loadV2Card(client, row.id, { profileId: row.profile_id });
      const card = {
        userCardId: row.id, profileId: row.profile_id, cardProductId: row.card_product_id, statementDay: row.statement_day,
      };
      if (v2) summary.v2Cards += 1;
      const plan = v2
        ? await cardStateV2.planCardRebuild(client, v2, {
          asOf, since: opts.since || null, caps: true, milestones: true, expected: true,
        })
        : null;
      const changes = plan
        ? plan.diff.caps.length + plan.diff.milestones.length + plan.diff.transactions.length + plan.txnRecordUpdates.length
        : 0;
      // C8 D33b: fee waivers on every card with rules (v1 maths, current period).
      let feePlan = await cardStateV2.planFeeWaiverRebuild(client, card, { asOf, v2 });
      const feeChanges = feePlan ? feePlan.diff.length : 0;
      // C8 D34e: a fee-waiver change that touches only records still counts.
      const feeRecords = feePlan ? feePlan.recordUpdates.length : 0;
      if (changes > 0 || feeChanges > 0 || feeRecords > 0) {
        summary.changedCards += 1;
        if (plan) {
          summary.capRows += plan.diff.caps.length;
          summary.milestoneRows += plan.diff.milestones.length;
          summary.transactions += plan.diff.transactions.length;
          summary.records += plan.txnRecordUpdates.length;
        }
        summary.feeWaiverRows += feeChanges;
        summary.feeWaiverRecords += feeRecords;
        log(`  ${row.slug} user_card ${row.id}: caps ${plan ? plan.diff.caps.length : 0}, `
          + `milestones ${plan ? plan.diff.milestones.length : 0}, `
          + `expected values ${plan ? plan.diff.transactions.length : 0}, records ${plan ? plan.txnRecordUpdates.length : 0}, `
          + `fee waivers ${feeChanges}, fee-waiver records ${feeRecords}`);
        if (plan) describe(plan, opts.verbose, log);
        describeFeeWaivers(feePlan, opts.verbose, log);
      }
      if (opts.apply && (changes > 0 || feeChanges > 0 || feeRecords > 0)) {
        if (changes > 0) {
          await cardStateV2.applyCardRebuild(client, row.profile_id, v2, plan);
          // Records just changed; plan the fee-waiver section on top of them.
          feePlan = await cardStateV2.planFeeWaiverRebuild(client, card, { asOf, v2 });
        }
        if (feePlan) await cardStateV2.applyFeeWaiverRebuild(client, row.profile_id, card, feePlan);
        await client.query(tx.commit);
      } else {
        await client.query(tx.rollback);
        if (opts.nested) await client.query(tx.commit);
      }
    } catch (err) {
      summary.failed += 1;
      await client.query(tx.rollback);
      if (opts.nested) await client.query(tx.commit);
      log(`  ${row.slug} user_card ${row.id}: FAILED (${err && err.code ? err.code : 'error'})`);
      if (opts.throwOnError) throw err;
    }
  }

  log(`recompute_card_state (${summary.mode}, as of ${summary.asOf}): scanned ${summary.scanned}, `
    + `v2 ${summary.v2Cards}, changed ${summary.changedCards} — cap rows ${summary.capRows}, `
    + `milestone rows ${summary.milestoneRows}, expected values ${summary.transactions}, `
    + `records ${summary.records}, fee-waiver rows ${summary.feeWaiverRows}, `
    + `fee-waiver records ${summary.feeWaiverRecords}, failed ${summary.failed}`);
  if (!opts.apply && summary.changedCards > 0) log('dry run: nothing written. Re-run with --apply to write.');
  return summary;
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { Client } = require('pg');
  const url = process.env.ADMIN_DATABASE_URL || process.env.DATABASE_URL || process.env.API_DATABASE_URL;
  if (!url) throw new Error('ADMIN_DATABASE_URL, DATABASE_URL, or API_DATABASE_URL must be set');
  const client = new Client({
    connectionString: url,
    ssl: process.env.DB_SSL === 'false' ? false : { rejectUnauthorized: false },
  });
  await client.connect();
  try {
    const summary = await recompute(client, opts);
    if (summary.failed > 0) process.exitCode = 1;
  } finally {
    await client.end();
  }
}

if (require.main === module) {
  main().catch((err) => {
    console.error(`recompute_card_state failed: ${err && err.message ? err.message : err}`);
    process.exit(1);
  });
}

module.exports = { recompute, parseArgs };
