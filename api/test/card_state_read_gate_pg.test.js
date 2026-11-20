'use strict';
// The wallet read skips a card's cap/milestone rebuild only when nothing it reads or writes changed since that card
// was last rebuilt. Every input is checked here against a real Postgres: a changed fingerprint must force the rebuild
// (fresh data), an unchanged one must allow the skip (no wasted work).
//   SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/scratch node --test api/test/card_state_read_gate_pg.test.js
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { cardFingerprints, creditFingerprint, createReadGate } = require('../src/card_state_read_gate');

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const skip = url ? false : 'SMS_V2_TEST_DATABASE_URL not set';
const CREDIT = 'issuer credit';
let pool;
const made = { profiles: [], issuers: [], products: [] };

test.before(async () => {
  if (skip) return;
  const { Pool } = require('pg');
  pool = new Pool({ connectionString: url });
});
test.after(async () => {
  if (skip || !pool) return;
  try {
    await pool.query('DELETE FROM profiles WHERE id = ANY($1::uuid[])', [made.profiles]);
    await pool.query('DELETE FROM card_products WHERE id = ANY($1::uuid[])', [made.products]);
    await pool.query('DELETE FROM issuers WHERE id = ANY($1::uuid[])', [made.issuers]);
  } finally { await pool.end(); }
});

async function wallet() {
  const profile = crypto.randomUUID();
  await pool.query('INSERT INTO profiles(id) VALUES ($1)', [profile]);
  made.profiles.push(profile);
  const slug = `gate-${crypto.randomUUID().slice(0, 8)}`;
  const issuer = (await pool.query("INSERT INTO issuers(slug, name) VALUES ($1, 'Gate issuer') RETURNING id", [slug])).rows[0].id;
  const product = (await pool.query("INSERT INTO card_products(issuer_id, slug, name, network) VALUES ($1, $2, 'Gate card', 'visa') RETURNING id", [issuer, slug])).rows[0].id;
  made.issuers.push(issuer); made.products.push(product);
  const cards = [];
  for (let i = 0; i < 2; i++) {
    cards.push((await pool.query('INSERT INTO user_cards(profile_id, card_product_id, last4) VALUES ($1, $2, $3) RETURNING id', [profile, product, `${i + 1}`.repeat(4)])).rows[0].id);
  }
  await pool.query(
    `INSERT INTO transactions(profile_id, user_card_id, amount_inr, occurred_at, source, instrument, entry_kind)
     VALUES ($1, $2, 500, now(), 'manual', 'credit_card', 'spend')`, [profile, cards[0]]);
  return { profile, product, cards };
}

const fps = (profile) => cardFingerprints(pool, profile);

test('an unchanged card may skip; each input change forces that card (and only that card) to rebuild', { skip }, async () => {
  const { profile, product, cards } = await wallet();
  const gate = createReadGate();
  const first = await fps(profile);
  assert.deepEqual(new Set(gate.staleCards(profile, first)), new Set(cards), 'nothing remembered: every card rebuilds');
  gate.commit(profile, { cards: first });
  assert.deepEqual(gate.staleCards(profile, await fps(profile)), [], 'nothing changed: nothing rebuilds');

  const changes = [
    ['a new transaction on the card', () => pool.query(
      `INSERT INTO transactions(profile_id, user_card_id, amount_inr, occurred_at, source, instrument, entry_kind)
       VALUES ($1, $2, 120, now(), 'manual', 'credit_card', 'spend')`, [profile, cards[0]])],
    ['an edited transaction', () => pool.query("UPDATE transactions SET amount_inr = amount_inr + 1 WHERE user_card_id = $1", [cards[0]])],
    ['a transaction moved off the card', () => pool.query('UPDATE transactions SET user_card_id = $2 WHERE user_card_id = $1', [cards[0], cards[1]])],
    ['a deleted transaction', () => pool.query('DELETE FROM transactions WHERE user_card_id = $1', [cards[1]])],
    ['the card row (statement day)', () => pool.query('UPDATE user_cards SET statement_day = 12 WHERE id = $1', [cards[0]])],
    ['the product rules version', () => pool.query('UPDATE card_products SET data_version = data_version + 1 WHERE id = $1', [product])],
  ];
  for (const [what, change] of changes) {
    const before = await fps(profile);
    gate.commit(profile, { cards: before });
    await change();
    const after = await fps(profile);
    const stale = gate.staleCards(profile, after);
    assert.ok(stale.length > 0, `${what} forces a rebuild`);
    gate.commit(profile, { cards: after });
  }
});

test('stored results changed by any other writer force a rebuild too', { skip }, async () => {
  const { profile, product, cards } = await wallet();
  const gate = createReadGate();
  const cap = (await pool.query(
    "INSERT INTO cap_rules(card_product_id, period, cap_value, measure, label) VALUES ($1, 'calendar_month', 1000, 'reward_value', 'Gate cap') RETURNING id", [product])).rows[0].id;
  gate.commit(profile, { cards: await fps(profile) });
  await pool.query(
    `INSERT INTO cap_states(profile_id, user_card_id, cap_rule_id, period_start, period_end, consumed, cap_value_snapshot)
     VALUES ($1, $2, $3, date_trunc('month', now())::date, (date_trunc('month', now()) + interval '1 month - 1 day')::date, 10, 1000)`,
    [profile, cards[0], cap]);
  assert.deepEqual(gate.staleCards(profile, await fps(profile)), [cards[0]]);
  gate.commit(profile, { cards: await fps(profile) });
  await pool.query('UPDATE cap_states SET consumed = 999 WHERE user_card_id = $1', [cards[0]]);
  assert.deepEqual(gate.staleCards(profile, await fps(profile)), [cards[0]], 'a hand-edited cap row is repaired');
});

test('the day is an input: a remembered card rebuilds on a new day', { skip }, async () => {
  const { profile } = await wallet();
  const gate = createReadGate();
  const today = await fps(profile);
  // Rewrite the remembered fingerprints as if they were taken yesterday.
  const yesterday = new Map([...today].map(([id, fp]) => [id, fp.replace(/\d{4}-\d{2}-\d{2}\|[^|]*$/, '2000-01-01|2000-01-01')]));
  gate.commit(profile, { cards: yesterday });
  assert.equal(gate.staleCards(profile, today).length, today.size);
});

test('the credit sweep may skip only while facts, account links and credit rows are unchanged', { skip }, async () => {
  const { profile, cards } = await wallet();
  const gate = createReadGate();
  const fp0 = await creditFingerprint(pool, profile, CREDIT);
  assert.equal(gate.creditsStale(profile, fp0), true, 'first read sweeps');
  gate.commit(profile, { credits: fp0 });
  assert.equal(gate.creditsStale(profile, await creditFingerprint(pool, profile, CREDIT)), false);
  const instrument = crypto.randomUUID();
  await pool.query(
    `INSERT INTO sms_v2_instruments(instrument_id, profile_id, kind, issuer_slug, mask_digits, display_name, status, first_seen_at, last_seen_at)
     VALUES ($1, $2, 'credit_card', 'hdfc', '5678', 'HDFC 5678', 'detected', now(), now())`, [instrument, profile]);
  const fp1 = await creditFingerprint(pool, profile, CREDIT);
  assert.equal(gate.creditsStale(profile, fp1), true, 'a new account');
  gate.commit(profile, { credits: fp1 });
  await pool.query('UPDATE sms_v2_instruments SET user_card_id = $2 WHERE instrument_id = $1', [instrument, cards[0]]);
  const fp2 = await creditFingerprint(pool, profile, CREDIT);
  assert.equal(gate.creditsStale(profile, fp2), true, 'an account linked to a card');
  gate.commit(profile, { credits: fp2 });
  await pool.query(
    `INSERT INTO points_ledger(profile_id, user_card_id, delta_points, reason, state, client_mutation_id)
     VALUES ($1, $2, 100, $3, 'confirmed', $4)`, [profile, cards[0], CREDIT, crypto.randomUUID()]);
  const fp3 = await creditFingerprint(pool, profile, CREDIT);
  assert.equal(gate.creditsStale(profile, fp3), true, 'a credit row added');
  gate.commit(profile, { credits: fp3 });
  await pool.query('DELETE FROM points_ledger WHERE profile_id = $1 AND reason = $2', [profile, CREDIT]);
  assert.equal(gate.creditsStale(profile, await creditFingerprint(pool, profile, CREDIT)), true, 'a credit row removed is put back');
});

test('marks are bounded and per account', () => {
  const gate = createReadGate({ maxEntries: 3 });
  gate.commit('p1', { cards: new Map([['a', '1'], ['b', '1'], ['c', '1'], ['d', '1']]) });
  assert.equal(gate.size, 3);
  assert.deepEqual(gate.staleCards('p1', new Map([['a', '1']])), ['a'], 'the oldest mark was dropped: rebuild');
  assert.deepEqual(gate.staleCards('p2', new Map([['d', '1']])), ['d'], 'another account never shares marks');
  gate.forget('p1');
  assert.equal(gate.size, 0);
});
