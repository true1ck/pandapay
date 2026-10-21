const test = require('node:test');
const assert = require('node:assert/strict');
const corpus = require('../../app/test/fixtures/sms_family_corpus.json');
const {
  parseSmsAgainstPatterns,
  redactSmsShape,
} = require('../src/sms_parser');
const {
  parseSubscriptionMandate,
} = require('../src/subscription_parser');
const {
  extractStatementDate,
} = require('../src/due_date_parser');

const byId = new Map(corpus.cases.map((c) => [c.id, c]));
const parse = (id) =>
  parseSmsAgainstPatterns(
    [],
    { sender: byId.get(id).sender, body: byId.get(id).body },
  );

// Phase 0 baseline: the server parser only sees messages the device forwards.
// The conservative built-in parser is probed directly below to record today's
// behavior. Later phases will harden the alert/garbage cases flagged here.

test('redactSmsShape masks amounts, suffixes, dates and references', () => {
  assert.equal(
    redactSmsShape(
      'Rs.1,250.50 debited from your A/c XX1234 on 16-10-26 for UPI-P2M to GROCERY_M. Avl bal Rs.8,750.25.',
    ),
    'X.#,###.## X X X A/c X#### X ##-##-## X X-P#M X X_M. X X X.#,###.##.',
  );
});

test('send_debit_with_balance: posted spend with balance snapshot', () => {
  const r = parse('send_debit_with_balance');
  assert.deepEqual(r.fields, {
    amountInr: 1250.5,
    merchant: 'UPI-P2M to GROCERY_M',
    date: '16-10-26',
    instrument: 'upi_bank',
    entryKind: 'spend',
    availableBalanceInr: 8750.25,
  });
});

test('balance_only without a pattern: server has nothing to learn from today', () => {
  const r = parse('balance_only');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no_transaction_match');
});

test('card_statement: no transaction match; statement day extractor works', () => {
  const r = parse('card_statement');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'not_a_transaction_alert');
  const day = extractStatementDate(byId.get('card_statement').body, new Date('2026-10-16'));
  assert.deepEqual(
    {
      date: day.date.toISOString(),
      day: day.day,
      raw: day.raw,
      explicit: day.explicit,
    },
    {
      date: '2026-10-11T18:30:00.000Z',
      day: 12,
      raw: '12-10-26',
      explicit: true,
    },
  );
});

test('bill_with_offer: no transaction match', () => {
  assert.equal(parse('bill_with_offer').reason, 'not_a_transaction_alert');
});

test('autopay_mandate: mandate extractor registers ceiling, merchant flaw recorded', () => {
  const r = parse('autopay_mandate');
  assert.equal(r.ok, false); // conservative parser does not fire on the mandate text
  const mandate = parseSubscriptionMandate({
    sender: byId.get('autopay_mandate').sender,
    body: byId.get('autopay_mandate').body,
  });
  assert.equal(mandate.ok, true);
  assert.equal(mandate.lifecycle, 'active');
  assert.equal(mandate.fields.merchant, 'NETFLIX with');
  assert.equal(mandate.fields.amountInr, 2000);
  assert.equal(mandate.fields.last4, '1797');
  assert.equal(mandate.fields.instrument, 'upi_bank');
});

test('autopay_scheduled: not a mandate and not a transaction', () => {
  const r = parse('autopay_scheduled');
  assert.equal(r.ok, false);
  assert.equal(
    parseSubscriptionMandate({
      sender: byId.get('autopay_scheduled').sender,
      body: byId.get('autopay_scheduled').body,
    }).reason,
    'non_mandate_alert',
  );
});

test('refund_with_offer: transfer/refund on the card leg', () => {
  const r = parse('refund_with_offer');
  assert.deepEqual(r.fields, {
    amountInr: 499,
    last4: '4321',
    merchant: 'Refund',
    transferKind: 'refund',
    instrument: 'credit_card',
    entryKind: 'transfer',
  });
});

test('card_bill_payment: transfer/card_bill', () => {
  const r = parse('card_bill_payment');
  assert.deepEqual(r.fields, {
    amountInr: 12000,
    merchant: 'Credit card bill payment',
    transferKind: 'card_bill',
    instrument: 'other',
    entryKind: 'transfer',
  });
});

test('kotak_settlement: investment payout vocabulary missing', () => {
  const r = parse('kotak_settlement');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no_transaction_match');
});

test('hdfc_txn_check_alert: KNOWN baseline gap - verification alert parses as a spend', () => {
  const r = parse('hdfc_txn_check_alert');
  assert.equal(r.ok, true);
  assert.equal(r.fields.entryKind, 'spend');
  assert.equal(r.fields.amountInr, 2000);
  // Garbage merchant proving the false positive.
  assert.match(r.fields.merchant, /contact you twice/);
});

test('reversed_credit: transfer/reversal', () => {
  const r = parse('reversed_credit');
  assert.deepEqual(r.fields, {
    amountInr: 500,
    merchant: 'Reversal',
    accountLast4: '1234',
    date: '16-10-26',
    instrument: 'upi_bank',
    transferKind: 'reversal',
    entryKind: 'transfer',
  });
});

test('upi_person_spend: spend with transfer party identified', () => {
  const r = parse('upi_person_spend');
  assert.deepEqual(r.fields, {
    amountInr: 250,
    merchant: 'Transfer to Sujay Enterprises',
    transferParty: 'Sujay Enterprises',
    transferKind: 'payment_to_person',
    accountLast4: '1234',
    date: '16-10-26',
    reference: '123456789012',
    instrument: 'upi_bank',
    entryKind: 'spend',
  });
});

test('salary_income: income entry', () => {
  const r = parse('salary_income');
  assert.deepEqual(r.fields, {
    amountInr: 50000,
    merchant: 'Salary',
    accountLast4: '1234',
    date: '16-10-26',
    instrument: 'upi_bank',
    entryKind: 'income',
  });
});

test('atm_withdrawal: transfer/cash_withdrawal on the debit card leg', () => {
  const r = parse('atm_withdrawal');
  assert.deepEqual(r.fields, {
    amountInr: 20000,
    merchant: 'Cash withdrawal',
    last4: '8406',
    instrument: 'debit_card',
    transferKind: 'cash_withdrawal',
    entryKind: 'transfer',
  });
});

test('ambiguous_suffix_two_banks: no automatic pairing anywhere', () => {
  const h = parse('ambiguous_suffix_two_banks');
  // KNOWN baseline gap: the vague "for balance transfer to another bank"
  // clause is classified as a payment_to_person spend with that party.
  assert.equal(h.ok, true);
  assert.equal(h.fields.entryKind, 'spend');
  assert.equal(h.fields.transferKind, 'payment_to_person');
  assert.equal(h.fields.accountLast4, '9080');
  const credit = parse('ambiguous_suffix_two_banks_second');
  assert.equal(credit.fields.entryKind, 'transfer');
  assert.equal(credit.fields.transferKind, 'incoming_bank_transfer_candidate');
  assert.equal(credit.fields.accountLast4, '9080');
  assert.notEqual(credit.fields.merchant, 'Sujay Kumar');
});
