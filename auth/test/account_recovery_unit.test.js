const test = require('node:test');
const assert = require('node:assert/strict');
const { parseFact, signUpMonthIst, deviceHash } = require('../src/services/accountRecovery');
const { cardFact } = require('../src/services/productApiClient');

test('four digits are always a card, never a year', () => {
  assert.deepEqual(parseFact('4821'), { kind: 'card', last4: '4821' });
  assert.deepEqual(parseFact(' 2026 '), { kind: 'card', last4: '2026' });
});

test('a month is accepted in both orders and with either separator', () => {
  for (const text of ['2026-11', '2026/11', '11/2026', '11-2026', '2026-1', '1/2026']) {
    assert.equal(parseFact(text).kind, 'month', text);
  }
  assert.deepEqual(parseFact('2026-11'), { kind: 'month', year: 2026, month: 11 });
  assert.deepEqual(parseFact('1/2026'), { kind: 'month', year: 2026, month: 1 });
});

test('anything else is no fact at all', () => {
  for (const text of ['', ' ', 'abc', '482', '48211', '2026-13', '2026-00', '2019-05', '2101-01', '48 21', null, undefined, 4821, {}]) {
    assert.equal(parseFact(text), null, String(text));
  }
});

test('the sign-up month is read in India time, so a late-evening UTC sign-up is next month', () => {
  assert.deepEqual(signUpMonthIst('2026-11-30T20:00:00Z'), { year: 2026, month: 12 });
  assert.deepEqual(signUpMonthIst('2026-11-30T18:29:59Z'), { year: 2026, month: 11 });
  assert.deepEqual(signUpMonthIst('2026-12-31T19:00:00Z'), { year: 2027, month: 1 });
  assert.deepEqual(signUpMonthIst(new Date('2026-06-15T00:00:00Z')), { year: 2026, month: 6 });
});

test('the device is only ever stored as a hash, and a different device is a different hash', () => {
  assert.match(deviceHash('device-1'), /^[0-9a-f]{64}$/);
  assert.notEqual(deviceHash('device-1'), deviceHash('device-2'));
  assert.equal(deviceHash('device-1').includes('device-1'), false);
});

const SECRET = 'c'.repeat(40);
const reply = (status, body) => async (url, init) => ({ ok: status < 300, status, json: async () => body, url, init });

test('the card question carries the secret and the user and returns only two booleans', async () => {
  let sent;
  const fetchImpl = async (url, init) => { sent = { url, init }; return { ok: true, json: async () => ({ has_cards: true, matched: false, card_number: '4111111111114821' }) }; };
  const result = await cardFact({ userId: 'u1', last4: '4821' }, { fetchImpl, base: 'http://api:4000', secret: SECRET });
  assert.deepEqual(result, { has_cards: true, matched: false });
  assert.equal(sent.url, 'http://api:4000/internal/recovery/card-fact');
  assert.equal(sent.init.headers['x-auth-service-secret'], SECRET);
  assert.deepEqual(JSON.parse(sent.init.body), { user_id: 'u1', last4: '4821' });
});

test('the card question fails closed: not configured, a short secret, a non-OK reply, a thrown error', async () => {
  await assert.rejects(cardFact({ userId: 'u' }, { fetchImpl: reply(200, {}), base: null, secret: SECRET }), /card_fact_unconfigured/);
  await assert.rejects(cardFact({ userId: 'u' }, { fetchImpl: reply(200, {}), base: 'http://api', secret: 'short' }), /card_fact_unconfigured/);
  await assert.rejects(cardFact({ userId: 'u' }, { fetchImpl: reply(500, {}), base: 'http://api', secret: SECRET }), /card_fact_unavailable/);
  await assert.rejects(cardFact({ userId: 'u' }, { fetchImpl: async () => { throw new Error('refused'); }, base: 'http://api', secret: SECRET }), /refused/);
  assert.deepEqual(await cardFact({ userId: 'u' }, { fetchImpl: reply(200, { has_cards: 'yes', matched: 1 }), base: 'http://api', secret: SECRET }), { has_cards: false, matched: false });
});
