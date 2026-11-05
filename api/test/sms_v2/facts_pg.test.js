'use strict';
// WP-08 against a real Postgres that already has the product migrations plus
// 20261111120000_sms_v2_core. Skipped unless SMS_V2_TEST_DATABASE_URL is set; use
// a disposable local database only (the test creates and removes its own rows).
//   SMS_V2_TEST_DATABASE_URL=postgres://postgres:pw@127.0.0.1:5548/scratch node --test api/test/sms_v2/facts_pg.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const zlib = require('node:zlib');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';

const h = require('./helpers');

let pool;
let storage;
let contracts;
const created = { profiles: [], cards: [], products: [], issuers: [] };
const calls = { apply: [], reverse: [] };

const deps = {
  loadUserCardForState: async (client, userId, cardId) => {
    const r = await client.query('SELECT id FROM user_cards WHERE id = $1 AND profile_id = $2 AND is_archived = false', [cardId, userId]);
    return r.rows[0] || null;
  },
  applyTransactionState: async (_client, userId, card, args) => { calls.apply.push({ userId, cardId: card.id, ...args }); return {}; },
  reverseTransactionState: async (_client, userId, card, row) => { calls.reverse.push({ userId, cardId: card.id, txnId: row.id }); return {}; },
};
const hooks = { afterEventsStored: async () => {} };

async function withUserClient(userId, fn) {
  const c = await pool.connect();
  try {
    await c.query('BEGIN');
    await c.query('SET LOCAL ROLE app_user');
    await c.query("SELECT set_config('app.user_id', $1, true)", [userId]);
    const out = await fn(c);
    await c.query('COMMIT');
    return out;
  } catch (e) {
    await c.query('ROLLBACK');
    throw e;
  } finally { c.release(); }
}

async function newProfile() {
  const id = crypto.randomUUID();
  await pool.query('INSERT INTO profiles(id) VALUES ($1)', [id]);
  created.profiles.push(id);
  return id;
}

async function newCard(profileId) {
  const slug = `wp08-${crypto.randomUUID().slice(0, 8)}`;
  const issuer = (await pool.query("INSERT INTO issuers(slug, name) VALUES ($1, 'WP08 test issuer') RETURNING id", [slug])).rows[0].id;
  const product = (await pool.query("INSERT INTO card_products(issuer_id, slug, name, network) VALUES ($1, $2, 'WP08 test card', 'visa') RETURNING id", [issuer, slug])).rows[0].id;
  const card = (await pool.query('INSERT INTO user_cards(profile_id, card_product_id) VALUES ($1, $2) RETURNING id', [profileId, product])).rows[0].id;
  created.issuers.push(issuer); created.products.push(product); created.cards.push(card);
  return card;
}

const ingest = (profileId, body, opts = {}) => withUserClient(profileId, (client) => storage.ingestBatch(client, profileId, body, { backfill: opts.backfill === true, categoryOnly: opts.categoryOnly === true, deps, hooks }));
const byId = (results) => new Map(results.map((r) => [`${r.kind}:${r.id}`, r]));
const statusOf = (results, kind, id) => { const r = byId(results).get(`${kind}:${id}`); return r ? r.status : undefined; };
const errorsOf = (results, kind, id) => (byId(results).get(`${kind}:${id}`) || {}).errors;
const txnsFor = async (profileId) => (await pool.query(
  `SELECT id, event_id, source_key, pipeline_version, amount_inr::float8 AS amount, merchant_name, category_id, user_card_id,
          entry_kind::text AS entry_kind, instrument::text AS instrument, rail::text AS rail, payment_method, status::text AS status, state_applied,
          is_backfill, occurred_at, source::text AS source
     FROM transactions WHERE profile_id = $1 ORDER BY created_at, id`, [profileId])).rows;

test.before(async () => {
  if (skip) return;
  const { Pool } = require('pg');
  pool = new Pool({ connectionString: url });
  storage = require('../../src/sms_v2/storage');
  contracts = require('../../src/sms_v2/contracts');
});

test.after(async () => {
  if (skip || !pool) return;
  try {
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [created.profiles]); // cascades every v2 row and transaction
    await pool.query('DELETE FROM user_cards WHERE id = ANY($1::uuid[])', [created.cards]);
    await pool.query('DELETE FROM card_products WHERE id = ANY($1::uuid[])', [created.products]);
    await pool.query('DELETE FROM issuers WHERE id = ANY($1::uuid[])', [created.issuers]);
  } finally { await pool.end(); }
});

// A card spend with its instrument, event and ledger entry.
function cardSpend(o = {}) {
  const inst = o.inst || h.instrument({ userCardId: o.userCardId || null });
  const f = h.fact({ sourceKey: o.sourceKey, minor: o.minor || 49900, instrument: h.mention() });
  const e = h.event(f, { type: o.type || 'purchase' });
  const l = h.ledger(e, { fromInstrumentId: inst.instrumentId, category: o.category });
  return { inst, f, e, l, body: h.batch({ items: [h.item([f])], instruments: o.skipInstrument ? [] : [inst], events: [e], ledger: [l] }) };
}

test('a full batch is accepted once and is a set of duplicates the second time', { skip }, async () => {
  const p = await newProfile();
  const s = cardSpend();
  const first = await ingest(p, s.body);
  assert.deepEqual(first.results.map((r) => r.status), ['accepted', 'accepted', 'accepted', 'accepted']);
  assert.deepEqual(first.results.map((r) => r.kind), ['instrument', 'fact', 'event', 'ledger']);
  const second = await ingest(p, s.body);
  assert.deepEqual(second.results.map((r) => r.status), ['duplicate', 'duplicate', 'duplicate', 'duplicate']);
  const facts = (await pool.query('SELECT payload, provenance FROM sms_v2_facts WHERE profile_id = $1', [p])).rows;
  assert.equal(facts.length, 1);
  assert.equal(JSON.stringify(facts[0]).includes('evidence'), false, 'evidence spans are never stored');
  assert.equal(facts[0].payload.instrument.raw, null);
  assert.equal(facts[0].payload.senderBrand, 'HDFCBK');
  const inst = (await pool.query('SELECT instrument_id FROM sms_v2_facts WHERE profile_id = $1', [p])).rows[0].instrument_id;
  assert.equal(inst, s.inst.instrumentId, 'the fact is linked to the instrument matching its mention');
});

test('history category refresh preserves user choices and cannot change money or card state', { skip }, async () => {
  const profile = await newProfile();
  const cardId = await newCard(profile);
  const spend = cardSpend({ userCardId: cardId });
  await ingest(profile, spend.body);
  const before = (await txnsFor(profile))[0];
  const previousCalls = { apply: calls.apply.length, reverse: calls.reverse.length };
  const category = { ...spend.l, category: 'groceries', categorySource: 'shared' };
  await ingest(profile, h.batch({ ledger: [category] }), { categoryOnly: true, backfill: true });
  const after = (await txnsFor(profile))[0];
  assert.equal(after.state_applied, before.state_applied);
  assert.equal(calls.apply.length, previousCalls.apply);
  assert.equal(calls.reverse.length, previousCalls.reverse);
  assert.equal(after.amount, before.amount);
  const customId = crypto.randomUUID();
  await pool.query("INSERT INTO user_categories(id,profile_id,name,slug) VALUES($1,$2,'Test choice','test-choice')", [customId, profile]);
  await pool.query('UPDATE transactions SET category_id=NULL,user_category_id=$1 WHERE profile_id=$2 AND event_id=$3', [customId, profile, spend.e.eventId]);
  await ingest(profile, h.batch({ ledger: [{ ...category, category: 'dining' }] }), { categoryOnly: true });
  assert.equal((await txnsFor(profile))[0].category_id, null);
  assert.equal((await pool.query('SELECT user_category_id FROM transactions WHERE profile_id=$1 AND event_id=$2', [profile, spend.e.eventId])).rows[0].user_category_id, customId);
  await pool.query('UPDATE transactions SET user_category_id=NULL WHERE profile_id=$1 AND event_id=$2', [profile, spend.e.eventId]);
  const chosen = { ...category, category: 'fuel', categorySource: 'user' };
  await ingest(profile, h.batch({ ledger: [chosen] }));
  await ingest(profile, h.batch({ ledger: [{ ...category, amountMinor: 100 }] }), { categoryOnly: true, backfill: true });
  const saved = (await pool.query('SELECT category_slug, category_source, amount_minor FROM sms_v2_ledger_entries WHERE profile_id=$1 AND entry_id=$2', [profile, category.entryId])).rows[0];
  assert.equal(saved.category_slug, 'fuel');
  assert.equal(saved.category_source, 'user');
  assert.equal(Number(saved.amount_minor), spend.l.amountMinor);
  await ingest(profile, h.batch({ ledger: [category] }));
  const protectedRow = (await pool.query('SELECT category_slug, category_source FROM sms_v2_ledger_entries WHERE profile_id=$1 AND entry_id=$2', [profile, category.entryId])).rows[0];
  assert.equal(protectedRow.category_slug, 'fuel');
  assert.equal(protectedRow.category_source, 'user');
  await pool.query("UPDATE transactions SET status='ignored' WHERE profile_id=$1 AND event_id=$2", [profile, spend.e.eventId]);
  await ingest(profile, h.batch({ ledger: [{ ...chosen, category: 'groceries' }] }), { categoryOnly: true });
  assert.equal((await txnsFor(profile))[0].status, 'ignored');
  const unseen = { ...chosen, entryId: h.sha('unseen-category') };
  const missing = await ingest(profile, h.batch({ ledger: [unseen] }), { categoryOnly: true });
  assert.equal(statusOf(missing.results, 'ledger', unseen.entryId), 'rejected');
});

test('a fact repeated inside one request, and the contract fixture, are handled', { skip }, async () => {
  const p = await newProfile();
  const f = h.fact({});
  const r = await ingest(p, h.batch({ items: [h.item([f]), h.item([f])] }));
  assert.deepEqual(r.results.map((x) => x.status).sort(), ['accepted', 'duplicate']);
});

test('a fact id that belongs to another profile is rejected without revealing it', { skip }, async () => {
  const a = await newProfile();
  const b = await newProfile();
  const f = h.fact({});
  await ingest(a, h.batch({ items: [h.item([f])] }));
  const r = await ingest(b, h.batch({ items: [h.item([f])] }));
  assert.equal(statusOf(r.results, 'fact', f.factId), 'rejected');
  assert.equal(errorsOf(r.results, 'fact', f.factId)[0].code, 'fact_id_conflict');
  assert.equal((await pool.query('SELECT count(*)::int AS n FROM sms_v2_facts WHERE profile_id = $1', [b])).rows[0].n, 0);
});

test('instrument key conflict: a different id for an existing key is rejected with the existing id', { skip }, async () => {
  const p = await newProfile();
  const first = h.instrument({});
  await ingest(p, h.batch({ instruments: [first] }));
  const clash = h.instrument({});
  const r = await ingest(p, h.batch({ instruments: [clash] }));
  assert.equal(statusOf(r.results, 'instrument', clash.instrumentId), 'rejected');
  const err = errorsOf(r.results, 'instrument', clash.instrumentId)[0];
  assert.equal(err.code, 'instrument_key_conflict');
  assert.equal(err.path, `existingInstrumentId:${first.instrumentId}`);
  // Two ids for one new key inside one request: the first wins.
  const x = h.instrument({ maskDigits: '1111' });
  const y = h.instrument({ maskDigits: '1111' });
  const both = await ingest(p, h.batch({ instruments: [x, y] }));
  assert.equal(statusOf(both.results, 'instrument', x.instrumentId), 'accepted');
  assert.equal(errorsOf(both.results, 'instrument', y.instrumentId)[0].path, `existingInstrumentId:${x.instrumentId}`);
  // Different kind or issuer is a different key; no mask is its own key.
  const other = [h.instrument({ kind: 'debit_card' }), h.instrument({ issuerSlug: 'icici' }), h.instrument({ kind: 'wallet', issuerSlug: 'paytm', maskDigits: null })];
  const ok = await ingest(p, h.batch({ instruments: other }));
  assert.deepEqual(ok.results.map((z) => z.status), ['accepted', 'accepted', 'accepted']);
  const again = h.instrument({ kind: 'wallet', issuerSlug: 'paytm', maskDigits: null });
  assert.equal((await ingest(p, h.batch({ instruments: [again] }))).results[0].errors[0].code, 'instrument_key_conflict');
});

test('instrument upsert by id: changes are accepted, repeats are duplicates, a user limit survives SMS', { skip }, async () => {
  const p = await newProfile();
  const base = h.instrument({ creditLimitMinor: 30000000, creditLimitSource: 'user', creditLimitAt: '2026-10-01T00:00:00Z', availableMinor: 100, availableAt: '2026-11-02T00:00:00Z' });
  await ingest(p, h.batch({ instruments: [base] }));
  assert.equal((await ingest(p, h.batch({ instruments: [base] }))).results[0].status, 'duplicate');
  const sms = { ...base, displayName: 'Renamed', creditLimitMinor: 10000000, creditLimitSource: 'sms', creditLimitAt: '2026-11-03T00:00:00Z', availableMinor: 5, availableAt: '2026-11-01T00:00:00Z', evidenceCount: 7 };
  assert.equal((await ingest(p, h.batch({ instruments: [sms] }))).results[0].status, 'accepted');
  const row = (await pool.query('SELECT display_name, credit_limit_minor::float8 AS lim, credit_limit_source, available_minor::float8 AS av, evidence_count FROM sms_v2_instruments WHERE instrument_id = $1', [base.instrumentId])).rows[0];
  assert.deepEqual(row, { display_name: 'Renamed', lim: 30000000, credit_limit_source: 'user', av: 100, evidence_count: 7 });
});

test('an instrument that names a card the profile does not own is rejected; an id owned by another profile is refused', { skip }, async () => {
  const a = await newProfile();
  const b = await newProfile();
  const card = await newCard(a);
  const stranger = h.instrument({ userCardId: card });
  const r = await ingest(b, h.batch({ instruments: [stranger] }));
  assert.equal(errorsOf(r.results, 'instrument', stranger.instrumentId)[0].code, 'instrument_user_card_unknown');
  const mine = h.instrument({ userCardId: card, maskDigits: '2222' });
  assert.equal((await ingest(a, h.batch({ instruments: [mine] }))).results[0].status, 'accepted');
  const theirs = { ...h.instrument({ maskDigits: '3333' }), instrumentId: mine.instrumentId };
  const clash = await ingest(b, h.batch({ instruments: [theirs] }));
  assert.equal(errorsOf(clash.results, 'instrument', mine.instrumentId)[0].code, 'instrument_id_conflict');
  const survivor = (await pool.query('SELECT profile_id, mask_digits FROM sms_v2_instruments WHERE instrument_id = $1', [mine.instrumentId])).rows[0];
  assert.deepEqual(survivor, { profile_id: a, mask_digits: '2222' });
});

test('an event may only name facts that exist for the profile', { skip }, async () => {
  const p = await newProfile();
  const f = h.fact({});
  const ghost = h.event({ ...f, factId: h.sha('never stored') });
  const r = await ingest(p, h.batch({ events: [ghost] }));
  assert.equal(statusOf(r.results, 'event', ghost.eventId), 'rejected');
  assert.equal(errorsOf(r.results, 'event', ghost.eventId)[0].code, 'event_leg_fact_unknown');
  // Facts stored earlier, or in the same request, are fine.
  const stored = h.fact({});
  await ingest(p, h.batch({ items: [h.item([stored])] }));
  assert.equal(statusOf((await ingest(p, h.batch({ events: [h.event(stored)] }))).results, 'event', stored.factId), 'accepted');
  const same = h.fact({});
  assert.equal(statusOf((await ingest(p, h.batch({ items: [h.item([same])], events: [h.event(same)] }))).results, 'event', same.factId), 'accepted');
  // Another profile's fact does not count.
  const q = await newProfile();
  assert.equal(statusOf((await ingest(q, h.batch({ events: [h.event(stored)] }))).results, 'event', stored.factId), 'rejected');
});

test('event legs grow and the status rules hold, including immutable user_confirmed', { skip }, async () => {
  const p = await newProfile();
  const debit = h.fact({ minor: 100000, attrs: { direction: 'debit', purpose: 'card_payment', rail: 'upi' } });
  const credit = h.fact({ minor: 100000, attrs: { direction: 'credit', purpose: 'card_payment', rail: 'upi' } });
  const credit2 = h.fact({ minor: 100000, attrs: { direction: 'credit', purpose: 'card_payment', rail: 'upi' } });
  await ingest(p, h.batch({ items: [h.item([debit]), h.item([credit]), h.item([credit2])] }));
  const legs1 = [{ factId: debit.factId, role: 'debit_leg' }];
  const legs2 = [...legs1, { factId: credit.factId, role: 'credit_leg' }];
  const mk = (status, legs, o = {}) => ({ ...h.event(debit, { type: 'card_bill_payment', status, legs, linkRuleId: 'LINK-CARD-BILL' }), ...o });
  const id = debit.factId;
  const read = async () => (await pool.query('SELECT status, legs FROM sms_v2_events WHERE event_id = $1', [id])).rows[0];

  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('awaiting_leg', legs1)] }))).results, 'event', id), 'accepted');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('awaiting_leg', legs1)] }))).results, 'event', id), 'duplicate');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('complete', legs2)] }))).results, 'event', id), 'accepted');
  assert.equal((await read()).legs.length, 2);
  // complete -> awaiting_leg is refused, and so is shrinking: the stale upload changes nothing.
  const back = await ingest(p, h.batch({ events: [mk('awaiting_leg', legs1)] }));
  assert.equal(errorsOf(back.results, 'event', id)[0].code, 'event_status_transition_invalid');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('complete', legs1)] }))).results, 'event', id), 'duplicate');
  assert.deepEqual((await read()).legs, legs2);
  // A leg cannot change role.
  const swapped = [legs1[0], { factId: credit.factId, role: 'reversal' }];
  assert.equal(errorsOf((await ingest(p, h.batch({ events: [mk('complete', swapped)] }))).results, 'event', id)[0].code, 'event_leg_role_conflict');
  // Anything -> user_confirmed, then nothing leaves it; legs still grow.
  const legs3 = [...legs2, { factId: credit2.factId, role: 'duplicate_notice' }];
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('user_confirmed', legs2)] }))).results, 'event', id), 'accepted');
  for (const s of ['awaiting_leg', 'ambiguous', 'complete']) {
    const r = await ingest(p, h.batch({ events: [mk(s, legs2, { type: 'unknown' })] }));
    assert.equal(errorsOf(r.results, 'event', id)[0].code, 'event_status_locked', s);
  }
  assert.equal((await read()).status, 'user_confirmed');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('user_confirmed', legs3)] }))).results, 'event', id), 'accepted');
  assert.equal((await read()).legs.length, 3);
  // awaiting_leg -> ambiguous -> complete on a fresh event.
  const f2 = h.fact({ minor: 500 });
  await ingest(p, h.batch({ items: [h.item([f2])] }));
  const e2 = (status) => h.event(f2, { type: 'unknown', status });
  assert.equal(statusOf((await ingest(p, h.batch({ events: [e2('awaiting_leg')] }))).results, 'event', f2.factId), 'accepted');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [e2('ambiguous')] }))).results, 'event', f2.factId), 'accepted');
  assert.equal(errorsOf((await ingest(p, h.batch({ events: [e2('awaiting_leg')] }))).results, 'event', f2.factId)[0].code, 'event_status_transition_invalid');
  assert.equal(statusOf((await ingest(p, h.batch({ events: [e2('complete')] }))).results, 'event', f2.factId), 'accepted');
  // A new explicit correction can remove and re-role a previously linked fact.
  const correctedLegs = [{ factId: id, role: 'original' }];
  assert.equal(statusOf((await ingest(p, h.batch({ events: [mk('user_confirmed', correctedLegs)] }))).results, 'event', id), 'accepted');
  assert.deepEqual((await read()).legs, correctedLegs);

});

test('an event id owned by another profile is rejected', { skip }, async () => {
  const a = await newProfile();
  const b = await newProfile();
  const f = h.fact({});
  await ingest(a, h.batch({ items: [h.item([f])], events: [h.event(f)] }));
  await ingest(b, h.batch({ items: [h.item([f])] })).catch(() => {});
  const g = h.fact({});
  await ingest(b, h.batch({ items: [h.item([g])] }));
  const stolen = { ...h.event(g), eventId: f.factId };
  const r = await ingest(b, h.batch({ events: [stolen] }));
  assert.equal(statusOf(r.results, 'event', f.factId), 'rejected');
});

test('ledger entries: unknown event, own-to-own amount rule, updates and repeats', { skip }, async () => {
  const p = await newProfile();
  const bank = h.instrument({ kind: 'bank_account', issuerSlug: 'sbi', maskDigits: '4321' });
  const card = h.instrument({});
  const debit = h.fact({ minor: 1000000, attrs: { direction: 'debit', purpose: 'card_payment', rail: 'upi' }, instrument: h.mention({ kind: 'bank_account', issuerSlug: 'sbi', maskDigits: '4321' }) });
  const credit = h.fact({ minor: 1000000, attrs: { direction: 'credit', purpose: 'card_payment', rail: 'upi' } });
  const ev = h.event(debit, { type: 'card_bill_payment', legs: [{ factId: debit.factId, role: 'debit_leg' }, { factId: credit.factId, role: 'credit_leg' }], linkRuleId: 'LINK-CARD-BILL' });
  await ingest(p, h.batch({ items: [h.item([debit]), h.item([credit])], instruments: [bank, card], events: [ev] }));

  const orphan = h.ledger({ ...ev, eventId: h.sha('missing event') }, { fromInstrumentId: bank.instrumentId });
  assert.equal(errorsOf((await ingest(p, h.batch({ ledger: [orphan] }))).results, 'ledger', orphan.entryId)[0].code, 'ledger_event_unknown');

  const own = (minor, index) => h.ledger(ev, { index, fromInstrumentId: bank.instrumentId, to: { instrumentId: card.instrumentId }, amountMinor: minor, isSpend: false, countsAsTransaction: false });
  const wrong = own(999999, 0);
  assert.equal(errorsOf((await ingest(p, h.batch({ ledger: [wrong] }))).results, 'ledger', wrong.entryId)[0].code, 'ledger_own_amount_mismatch');
  const good = own(1000000, 1);
  assert.equal(statusOf((await ingest(p, h.batch({ ledger: [good] }))).results, 'ledger', good.entryId), 'accepted');
  assert.equal(statusOf((await ingest(p, h.batch({ ledger: [good] }))).results, 'ledger', good.entryId), 'duplicate');
  // ownUnresolved counts as own too.
  const unresolved = h.ledger(ev, { index: 2, fromInstrumentId: bank.instrumentId, to: { ownUnresolved: 'credit_card' }, amountMinor: 1, isSpend: false, countsAsTransaction: false });
  assert.equal(errorsOf((await ingest(p, h.batch({ ledger: [unresolved] }))).results, 'ledger', unresolved.entryId)[0].code, 'ledger_own_amount_mismatch');
  // A spend entry to an external party is unconstrained, and an update is accepted.
  const spend = h.ledger(ev, { index: 3, fromInstrumentId: bank.instrumentId, amountMinor: 5 });
  assert.equal(statusOf((await ingest(p, h.batch({ ledger: [spend] }))).results, 'ledger', spend.entryId), 'accepted');
  const edited = { ...spend, category: 'groceries' };
  assert.equal(statusOf((await ingest(p, h.batch({ ledger: [edited] }))).results, 'ledger', spend.entryId), 'accepted');
  const stored = (await pool.query('SELECT category_slug, to_external FROM sms_v2_ledger_entries WHERE entry_id = $1', [spend.entryId])).rows[0];
  assert.deepEqual(stored, { category_slug: 'groceries', to_external: 'SYNTHETIC SHOP' });
});

test('transactions are projected for every event type, per the Contracts table', { skip }, async () => {
  const p = await newProfile();
  const card = h.instrument({});
  const bank = h.instrument({ kind: 'bank_account', issuerSlug: 'sbi', maskDigits: '4321' });
  const categories = new Map((await pool.query("SELECT slug, id FROM spend_categories")).rows.map((r) => [r.slug, r.id]));
  const slug = [...categories.keys()][0];
  const expectKind = {
    purchase: 'spend', subscription_charge: 'spend', fee: 'spend', emi: 'spend', bill_payment: 'spend', atm_withdrawal: 'spend', p2p_out: 'spend',
    refund: 'refund', cashback: 'income', income: 'income', p2p_in: 'income', dividend: 'income', investment: 'investment',
    own_transfer: 'transfer', card_bill_payment: 'transfer', wallet_topup: 'transfer', investment_withdrawal: 'transfer',
  };
  const inflow = new Set(['refund', 'cashback', 'income', 'p2p_in', 'dividend', 'investment_withdrawal']);
  const items = []; const events = []; const ledger = []; const made = new Map();
  let n = 0;
  for (const type of [...Object.keys(expectKind), 'unknown', 'ipo_application']) {
    const f = h.fact({ sourceKey: `sms:synthetic:type:${type}`, minor: 10000 + (n += 1) });
    const legs = type === 'ipo_application' ? [{ factId: f.factId, role: 'hold_placed' }] : [{ factId: f.factId, role: 'debit_leg' }];
    const e = h.event(f, { type, legs });
    const l = inflow.has(type)
      ? h.ledger(e, { from: { external: 'SYNTHETIC SOURCE' }, to: { instrumentId: bank.instrumentId }, category: null })
      : h.ledger(e, { fromInstrumentId: card.instrumentId, category: type === 'purchase' ? slug : null, to: type === 'purchase' ? { external: 'SYNTHETIC SHOP' } : { external: 'SYNTHETIC OTHER' } });
    items.push(h.item([f])); events.push(e); ledger.push(l); made.set(type, { f, e });
  }
  const r = await ingest(p, h.batch({ items, instruments: [card, bank], events, ledger }));
  assert.ok(r.results.every((x) => x.status === 'accepted'), JSON.stringify(r.results.filter((x) => x.status !== 'accepted')));
  const rows = await txnsFor(p);
  const rowOf = new Map(rows.map((x) => [x.event_id, x]));
  for (const [type, kind] of Object.entries(expectKind)) {
    const row = rowOf.get(made.get(type).e.eventId);
    assert.ok(row, `${type} should have a row`);
    assert.equal(row.entry_kind, kind, type);
    assert.equal(row.pipeline_version, 2);
    assert.equal(row.source, 'sms');
    assert.equal(row.status, 'active');
    assert.equal(row.source_key, `sms:synthetic:type:${type}`);
    assert.equal(row.amount, made.get(type).e.amountMinor / 100);
    assert.equal(new Date(row.occurred_at).toISOString(), '2026-11-01T07:00:11.000Z');
  }
  assert.equal(rowOf.has(made.get('unknown').e.eventId), false);
  assert.equal(rowOf.has(made.get('ipo_application').e.eventId), false, 'a held IPO is not a row');
  assert.equal(rows.length, Object.keys(expectKind).length);
  const purchase = rowOf.get(made.get('purchase').e.eventId);
  assert.equal(purchase.merchant_name, 'SYNTHETIC SHOP');
  assert.equal(purchase.category_id, categories.get(slug));
  assert.equal(purchase.instrument, 'credit_card');
  assert.equal(rowOf.get(made.get('income').e.eventId).merchant_name, 'SYNTHETIC SOURCE');
  assert.equal(rowOf.get(made.get('income').e.eventId).instrument, 'upi_bank');
  // Converting the IPO later makes it an investment row.
  const ipo = made.get('ipo_application');
  const converted = { ...ipo.e, legs: [...ipo.e.legs, { factId: h.sha('conv'), role: 'hold_converted' }] };
  const convFact = h.fact({ sourceKey: 'sms:synthetic:ipo:conv', factId: h.sha('conv'), factType: 'hold', amounts: [{ role: 'held', minor: 1, unit: 'INR' }], attrs: { phase: 'converted', purpose: 'ipo_asba' }, counterparty: null });
  await ingest(p, h.batch({ items: [h.item([convFact])], events: [converted], ledger: [h.ledger(converted, { fromInstrumentId: card.instrumentId, to: { external: 'SYNTHETIC ISSUER' }, category: null, isSpend: false })] }));
  const after = (await txnsFor(p)).find((x) => x.event_id === ipo.e.eventId);
  assert.equal(after.entry_kind, 'investment');
});

test('card state is applied exactly once for a card spend and never for backfill', { skip }, async () => {
  const p = await newProfile();
  const userCard = await newCard(p);
  calls.apply.length = 0; calls.reverse.length = 0;
  const live = cardSpend({ userCardId: userCard, minor: 123456 });
  await ingest(p, live.body);
  assert.equal(calls.apply.length, 1);
  assert.equal(calls.apply[0].userCardId, userCard);
  assert.equal(calls.apply[0].amount, 1234.56);
  assert.equal(calls.apply[0].sign, 1);
  assert.equal(calls.apply[0].merchantName, 'SYNTHETIC SHOP');
  let row = (await txnsFor(p))[0];
  assert.equal(row.state_applied, true);
  assert.equal(row.is_backfill, false);
  // Re-uploads and duplicates do not apply again.
  await ingest(p, live.body);
  await ingest(p, h.batch({ ledger: [live.l] }));
  await ingest(p, h.batch({ events: [live.e] }));
  assert.equal(calls.apply.length, 1);
  assert.equal(calls.reverse.length, 0);

  // Backfill: row recorded, state untouched, and a later live touch does not apply it either.
  const old = cardSpend({ userCardId: userCard, inst: live.inst, skipInstrument: true, minor: 7000 });
  await ingest(p, old.body, { backfill: true });
  assert.equal(calls.apply.length, 1);
  row = (await txnsFor(p)).find((x) => x.event_id === old.e.eventId);
  assert.equal(row.state_applied, false);
  assert.equal(row.is_backfill, true);
  await ingest(p, h.batch({ events: [{ ...old.e, confidence: 0.5 }], ledger: [old.l] }));
  assert.equal(calls.apply.length, 1);

  // Not a credit-card spend: no state. Same for a refund onto the card.
  const bank = h.instrument({ kind: 'bank_account', issuerSlug: 'sbi', maskDigits: '4321', userCardId: userCard });
  const viaBank = cardSpend({ inst: bank, minor: 800 });
  await ingest(p, viaBank.body);
  const refund = cardSpend({ inst: live.inst, skipInstrument: true, type: 'refund', minor: 900 });
  await ingest(p, h.batch({ items: refund.body.items, events: refund.body.events, ledger: [h.ledger(refund.e, { from: { external: 'SYNTHETIC SHOP' }, to: { instrumentId: live.inst.instrumentId }, category: null })] }));
  assert.equal(calls.apply.length, 1);

  // A changed amount reverses the old effect, then applies the new one: net still one live application.
  const edited = { ...live.e, amountMinor: 200000 };
  await ingest(p, h.batch({ events: [edited], ledger: [{ ...live.l, amountMinor: 200000 }] }));
  assert.equal(calls.reverse.length, 1);
  assert.equal(calls.reverse[0].txnId, (await txnsFor(p)).find((x) => x.event_id === live.e.eventId).id);
  assert.equal(calls.apply.length, 2);
  assert.equal(calls.apply[1].amount, 2000);
  assert.equal((await txnsFor(p)).find((x) => x.event_id === live.e.eventId).state_applied, true);
});

test('a card spend whose card is archived keeps its row without card state', { skip }, async () => {
  const p = await newProfile();
  const userCard = await newCard(p);
  await pool.query('UPDATE user_cards SET is_archived = true WHERE id = $1', [userCard]);
  calls.apply.length = 0;
  const s = cardSpend({ userCardId: userCard });
  const r = await ingest(p, s.body);
  assert.ok(r.results.every((x) => x.status === 'accepted'));
  assert.equal(calls.apply.length, 0);
  assert.equal((await txnsFor(p)).length, 1);
});

test('an event that stops counting retires its row and undoes card state', { skip }, async () => {
  const p = await newProfile();
  const userCard = await newCard(p);
  calls.apply.length = 0; calls.reverse.length = 0;
  const s = cardSpend({ userCardId: userCard });
  await ingest(p, s.body);
  assert.equal(calls.apply.length, 1);
  await ingest(p, h.batch({ events: [{ ...s.e, type: 'unknown' }] }));
  const row = (await txnsFor(p))[0];
  assert.equal(row.status, 'ignored');
  assert.equal(row.state_applied, false);
  assert.equal(calls.reverse.length, 1);
});

test('an explicit user restore reactivates one projection and reapplies card state once', { skip }, async () => {
  const p=await newProfile();const userCard=await newCard(p);calls.apply.length=0;calls.reverse.length=0;
  const spend=cardSpend({userCardId:userCard});await ingest(p,spend.body);
  await ingest(p,h.batch({events:[{...spend.e,type:'unknown',status:'user_confirmed'}]}));
  assert.equal((await txnsFor(p))[0].status,'ignored');
  const restore=h.batch({events:[{...spend.e,status:'user_confirmed'}],ledger:[spend.l]});
  await ingest(p,restore);await ingest(p,restore);
  assert.equal((await txnsFor(p))[0].status,'active');assert.equal(calls.reverse.length,1);assert.equal(calls.apply.length,2);
});

test('a v1 row for the same message is adopted, not duplicated, and a shared message gets a distinct key', { skip }, async () => {
  const p = await newProfile();
  const sourceKey = `sms:synthetic:adopt:${crypto.randomUUID()}`;
  await pool.query(
    `INSERT INTO transactions(profile_id, amount_inr, occurred_at, source, source_key, merchant_name, state_applied)
     VALUES ($1, 499.00, now(), 'sms', $2, 'V1 NAME', true)`, [p, sourceKey]);
  calls.apply.length = 0;
  const s = cardSpend({ sourceKey });
  await ingest(p, s.body);
  const rows = await txnsFor(p);
  assert.equal(rows.length, 1);
  assert.equal(rows[0].event_id, s.e.eventId);
  assert.equal(rows[0].pipeline_version, 2);
  assert.equal(rows[0].merchant_name, 'V1 NAME');
  assert.equal(calls.apply.length, 0);
  // Two events anchored on one message: the second gets a suffixed source key.
  const shared = `sms:synthetic:shared:${crypto.randomUUID()}`;
  const f1 = h.fact({ sourceKey: shared, idx: 0 });
  const f2 = h.fact({ sourceKey: shared, idx: 1, minor: 1200 });
  const inst = h.instrument({ maskDigits: '9999' });
  const events = [h.event(f1), h.event(f2)];
  await ingest(p, h.batch({ items: [h.item([f1, f2])], instruments: [inst], events, ledger: events.map((e) => h.ledger(e, { fromInstrumentId: inst.instrumentId })) }));
  const keys = (await txnsFor(p)).filter((x) => x.source_key.startsWith(shared)).map((x) => x.source_key).sort();
  assert.equal(keys.length, 2);
  assert.equal(keys[0], shared);
  assert.match(keys[1], new RegExp(`^${shared}#[0-9a-f]{12}$`));
});

test('the afterEventsStored hook runs inside the batch with the stored events', { skip }, async () => {
  const p = await newProfile();
  const seen = [];
  const s = cardSpend();
  await withUserClient(p, (client) => storage.ingestBatch(client, p, s.body, {
    deps, hooks: { afterEventsStored: async (c, profile, events) => { seen.push([profile, events.map((e) => e.eventId), typeof c.query]); } },
  }));
  assert.deepEqual(seen, [[p, [s.e.eventId], 'function']]);
  await withUserClient(p, (client) => storage.ingestBatch(client, p, s.body, {
    deps, hooks: { afterEventsStored: async () => { seen.push('again'); } },
  }));
  assert.equal(seen.length, 1, 'a duplicate batch stores nothing, so the hook is not called');
});

// ---------- sync ----------

test('sync pages at 1,000 rows per entity, resumes from the cursor and sees later changes', { skip }, async () => {
  const p = await newProfile();
  await pool.query(
    `INSERT INTO sms_v2_events (event_id, profile_id, type, status, legs, confidence, occurred_at, amount_minor)
     SELECT encode(sha256(('sync-' || g)::bytea), 'hex'), $1, 'purchase', 'complete',
            jsonb_build_array(jsonb_build_object('factId', encode(sha256(('sync-' || g)::bytea), 'hex'), 'role', 'debit_leg')),
            0.9, now(), 100 + g
       FROM generate_series(1, 1500) g`, [p]);
  const read = (cursor) => withUserClient(p, (client) => storage.readChanges(client, p, storage.decodeCursor(cursor) || {}));
  const first = await read(undefined);
  assert.equal(first.events.length, 1000);
  assert.equal(first.hasMore, true);
  assert.equal(first.instruments.length, 0);
  const second = await read(first.cursor);
  assert.equal(second.events.length, 500);
  assert.equal(second.hasMore, false);
  const all = [...first.events, ...second.events].map((e) => e.eventId);
  assert.equal(new Set(all).size, 1500, 'no row repeated or skipped across pages');
  const drained = await read(second.cursor);
  assert.equal(drained.events.length, 0);
  assert.equal(drained.cursor, second.cursor, 'no change, same cursor');
  // A change after the cursor shows up exactly once; an unchanged one does not.
  const s = cardSpend();
  await ingest(p, s.body);
  const next = await read(drained.cursor);
  assert.deepEqual(next.events.map((e) => e.eventId), [s.e.eventId]);
  assert.deepEqual(next.instruments.map((i) => i.instrumentId), [s.inst.instrumentId]);
  assert.deepEqual(next.ledger.map((l) => l.entryId), [s.l.entryId]);
  assert.deepEqual(await read(next.cursor).then((x) => x.events.length + x.instruments.length + x.ledger.length), 0);
  await ingest(p, h.batch({ events: [{ ...s.e, status: 'user_confirmed' }] }));
  const changed = await read(next.cursor);
  assert.deepEqual(changed.events.map((e) => e.status), ['user_confirmed']);
});

test('sync returns contract-shaped documents and never another profile\'s rows', { skip }, async () => {
  const a = await newProfile();
  const b = await newProfile();
  const s = cardSpend();
  await ingest(a, s.body);
  const mine = await withUserClient(a, (client) => storage.readChanges(client, a, {}));
  assert.deepEqual(mine.instruments, [s.inst]);
  assert.deepEqual(mine.events, [s.e]);
  assert.deepEqual(mine.ledger, [s.l]);
  assert.equal(mine.facts[0].factId, s.f.factId);
  assert.deepEqual(mine.facts[0].evidence, []);
  assert.equal(mine.facts[0].instrument.raw, null);
  assert.equal('senderBrand' in mine.facts[0], false);
  assert.equal('bodyHash' in mine.facts[0], false);
  assert.match(mine.updatedAt.events[s.e.eventId], /^\d{4}-.*Z$/);
  const body = { cursor: mine.cursor, instruments: mine.instruments, events: mine.events, ledger: mine.ledger, facts: mine.facts, updatedAt: mine.updatedAt, aiResults: [], corrections: [], latestBundleVersion: 0 };
  assert.deepEqual(contracts.validateResponse('sync', body), { ok: true, errors: [] });
  const theirs = await withUserClient(b, (client) => storage.readChanges(client, b, {}));
  assert.deepEqual([theirs.instruments.length, theirs.events.length, theirs.ledger.length, theirs.facts.length], [0, 0, 0, 0]);
});

test('instrument-only rejection retires ledger and card effects, and stale uploads cannot restore them', { skip }, async () => {
  const p = await newProfile();
  const card = await newCard(p);
  const s = cardSpend({ userCardId: card });
  await ingest(p, s.body);
  const initial = await withUserClient(p, (client) => storage.readChanges(client, p, {}));
  assert.equal((await txnsFor(p))[0].state_applied, true);
  const reversals = calls.reverse.length;
  const rejected = { ...s.inst, status: 'rejected' };
  await ingest(p, h.batch({ instruments: [rejected] }));
  const after = (await txnsFor(p))[0];
  assert.equal(after.status, 'ignored');
  assert.equal(after.state_applied, false);
  assert.equal(calls.reverse.length, reversals + 1);
  const remaining = () => pool.query('SELECT count(*)::int AS n FROM sms_v2_ledger_entries WHERE profile_id = $1', [p]);
  assert.equal((await remaining()).rows[0].n, 0);
  const changed = await withUserClient(p, (client) => storage.readChanges(client, p, storage.decodeCursor(initial.cursor)));
  assert.equal(changed.instruments[0].status, 'rejected');
  assert.equal(changed.events[0].eventId, s.e.eventId, 'unchanged event is emitted to retire client ledger');
  await ingest(p, h.batch({ events: [s.e] }));
  await ingest(p, s.body); // stale detected instrument, original facts/event/ledger
  assert.equal((await remaining()).rows[0].n, 0);
  assert.equal((await txnsFor(p))[0].status, 'ignored');
  assert.equal(calls.reverse.length, reversals + 1, 'card state is reversed only once');
  assert.equal((await pool.query('SELECT status FROM sms_v2_instruments WHERE profile_id = $1', [p])).rows[0].status, 'rejected');
  const other = await newProfile();
  const wrongOwner = await ingest(other, h.batch({ instruments: [{ ...rejected, userCardId: null }] }));
  assert.equal(wrongOwner.results[0].status, 'rejected');
  assert.equal((await txnsFor(p))[0].status, 'ignored');
});

// ---------- HTTP end to end ----------

test('POST /sms/v2/facts:batch and GET /sms/v2/sync over HTTP with the real wiring', { skip }, async () => {
  const express = require('express');
  const { registerSmsV2 } = require('../../src/sms_v2');
  const a = await newProfile();
  const b = await newProfile();
  const state = { flag: true };
  const app = express();
  registerSmsV2(app, {
    requireAuth: (req, res, next) => { req.userId = req.headers['x-user']; return req.userId ? next() : res.status(401).json({ error: 'unauthorized' }); },
    requireAdmin: (req, res) => res.status(403).json({ error: 'Admin access required' }),
    withUserClient,
    readFlag: async () => (state.flag ? { key: 'sms_pipeline_v2_enabled', is_enabled: true, rollout_percent: 100 } : null),
    flagCacheMs: 0,
    signer: null,
    ...deps,
  });
  const server = await new Promise((resolve) => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const s = cardSpend();
    const post = (body, user = a, q = '') => fetch(`${base}/sms/v2/facts:batch${q}`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'content-encoding': 'gzip', 'x-user': user }, body: zlib.gzipSync(Buffer.from(JSON.stringify(body))),
    });
    const res = await post(s.body);
    assert.equal(res.status, 200);
    const json = await res.json();
    assert.deepEqual(contracts.validateResponse('facts_batch', json), { ok: true, errors: [] });
    assert.deepEqual(json.results.map((r) => r.status), ['accepted', 'accepted', 'accepted', 'accepted']);
    const clash = h.instrument({});
    const rejected = await (await post(h.batch({ instruments: [clash] }))).json();
    assert.deepEqual(contracts.validateResponse('facts_batch', rejected), { ok: true, errors: [] });
    assert.equal(rejected.results[0].errors[0].code, 'instrument_key_conflict');

    const sync = await fetch(`${base}/sms/v2/sync`, { headers: { 'x-user': a } });
    assert.equal(sync.status, 200);
    assert.equal(sync.headers.get('x-sms-sync-has-more'), '0');
    const synced = await sync.json();
    assert.deepEqual(contracts.validateResponse('sync', synced), { ok: true, errors: [] });
    assert.equal(synced.events.length, 1);
    assert.ok(Number.isInteger(synced.latestBundleVersion) && synced.latestBundleVersion >= 0,
      'the scratch database may already contain a published development bundle');
    const again = await (await fetch(`${base}/sms/v2/sync?cursor=${encodeURIComponent(synced.cursor)}`, { headers: { 'x-user': a } })).json();
    assert.equal(again.events.length + again.instruments.length + again.ledger.length, 0);
    const refresh = await fetch(`${base}/sms/v2/categories:batch`, {
      method: 'POST', headers: { 'content-type': 'application/json', 'content-encoding': 'gzip', 'x-user': a },
      body: zlib.gzipSync(Buffer.from(JSON.stringify(h.batch({ ledger: [{ ...s.l, category: 'groceries', categorySource: 'shared' }] })))),
    });
    assert.equal(refresh.status, 200);
    const refreshed = await refresh.json();
    assert.deepEqual(contracts.validateResponse('facts_batch', refreshed), { ok: true, errors: [] });
    assert.equal(refreshed.results[0].status, 'accepted');
    const categoryPage = await (await fetch(`${base}/sms/v2/sync?cursor=${encodeURIComponent(synced.cursor)}`, { headers: { 'x-user': a } })).json();
    assert.equal(categoryPage.ledger.length, 1);
    assert.equal(categoryPage.ledger[0].category, 'groceries');
    assert.equal((await txnsFor(a)).length, 1);
    assert.equal((await txnsFor(a))[0].amount, s.l.amountMinor / 100);
    const other = await (await fetch(`${base}/sms/v2/sync`, { headers: { 'x-user': b } })).json();
    assert.equal(other.events.length, 0);

    // Backfill flag over HTTP: the row exists, no card state.
    const userCard = await newCard(b);
    calls.apply.length = 0;
    const old = cardSpend({ userCardId: userCard });
    assert.equal((await post(old.body, b, '?backfill=true')).status, 200);
    assert.equal(calls.apply.length, 0);

    // Exactly 500 items is fine.
    const items = Array.from({ length: 500 }, () => h.item([h.fact({})]));
    const big = await post(h.batch({ items }));
    assert.equal(big.status, 200);
    assert.equal((await big.json()).results.length, 500);

    state.flag = false;
    assert.equal((await post(s.body)).status, 404);
    assert.equal((await fetch(`${base}/sms/v2/sync`, { headers: { 'x-user': a } })).status, 404);
  } finally { server.closeAllConnections(); server.close(); }
});

test('a UPI movement stores its payment method and the transaction route can return it', { skip }, async () => {
  const profile = await newProfile();
  const inst = h.instrument({ kind: 'bank_account', userCardId: null });
  const f = h.fact({ rail: 'upi', minor: 25000, instrument: h.mention({ kind: 'bank_account', maskDigits: '1234', maskLength: 4 }) });
  const e = h.event(f, { type: 'purchase' });
  const l = h.ledger(e, { fromInstrumentId: inst.instrumentId });
  await ingest(profile, h.batch({ items: [h.item([f])], instruments: [inst], events: [e], ledger: [l] }));
  const [row] = await txnsFor(profile);
  assert.equal(row.payment_method, 'upi');
  assert.equal(row.rail, 'upi_qr');

  // A card payment has no payment method.
  const card = cardSpend();
  await ingest(profile, card.body);
  const rows = await txnsFor(profile);
  assert.equal(rows.filter((r) => r.payment_method === 'upi').length, 1);
  assert.equal(rows.filter((r) => r.payment_method === null).length, 1);
});
