const test = require('node:test');
const assert = require('node:assert/strict');

const { extractCreditLimit } = require('../src/card_limit_parser');

test('extracts an explicit Indian credit limit and card suffix', () => {
  assert.deepEqual(
    extractCreditLimit('Your HDFC credit card ending 8406 has a credit limit of Rs. 1,50,000.'),
    { amountInr: 150000, last4: '8406' },
  );
});

test('supports total limit wording and rupee symbol', () => {
  assert.deepEqual(
    extractCreditLimit('Total credit limit: ₹250000 on card XXXX1234'),
    { amountInr: 250000, last4: '1234' },
  );
});

test('handles issuer alerts that announce a limit increase', () => {
  assert.deepEqual(
    extractCreditLimit('Credit limit across your Axis Bank Credit Card(s) has been increased to INR 80000 with immediate effect.'),
    { amountInr: 80000, last4: null },
  );
});

test('does not mistake available limit or amount due for the credit limit', () => {
  assert.equal(
    extractCreditLimit('Available credit limit is Rs 80,000. Amount due is Rs 12,000.'),
    null,
  );
});

