'use strict';
// Disposable migrated Postgres only; synthetic legacy source history.
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const h = require('./helpers');
const url = process.env.SMS_V2_TEST_DATABASE_URL;
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';
let pool;
const profiles = [];
const cards = [];
let applies = 0;
const deps = {
  loadUserCardForState: async (_client, _profile, id) => ({ id }),
  applyTransactionState: async () => { applies += 1; },
  reverseTransactionState: async () => { throw new Error('history supersede must not reverse historical card state'); },
};
async function own(profile, fn) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query('SET LOCAL ROLE app_user');
    await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
    const value = await fn(client);
    await client.query('COMMIT');
    return value;
  } catch (e) { await client.query('ROLLBACK'); throw e; }
  finally { client.release(); }
}
async function profile() {
  const id = crypto.randomUUID();
  await pool.query('INSERT INTO profiles(id) VALUES($1)', [id]);
  profiles.push(id); return id;
}
async function legacy(p, sourceKey, overrides = {}) {
  return (await pool.query(`INSERT INTO transactions(profile_id,source_key,amount_inr,occurred_at,source,status,entry_kind,instrument,state_applied,note)
    VALUES($1,$2,499,$3,$4,$5,'spend','upi_bank',true,'Synthetic retained edit') RETURNING id`,
  [p, sourceKey, h.T0, overrides.source || 'sms', overrides.status || 'active'])).rows[0].id;
}
async function ingest(p, body, backfill = false) {
  const { ingestBatch } = require('../../src/sms_v2/storage');
  const { supersedeLegacy } = require('../../src/sms_v2/legacy_supersede');
  return own(p, c => ingestBatch(c, p, body, { backfill, deps, hooks: { afterEventsStored: supersedeLegacy } }));
}
test.before(async () => { if (skip) return; pool = new (require('pg').Pool)({ connectionString: url }); });
test.after(async () => {
  if (!pool) return;
  await pool.query('DELETE FROM profiles WHERE id=ANY($1::uuid[])', [profiles]);
  for (const item of cards) {
    await pool.query('DELETE FROM card_products WHERE id=$1', [item.product]);
    await pool.query('DELETE FROM issuers WHERE id=$1', [item.issuer]);
  }
  await pool.end();
});

test('all event leg source keys supersede exactly active legacy SMS rows, preserve edits, and replay idempotently', { skip }, async () => {
  const p = await profile(); const other = await profile();
  const a = h.fact({}); const b = h.fact({});
  const ignored = h.fact({}); const manual = h.fact({}); const missingBody = `sms:synthetic:no-body:${crypto.randomUUID()}`;
  const idA = await legacy(p, a.sourceKey); const idB = await legacy(p, b.sourceKey);
  const idOther = await legacy(other, a.sourceKey);
  const idIgnored = await legacy(p, ignored.sourceKey, { status: 'ignored' });
  const idManual = await legacy(p, manual.sourceKey, { source: 'manual' });
  const idMissing = await legacy(p, missingBody);
  const inst = h.instrument({ kind: 'bank_account' });
  const event = h.event(a, { type: 'card_bill_payment', legs: [
    { factId: a.factId, role: 'debit_leg' }, { factId: b.factId, role: 'credit_leg' },
    { factId: ignored.factId, role: 'original' }, { factId: manual.factId, role: 'original' },
  ] });
  const body = h.batch({ items: [a, b, ignored, manual].map(f => h.item([f])), instruments: [inst], events: [event],
    ledger: [h.ledger(event, { fromInstrumentId: inst.instrumentId })] });
  await ingest(p, body, true);
  const read = () => pool.query('SELECT id,status::text,pipeline_version,event_id,superseded_by_event_id,note,source_key FROM transactions WHERE profile_id=ANY($1::uuid[]) ORDER BY id', [[p, other]]);
  const before = (await read()).rows;
  const rows = new Map(before.map(r => [r.id, r]));
  for (const id of [idA, idB]) {
    assert.equal(rows.get(id).status, 'superseded');
    assert.equal(rows.get(id).superseded_by_event_id, event.eventId);
    assert.equal(rows.get(id).note, 'Synthetic retained edit');
    assert.equal(rows.get(id).pipeline_version, 1);
    assert.equal(rows.get(id).event_id, null, 'legacy source row is retained, never adopted');
  }
  assert.equal(rows.get(idOther).status, 'active');
  assert.equal(rows.get(idIgnored).status, 'ignored');
  assert.equal(rows.get(idManual).status, 'active');
  assert.equal(rows.get(idMissing).status, 'active');
  const v2 = before.find(r => r.event_id === event.eventId);
  assert.equal(v2.status, 'active');
  assert.equal(v2.source_key, `${a.sourceKey}#${event.eventId.slice(0, 12)}`);
  await ingest(p, body, true);
  assert.deepEqual((await read()).rows, before);
  await assert.rejects(own(p, c => c.query("UPDATE transactions SET status='active',superseded_by_event_id=NULL WHERE id=$1", [idA])), { code: '42501' });
});

test('legacy source history suppresses card state even when live upload omits backfill', { skip }, async () => {
  const p = await profile(); const fact = h.fact({});
  const slug = `wp16-${crypto.randomUUID()}`;
  const issuer = (await pool.query("INSERT INTO issuers(slug,name) VALUES($1,'Synthetic WP16 issuer') RETURNING id", [slug])).rows[0].id;
  const product = (await pool.query("INSERT INTO card_products(issuer_id,slug,name,network) VALUES($1,$2,'Synthetic WP16 card','visa') RETURNING id", [issuer, slug])).rows[0].id;
  const card = (await pool.query('INSERT INTO user_cards(profile_id,card_product_id) VALUES($1,$2) RETURNING id', [p, product])).rows[0].id;
  cards.push({ issuer, product });
  await legacy(p, fact.sourceKey);
  const instrument = h.instrument({ userCardId: card }); const event = h.event(fact);
  const baseline = applies;
  await ingest(p, h.batch({ items: [h.item([fact])], instruments: [instrument], events: [event], ledger: [h.ledger(event, { fromInstrumentId: instrument.instrumentId })] }));
  const row = (await pool.query('SELECT is_backfill,state_applied FROM transactions WHERE profile_id=$1 AND event_id=$2', [p, event.eventId])).rows[0];
  assert.deepEqual(row, { is_backfill: true, state_applied: false });
  assert.equal(applies, baseline);
});

test('actual reports exclude superseded legacy rows while including the v2 replacement', { skip }, async () => {
  const p = await profile(); const fact = h.fact({});
  await legacy(p, fact.sourceKey);
  const instrument = h.instrument({ kind: 'bank_account' }); const event = h.event(fact);
  await ingest(p, h.batch({ items: [h.item([fact])], instruments: [instrument], events: [event], ledger: [h.ledger(event, { fromInstrumentId: instrument.instrumentId })] }), true);
  const reports = require('../../src/spend_reports');
  const bounds = { start: new Date('2026-11-01T00:00:00Z'), end: new Date('2026-12-01T00:00:00Z') };
  const result = await own(p, async c => ({
    totals: await reports.periodTotals(c, p, bounds),
    budget: await reports.budgetSpend(c, p, { scope: 'overall' }, bounds),
    instruments: await reports.spendByInstrument(c, p, bounds),
    categories: await reports.spendByCategory(c, p, bounds),
    subcategories: await reports.spendBySubcategory(c, p, bounds),
    merchants: await reports.spendByMerchant(c, p, bounds),
    cards: await reports.spendByCard(c, p, bounds),
    cardCategories: await reports.spendByCardCategory(c, p, bounds),
    series: await reports.spendSeries(c, p, 'month', 1, new Date('2026-11-15T00:00:00Z'), { timeZone: 'UTC' }),
  }));
  assert.equal(result.totals.spend.totalInr, 499);
  assert.equal(result.totals.spend.txnCount, 1);
  assert.equal(result.categories[0].totalInr, 499);
  assert.deepEqual(result.subcategories, []);
  assert.equal(result.merchants[0].totalInr, 499);
  assert.equal(result.cards[0].totalInr, 499);
  assert.equal(result.cardCategories[0].totalInr, 499);
  assert.equal(result.series[0].spendInr, 499);
  assert.equal(result.series[0].txnCount, 1);
  assert.equal(result.budget.spentInr, 499);
  assert.equal(result.budget.txnCount, 1);
  assert.equal(result.instruments[0].totalInr, 499);
  assert.equal(result.instruments[0].txnCount, 1);
});
