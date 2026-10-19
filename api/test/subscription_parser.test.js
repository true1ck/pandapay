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

test('parses a cancelled UPI mandate with cancelled lifecycle for subscription chain tracking', () => {
  const result = parseSubscriptionMandate({
    body: 'Your UPI-Mandate is successfully cancelled towards OpenAI LLC for 1999.00 from A/c No.XXXXXXXX8648. UMN:df897d943114d6183eb-b0262e63efe2@ybl -SBI',
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'cancelled');
  assert.equal(result.fields.merchant, 'OpenAI LLC');
});

test('parses Axis Bank AutoPay activation SMS with card suffix, max limit, and mandate ID', () => {
  const result = parseSubscriptionMandate({
    body: `AutoPay activation successful.
Txn amt: INR 0.00
Merchant: OpenAILLC
Axis Bank Card no.: XX7105
Max limit: INR 1999.00
ID: YhygiWSayx
Manage AutoPay at https://www.sihub.in/managesi/axisbank
We will inform you of the txn amt before any future debits initiated by OpenAILLC.
TnC apply.`,
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'active');
  assert.equal(result.fields.merchant, 'OpenAILLC');
  assert.equal(result.fields.amountInr, 1999);
  assert.equal(result.fields.last4, '7105');
  assert.equal(result.fields.instrument, 'card');
  assert.equal(result.fields.reference, 'YhygiWSayx');
  assert.equal(result.fields.cadenceDays, 30);
});

test('parses AutoPay de-activation / cancellation SMS', () => {
  const result = parseSubscriptionMandate({
    body: `AutoPay de-activation successful.
Merchant: OpenAILLC
Axis Bank Card no.: XX7105
ID: YhygiWSayx`,
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'cancelled');
  assert.equal(result.fields.merchant, 'OpenAILLC');
});

test('rejects dates, account numbers, and cadence labels as merchants', () => {
  for (const merchant of ['7308080808', '31/12/2035', 'MONTHLY']) {
    const result = parseSubscriptionMandate({
      body: `UPI AutoPay mandate for ${merchant} has been created. Amount Rs. 1,649 every month.`,
    });
    assert.equal(result.ok, false, merchant);
    assert.ok(
      result.reason === 'mandate_merchant_invalid' || result.reason === 'mandate_merchant_missing',
      merchant
    );
  }
});

test('parses HDFC Standing Instruction alert with card and ref', () => {
  const result = parseSubscriptionMandate({
    body: 'Dear Customer, Standing Instruction (SI) of Rs 199.00 towards NETFLIX on HDFC Bank Card ending 1234 has been registered successfully. SI Ref No: 12345678.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'active');
  assert.equal(result.fields.merchant, 'NETFLIX');
  assert.equal(result.fields.amountInr, 199);
  assert.equal(result.fields.instrument, 'card');
  assert.equal(result.fields.last4, '1234');
  assert.equal(result.fields.reference, '12345678');
});

test('parses SBI AutoPay alert with towards clause and card ending', () => {
  const result = parseSubscriptionMandate({
    body: 'Dear Cardholder, AutoPay has been registered for Rs. 649.00 towards Disney+ Hotstar on your SBI Card ending 4321. Ref No: 123456.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'active');
  assert.equal(result.fields.merchant, 'Disney+ Hotstar');
  assert.equal(result.fields.amountInr, 649);
  assert.equal(result.fields.instrument, 'card');
  assert.equal(result.fields.last4, '4321');
  assert.equal(result.fields.reference, '123456');
});

test('parses UPI mandate alert with UMN and frequency', () => {
  const result = parseSubscriptionMandate({
    body: 'Mandate created successfully towards Spotify India for upto Rs. 299.00. Frequency: Monthly. UMN: 123456789@upi.',
  });
  assert.equal(result.ok, true);
  assert.equal(result.lifecycle, 'active');
  assert.equal(result.fields.merchant, 'Spotify India');
  assert.equal(result.fields.amountInr, 299);
  assert.equal(result.fields.instrument, 'upi_bank');
  assert.equal(result.fields.reference, '123456789');
});

