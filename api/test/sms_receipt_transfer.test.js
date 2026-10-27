'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  parseSmsAgainstPatterns,
  parseBuiltInAccountTransfer,
  parseBuiltInPaymentReceipt,
} = require('../src/sms_parser');

const SBI =
  'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct26 trf to Sunali Mundra '
  + 'Refno 665663775318 If not u? call-1800111109 for other services-18001234-SBI';
const BALAJI =
  'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
  + 'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r - myBillBook';

test('SBI currencyless transfer keeps the printed party, date and reference', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'AX-SBIUPI-S',
    body: SBI,
  });
  assert.equal(result.ok, true);
  assert.equal(result.parserKind, 'builtin_account_transfer');
  assert.equal(result.fields.amountInr, 50);
  assert.equal(result.fields.merchant, 'Transfer to Sunali Mundra');
  assert.equal(result.fields.transferParty, 'Sunali Mundra');
  assert.equal(result.fields.date, '17Oct26');
  assert.equal(result.fields.reference, '665663775318');
  assert.equal(result.fields.accountLast4, '5121');
  assert.equal(result.fields.entryKind, 'spend');
});

test('SBI transfer with a trailing available balance keeps the movement amount', () => {
  const result = parseBuiltInAccountTransfer({
    body: `${SBI} Avail Bal Rs 1200.00.`,
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 50);
  assert.equal(result.fields.availableBalanceInr, 1200);
  assert.equal(result.fields.merchant, 'Transfer to Sunali Mundra');
});

test('myBillBook receipt yields clean evidence without posting or inventing an instrument', () => {
  const result = parseSmsAgainstPatterns([], {
    sender: 'CP-MBILBK-S',
    body: BALAJI,
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'merchant_ebill_receipt');
  assert.deepEqual(result.receipt, {
    amountInr: 700,
    merchant: 'Balaji Sports',
    completed: true,
    receiptOnly: true,
    source: 'merchant_ebill',
  });
  assert.equal(result.fields, undefined);
  assert.equal(result.receipt.instrument, undefined);
});

for (const merchant of ['7-Eleven', 'Café Müller', 'सुजय स्टोर्स']) {
  test(`receipt merchant capture preserves ${merchant}`, () => {
    const result = parseSmsAgainstPatterns([], {
      sender: 'CP-MBILBK-S',
      body: `Hello, your payment of Rs. 700.0 to ${merchant} has been recorded. `
        + 'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r - myBillBook',
    });
    assert.equal(result.ok, false);
    assert.equal(result.reason, 'merchant_ebill_receipt');
    assert.equal(result.receipt.amountInr, 700);
    assert.equal(result.receipt.merchant, merchant);
    assert.equal(result.receipt.receiptOnly, true);
    assert.equal(result.fields, undefined);
  });
}

test('receipt parser rejects future, failed and download-only notices', () => {
  assert.equal(
    parseBuiltInPaymentReceipt({
      body: 'Your payment of Rs 700 to Balaji Sports will be recorded. View the payment receipt here.',
    }).reason,
    'receipt_not_completed',
  );
  assert.equal(
    parseBuiltInPaymentReceipt({
      body: 'Your payment of Rs 700 to Balaji Sports failed. View the payment receipt here.',
    }).reason,
    'receipt_not_completed',
  );
  assert.equal(
    parseBuiltInPaymentReceipt({
      body: 'Your statement has been downloaded. View the payment receipt here.',
    }).reason,
    'receipt_not_completed',
  );
});

test('boilerplate recipient fallback cannot fabricate a transfer merchant', () => {
  const result = parseBuiltInAccountTransfer({
    body: 'A/c XX5121 debited by 50.00 trf to other services-18001234-SBI',
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_transfer_destination');
});
