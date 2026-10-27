'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  CANONICAL_MERCHANT_ALIASES,
  cleanMerchantName,
  isWeakMerchantName,
  merchantEvidence,
} = require('../src/merchant_identity');

const BALAJI =
  'Hello, your payment of Rs. 700.0 to Balaji Sports has been recorded. '
  + 'View the payment receipt here: https://mybillbook.in/cpp/?t=ljbffep4r - myBillBook';
const SBI =
  'Dear UPI User A/C X5121 debited by 50.00 on date 17Oct26 trf to Sunali Mundra '
  + 'Refno 665663775318 If not u? call-1800111109 for other services-18001234-SBI';

test('cleans receipt boilerplate and payment-app signatures', () => {
  assert.equal(cleanMerchantName('Balaji Sports'), 'Balaji Sports');
  assert.equal(cleanMerchantName('"Balaji Sports"'), 'Balaji Sports');
  assert.equal(cleanMerchantName('Balaji Sports has been recorded'), 'Balaji Sports');
  assert.equal(cleanMerchantName('Balaji Sports - myBillBook'), 'Balaji Sports');
  assert.equal(cleanMerchantName('other services-18001234-SBI'), null);
});

test('rejects hash, reference and account-like IDs without rejecting brands', () => {
  for (const value of [
    'ljbffep4r',
    '665663775318',
    'X5121',
    'REF123456',
    'HDFC0001234',
    'https://mybillbook.in/cpp/?t=ljbffep4r',
  ]) {
    assert.equal(isWeakMerchantName(value), true, value);
  }
  for (const value of ['7-Eleven', '99acres', '3M', '24x7', 'Café Müller', 'सुजय स्टोर्स']) {
    assert.equal(isWeakMerchantName(value), false, value);
    assert.equal(cleanMerchantName(value), value);
  }
});

test('canonical and derived labels are preserved as identities', () => {
  for (const alias of CANONICAL_MERCHANT_ALIASES) {
    assert.equal(cleanMerchantName(alias), alias);
    assert.equal(isWeakMerchantName(alias), false, alias);
  }
  assert.equal(cleanMerchantName('Transfer to Sunali Mundra'), 'Transfer to Sunali Mundra');
  assert.equal(cleanMerchantName('Transfer to ljbffep4r'), null);
});

test('grounds direct names and derived transfer labels in the SMS', () => {
  assert.equal(merchantEvidence('Balaji Sports', BALAJI).ok, true);
  assert.equal(merchantEvidence('Phantom Bazaar', BALAJI).ok, false);
  assert.equal(merchantEvidence('Transfer to Sunali Mundra', SBI).ok, true);
  assert.equal(merchantEvidence('Transfer to Phantom Vendor', SBI).ok, false);
  assert.equal(merchantEvidence('Refund', 'Refund of Rs 200 credited').ok, true);
  assert.equal(merchantEvidence('Reward or cashback', 'Rs 50 debited').ok, false);
  assert.equal(merchantEvidence('Salary', 'Salary credited to A/c XX1234').ok, true);
});

test('canonical aliases require their own transaction context', () => {
  const swiggyDebit =
    'Sent Rs.420.00 from HDFC Bank A/C **1797 to SWIGGY UPI on 24-10-26. '
    + 'UPI Ref 429812345678. Avail Bal: Rs.45,120.50';
  const cardPurchase =
    'Rs 420.00 debited from your Credit Card XX1234 at Swiggy on 24-10-26.';
  const cashback = 'Rs 50 cashback credited on 24-10-26.';
  const amazonPurchase = 'Rs 500 debited for Amazon purchase on 24-10-26.';
  const liars = [
    ['Bank transfer', swiggyDebit],
    ['Credit card bill payment', cardPurchase],
    ['Card statement adjustment', cardPurchase],
    ['Amazon Pay Later', amazonPurchase],
    ['Refund', cashback],
    ['Reversal', cashback],
  ];
  for (const [alias, body] of liars) {
    assert.equal(merchantEvidence(alias, body).ok, false, `${alias}: ${body}`);
  }

  const supported = [
    ['Bank transfer', 'Rs 5,000 credited from HDFC Bank A/c XX1234 via NEFT transfer on 24-10-26.'],
    ['Credit card bill payment', 'Payment of Rs 5,000 towards your HDFC Credit Card bill on 24-10-26.'],
    ['Card statement adjustment', 'Rs 500 credited to your HDFC Credit Card on 24-10-26.'],
    ['Amazon Pay Later', 'Availing Pay Later credit of Rs 500 on 24-10-26.'],
    ['Refund', 'Refund of Rs 200 credited on 24-10-26.'],
    ['Reversal', 'Reversal of Rs 200 credited on 24-10-26.'],
    ['Reward or cashback', 'Rs 50 cashback credited on 24-10-26.'],
    ['Wallet load', 'Wallet loaded with Rs 500 on 24-10-26.'],
  ];
  for (const [alias, body] of supported) {
    assert.equal(merchantEvidence(alias, body).ok, true, `${alias}: ${body}`);
  }
});
