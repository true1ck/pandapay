const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseSms,
  parseSmsAgainstPatterns,
  parseConservativeBankSpend,
  redactSmsShape,
  isBankAccountMessage,
  isNonTransactionNoise,
  isInvestmentFolioAllotment,
  parseTransactionDate,
  parseSmsTransactionTimestamp,
} = require('../src/sms_parser');
const { extractCreditLimit } = require('../src/card_limit_parser');

// Realistic synthetic (not real customer) Indian bank SMS formats.

const HDFC_PATTERN = {
  id: 'p-hdfc-1',
  sender_pattern: 'HDFCBK',
  regex: 'Rs\\.?\\s?([\\d,]+\\.?\\d*) spent on your HDFC Bank Card ending (\\d{4}) at ([A-Za-z0-9 &._-]+?) on (\\d{2}-\\d{2}-\\d{2})',
  field_map: { amount: 1, last4: 2, merchant: 3, date: 4 },
};

const ICICI_PATTERN = {
  id: 'p-icici-1',
  sender_pattern: 'ICICIB',
  regex: 'INR ([\\d,]+\\.?\\d*) spent on ICICI Bank Card XX(\\d{4}) at ([A-Za-z0-9 &._-]+?) on (\\d{2}-[A-Za-z]{3}-\\d{2})',
  field_map: { amount: 1, last4: 2, merchant: 3, date: 4 },
};

test('successful parse: HDFC-style SMS extracts all fields', () => {
  const sms = {
    sender: 'VM-HDFCBK-S',
    body: 'Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL on 04-08-26. Avl limit Rs.85,000.',
  };
  const result = parseSms(HDFC_PATTERN, sms);
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 1499);
  assert.equal(result.fields.last4, '4321');
  assert.equal(result.fields.merchant, 'AMAZON RETAIL');
  assert.equal(result.fields.date, '04-08-26');
});

test('a configured card pattern without merchant mapping retains an independently verified payee', () => {
  const pattern = {
    ...HDFC_PATTERN,
    field_map: { amount: 1, last4: 2, date: 4 },
  };
  const result = parseSmsAgainstPatterns([pattern], {
    sender: 'VM-HDFCBK-S',
    body: 'Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL on 04-08-26. Avl limit Rs.85,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'configured_pattern');
  assert.equal(result.fields.merchant, 'AMAZON RETAIL');
});

test('merchant enrichment leaves payee absent when the card alert names none', () => {
  const pattern = {
    ...HDFC_PATTERN,
    regex: 'Rs\\.?\\s?([\\d,]+\\.?\\d*) spent on your HDFC Bank Card ending (\\d{4})',
    field_map: { amount: 1, last4: 2 },
  };
  const result = parseSmsAgainstPatterns([pattern], {
    sender: 'VM-HDFCBK-S',
    body: 'Rs.1,499.00 spent on your HDFC Bank Card ending 4321. Avl limit Rs.85,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.merchant, undefined);
});

test('Axis card alerts with merchant after date and time capture it before the support number', () => {
  const sms = {
    sender: 'VM-AXISBK-S',
    body: 'Spent INR 505 Axis Bank Card no. XX0000 02-10-26 23:11:37 IST FLIPKART PA Avl Limit: INR 77901 Not you? SMS BLOCK 0000 to 9000000000',
  };
  const result = parseSmsAgainstPatterns([], sms);
  assert.equal(result.ok, true);
  assert.equal(result.fields.merchant, 'FLIPKART PA');
  assert.notEqual(result.fields.merchant, '9000000000');

  const pattern = {
    id: 'axis-card-partial',
    sender_pattern: 'AXISBK',
    regex: 'Spent INR ([0-9,]+) Axis Bank Card no\\. XX(\\d{4}) (\\d{2}-\\d{2}-\\d{2})',
    field_map: { amount: 1, last4: 2, date: 3 },
  };
  const configured = parseSmsAgainstPatterns([pattern], sms);
  assert.equal(configured.parserKind, 'configured_pattern');
  assert.equal(configured.fields.merchant, 'FLIPKART PA');
});

test('explicit IST swipe time is retained and uncertain times use the bank date', () => {
  const received = new Date('2026-10-02T17:42:00.000Z');
  const exact = parseSmsTransactionTimestamp(
    '02-10-26', 'Card XX0000 02-10-26 23:11:37 IST FLIPKART PA', received,
  );
  assert.equal(exact.date.toISOString(), '2026-10-02T17:41:37.000Z');
  assert.equal(exact.precise, true);
  const dateOnly = parseTransactionDate('02-10-26', received);
  assert.equal(
    parseSmsTransactionTimestamp('02-10-26', 'Card XX0000 02-10-26 23:11:37 FLIPKART PA', received).date.getTime(),
    dateOnly.getTime(),
  );
  assert.equal(
    parseSmsTransactionTimestamp('02-10-26', 'Card XX0000 02-10-26 25:11:37 IST FLIPKART PA', received).date.getTime(),
    dateOnly.getTime(),
  );
});

test('successful parse: ICICI-style SMS with alphabetic month in date', () => {
  const sms = {
    sender: 'AD-ICICIB',
    body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  };
  const result = parseSms(ICICI_PATTERN, sms);
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 250);
  assert.equal(result.fields.last4, '7788');
  assert.equal(result.fields.merchant, 'SWIGGY');
});

test('card suffixes retain spend details but require evidence for a credit/debit type on every parser path', () => {
  const pattern = {
    id: 'card-type-evidence',
    regex: 'INR (\\d+) spent on .*?Card (?:XX)?(\\d{4}) at (\\w+)',
    field_map: { amount: 1, last4: 2, merchant: 3 },
  };
  const cases = [
    ['Bank Card XX7788', '', 'other'],
    ['Bank Card 7788', ' Bal Rs.9000.', 'other'],
    ['Bank Credit Card XX7788', '', 'credit_card'],
    ['Bank Card XX7788', ' Avl Limit Rs.9000.', 'credit_card'],
    ['Bank Card XX7788', ' Available credit limit Rs.9000.', 'credit_card'],
    ['Bank Card XX7788', ' Avl. lmt Rs.9000.', 'credit_card'],
    ['Bank Debit Card XX7788', ' Avl Limit Rs.9000.', 'debit_card'],
    ['Bank Card XX7788', ' SMS BLOCK DC 7788.', 'debit_card'],
  ];
  for (const [cardLabel, footer, instrument] of cases) {
    const sms = { sender: 'ICICIB', body: `INR 250 spent on ICICI ${cardLabel} at SWIGGY on 05-Aug-26.${footer}` };
    for (const result of [
      parseSms(pattern, sms),
      parseConservativeBankSpend(sms),
      parseSmsAgainstPatterns([], sms),
      parseSmsAgainstPatterns([pattern], sms),
    ]) {
      assert.equal(result.ok, true, sms.body);
      assert.equal(result.fields.instrument, instrument, sms.body);
      assert.equal(result.fields.last4, '7788');
      assert.equal(result.fields.amountInr, 250);
      assert.equal(result.fields.merchant, 'SWIGGY');
      assert.equal(result.fields.entryKind, 'spend');
    }
  }
});

test('last-resort card parser preserves an untyped paid alert and merchant enrichment', () => {
  const sms = {
    sender: 'BANK', body: 'INR 250 paid on Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  };
  const pattern = {
    id: 'paid-card', regex: 'INR (\\d+) paid on Bank Card XX(\\d{4})',
    field_map: { amount: 1, last4: 2 },
  };
  for (const patterns of [[], [pattern]]) {
    const result = parseSmsAgainstPatterns(patterns, sms);
    assert.equal(result.ok, true);
    assert.equal(result.fields.instrument, 'other');
    assert.equal(result.fields.last4, '7788');
    assert.equal(result.fields.merchant, 'SWIGGY');
    assert.equal(result.fields.entryKind, 'spend');
  }
});

test('card credits do not assume a generic or explicitly debit card is a credit card', () => {
  for (const [label, instrument] of [
    ['card', 'other'], ['debit card', 'debit_card'], ['credit card', 'credit_card'],
  ]) {
    const result = parseSmsAgainstPatterns([], {
      sender: 'BANK', body: `INR 250 refunded to your ${label} XX7788.`,
    });
    assert.equal(result.ok, true);
    assert.equal(result.fields.instrument, instrument);
    assert.equal(result.fields.last4, '7788');
    assert.equal(result.fields.entryKind, 'transfer');
  }
});

test('cardless configured patterns and suffix-free generic cards have no implicit credit type', () => {
  const pattern = { regex: 'INR (\\d+) spent at (\\w+)', field_map: { amount: 1, merchant: 2 } };
  assert.equal(parseSms(pattern, { body: 'INR 250 spent at SWIGGY.' }).fields.instrument, 'other');
  const result = parseConservativeBankSpend({ body: 'INR 250 spent on Bank Card at SWIGGY.' });
  assert.equal(result.ok, true);
  assert.equal(result.fields.instrument, 'other');
});

test('built-in SMS parsing preserves UPI merchant and MCC metadata', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'UPI',
    body: 'Rs 650 paid to FOODHUB@upi via UPI on 2026-10-02. MCC: 5812. UPI Ref 1234567890',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.merchant, 'FOODHUB@upi');
  assert.equal(result.fields.mcc, '5812');
});

test('malformed/partial match: body missing the "spent on" clause fails cleanly', () => {
  const sms = {
    sender: 'VM-HDFCBK-S',
    body: 'Your HDFC Bank Card ending 4321 payment of Rs.500 is due on 10-08-26.',
  };
  const result = parseSms(HDFC_PATTERN, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_regex_match');
});

test('malformed: amount field captures non-numeric text -> unparseable_amount, never a fabricated guess', () => {
  const badPattern = {
    id: 'p-bad-1',
    sender_pattern: 'HDFCBK',
    regex: 'spent (\\w+) at ([A-Za-z ]+)',
    field_map: { amount: 1, merchant: 2 },
  };
  const sms = { sender: 'HDFCBK', body: 'spent MANY at CAFE COFFEE DAY' };
  const result = parseSms(badPattern, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unparseable_amount');
});

test('wrong-issuer sender mismatch: ICICI pattern does not match an SBI sender', () => {
  const sms = {
    sender: 'SBIINB',
    body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  };
  const result = parseSms(ICICI_PATTERN, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'sender_mismatch');
});

test('pattern with no sender_pattern configured matches any sender', () => {
  const openPattern = { ...HDFC_PATTERN, id: 'p-open', sender_pattern: null };
  const sms = {
    sender: 'RANDOM-SENDER',
    body: 'Rs.100 spent on your HDFC Bank Card ending 1111 at TEST STORE on 01-01-26.',
  };
  const result = parseSms(openPattern, sms);
  assert.equal(result.ok, true);
});

test('empty SMS body fails without throwing', () => {
  const result = parseSms(HDFC_PATTERN, { sender: 'HDFCBK', body: '   ' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'empty_body');
});

test('invalid pattern (no regex) fails cleanly', () => {
  const result = parseSms({ field_map: {} }, { sender: 'HDFCBK', body: 'Rs.10 spent' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'invalid_pattern');
});

test('field_map missing "amount" entirely is rejected even if regex matches', () => {
  const noAmountPattern = {
    id: 'p-noamount',
    sender_pattern: 'HDFCBK',
    regex: 'at ([A-Za-z ]+) on',
    field_map: { merchant: 1 },
  };
  const sms = { sender: 'HDFCBK', body: 'spent at TEST STORE on 01-01-26' };
  const result = parseSms(noAmountPattern, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_amount_field_mapped');
});

test('parseSmsAgainstPatterns tries candidates in order and returns the first match with its patternId', () => {
  const sms = {
    sender: 'AD-ICICIB',
    body: 'INR 999 spent on ICICI Bank Card XX1234 at ZOMATO on 06-Aug-26.',
  };
  const result = parseSmsAgainstPatterns([HDFC_PATTERN, ICICI_PATTERN], sms);
  assert.equal(result.ok, true);
  assert.equal(result.patternId, 'p-icici-1');
  assert.equal(result.fields.merchant, 'ZOMATO');
});

test('parseSmsAgainstPatterns returns ok:false with a reason when nothing matches', () => {
  const sms = { sender: 'AXISBK', body: 'Totally unrelated promotional message.' };
  const result = parseSmsAgainstPatterns([HDFC_PATTERN, ICICI_PATTERN], sms);
  assert.equal(result.ok, false);
  assert.ok(result.reason);
});

test('parseSmsAgainstPatterns with an empty pattern list reports a transaction mismatch', () => {
  const result = parseSmsAgainstPatterns([], { sender: 'HDFCBK', body: 'Rs.10 spent' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_transaction_match');
});

test('conservative fallback parses a card spend when the pattern table is empty', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'VM-NEWBNK',
    body: 'INR 1,250.50 spent on your credit card ending 7788 at AMAZON PAY on 09-Sep-2026.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'conservative_fallback');
  assert.equal(result.fields.amountInr, 1250.5);
  assert.equal(result.fields.last4, '7788');
  assert.equal(result.fields.merchant, 'AMAZON PAY');
});

test('ICICI card alerts keep the merchant and do not capture the later support number', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'JX-ICICIT-S',
    body: 'INR 1,999.00 spent using ICICI Bank Card XX9008 on 01-Oct-26 on OPENAI *CHATGPT. Avl Limit: INR 5,23,661.68. If not you, call 18002662/SMS BLOCK 9008 to 9215676766.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'conservative_fallback');
  assert.equal(result.fields.amountInr, 1999);
  assert.equal(result.fields.instrument, 'credit_card');
  assert.equal(result.fields.last4, '9008');
  assert.equal(result.fields.merchant, 'OPENAI *CHATGPT');
  assert.equal(result.fields.date, '01-Oct-26');
});

test('conservative fallback rejects OTP, due, refund, failed and non-card account messages', () => {
  const messages = [
    'OTP 123456 for INR 500 transaction on your card ending 7788',
    'Payment due of INR 500 on your credit card ending 7788',
    'INR 500 refunded to your credit card ending 7788',
    'INR 500 transaction failed on your credit card ending 7788',
    'INR 500 debited from your account at AMAZON',
  ];
  for (const body of messages) {
    assert.equal(parseConservativeBankSpend({ sender: 'BANK', body }).ok, false, body);
  }
});

test('all parser paths reject card due reminders and non-purchase card alerts', () => {
  const messages = [
    'Payment of INR 5590.75 for Axis Bank Credit Card no. XX7105 is due on 02-04-26 with minimum amount due of INR 112. Ignore if paid.',
    'Statement for your Axis Bank Credit Card no. XX7105 has been generated.',
    'Your new Flipkart Credit Card no. XX7105 has been dispatched to your address.',
    'MoneyBack+ xx8708: Spend ₹15000, get ₹250',
  ];
  for (const body of messages) {
    assert.equal(parseSmsAgainstPatterns([], { sender: 'BANK', body }).ok, false, body);
  }
});

test('credit-card bill payment receipts become transfers, not spending', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'PAYMENT OF Rs. 15660.00 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 8708. Thank you.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_card_bill_payment');
  assert.equal(result.fields.amountInr, 15660);
  assert.equal(result.fields.last4, '8708');
  assert.equal(result.fields.entryKind, 'transfer');
});

test('paid card bills remain transfers while purchases on the same card remain spend', () => {
  const payments = [
    'Your Axis Bank Credit Card bill of Rs. 80000 paid successfully for card ending 2006.',
    'Rs. 80000 debited from your account for Axis Bank Flipkart Credit Card ending 2006.',
    'Payment of INR 80000 to your credit card ending 2006 completed.',
  ];
  for (const body of payments) {
    const result = parseSmsAgainstPatterns([], { sender: 'AXISBK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
  }
  const purchase = parseSmsAgainstPatterns([], {
    sender: 'AXISBK',
    body: 'Rs. 80000 spent on your Axis Bank Flipkart Credit Card ending 2006 at FLIPKART INTERNET.',
  });
  assert.equal(purchase.ok, true);
  assert.equal(purchase.fields.entryKind, 'spend');
});

test('a successful card purchase called a payment is not mistaken for a bill payment', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'AXISBK',
    body: 'Your payment of INR 2500 on your credit card ending 2006 at AMAZON was successful.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'spend');
  assert.notEqual(result.fields.transferKind, 'card_bill');
});

test('bank-to-bank account narration without the word self is not spending', () => {
  const cases = [
    'Rs.80000 transferred from Canara Bank A/c XX2626 to HDFC Bank A/c XX9080. UTR 123456789012.',
    'A/c XX2626 debited Rs.80000 towards HDFC Bank A/c XX9080 via IMPS Ref 123456789012.',
  ];
  for (const body of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'CANBNK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, 'account_to_account_candidate', body);
    assert.equal(result.fields.destinationAccountLast4, '9080', body);
  }
});

test('the incoming credit leg of an account transfer is retained as a transfer candidate', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'INR 80000 credited to HDFC Bank A/c XX9080 from Canara Bank A/c XX2626. UTR 123456789012.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'incoming_bank_transfer_candidate');
  assert.equal(result.fields.accountLast4, '9080');
});

test('wallet top-ups are transfers while wallet merchant payments remain spend', () => {
  const topUp = parseSmsAgainstPatterns([], {
    sender: 'PAYTM',
    body: 'Rs.5000 added to Paytm wallet from your bank account. UPI Ref 123456789012.',
  });
  assert.equal(topUp.ok, true);
  assert.equal(topUp.fields.entryKind, 'transfer');
  assert.equal(topUp.fields.transferKind, 'wallet_load');

  const purchase = parseSmsAgainstPatterns([], {
    sender: 'PAYTM',
    body: 'Rs.5000 paid to grocery@upi from your bank account via UPI. UPI Ref 123456789012.',
  });
  assert.equal(purchase.ok, true);
  assert.equal(purchase.fields.entryKind, 'spend');
});

test('wallet credit leg of a top-up is also a transfer', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'PAYTM',
    body: 'Paytm wallet credited with Rs.5000 from your bank account. UPI Ref 123456789012.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'wallet_load');
  assert.equal(result.fields.merchant, 'Wallet load');
});

test('a broker settlement payout is an investment-proceeds money-in, not wallet load', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'VM-DHANHQ-S',
    body: 'Dear Sujay We have transferred Rs 93.82 to your bank account ending with XXXXXXX2626 as a part of running account settlement vide Ref No PO26101713812965. To continue trading and investing, add funds back to your Dhan account.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'investment_proceeds');
  assert.equal(result.fields.merchant, 'Investment proceeds');
  assert.equal(result.fields.accountLast4, '2626');
});

test('a genuine wallet instruction over its own payload still parses as wallet load', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'PAYTM',
    body: 'Rs.5000 added to Paytm wallet from your bank account. UPI Ref 123456789012.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'wallet_load');
});

test('a debit addressed to the profile name is a self-transfer, not spending', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Sent Rs.5000.00 From HDFC Bank A/C *1797 To SUJAY SHANTARAM KURTIKAR. Not you? Call 1800. Ref 12345678',
    ownUserName: 'Sujay Shantaram Kurtikar',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'account_to_account');
  assert.equal(result.fields.merchant, 'Transfer between own accounts');
});

test('same person named without a profile name stays a person payment', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Sent Rs.5000.00 From HDFC Bank A/C *1797 To SUJAY SHANTARAM KURTIKAR. Not you? Call 1800. Ref 12345678',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.transferKind, 'payment_to_person');
});

test('a different named recipient is spending even with a profile name', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Sent Rs.5000.00 From HDFC Bank A/C *1797 To PRIYA VASANTA RAJAN. Not you? Call 1800. Ref 12345678',
    ownUserName: 'Sujay Shantaram Kurtikar',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.transferKind, 'payment_to_person');
});

test('a credit received from the profile name is the paired self-transfer leg', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs.5000.0 credited to your HDFC Bank A/C *9080 from SUJAY SHANTARAM KURTIKAR on 20-10-26. Ref 99887765',
    ownUserName: 'Sujay Shantaram Kurtikar',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'account_to_account');
  assert.equal(result.fields.merchant, 'Transfer between own accounts');
  // The credited leg keeps its own account suffix, not the debit leg's.
  assert.equal(result.fields.accountLast4, '9080');
});

test('abbreviated card bill payment messages are transfers', () => {
  const cases = [
    'CARD BILL PAY of Rs.80000 successful. Ref 123456789012.',
    'IMPS CC PMT Rs.80000 debited from Canara A/c XX2626. UTR 123456789012.',
    'Rs.80000 debited towards your card payment. Ref 123456789012.',
  ];
  for (const body of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'CANBNK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, 'card_bill', body);
  }
});

test('bank-account credits become incoming income entries', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Your HDFC Bank A/c XX1797 is credited with Rs. 45,000.00 by SALARY on 30-09-26. UTR 123456789012. Avl Bal Rs. 98,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_account_credit');
  assert.equal(result.fields.amountInr, 45000);
  assert.equal(result.fields.entryKind, 'income');
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.accountLast4, '1797');
  assert.equal(result.fields.merchant, 'Salary');
  assert.equal(result.fields.reference, '123456789012');
});

test('generic bank-origin credits are transfer candidates until paired', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Your HDFC Bank A/c XX9080 is credited with Rs.80,000 from CANARA BANK. UTR 123456789012. Avl Bal Rs.1,20,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_account_credit');
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'incoming_bank_transfer_candidate');
  assert.equal(result.fields.merchant, 'Bank transfer');
});

test('posted reversal and refund wording override overlapping income keywords', () => {
  const cases = [
    ['Interest reversal of Rs.500 credited to your account ending 2626.', 'reversal'],
    ['Salary advance of Rs.10000 credited to your account ending 2626.', 'loan_disbursement'],
    ['Dividend refund of Rs.250 credited to your account ending 2626.', 'refund'],
  ];
  for (const [body, transferKind] of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'BANK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, transferKind, body);
  }
});

test('loan interest charges remain spend while principal repayments stay transfers', () => {
  const fee = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Loan interest charge of Rs.500 debited from your account ending 2626.',
  });
  const repayment = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Loan repayment of Rs.5000 debited from your account ending 2626.',
  });
  assert.equal(fee.ok, true);
  assert.equal(fee.fields.entryKind, 'spend');
  assert.equal(fee.fields.transferKind, 'fee');
  assert.equal(repayment.ok, true);
  assert.equal(repayment.fields.entryKind, 'transfer');
  assert.equal(repayment.fields.transferKind, 'loan_repayment');
});

test('bank-account summary evidence excludes insurance and investment account suffixes', () => {
  assert.equal(
    isBankAccountMessage('Your Canara Bank A/c *5702 was credited with Rs.5000. Avl Bal Rs.12000.'),
    true,
  );
  assert.equal(
    isBankAccountMessage('PYTMBK: Your bank account *5702 was debited Rs.100. Available balance Rs.900.'),
    true,
  );
  assert.equal(
    isBankAccountMessage('Paytm Payments Bank A/c *5702: Available balance is Rs.900.'),
    true,
  );
  assert.equal(
    isBankAccountMessage('Your account *5702 was credited with Rs.5000. Avl Bal Rs.900.', 'HDFCBK'),
    true,
  );
  assert.equal(
    isBankAccountMessage('Your account *5702 was credited with Rs.5000. Avl Bal Rs.900.', 'UNKNOWN'),
    false,
  );
  assert.equal(
    isBankAccountMessage('LICIND: Premium of Rs.5000 debited from policy account ending 5702.'),
    false,
  );
  assert.equal(
    isBankAccountMessage('DHANHQ: Funds credited to trading account ending 5702.'),
    false,
  );
  assert.equal(
    isBankAccountMessage('Paytm Money demat account *5702 credited with units. Portfolio value Rs.900.'),
    false,
  );
  assert.equal(
    isBankAccountMessage('Rs.850 spent on your HDFC Bank Debit Card ending 5702. Avl Bal Rs.12000.'),
    false,
  );
  assert.equal(
    isBankAccountMessage('Avl Bal Rs.12000 for investment account ending 5702.'),
    false,
  );
  assert.equal(
    isBankAccountMessage(
      'Hi Sujay, Your Pay Later a/c XXX6016 has got you personal loan upto Rs 4,00,000 with instant credit.',
      'VM-axioFN',
    ),
    false,
  );
  assert.equal(
    isBankAccountMessage(
      'Reminder Sujay, by continuing timely EMI payments against your Pay Later a/c XXX6016, you are building a credit score.',
      'VD-axioLN',
    ),
    false,
  );
  assert.equal(
    isBankAccountMessage(
      'We have received your timely repayment towards your Pay Later XXX6016 a/c.',
      'VD-axioLN',
    ),
    false,
  );
});

test('refunds and rewards are non-income movements, while credit-card bill receipts stay transfers', () => {
  const refund = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Refund of Rs. 250 received in your savings account ending 5799 from AMAZON on 02-10-26.',
  });
  assert.equal(refund.ok, true);
  assert.equal(refund.fields.entryKind, 'transfer');
  assert.equal(refund.fields.transferKind, 'refund');
  assert.equal(refund.fields.merchant, 'Refund');

  const cashback = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Cashback of INR 80 credited to your wallet on 03-10-26.',
  });
  assert.equal(cashback.ok, true);
  assert.equal(cashback.fields.entryKind, 'transfer');
  assert.equal(cashback.fields.transferKind, 'reward');
  assert.equal(cashback.fields.instrument, 'wallet');
});

test('card refunds, reversals and statement rewards remain visible transfers', () => {
  for (const [body, kind, merchant] of [
    ['Your credit card ending 7788 was credited Rs.250 as refund from AMAZON.', 'refund', 'Refund'],
    ['Reversal of Rs.500 posted to your credit card ending 7788.', 'reversal', 'Reversal'],
    ['Cashback of Rs.80 credited to your credit card ending 7788.', 'reward', 'Reward or cashback'],
    ['Statement credit of Rs.100 applied to card ending 7788.', 'card_adjustment', 'Card statement adjustment'],
  ]) {
    const result = parseSmsAgainstPatterns([], { sender: 'BANK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, kind, body);
    assert.equal(result.fields.merchant, merchant, body);
  }
});

test('salary advances are loan disbursements, not earned salary', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Salary advance of Rs.25,000 credited to your bank account.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'loan_disbursement');
});

test('unlabelled credits stay out of earned income until classified', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Your HDFC Bank A/c XX9080 is credited with Rs.80,000. UTR 123456789012. Avl Bal Rs.1,20,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.transferKind, 'unclassified_credit');
});

test('loan repayments and bank fees do not inflate purchase spending', () => {
  const loan = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'EMI repayment of Rs.12,000 debited from your bank account. Ref 123456789012.',
  });
  assert.equal(loan.ok, true);
  assert.equal(loan.fields.entryKind, 'transfer');
  assert.equal(loan.fields.transferKind, 'loan_repayment');

  const fee = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Service charge of Rs.250 debited from your bank account. Ref 123456789012.',
  });
  assert.equal(fee.ok, true);
  assert.equal(fee.fields.entryKind, 'spend');
  assert.equal(fee.fields.transferKind, 'fee');
});

test('credited EMI repayment alerts are loan repayments, not income', () => {
  for (const body of [
    'Dear Customer, your account no. XX3510 has been credited with Rs.6300 towards the payment of EMI on 04-10-2026. UCO Bank',
    'Dear Customer, your account no. XX2315 has been credited with Rs.9700 towards the payment of EMI on 04-10-2026. UCO Bank',
    'Loan EMI payment of Rs.5000 credited to your account ending 2626.',
    'Your a/c XX4455 has been credited with Rs.8500. Equated Monthly Installment received towards home loan. SBI',
  ]) {
    const result = parseSmsAgainstPatterns([], { sender: 'VM-UCOBNK-S', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, 'loan_repayment', body);
    assert.equal(result.fields.merchant, 'Loan or EMI repayment', body);
  }
});

test('loan disbursement, investment proceeds, gifts and reimbursements are not earned income by default', () => {
  const cases = [
    ['Loan disbursement of Rs.50000 credited to your bank account.', 'loan_disbursement'],
    ['Mutual fund redemption proceeds of Rs.50000 credited to your bank account.', 'investment_proceeds'],
    ['Gift of Rs.5000 received in your savings account.', 'gift_received'],
    ['Expense reimbursement of Rs.5000 credited to your bank account.', 'reimbursement'],
  ];
  for (const [body, transferKind] of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'BANK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'transfer', body);
    assert.equal(result.fields.transferKind, transferKind, body);
  }
});

test('offers and service notices never become transactions', () => {
  for (const [sender, body] of [
    ['TX-WAKFTT-P', 'Treat yourself to Wakefit sofa at just Rs.28,125. Grab offer now.'],
    ['BP-SBICRD-S', 'Trxns. of combined value Rs.40016 are eligible for conversion to Flexipay EMIs.'],
    ['VA-SBIBNK-S', 'YONO services is being blocked due to suspicious txns in your account. Visit nearest branch.'],
  ]) {
    assert.equal(parseSmsAgainstPatterns([], { sender, body }).reason, 'non_transaction_message');
  }
  assert.equal(parseSmsAgainstPatterns([], {
    sender: 'BANK', body: 'Cashback of INR 80 credited to your wallet on 03-10-26.'
  }).ok, true);
});

test('marketing appended to real alerts does not hide the event', () => {
  const posted = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Your card XX1234 was debited Rs.500 at STORE. Get 5% cashback on your next purchase.',
  });
  assert.equal(posted.ok, true);
  assert.equal(posted.fields.amountInr, 500);
  assert.equal(parseSmsAgainstPatterns([], {
    sender: 'BP-SBICRD-S',
    body: 'You spent Rs.40016 on your SBI Credit Card and are eligible for conversion to Flexipay EMIs.',
  }).reason, 'non_transaction_message');
  assert.notEqual(parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Your credit card bill of Rs.5000 is due on 25 Oct. Get cashback when you pay.',
  }).reason, 'non_transaction_message');
  const purchase = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Purchase of Rs.1200 at AMAZON completed. Offer valid for next order.',
  });
  assert.notEqual(purchase.reason, 'security_message');
  assert.notEqual(purchase.reason, 'non_transaction_message');
});

test('email offers and unlabeled time-limited codes are screened', () => {
  assert.equal(parseSmsAgainstPatterns([], {
    sender: 'deals@example.com',
    body: 'Apply now for a credit card and get a Rs.500 voucher.',
  }).reason, 'non_transaction_message');
  assert.equal(parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: '123456 valid for 10 minutes. Do not share this code.',
  }).reason, 'security_message');
});

test('credit-limit and balance notices are not treated as incoming money', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'BANK',
    body: 'Your account credit limit is Rs. 50,000. Available balance is Rs. 12,000.',
  });
  assert.equal(result.ok, false);
});

test('an actual purchase on a credit card remains spend', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Spent Rs 48 at AIRTEL on your HDFC Bank Credit Card ending 8708 on 2026-10-02.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.instrument, 'credit_card');
});

test('autopay reminder without a posted amount creates no transaction', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'SLICE',
    body: 'Your credit card bill will be debited on 05-10-2026 via autopay from savings account ending 5799.',
  });
  assert.equal(result.ok, false);
});

test('a specific richer configured pattern wins over an open generic pattern', () => {
  const open = {
    id: 'open',
    sender_pattern: null,
    regex: 'INR ([0-9]+) spent',
    field_map: { amount: 1 },
    version: 99,
  };
  const specific = { ...ICICI_PATTERN, version: 1 };
  const result = parseSmsAgainstPatterns([open, specific], {
    sender: 'AD-ICICIB',
    body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  });
  assert.equal(result.patternId, 'p-icici-1');
  assert.equal(result.fields.merchant, 'SWIGGY');
});

test('redactSmsShape strips digits to # and collapses letter runs to X, leaving no digits (matches parser_failures CHECK)', () => {
  const shape = redactSmsShape('Rs.1,499.00 spent on HDFC Card ending 4321 at AMAZON on 04-08-26');
  assert.doesNotMatch(shape, /\d/);
  assert.doesNotMatch(shape, /[A-Za-z]{2,}/);
});

test('built-in UPI debit fallback parses a bank-account SMS without treating the account suffix as a card', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs 640 debited from HDFC Bank A/c XX1797 via UPI to SWIGGY on 19-09-26. UPI Ref No 107392990952',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 640);
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.last4, undefined);
  assert.equal(result.fields.reference, '107392990952');
});

test('declined UPI alerts are never converted into spending', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'UPI Transaction Declined for your HDFC Bank account ending 1797 for security reasons',
  });
  assert.equal(result.ok, false);
});

test('built-in card fallback handles a QR/card alert when no issuer pattern is configured', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs.1,250 debited from your HDFC Bank Credit Card ending 8708 at CAFE via UPI on 19-09-26',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 1250);
  assert.equal(result.fields.last4, '8708');
  assert.equal(result.fields.instrument, 'credit_card');
});

test('built-in card fallback handles a single-x mask, rupee symbol, and ISO date', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Spent ₹210 from HDFC Bank Card x8406 at QUALITY FUEL STATION on 2025-08-14. Available limit ₹12,000.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 210);
  assert.equal(result.fields.last4, '8406');
  assert.equal(result.fields.merchant, 'QUALITY FUEL STATION');
  assert.equal(result.fields.date, '2025-08-14');
});

test('ATM withdrawal alerts are debit-card transactions, not credit-card purchases', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs.20000 withdrawn from HDFC Bank Card x8406 at PONDA BR on 2026-03-31:21:23:47 Bal Rs.136232.02 Not You? SMS BLOCK DC 8406',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 20000);
  assert.equal(result.fields.instrument, 'debit_card');
  assert.equal(result.fields.last4, '8406');
  assert.equal(result.fields.entryKind, 'transfer');
});

test('a posted mutual fund SIP is an investment, not consumption', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Your HDFC Bank A/c *1797 was debited by Rs.5000 for Mutual Fund SIP on 13/10/26. Ref 131234538577',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'investment');
  assert.equal(result.fields.accountLast4, '1797');
});

test('broker funding debits are investments, not spend or subscriptions', () => {
  const messages = [
    'Your A/c *1797 is debited by Rs.5000 towards Groww. Ref 131234538577',
    'INR 5000 transferred to Zerodha for adding funds from HDFC Bank A/c *1797.',
    'Funds added to your Upstox trading account for Rs.2500. UTR 123456789012.',
  ];
  for (const body of messages) {
    const result = parseSmsAgainstPatterns([], { sender: 'HDFCBK', body });
    assert.equal(result.ok, true, body);
    assert.equal(result.fields.entryKind, 'investment', body);
    assert.notEqual(result.fields.entryKind, 'spend', body);
    assert.notEqual(result.fields.merchant, 'Bank transfer', body);
  }
});

test('broker fund acknowledgements are not incoming salary or income', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'ZERODHA',
    body: 'Funds credited to your Zerodha trading account: Rs.5000.00. Ref 123456789012.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_investment_movement');
  assert.equal(result.fields.entryKind, 'investment');
  assert.equal(result.fields.merchant, 'Zerodha');
});

test('explicit debit-card purchase alerts stay debit-card transactions', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs.850 debited from HDFC Bank Debit Card ending 8406 at LOCAL CAFE on 2026-10-13. SMS BLOCK DC 8406',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 850);
  assert.equal(result.fields.last4, '8406');
  assert.equal(result.fields.instrument, 'debit_card');
});

test('built-in card fallback handles the bare HDFC Card NNNN format and underscore merchant', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'JD-HDFCBK-S',
    body: 'Rs.1229 spent on HDFC Bank Card 8708 at _ABHIKSHA PALACE. on 2026-07-18:21:32:14.Not U? To Block & Reissue',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 1229);
  assert.equal(result.fields.last4, '8708');
  assert.equal(result.fields.merchant, 'ABHIKSHA PALACE');
  assert.equal(result.fields.date, '2026-07-18');
});

test('built-in UPI fallback stops merchant extraction before the source-account clause', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: '₹500 sent to merchant@upi from your account via UPI on 2025-08-14. UPI Ref 627289108470',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 500);
  assert.equal(result.fields.merchant, 'merchant@upi');
  assert.equal(result.fields.instrument, 'upi_bank');
});

test('account debit without a payee needs review instead of inflating spending', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'UBIN-BANK',
    body: 'A/c *8565 Debited for Rs:2.00 on 08-07-2025 12:50:01 by Mob Bk ref no 4987654321 Avl Bal Rs 900.00',
  });

  assert.equal(result.ok, false);
});

test('explicit own-account transfer is recorded as a transfer, not spending', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'VM-HDFCBK-T',
    body: 'Sent Rs.5000.00 From your HDFC Bank A/C *1797 To your Canara Bank A/C *5702 On 13/10/26 Ref 131234538577 Not You?',
  });

  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_account_transfer');
  assert.equal(result.fields.amountInr, 5000);
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.accountLast4, '1797');
  assert.equal(result.fields.transferParty, 'your Canara Bank A/C');
  assert.equal(result.fields.transferKind, 'account_to_account');
  assert.equal(result.fields.date, '13/10/26');
  assert.equal(result.fields.reference, '131234538577');
});

test('incoming leg of an own-account transfer is not income', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'CANARA',
    body: 'Your Canara Bank account *5702 was credited with Rs.5000 from your HDFC Bank account *1797 to your Canara Bank account *5702. Ref 131234538577',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'transfer');
  assert.equal(result.fields.accountLast4, '5702');
});

test('a payment to a named person remains money out, not a self-transfer', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Sent Rs.5000.00 From HDFC Bank A/C *1797 To ANOTHER PERSON On 13/10/26 Ref 131234538577',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.transferKind, 'payment_to_person');
});

test('named mobile-banking beneficiary debit is imported as a cardless spend', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'VA-UNIONNB-T',
    body: 'Union Bank of India A/c *8565 Debited Rs:4000.00 on 13-10-2026 19:30:59 by Mob Bk ref no 104241294136, Fvg: HANDRICH Avl Bal Rs:28995.92.',
  });

  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_beneficiary_debit');
  assert.equal(result.fields.amountInr, 4000);
  assert.equal(result.fields.merchant, 'HANDRICH');
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.accountLast4, '8565');
  assert.equal(result.fields.entryKind, 'spend');
  assert.equal(result.fields.date, '13-10-2026');
  assert.equal(result.fields.reference, '104241294136');
  assert.equal(result.fields.availableBalanceInr, 28995.92);
});

test('transaction matrix auto-classifies bank, UPI, debit-card and credit-card alerts', () => {
  const cases = [
    {
      body: 'A/c *8565 Debited Rs:4000.00 on 13-10-2026 by Mob Bk ref no 104241294136, Fvg: HANDRICH',
      instrument: 'upi_bank',
      entryKind: 'spend',
      parserKind: 'builtin_beneficiary_debit',
    },
    {
      body: 'Rs 640 debited from HDFC Bank A/c XX1797 via UPI to SWIGGY on 19-09-26. UPI Ref No 107392990952',
      instrument: 'upi_bank',
      entryKind: 'spend',
      parserKind: undefined,
    },
    {
      body: 'Rs.850 debited from HDFC Bank Debit Card ending 8406 at LOCAL CAFE on 2026-10-13',
      instrument: 'debit_card',
      entryKind: 'spend',
      parserKind: undefined,
    },
    {
      body: 'Rs.1250 spent on HDFC Bank Credit Card ending 8708 at AMAZON on 2026-10-13',
      instrument: 'credit_card',
      entryKind: 'spend',
      parserKind: undefined,
    },
    {
      body: 'Sent Rs.5000.00 From your HDFC Bank A/C *1797 To your Canara Bank A/C *5702 On 13/10/26 Ref 131234538577',
      instrument: 'upi_bank',
      entryKind: 'transfer',
      parserKind: 'builtin_account_transfer',
    },
  ];

  for (const scenario of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'MATRIX-BANK', body: scenario.body });
    assert.equal(result.ok, true, scenario.body);
    assert.equal(result.fields.instrument, scenario.instrument, scenario.body);
    assert.equal(result.fields.entryKind, scenario.entryKind, scenario.body);
    if (scenario.parserKind) assert.equal(result.parserKind, scenario.parserKind, scenario.body);
  }
});

test('built-in UPI fallback stops merchant extraction before parenthesized reference metadata', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'SLICE-BANK',
    body: 'Rs.293 sent from a/c xx5799 on 18-Jul-26 to ekart (UPI Ref 123456789012)',
  });

  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 293);
  assert.equal(result.fields.merchant, 'ekart');
  assert.equal(result.fields.date, '18-Jul-26');
});

test('configured patterns cannot misclassify a bank-account UPI alert as a card spend', () => {
  const broadPattern = {
    id: 'p-wrong-instrument',
    sender_pattern: 'HDFCBK',
    regex: 'Rs\\s([\\d]+) sent to ([A-Za-z0-9@]+) using (credit_card)',
    field_map: { amount: 1, merchant: 2, instrument: 3 },
  };
  const result = parseSmsAgainstPatterns([broadPattern], {
    sender: 'VM-HDFCBK-S',
    body: 'Rs 500 sent to TESTMERCHANT@upi using credit_card from your account via UPI on 2026-10-02',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.last4, undefined);
});

test('configured patterns cannot override explicit debit-card evidence as credit', () => {
  const broadPattern = {
    id: 'p-wrong-card-type',
    sender_pattern: 'HDFCBK',
    regex: 'Rs\\s([\\d]+) debited from HDFC Bank Debit Card ending (\\d{4})',
    field_map: { amount: 1, last4: 2, instrument: 2 },
  };
  const result = parseSmsAgainstPatterns([broadPattern], {
    sender: 'VM-HDFCBK-S',
    body: 'Rs 850 debited from HDFC Bank Debit Card ending 8406 at LOCAL CAFE',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.last4, '8406');
  assert.equal(result.fields.instrument, 'debit_card');
});

test('OTP/security alerts are rejected even when they contain transaction-shaped fields', () => {
  const otp = {
    sender: 'VM-HDFCBK-S',
    body: 'OTP is 643697 for txn of INR 889.46 at TATAPAYMENT on HDFC Bank card ending 1366. Valid till 07:25. Do not share OTP.',
  };
  const broadPattern = {
    id: 'p-broad',
    regex: 'INR ([\\d.]+).*card ending (\\d{4})',
    field_map: { amount: 1, last4: 2 },
  };
  assert.equal(parseSms(broadPattern, otp).reason, 'security_message');
  assert.equal(parseSmsAgainstPatterns([broadPattern], otp).ok, false);
});

test('synthetic live-SMS matrix auto-parses completed spend alerts and rejects non-spends', () => {
  const cases = [
    {
      name: 'HDFC x-mask card spend',
      body: 'Spent Rs.210 From HDFC Bank Card x8406 At QUALITY FUEL STATION On 2026-10-02:13:50:00 Bal Rs.91903.82 Not You?',
      expected: { amountInr: 210, last4: '8406', merchant: 'QUALITY FUEL STATION', instrument: 'other' },
    },
    {
      name: 'HDFC bare card suffix spend',
      body: 'Rs.1229 spent on HDFC Bank Card 8708 at _ABHIKSHA PALACE. on 2026-10-02:13:51:00 Not U?',
      expected: { amountInr: 1229, last4: '8708', merchant: 'ABHIKSHA PALACE', instrument: 'other' },
    },
    {
      name: 'UPI debit',
      body: 'Rs 500 sent to TESTMERCHANT@upi from your account via UPI on 2026-10-02. UPI Ref 627289108470',
      expected: { amountInr: 500, merchant: 'TESTMERCHANT@upi', instrument: 'upi_bank', reference: '627289108470' },
    },
  ];

  for (const scenario of cases) {
    const result = parseSmsAgainstPatterns([], { sender: 'SYNTHETIC-BANK', body: scenario.body });
    assert.equal(result.ok, true, scenario.name);
    for (const [field, value] of Object.entries(scenario.expected)) {
      assert.equal(result.fields[field], value, `${scenario.name}: ${field}`);
    }
  }

  const rejected = [
    'TXN DECLINED: Rs.400.00 on 2026-10-02 at 13:52 on HDFC Bank Debit Card xx8406. Reason: Tap and Pay usage disabled',
    'Transaction Reversed! On HDFC Bank CREDIT Card xx8708 Amt: Rs.103.49 By TEST MERCHANT On 2026-10-02:13:53:00',
  ];
  for (const body of rejected) {
    const result = parseSmsAgainstPatterns([], { sender: 'SYNTHETIC-BANK', body });
    assert.equal(result.ok, false, body);
    assert.equal(result.reason, 'not_a_successful_spend', body);
  }

  const otp = parseSmsAgainstPatterns([], {
    sender: 'SYNTHETIC-BANK',
    body: 'OTP is 643697 for txn of INR 889.46 at TESTPAYMENT on HDFC Bank card ending 1366. Valid till 07:25. Do not share OTP.',
  });
  assert.equal(otp.ok, false);
  assert.equal(otp.reason, 'security_message');
});

test('promotional prices and service notices do not become transactions', () => {
  const noise = [
    ['TX-WAKFTT-P', 'Treat yourself to a sofa at just Rs.28,125. Grab offer today.'],
    ['BP-SBICRD-S', 'Card trxns. of combined value Rs.40016 are eligible for conversion to EMIs.'],
    ['VA-SBIBNK-S', 'YONO services is being blocked due to suspicious txns in your account. Visit nearest branch.'],
    ['VZ-ViCARE-S', 'Call Forwarding is now active on your Vodafone idea number.'],
    ['VZ-ViCARE-S', 'Calls are being forwarded to +919876543210. To deactivate this service dial *#62#.'],
    ['VM-ZERODH', 'Zerodha Broking reported your Fund bal Rs 4500 and securities bal Rs 25000. Balances excludes your Bank.'],
    ['AD-NSEIND', 'NSE Alert: Beware of dealing in unsolicited tips through SMS. Never trade on unsolicited tips.'],
    ['VK-POLBZR', 'Your car insurance policy is due for renewal. Renew now with Policybazaar for 50% discount.'],
    ['VM-PAYTMW', 'Your wallet balance is Rs 0. Add money to wallet now and enjoy instant checkouts.'],
    ['VM-HDFCBK-S', 'Transaction Check Alert! We tried to contact and confirm txn on HDFC Bank Card 8708'],
  ];
  for (const [sender, body] of noise) {
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, body);
    assert.equal(result.reason, 'non_transaction_message', body);
  }
  const real = parseSmsAgainstPatterns([], {
    sender: 'VM-JIOINF-T',
    body: 'Recharge of Rs.349 successful. Get an additional recharge FREE.',
  });
  assert.notEqual(real.reason, 'non_transaction_message');

  const debitWithPromoFooter = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: 'Rs.1,250 debited from card XX1234 at Swiggy. Enjoy 20% off on your next order with coupon SWIGGY20.',
  });
  assert.equal(debitWithPromoFooter.ok, true);
  assert.equal(debitWithPromoFooter.fields.amountInr, 1250);
  assert.equal(debitWithPromoFooter.fields.last4, '1234');
});

test('Slice UPI credit-card alerts remain card transactions, not bank-account UPI', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'VM-SLCBNK-S',
    body: 'Rs. 80 spent on your credit card xx9080 at Shantesh gurudas gaude on 14-Jul-26 (UPI Ref: 619586155507). Not you? Call 080-4832-9999 - slice',
  });

  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 80);
  assert.equal(result.fields.last4, '9080');
  assert.equal(result.fields.merchant, 'Shantesh gurudas gaude');
  assert.equal(result.fields.instrument, 'credit_card');
});

test('credit-card account references never become bank account evidence', () => {
  const result = parseSms(HDFC_PATTERN, {
    sender: 'VM-HDFCBK',
    body: 'Rs.100 spent on your HDFC Bank Card ending 8708 at SHOP on 04-08-26. Credit card account ending 8708.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.accountLast4, undefined);
});

test('an AutoPay bill notice is a bill, never a purchase', () => {
  // The issuer states the amount that WILL be deducted for the card bill.
  // Read as a spend it invents a transaction for money that has not moved —
  // and it moves the card's limit state with it.
  const alert = parseSmsAgainstPatterns([], {
    sender: 'VD-HDFCBK-S',
    body:
      'AutoPay Alert! \n Your HDFC Bank Credit Card 8708 bill \n Total Amt: Rs.10944 \n will be deducted from your A/C 1797 on 09/OCT/2026. Ignore if paid',
  });
  assert.equal(alert.ok, false);

  const reminder = parseSmsAgainstPatterns([], {
    sender: 'VM-HDFCBN-S',
    body:
      'AutoPay Reminder: \n Rs.1147 will be deducted from HDFC Bank A/c 1797 on 08/SEP/2026 for Credit Card 8708 bill. \n For Query: Ask EVA resu.io/ZPCKZ7',
  });
  assert.equal(reminder.ok, false);
});

test('a real card purchase is still a purchase', () => {
  const spend = parseSmsAgainstPatterns([], {
    sender: 'AD-HDFCBK-S',
    body:
      'Spent Rs.85781 On HDFC Bank Card 8708 At Flipkart On 2026-10-20:22:35:07.Not You? To Block+Reissue Call 18002586161',
  });
  assert.equal(spend.ok, true);
  assert.equal(spend.fields.entryKind, 'spend');
  assert.equal(spend.fields.amountInr, 85781);
  assert.equal(spend.fields.last4, '8708');
});

test('security and service check alerts are recognized as non-transaction noise', () => {
  const checkAlert = 'Transaction Check Alert!\\nWe tried to contact and confirm txn on HDFC Bank Card 8708\\nAmt: 85781\\nOn: 20-10-2026 22:35:07.160\\nNot you? Call 18001600/18002600';
  assert.equal(isNonTransactionNoise('VM-HDFCBK-S', checkAlert), true);

  const callForwarding = 'Alert: Call Forwarding is now active on your mobile number. All incoming calls are being forwarded to +91-2271346602. To deactivate this service, dial ##002# from your phone.';
  assert.equal(isNonTransactionNoise('VZ-ViCARE-S', callForwarding), true);

  const realSpend = 'Spent Rs.85781 On HDFC Bank Card 8708 At Flipkart On 2026-10-20:22:35:07. Not You? Call 1800';
  assert.equal(isNonTransactionNoise('AD-HDFCBK-S', realSpend), false);
});

test('wallet debit parses as instrument wallet and entryKind spend', () => {
  const mobikwik = parseSmsAgainstPatterns([], {
    sender: 'VM-MBKWIK',
    body: 'Rs.10.0 has been debited from your MobiKwik wallet. Remaining balance: Rs.12.17',
  });
  assert.equal(mobikwik.ok, true);
  assert.equal(mobikwik.fields.instrument, 'wallet');
  assert.equal(mobikwik.fields.entryKind, 'spend');
  assert.equal(mobikwik.fields.amountInr, 10.0);
  assert.equal(mobikwik.fields.accountLast4, 'MobiKwik');
  assert.equal(mobikwik.fields.availableBalanceInr, 12.17);

  const paytm = parseSmsAgainstPatterns([], {
    sender: 'Paytm',
    body: 'Rs.50.0 debited from your Paytm wallet',
  });
  assert.equal(paytm.ok, true);
  assert.equal(paytm.fields.instrument, 'wallet');
  assert.equal(paytm.fields.entryKind, 'spend');
  assert.equal(paytm.fields.amountInr, 50.0);
  assert.equal(paytm.fields.accountLast4, 'Paytm');
});

test('card setting updates and delivery memos are recognized as non-transaction noise', () => {
  const cardSetting = 'Modification Success! Card usage settings for Credit Card ending with XX8708 modified';
  assert.equal(isNonTransactionNoise('HDFCBK', cardSetting), true);
  const cardSettingParse = parseSmsAgainstPatterns([], {
    sender: 'HDFCBK',
    body: cardSetting,
  });
  assert.equal(cardSettingParse.ok, false);
  assert.equal(cardSettingParse.reason, 'non_transaction_message');

  const deliveryMemo = 'Bharatgas cylinder is out for delivery with Cash Memo Amount Rs 926.5. Pls share Delivery Code 734900';
  assert.equal(isNonTransactionNoise('BP-BHARAT', deliveryMemo), true);
  const deliveryMemoParse = parseSmsAgainstPatterns([], {
    sender: 'BP-BHARAT',
    body: deliveryMemo,
  });
  assert.equal(deliveryMemoParse.ok, false);
  assert.equal(deliveryMemoParse.reason, 'non_transaction_message');
});

test('new noise patterns are identified as non-transaction noise in parity with Dart', () => {
  const noiseAlerts = [
    ['CDSLIN', 'CDSL: Unpledge confirmed for 100 shares in demat account.'],
    ['NSDLIN', 'NSDL: Pledge setup request initiated for a/c 1234.'],
    ['KFINTECH', 'Updated your address under folio 98765432 based on feed received from KRA.'],
    ['CAMS', 'Address in folio 12345/6 is updated based on feed received from KRA.'],
    ['HDFCBK', 'Due to scheduled maintenance NetBanking services will be unavailable from 02:00 to 05:00.'],
    ['ICICIB', 'Registration alert: device name iPhone 15 was registered on iMobile Pay.'],
    ['AMAZON', 'Reminder: 5 cashback coupons expire at midnight. Use code FESTIVE.'],
    ['DELHIV', 'Order is dispatched through Delhivery with tracking 123456789.'],
    ['BLUEDART', 'Your order is dispatched through Blue Dart express logistics.'],
    ['FLIPKT', 'We have received your order ID OD123456789. We are preparing it for shipment.'],
    ['AXISBK', 'Lifetime-free credit card facility has been enabled for your account. Limit Rs. 2,00,000.'],
    ['BAJAJA', 'Two wheeler insurance for MH01AB1234 has expired. Renew today at Rs. 1499.'],
    ['ACKOIN', 'Car insurance expired! Renew before midnight to protect your NCB.'],
    ['HDFCER', 'Vehicle insurance for DL01CD5678 will expire tomorrow. Premium Rs 2150.'],
  ];

  for (const [sender, body] of noiseAlerts) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
  }
});

test('card control, linking and settlement explanations are non-transaction noise', () => {
  const controlNotices = [
    ['VA-SLCBNK-S', 'Your transaction limit for pinless UPI on your slice credit card has been updated. You can check and change it in the app - slice'],
    ['VM-HDFCBN-S', 'Dear Customer, Security Tip-Enable Online use & Set Limit on HDFC Bank Credit Card 1366. Use NetBanking/MyCards/WhatsApp https://1.hdfc.bank.in/HDFCBK/s/yjGKjM5'],
    ['VD-HDFCBK-S', 'HDFC Bank Credit Card has been linked for NetBanking. Pls login to NetBanking and select Credit Cards tab to view statement details or to make payment'],
    ['VK-LEMONN-S', 'Dear SUJAY SHANTARAM KURTIKAR, as per SEBI and exchange guidelines, unused funds in your Lemonn trading account will be transferred back to your registered bank account on the day of settlement.'],
  ];
  for (const [sender, body] of controlNotices) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, 'Should not mint a transaction: ' + body);
    assert.equal(result.reason, 'non_transaction_message');
  }

  const actionableMessages = [
    'Your HDFC Bank Credit Card 1366 statement has been generated. Total due INR 5,000 by 05-Nov-2026.',
    'Spent Rs 500 on HDFC Bank Credit Card 1366 at AMAZON on 20-Oct-2026.',
    'AutoPay e-mandate registered for NETFLIX with maximum limit of INR 2,000 on card XX7105.',
    'INR 5000 transferred to your bank account XXXX1234 on 20-Oct-2026.',
    'Security tip: your HDFC Bank Credit Card ending 1366 was debited INR 500 at AMAZON on 20-Oct-2026.',
    'Security Alert: Your HDFC Bank Credit Card ending 1366 was used for INR 5,000 at AMAZON on 20-Oct-2026. If not you, call 18002586161.',
    'Txn of INR 500 declined on your HDFC Bank Credit Card 1366 because it exceeds your transaction limit.',
    'Your HDFC Bank Credit Card ending 1366 credit limit has been set at INR 2,00,000.',
  ];
  for (const body of actionableMessages) {
    assert.equal(isNonTransactionNoise('VM-HDFCBK-S', body), false, 'Should not be noise: ' + body);
  }

  // A limit alert is not a spend, but the explicit amount must still reach the
  // card-limit sync path.
  const limitAlert = 'Your HDFC Bank Credit Card ending 1366 credit limit has been set at INR 2,00,000.';
  const detected = extractCreditLimit(limitAlert);
  assert.equal(detected.amountInr, 200000);
  assert.equal(detected.last4, '1366');
});

test('biller onboarding and future bill promises are non-transaction noise', () => {
  const onboardingNotices = [
    ['CP-AXISBK-S', 'You have added Goa Electricity Department 60008413407 to Axis Bank Bill Pay service. We will notify you once the bill is generated.'],
    ['AXISBK', 'You have successfully registered for paperless e-bill. We will notify you when the bill is generated.'],
    ['HDFCBK', 'Bill Pay service has been activated for your account.'],
    ['HDFCBK', 'Your first bill will be generated on 05-Nov-2026.'],
    ['AXISBK', 'BillPay registration successful. You will receive your bill every month.'],
    ['AXISBK', 'You will receive your bill on the 5th of every month.'],
    ['AXISBK', 'Bill generation date: 05-Nov-2026.'],
    ['AXISBK', 'Bill fetch is now enabled for your biller.'],
    ['AXISBK', 'Your biller will send you the bill every month.'],
    ['HDFCBK', 'You have added Goa Electricity Department as a payee.'],
  ];
  for (const [sender, body] of onboardingNotices) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, 'Should not mint a bill: ' + body);
    assert.equal(result.reason, 'non_transaction_message');
  }

  const actionableBillMessages = [
    'Your electricity bill of Rs 1,200 is generated. Due on 05-Nov-2026.',
    'Bill payment of Rs 500 scheduled on 05-Nov-2026.',
    'You have added Goa Electricity Department to Bill Pay with AutoPay maximum limit INR 2,000.',
    'Your bill is due today. Login to view.',
    'Your first bill will be generated on 05-Nov-2026. Total due INR 500.',
    'You have added Goa Electricity Department to Bill Pay. Bill payment failed.',
  ];
  for (const body of actionableBillMessages) {
    assert.equal(isNonTransactionNoise('AXISBK', body), false, 'Should not be noise: ' + body);
  }
});

test('telecom retention deductions, airtime charges, and recharge reminders with 10-digit numbers are non-transaction noise', () => {
  const noiseMessages = [
    ['JZ-JIOPAY-S', 'Number retention charges of Rs. 9.88 has been deducted from Top-up balance on Jio Number 8010377706 as there was no usage observed for last 90 days. Kindly recharge your Jio Number with a valid plan to avoid these charges in future. To recharge, click http://tiny.jio.com/dmyjiorchgpl'],
    ['VD-axioPL-S', 'Congrats Sujay, We have received your timely repayment towards your Pay Later XXX6016 a/c .You can now check your updated personal loan eligibility here https://u.axio.ac/axo/1XOUraa9OMgJw7 -axio'],
    ['AD-AIRTEL-S', 'Recharge your Airtel number 9876543210 with Rs 299 to get unlimited calls and 1.5GB/day validity 28 days.'],
    ['AD-AIRTEL-S', 'Rs. 10.00 debited from talktime balance on Airtel mobile 9876543210 towards value added service.'],
    ['VI-CARE', 'Recharge your Vi number 9822012345 to get unlimited calls and data pack. Hurry!'],
    ['VI-CARE', 'Rs. 20 deducted from main balance on Vi prepaid number 9822012345.'],
    ['DZ-BSNL-S', 'Recharge your BSNL prepaid number 9443210987 with Rs 199 for 30 days validity.'],
    ['DZ-BSNL-S', 'Rs 5 debited from core balance on BSNL number 9443210987.'],
  ];
  for (const [sender, body] of noiseMessages) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, 'Should not match transaction: ' + body);
    assert.equal(result.reason, 'non_transaction_message');
  }
});

test('bank debits for mobile recharge with masked account or card are not noise', () => {
  const bankRechargeMessages = [
    ['VM-HDFCBK-S', 'A/c XX1234 debited Rs 299 for Jio recharge on 8010377706 on 25-Oct-26.'],
    ['SBIINB', 'Dear SBI User, your A/c ending in 5678 debited by Rs. 299 on 25-Oct-26 for Vi recharge on 9822012345.'],
    ['AXISBK', 'Card ending 4321 debited INR 499 towards Airtel recharge on 9876543210 on 25-10-26.'],
    ['HDFCBK', 'A/c XX9876 debited Rs. 199 for BSNL prepaid recharge on 9443210987.'],
  ];
  for (const [sender, body] of bankRechargeMessages) {
    assert.equal(isNonTransactionNoise(sender, body), false, 'Should not be noise: ' + body);
  }
});

test('postpaid telecom bills with amount due or bill generated are not noise', () => {
  const postpaidBillMessages = [
    ['AD-AIRTEL-S', 'Airtel postpaid bill of Rs 599 for 9876543210 is generated. Due date 15-Nov'],
    ['JZ-JIOPAY-S', 'Jio postpaid bill of Rs 399 generated for 8010377706. Amount due: Rs 399, due date 20-Nov-2026.'],
    ['VI-CARE', 'Vi Postpaid: Bill generated for mobile 9822012345. Total amount due Rs. 701 by 12-Nov-2026.'],
    ['DZ-BSNL-S', 'BSNL Postpaid bill of Rs 450 generated for 9443210987. Payment due date is 21-Nov-2026.'],
  ];
  for (const [sender, body] of postpaidBillMessages) {
    assert.equal(isNonTransactionNoise(sender, body), false, 'Should not be noise: ' + body);
  }
});

test('mutual fund folio unit allotment does not create a cash spend or duplicate investment transaction', () => {
  const amcMessages = [
    'Folio 12345/67: Purchase of Rs 5000 in HDFC Top 100 Fund processed. 54.321 units allotted at NAV 92.0450 on 05-Oct-2026.',
    'Dear Investor, 45.123 units allotted under Folio 9876543/21 in Nippon India Small Cap Fund - Reg (G) for your investment of Rs 5,000 at NAV 110.8123 on 05-Oct-2026.',
    'Units: 25.432, NAV: 196.50 allotted for your investment of Rs. 5000 in Parag Parikh Flexi Cap Fund, Folio: 123456789.',
    'Units allotted under folio 11223344 for Rs 10000 in ICICI Prudential Bluechip Fund. NAV: 85.25.',
  ];

  for (const body of amcMessages) {
    assert.equal(isInvestmentFolioAllotment(body), true);
    assert.equal(isNonTransactionNoise('HDFCMF', body), false);
    const result = parseSmsAgainstPatterns([], { sender: 'HDFCMF', body });
    assert.equal(result.ok, false);
    assert.equal(result.reason, 'mf_folio_unit_allotment');
    assert.equal(result.isObservation, true);
    assert.ok(result.fields.amountInr > 0);
  }
});

test('Scapia txn-of card purchase parses without card last4 or configured patterns', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'AD-FEDSCP-S',
    body: 'Your txn of ₹1,018 at 3 Rajdhani Parantha House on your Scapia Federal RuPay credit card earned you 5% rewards!',
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'conservative_fallback');
  assert.equal(result.fields.amountInr, 1018);
  assert.equal(result.fields.merchant, '3 Rajdhani Parantha House');
  assert.equal(result.fields.last4, undefined);
});

test('AutoPay activation and mandate notices are not flagged as noise and do not mint fake cash spend', () => {
  const autoPaySetupMessages = [
    'AutoPay activation successful.\nTxn amt: INR 0.00\nMerchant: OpenAILLC\nAxis Bank Card no.: XX7105\nMax limit: INR 1999.00\n...',
    'AutoPay activation successful. Txn amt: INR 0.00 Merchant: OpenAI LLC Axis Bank Card no.: XX7105 Max limit: INR 1999.00.',
    'AutoPay e-mandate successfully registered for NETFLIX with maximum limit of INR 2,000.00 on Axis Bank Card no.: XX7105',
    'Standing Instruction created towards AGIONE TEC. Max limit: INR 500.00 on card ending 1234.',
  ];

  for (const body of autoPaySetupMessages) {
    assert.equal(isNonTransactionNoise('VM-AXISBK-S', body), false, 'Should not be flagged as noise: ' + body);
    const result = parseSmsAgainstPatterns([], { sender: 'VM-AXISBK-S', body });
    assert.equal(result.ok, false, 'Should not mint a spend transaction: ' + body);
    assert.equal(result.reason, 'card_bill_notice');
  }
});

test('completed AutoPay debit of a real purchase still parses as spend', () => {
  const body = 'AutoPay debit of INR 1000 on credit card XX7105 at NETFLIX was successful on 18-Oct-2026.';
  assert.equal(isNonTransactionNoise('VM-AXISBK-S', body), false);
  const result = parseSmsAgainstPatterns([], { sender: 'VM-AXISBK-S', body });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 1000);
  assert.equal(result.fields.last4, '7105');
  assert.equal(result.fields.merchant, 'NETFLIX');
  assert.equal(result.fields.entryKind, 'spend');
});

test('merchant name extraction extracts Merchant: <Name> and created towards <Name>', () => {
  // 1. Card spend with Merchant: <Name>
  const cardWithMerchantLabel = parseSmsAgainstPatterns([], {
    sender: 'AD-AXISBK',
    body: 'Spent INR 500.00 on Axis Bank Card XX7105 on 20-Oct-2026. Merchant: OpenAILLC. Avl limit: INR 45000.',
  });
  assert.equal(cardWithMerchantLabel.ok, true);
  assert.equal(cardWithMerchantLabel.fields.merchant, 'OpenAILLC');
  assert.equal(cardWithMerchantLabel.fields.amountInr, 500);

  // 2. Card spend with created towards <Name>
  const cardWithCreatedTowards = parseSmsAgainstPatterns([], {
    sender: 'AD-AXISBK',
    body: 'INR 250.00 debited from card XX7105 created towards AGIONE TEC on 20-Oct-2026.',
  });
  assert.equal(cardWithCreatedTowards.ok, true);
  assert.equal(cardWithCreatedTowards.fields.merchant, 'AGIONE TEC');
  assert.equal(cardWithCreatedTowards.fields.amountInr, 250);

  // 3. UPI debit with Merchant: <Name>
  const upiWithMerchantLabel = parseSmsAgainstPatterns([], {
    sender: 'AX-AXISBK',
    body: 'INR 350.00 debited from A/C XX1234 on 20-Oct-2026. Merchant: OpenAILLC. UPI Ref: 123456789012.',
  });
  assert.equal(upiWithMerchantLabel.ok, true);
  assert.equal(upiWithMerchantLabel.fields.merchant, 'OpenAILLC');
  assert.equal(upiWithMerchantLabel.fields.amountInr, 350);

  // 4. UPI debit with created towards <Name>
  const upiWithCreatedTowards = parseSmsAgainstPatterns([], {
    sender: 'AX-AXISBK',
    body: 'INR 450.00 debited from A/C XX1234 on 20-Oct-2026 created towards AGIONE TEC. UPI Ref: 123456789012.',
  });
  assert.equal(upiWithCreatedTowards.ok, true);
  assert.equal(upiWithCreatedTowards.fields.transferParty || upiWithCreatedTowards.fields.merchant, 'AGIONE TEC');
  assert.equal(upiWithCreatedTowards.fields.amountInr, 450);
});

test('gambling and betting spam is identified as non-transaction noise', () => {
  const gamblingAlerts = [
    ['CP-DISHTV-S', 'GullyBET: Play online casino, slots & aviator with huge bonus up to 100%. Bet and win now: gbets.win'],
    ['CP-DISHTV-S', 'Huge bonus on India\'s top betting app! Instant withdrawal of your winnings. Play casino and slots on GullyBET now.'],
    ['CP-DISHTV-S', 'Teen patti & live casino on GullyBET! Rs. 500 bonus credited on first deposit. Bet now at gbets.win'],
    ['CP-GAMBLE', 'Join top online gambling & betting site today! Play aviator, slots & cockfight with huge bonus.'],
    ['CP-DISHTV-S', 'GullyBET: Fast withdrawal of Rs. 2,000 bonus. Win big on casino and fancy bet!'],
  ];

  for (const [sender, body] of gamblingAlerts) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, 'Should not match transaction for: ' + body);
    assert.equal(result.reason, 'non_transaction_message');
  }
});

test('loan and credit limit marketing notices without currency amount are non-transaction noise', () => {
  const limitMarketingAlerts = [
    ['VK-BFDLPS-S', 'New credit alert! Your loan limit is revised. Visit Bajaj Markets to view your updated limit.'],
    ['VK-BFDLPS-S', 'Dear customer, your loan limit is revised. Check your revised limit on Bajaj Markets app now.'],
    ['VK-BFDLPS-S', 'New credit alert: loan limit has been increased. Check updated limit here.'],
    ['AD-LOANS', 'Good news! Your credit limit is revised. Tap to view your updated limit.'],
  ];

  for (const [sender, body] of limitMarketingAlerts) {
    assert.equal(isNonTransactionNoise(sender, body), true, 'Expected noise for: ' + body);
    const result = parseSmsAgainstPatterns([], { sender, body });
    assert.equal(result.ok, false, 'Should not match transaction for: ' + body);
    assert.equal(result.reason, 'non_transaction_message');
  }
});

test('real ATM cash withdrawals and real salary or UPI credits are not noise', () => {
  // Counter-tests specifically required by specification
  assert.equal(isNonTransactionNoise('VM-HDFCBK-S', 'Cash withdrawal of Rs. 2,000 from A/c XX1234'), false);
  assert.equal(isNonTransactionNoise('VM-HDFCBK-S', 'Rs. 50,000 credited to A/c XX1234'), false);

  const realMovements = [
    ['VM-HDFCBK-S', 'Cash withdrawal of Rs. 2,000 from A/c XX1234 on 24-Oct-2026. Avl Bal Rs. 45,000.'],
    ['VM-HDFCBK-S', 'Rs. 50,000 credited to A/c XX1234 on 24-Oct-2026 by Salary. Avl Bal Rs. 95,000.'],
    ['AD-ICICIB', 'Rs. 2,000.00 credited to A/c XX5678 on 24-Oct-2026 via UPI.'],
    ['VM-SBIINB-S', 'Dear Customer, Cash withdrawal of Rs. 2,000 from A/c XX1234 at ATM on 24-Oct-2026.'],
  ];

  for (const [sender, body] of realMovements) {
    assert.equal(isNonTransactionNoise(sender, body), false, 'Should not be noise: ' + body);
  }
});


test('Axio Amazon Pay Later drawdown parses as spend transaction with merchant Amazon Pay Later', () => {
  const drawdowns = [
    {
      sender: 'AX-axioFS-S',
      body: 'Thank you for availing Pay Later credit of Rs299.0. For more info click https://u.axio.ac/axo/UqpJfCtWpqntk To report misuse call 180012001637 -axio',
      amountInr: 299,
    },
    {
      sender: 'VM-axioFS-S',
      body: 'Thank you for availing Pay Later credit of Rs859.0. For more info click https://u.axio.ac/axo/OIzBfFTIVHRH30R To report misuse call 180012001637 -axio',
      amountInr: 859,
    },
  ];

  for (const item of drawdowns) {
    const result = parseSmsAgainstPatterns([], { sender: item.sender, body: item.body });
    assert.equal(result.ok, true, 'Failed to parse: ' + item.body);
    assert.equal(result.parserKind, 'builtin_pay_later_drawdown');
    assert.equal(result.fields.amountInr, item.amountInr);
    assert.equal(result.fields.merchant, 'Amazon Pay Later');
    assert.equal(result.fields.entryKind, 'spend');
    assert.equal(result.fields.instrument, 'other');
    assert.equal(result.fields.accountLast4, 'Amazon Pay Later');
  }
});

test('Axis UPI P2M narration names the merchant after a masked reference', () => {
  const body = 'INR 12.00 debited\n'
    + 'A/c no. XX2583\n'
    + '21-10-26, 22:41:20\n'
    + 'UPI/P2M/**** 6977/MANYAM VISWANADA RE\n'
    + 'Not you? SMS BLOCKUPI Cust ID to **** 0002\n'
    + 'Axis Bank';
  const result = parseSmsAgainstPatterns([], { sender: 'AD-AXISBK-S', body });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 12);
  assert.equal(result.fields.merchant, 'MANYAM VISWANADA RE');
});

test('UPI P2M narration without a party token does not invent a merchant', () => {
  const body = 'INR 12.00 debited\nA/c no. XX2583\n21-10-26, 22:41:20\n'
    + 'UPI/P2M/**** 6977\nNot you? SMS BLOCKUPI Cust ID to **** 0002';
  const result = parseSmsAgainstPatterns([], { sender: 'AD-AXISBK-S', body });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 12);
  assert.ok(!result.fields.merchant || !/^P2M$/i.test(result.fields.merchant));
});

test('"debited towards X for INR" names X and never the VPA hash', () => {
  const body = 'Your A/c has been debited towards Google Play for INR 4999.00 '
    + 'on 10-10-26. '
    + '9901e1edad8e46cd937da209ef0baf55@axl - Axis Bank';
  const result = parseSmsAgainstPatterns([], { sender: 'AD-AXISBK-S', body });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 4999);
  assert.equal(result.fields.merchant, 'Google Play');
  assert.notEqual(result.fields.merchant, 'Bank transfer');
});
