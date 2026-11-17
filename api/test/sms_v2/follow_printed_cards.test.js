'use strict';
// What the bank printed decides which card or account a row is built on. A
// ledger side the event's own messages rule out (another bank, another number)
// is built on the instrument those messages name.
const test = require('node:test');
const assert = require('node:assert/strict');
process.env.JWT_ACCESS_SECRET = process.env.JWT_ACCESS_SECRET || 'ci_only_not_a_real_secret';
const { followPrintedCards, printedCardRulesOut } = require('../../src/sms_v2/storage');

const SBI = '11111111-1111-4111-8111-111111111111';
const PNB = '22222222-2222-4222-8222-222222222222';
const SBI_OTHER = '33333333-3333-4333-8333-333333333333';
const BANK = '44444444-4444-4444-8444-444444444444';
const SBI_LONG = '55555555-5555-4555-8555-555555555555';

const rows = {
  [SBI]: { id: SBI, kind: 'credit_card', issuer_slug: 'sbi', mask_digits: '2837', user_card_id: 'wallet-sbi', status: 'confirmed' },
  [PNB]: { id: PNB, kind: 'credit_card', issuer_slug: 'pnb', mask_digits: '1260', user_card_id: 'wallet-pnb', status: 'confirmed' },
  [SBI_OTHER]: { id: SBI_OTHER, kind: 'credit_card', issuer_slug: 'sbi', mask_digits: '4400', user_card_id: null, status: 'confirmed' },
  [BANK]: { id: BANK, kind: 'bank_account', issuer_slug: 'sbi', mask_digits: '8648', user_card_id: null, status: 'confirmed' },
  [SBI_LONG]: { id: SBI_LONG, kind: 'credit_card', issuer_slug: 'sbi', mask_digits: '992837', user_card_id: 'wallet-x', status: 'confirmed' },
};
const sbiPrinted = { kind: 'credit_card', issuerSlug: 'sbi', maskDigits: '2837' };

function fakeClient(facts) {
  return {
    async query(sql, params) {
      if (sql.includes('FROM sms_v2_facts')) return { rows: facts.filter((f) => params[1].includes(f.id)) };
      if (sql.includes('FROM sms_v2_instruments')) return { rows: params[1].map((id) => rows[id]).filter(Boolean) };
      throw new Error(`unexpected query ${sql}`);
    },
  };
}

async function run({ type = 'purchase', legs, ledger, facts }) {
  const events = new Map([['e1', { eventId: 'e1', type, legs }]]);
  const ledgerOf = new Map([['e1', ledger]]);
  const instruments = new Map();
  await followPrintedCards(fakeClient(facts), 'p', { events, ledgerOf, instruments });
  return { entry: ledgerOf.get('e1')[0], instruments };
}

test('printedCardRulesOut: another bank or number is ruled out; one number printed longer is not', () => {
  const shape = (i) => ({ issuerSlug: i.issuer_slug, maskDigits: i.mask_digits });
  assert.equal(printedCardRulesOut(sbiPrinted, shape(rows[PNB])), true);
  assert.equal(printedCardRulesOut(sbiPrinted, shape(rows[SBI_OTHER])), true);
  assert.equal(printedCardRulesOut(sbiPrinted, shape(rows[SBI])), false);
  assert.equal(printedCardRulesOut(sbiPrinted, shape(rows[SBI_LONG])), false);
  assert.equal(printedCardRulesOut({ issuerSlug: 'sbi', maskDigits: null }, shape(rows[SBI_OTHER])), false);
  assert.equal(printedCardRulesOut(null, shape(rows[PNB])), false);
});

test('an SBI card spend sent on a PNB card is built on the SBI card and its wallet card', async () => {
  const { entry, instruments } = await run({
    legs: [{ factId: 'f1', role: 'debit_leg' }],
    ledger: [{ entryId: 'l1', unit: 'INR', fromInstrumentId: PNB, toExternal: 'OWNLY' }],
    facts: [{ id: 'f1', instrument_id: SBI, printed: sbiPrinted }],
  });
  assert.equal(entry.fromInstrumentId, SBI);
  assert.equal(instruments.get(SBI).userCardId, 'wallet-sbi');
});

test('another number of the same bank is corrected too', async () => {
  const { entry } = await run({
    legs: [{ factId: 'f1', role: 'debit_leg' }],
    ledger: [{ entryId: 'l1', unit: 'INR', fromInstrumentId: SBI_OTHER, toExternal: 'SHOP' }],
    facts: [{ id: 'f1', instrument_id: SBI, printed: sbiPrinted }],
  });
  assert.equal(entry.fromInstrumentId, SBI);
});

test('a refund puts the money back on the card the SMS names', async () => {
  const { entry } = await run({
    type: 'refund',
    legs: [{ factId: 'f1', role: 'credit_leg' }],
    ledger: [{ entryId: 'l1', unit: 'INR', fromExternal: 'SHOP', toInstrumentId: PNB }],
    facts: [{ id: 'f1', instrument_id: SBI, printed: sbiPrinted }],
  });
  assert.equal(entry.toInstrumentId, SBI);
});

test('a link that fits what was printed is left alone', async () => {
  const entry0 = { entryId: 'l1', unit: 'INR', fromInstrumentId: SBI_LONG, toExternal: 'SHOP' };
  const { entry } = await run({
    legs: [{ factId: 'f1', role: 'debit_leg' }],
    ledger: [entry0],
    facts: [{ id: 'f1', instrument_id: SBI, printed: sbiPrinted }],
  });
  assert.equal(entry, entry0);
});

test('a card bill paid from a bank account keeps both sides: each is named by its own message', async () => {
  const entry0 = { entryId: 'l1', unit: 'INR', fromInstrumentId: BANK, toInstrumentId: SBI };
  const { entry } = await run({
    type: 'card_bill_payment',
    legs: [{ factId: 'f1', role: 'debit_leg' }, { factId: 'f2', role: 'credit_leg' }],
    ledger: [entry0],
    facts: [
      { id: 'f1', instrument_id: BANK, printed: { kind: 'bank_account', issuerSlug: 'sbi', maskDigits: '8648' } },
      { id: 'f2', instrument_id: SBI, printed: sbiPrinted },
    ],
  });
  assert.equal(entry, entry0);
});

test('a message that printed only its bank does not overrule a card of that bank', async () => {
  const entry0 = { entryId: 'l1', unit: 'INR', fromInstrumentId: SBI_OTHER, toExternal: 'SHOP' };
  const { entry } = await run({
    legs: [{ factId: 'f1', role: 'debit_leg' }],
    ledger: [entry0],
    facts: [{ id: 'f1', instrument_id: null, printed: { kind: 'credit_card', issuerSlug: 'sbi', maskDigits: null } }],
  });
  assert.equal(entry, entry0);
});

test('when the card the SMS names is not known, nothing is guessed', async () => {
  const entry0 = { entryId: 'l1', unit: 'INR', fromInstrumentId: PNB, toExternal: 'SHOP' };
  const { entry } = await run({
    legs: [{ factId: 'f1', role: 'debit_leg' }],
    ledger: [entry0],
    facts: [{ id: 'f1', instrument_id: null, printed: sbiPrinted }],
  });
  assert.equal(entry, entry0);
});
