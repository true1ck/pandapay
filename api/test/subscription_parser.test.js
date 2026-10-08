const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSubscriptionMandate } = require('../src/subscription_parser');

test('parses a confirmed UPI monthly mandate without creating a spend', () => {
  const result = parseSubscriptionMandate({
    body: 'UPI AutoPay mandate for ChatGPT has been created. Amount Rs. 499 every month. UPI Ref 1234567890.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.merchant, 'ChatGPT');
  assert.equal(result.fields.amountInr, 499);
  assert.equal(result.fields.cadenceDays, 30);
  assert.equal(result.fields.instrument, 'upi_bank');
});

test('recognizes a card subscription mandate and card suffix', () => {
  const result = parseSubscriptionMandate({
    body: 'Recurring payment instruction registered for Netflix on your HDFC credit card ending 8708. Monthly amount INR 649.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.fields.merchant, 'Netflix');
  assert.equal(result.fields.last4, '8708');
  assert.equal(result.fields.instrument, 'card');
});

test('does not treat a bill autopay reminder as a subscription mandate', () => {
  const result = parseSubscriptionMandate({
    body: 'Your credit card bill will be debited on 05-10-2026 via autopay from savings account.',
  });
  assert.equal(result.ok, false);
});

test('does not guess a merchant from an unrelated mandate notice', () => {
  const result = parseSubscriptionMandate({
    body: 'Your standing instruction has been confirmed. Amount Rs. 250 will be debited monthly.',
  });
  assert.equal(result.ok, false);
});

test('does not treat a cancelled UPI mandate as a subscription', () => {
  const result = parseSubscriptionMandate({
    body: 'Your UPI-Mandate is successfully cancelled towards OpenAI LLC for 1999.00 from A/c No.XXXXXXXX8648. UMN:df897d943114d6183eb-b0262e63efe2@ybl -SBI',
  });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'non_mandate_alert');
});

test('rejects dates, account numbers, and cadence labels as merchants', () => {
  for (const merchant of ['7308080808', '31/12/2035', 'MONTHLY']) {
    const result = parseSubscriptionMandate({
      body: `UPI AutoPay mandate for ${merchant} has been created. Amount Rs. 1,649 every month.`,
    });
    assert.equal(result.ok, false, merchant);
    assert.equal(result.reason, 'mandate_merchant_invalid', merchant);
  }
});
