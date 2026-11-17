'use strict';
// A card row's wallet card (and so its reward) is decided when the server builds
// the row. When a wallet card is linked to an instrument LATER (the card was
// added after its messages were read, or was removed and added again), the rows
// already built for that instrument must follow at once. They used to stay
// "credit card, no wallet card" with no reward for ever, because linking only
// updated the instrument row, and re-projection only covered events in the same
// upload. Owner, 18 Nov 2026: 262 spends on three newly added cards.
//
// Real Postgres with the product migrations; skipped unless SMS_V2_TEST_DATABASE_URL
// is set (a disposable local database only; the test removes its own rows):
//   SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/scratch node --test api/test/sms_v2/link_heal_pg.test.js
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';
const h = require('./helpers');

let pool;
let storage;
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
  const slug = `heal-${crypto.randomUUID().slice(0, 8)}`;
  const issuer = (await pool.query("INSERT INTO issuers(slug, name) VALUES ($1, 'Heal test issuer') RETURNING id", [slug])).rows[0].id;
  const product = (await pool.query("INSERT INTO card_products(issuer_id, slug, name, network) VALUES ($1, $2, 'Heal test card', 'visa') RETURNING id", [issuer, slug])).rows[0].id;
  const card = (await pool.query('INSERT INTO user_cards(profile_id, card_product_id) VALUES ($1, $2) RETURNING id', [profileId, product])).rows[0].id;
  created.issuers.push(issuer); created.products.push(product); created.cards.push(card);
  return card;
}

const ingest = (profileId, body) => withUserClient(profileId, (client) => storage.ingestBatch(client, profileId, body, { backfill: false, categoryOnly: false, deps, hooks }));
const txns = async (profileId) => (await pool.query(
  `SELECT id, event_id, user_card_id, state_applied, instrument::text AS instrument FROM transactions WHERE profile_id = $1 AND status = 'active'`, [profileId])).rows;

test.before(async () => {
  if (skip) return;
  const { Pool } = require('pg');
  pool = new Pool({ connectionString: url });
  storage = require('../../src/sms_v2/storage');
});
test.after(async () => {
  if (skip || !pool) return;
  try {
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [created.profiles]);
    await pool.query('DELETE FROM user_cards WHERE id = ANY($1::uuid[])', [created.cards]);
    await pool.query('DELETE FROM card_products WHERE id = ANY($1::uuid[])', [created.products]);
    await pool.query('DELETE FROM issuers WHERE id = ANY($1::uuid[])', [created.issuers]);
  } finally { await pool.end(); }
});

/** [n] spends on [inst], as the phone would upload them. */
function spends(inst, n, tag) {
  const items = [], events = [], ledger = [];
  for (let i = 0; i < n; i++) {
    const f = h.fact({
      sourceKey: `sms:synthetic:${tag}:${i}`, minor: 10000 + i,
      instrument: h.mention({ issuerSlug: inst.issuerSlug, maskDigits: inst.maskDigits }),
    });
    const e = h.event(f);
    items.push(h.item([f])); events.push(e);
    ledger.push(h.ledger(e, { fromInstrumentId: inst.instrumentId }));
  }
  return { items, events, ledger };
}
const reset = () => { calls.apply.length = 0; calls.reverse.length = 0; };

test('cards linked after their messages were stored: every row follows in the same upload, past the per-upload repair size', { skip }, async () => {
  const p = await newProfile();
  const big = h.instrument({ maskDigits: '8127' });
  const small = h.instrument({ maskDigits: '0680' });
  const a = spends(big, 230, 'big'), b = spends(small, 30, 'small');
  await ingest(p, h.batch({
    items: [...a.items, ...b.items], instruments: [big, small],
    events: [...a.events, ...b.events], ledger: [...a.ledger, ...b.ledger],
  }));
  let rows = await txns(p);
  assert.equal(rows.length, 260);
  assert.ok(rows.every((r) => r.user_card_id === null && r.instrument === 'credit_card'), 'built before any wallet card: unlinked');

  // The person adds both cards to the wallet; the phone sends only the links.
  const cardBig = await newCard(p), cardSmall = await newCard(p);
  reset();
  await ingest(p, h.batch({ instruments: [{ ...big, userCardId: cardBig }, { ...small, userCardId: cardSmall }] }));

  rows = await txns(p);
  const byEvent = new Map(rows.map((r) => [r.event_id, r]));
  assert.ok(a.events.every((e) => byEvent.get(e.eventId).user_card_id === cardBig), 'all 230 rows are on the first card');
  assert.ok(b.events.every((e) => byEvent.get(e.eventId).user_card_id === cardSmall), 'all 30 rows are on the second card');
  assert.ok(rows.every((r) => r.state_applied === true), 'every row had its reward applied');
  assert.equal(calls.apply.length, 260, 'each spend priced once');
});

test('a card removed and added again: its rows move to the new card and the old card is undone', { skip }, async () => {
  const p = await newProfile();
  const oldCard = await newCard(p);
  const inst = h.instrument({ maskDigits: '1260', userCardId: oldCard });
  const s = spends(inst, 12, 'relink');
  await ingest(p, h.batch({ items: s.items, instruments: [inst], events: s.events, ledger: s.ledger }));
  assert.ok((await txns(p)).every((r) => r.user_card_id === oldCard));

  const newer = await newCard(p);
  reset();
  await ingest(p, h.batch({ instruments: [{ ...inst, userCardId: newer }] }));

  const rows = await txns(p);
  assert.ok(rows.every((r) => r.user_card_id === newer), 'every row is on the new card');
  assert.equal(calls.apply.length, 12, 'priced on the new card');
  assert.ok(calls.apply.every((c) => c.cardId === newer));
  assert.equal(calls.reverse.length, 12, 'taken back from the old card');
});

test('sending the same link again, or a link for another card, changes nothing', { skip }, async () => {
  const p = await newProfile();
  const card = await newCard(p);
  const inst = h.instrument({ maskDigits: '4444', userCardId: card });
  const other = h.instrument({ maskDigits: '5555' });
  const s = spends(inst, 5, 'same'), o = spends(other, 5, 'other');
  await ingest(p, h.batch({ items: [...s.items, ...o.items], instruments: [inst, other], events: [...s.events, ...o.events], ledger: [...s.ledger, ...o.ledger] }));
  reset();
  const again = await ingest(p, h.batch({ instruments: [inst] }));
  assert.deepEqual(again.results.map((r) => r.status), ['duplicate']);
  assert.equal(calls.apply.length, 0);
  assert.equal(calls.reverse.length, 0);
  const rows = await txns(p);
  const otherRows = rows.filter((r) => o.events.some((e) => e.eventId === r.event_id));
  assert.ok(otherRows.every((r) => r.user_card_id === null), 'the unlinked card keeps its rows unlinked');
});

test('a link that arrives with its own messages in the same upload is applied once', { skip }, async () => {
  const p = await newProfile();
  const card = await newCard(p);
  const inst = h.instrument({ maskDigits: '6666', userCardId: card });
  const s = spends(inst, 4, 'together');
  reset();
  await ingest(p, h.batch({ items: s.items, instruments: [inst], events: s.events, ledger: s.ledger }));
  assert.equal(calls.apply.length, 4, 'not priced a second time by the link');
  assert.ok((await txns(p)).every((r) => r.user_card_id === card && r.state_applied === true));
});
