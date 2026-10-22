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

test('hdfc_txn_check_alert: verification alert rejected as non-transaction noise', () => {
  const r = parse('hdfc_txn_check_alert');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'non_transaction_message');
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

test('call_forwarding_vicare: nonfinancial service alert is non_transaction_message', () => {
  const r = parse('call_forwarding_vicare');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'non_transaction_message');
});

test('cashback_offer_only: conditional offer is non_transaction_message', () => {
  const r = parse('cashback_offer_only');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'non_transaction_message');
});

test('otp_security: safety veto rejects with security_message', () => {
  const r = parse('otp_security');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'security_message');
});

test('declined_attempt: declined attempt is not a successful spend', () => {
  const r = parse('declined_attempt');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'not_a_successful_spend');
});

test('outstanding_reminder: outstanding statement reminder has no transaction match', () => {
  const r = parse('outstanding_reminder');
  assert.equal(r.ok, false);
  assert.equal(r.reason, 'no_transaction_match');
});

// Phase 2/3 device routing: the shapes the device minter
// (buildSmsFactsForObservation) produces for recognized non-spend families
// must be accepted by the server contract verbatim. Pinning both sides of
// the same corpus keeps the Dart/Node validators in lockstep.
const deviceMintedShapes = {
  balance_only: {
    factType: 'balance_snapshot',
    payload: {
      availableBalanceInr: 9000,
      asOfAt: '2026-10-16T04:30:00.000Z',
      instrument: 'upi_bank',
      accountLast4: '9876',
    },
  },
  card_statement: [
    {
      factType: 'bill_obligation',
      payload: {
        amountRole: 'due_total',
        amountDueInr: 3000,
        dueDate: '2026-11-04T18:30:00.000Z',
        statementDate: '2026-10-11T18:30:00.000Z',
        billerName: 'Axis Bank',
        last4: '4321',
        instrument: 'credit_card',
      },
    },
    {
      factType: 'bill_obligation',
      payload: {
        amountRole: 'due_minimum',
        minimumDueInr: 600,
        dueDate: '2026-11-04T18:30:00.000Z',
        statementDate: '2026-10-11T18:30:00.000Z',
        billerName: 'Axis Bank',
        last4: '4321',
        instrument: 'credit_card',
      },
    },
  ],
  bill_with_offer: {
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 1500,
      dueDate: '2026-10-17T18:30:00.000Z',
      billerName: 'TNEB electricity',
      accountLast4: null,
    },
  },
  autopay_mandate: {
    factType: 'mandate_lifecycle',
    payload: {
      mandateStatus: 'registered',
      asOfAt: '2026-10-16T10:00:00.000Z',
      limitInr: 2000,
      merchant: 'NETFLIX',
      accountLast4: '1797',
    },
  },
  autopay_failed: {
    factType: 'pending_or_failed_attempt',
    payload: {
      attemptStatus: 'failed',
      occurredAt: '2026-10-16T10:00:00.000Z',
      merchant: 'NETFLIX',
    },
  },
  mandate_cancelled: {
    factType: 'mandate_lifecycle',
    payload: {
      mandateStatus: 'cancelled',
      asOfAt: '2026-10-16T10:00:00.000Z',
      merchant: 'NETFLIX',
      accountLast4: '1797',
    },
  },
  declined_attempt: {
    factType: 'pending_or_failed_attempt',
    payload: {
      attemptStatus: 'failed',
      occurredAt: '2026-10-16T10:00:00.000Z',
      merchant: null,
      last4: '4321',
      instrument: 'credit_card',
    },
  },
};

test('device-minted fact shapes validate under the server contract verbatim', async () => {
  const { validateFactSet } = require('../src/sms_facts');
  for (const [caseId, fact] of Object.entries(deviceMintedShapes)) {
    const list = Array.isArray(fact) ? fact : [fact];
    const result = validateFactSet(
      list.map((f) => ({
        factType: f.factType,
        payload: Object.fromEntries(
          Object.entries(f.payload).filter(([, v]) => v !== null),
        ),
      })),
    );
    assert.deepEqual(
      { case: caseId, ...result },
      { case: caseId, valid: true, errors: [] },
      `device-minted shape for ${caseId} must be server-valid`,
    );
  }
  // The device never posts a parsed bill as spend semantics: the due roles
  // are refused with a posted entryKind and the attempt family refuses any
  // amountInr at all.
  const asSpend = validateFactSet([
    {
      factType: 'bill_obligation',
      payload: {
        amountRole: 'due_total',
        amountDueInr: 3000,
        dueDate: '2026-11-04T18:30:00.000Z',
      },
    },
  ]);
  assert.equal(asSpend.valid, true);
});
