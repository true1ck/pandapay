'use strict';
// The server builds Activity rows from ledger entries. An entry can name an
// instrument id the server never stored (a reinstalled phone's ids clash with
// the ones it uploaded before). The row's payment method is then resolved
// through the event's own facts instead of becoming "not matched".
const test = require('node:test');
const assert = require('node:assert/strict');
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const { resolveUnknownInstruments } = require('../../src/sms_v2/storage');

const KNOWN = '11111111-1111-4111-8111-111111111111';
const OTHER = '22222222-2222-4222-8222-222222222222';
const PHONE = '99999999-9999-4999-8999-999999999999';

function fakeClient({ instruments, facts }) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push(sql);
      if (sql.includes('FROM sms_v2_instruments')) return { rows: instruments };
      if (sql.includes('FROM sms_v2_facts')) {
        return { rows: facts.filter((f) => params[1].includes(f.fact_id)) };
      }
      throw new Error(`unexpected query ${sql}`);
    },
  };
}

const card = { id: KNOWN, kind: 'credit_card', issuer_slug: 'sbi', mask_digits: '2837', user_card_id: 'wallet-1', status: 'detected' };
const bank = { id: OTHER, kind: 'bank_account', issuer_slug: 'icici', mask_digits: '4911', user_card_id: null, status: 'detected' };

test('a spend whose ledger names an unknown id takes the instrument its fact is linked to', async () => {
  const events = new Map([['e1', { eventId: 'e1', type: 'purchase', legs: [{ factId: 'f1', role: 'original' }] }]]);
  const ledgerOf = new Map([['e1', [{ entryId: 'l1', unit: 'INR', fromInstrumentId: PHONE, toExternal: 'SHOP' }]]]);
  const instruments = new Map();
  await resolveUnknownInstruments(fakeClient({
    instruments: [card, bank],
    facts: [{ fact_id: 'f1', instrument_id: KNOWN, mention: { kind: 'credit_card', issuerSlug: 'sbi', maskDigits: '2837' } }],
  }), 'p', { events, ledgerOf, instruments });
  assert.equal(ledgerOf.get('e1')[0].fromInstrumentId, KNOWN);
  assert.equal(instruments.get(KNOWN).userCardId, 'wallet-1');
});

test('without a stored link the fact\'s mention is matched by key', async () => {
  const events = new Map([['e1', { eventId: 'e1', type: 'purchase', legs: [{ factId: 'f1', role: 'original' }] }]]);
  const ledgerOf = new Map([['e1', [{ entryId: 'l1', unit: 'INR', fromInstrumentId: PHONE, toExternal: 'SHOP' }]]]);
  const instruments = new Map();
  await resolveUnknownInstruments(fakeClient({
    instruments: [card],
    facts: [{ fact_id: 'f1', instrument_id: PHONE, mention: { kind: 'credit_card', issuerSlug: 'sbi', maskDigits: '2837' } }],
  }), 'p', { events, ledgerOf, instruments });
  assert.equal(ledgerOf.get('e1')[0].fromInstrumentId, KNOWN);
});

test('money in resolves the receiving side, and a corrected money leg wins over the original', async () => {
  const events = new Map([['e1', { eventId: 'e1', type: 'income', legs: [{ factId: 'f0', role: 'original' }, { factId: 'f1', role: 'credit_leg' }] }]]);
  const ledgerOf = new Map([['e1', [{ entryId: 'l1', unit: 'INR', fromExternal: 'EMPLOYER', toInstrumentId: PHONE }]]]);
  const instruments = new Map();
  await resolveUnknownInstruments(fakeClient({
    instruments: [card, bank],
    facts: [
      { fact_id: 'f0', instrument_id: KNOWN, mention: null },
      { fact_id: 'f1', instrument_id: OTHER, mention: null },
    ],
  }), 'p', { events, ledgerOf, instruments });
  assert.equal(ledgerOf.get('e1')[0].toInstrumentId, OTHER);
  assert.equal(ledgerOf.get('e1')[0].fromExternal, 'EMPLOYER');
});

test('entries whose instruments are all known are left alone and nothing is queried', async () => {
  const events = new Map([['e1', { eventId: 'e1', type: 'purchase', legs: [{ factId: 'f1', role: 'original' }] }]]);
  const entry = { entryId: 'l1', unit: 'INR', fromInstrumentId: KNOWN, toExternal: 'SHOP' };
  const ledgerOf = new Map([['e1', [entry]]]);
  const instruments = new Map([[KNOWN, { kind: 'credit_card', userCardId: null, status: 'detected' }]]);
  const client = fakeClient({ instruments: [card], facts: [] });
  await resolveUnknownInstruments(client, 'p', { events, ledgerOf, instruments });
  assert.equal(ledgerOf.get('e1')[0], entry);
  assert.equal(client.calls.length, 0);
});

test('nothing to resolve from leaves the entry as it was', async () => {
  const events = new Map([['e1', { eventId: 'e1', type: 'purchase', legs: [{ factId: 'f1', role: 'original' }] }]]);
  const ledgerOf = new Map([['e1', [{ entryId: 'l1', unit: 'INR', fromInstrumentId: PHONE, toExternal: 'SHOP' }]]]);
  await resolveUnknownInstruments(fakeClient({
    instruments: [bank],
    facts: [{ fact_id: 'f1', instrument_id: null, mention: { kind: 'credit_card', issuerSlug: 'hdfc', maskDigits: '8127' } }],
  }), 'p', { events, ledgerOf, instruments: new Map() });
  assert.equal(ledgerOf.get('e1')[0].fromInstrumentId, PHONE);
});
