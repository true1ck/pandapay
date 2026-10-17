const test = require('node:test');
const assert = require('node:assert/strict');

const { extractDueDate, extractLast4 } = require('../src/due_date_parser');

test('extracts a numeric payment due date and card suffix', () => {
  const result = extractDueDate(
    'HDFC Bank Credit Card ending 8406. Payment due date: 16/10/2026.',
  );
  assert.equal(result.day, 16);
  assert.equal(result.date.getFullYear(), 2026);
  assert.equal(extractLast4('HDFC Bank Credit Card ending 8406.'), '8406');
});

test('supports month-name due dates', () => {
  const result = extractDueDate('Your amount is due by 5 Oct 2026.');
  assert.equal(result.day, 5);
  assert.equal(result.date.getMonth(), 9);
});

test('supports issuer hyphenated and ordinal date formats', () => {
  assert.equal(extractDueDate('Payment due date: 16-Oct-26.').day, 16);
  assert.equal(extractDueDate('Your amount is due by 5th October 2026.').day, 5);
  assert.equal(extractDueDate('Payment due on Oct 16, 2026.').day, 16);
});

test('supports ISO dates and bill/payable wording', () => {
  assert.equal(extractDueDate('Bill payable by: 2026-11-02.').day, 2);
  assert.equal(extractDueDate('Minimum amount due date is 02.11.2026.').day, 2);
});

test('supports masked card-number variants used in statement alerts', () => {
  for (const body of [
    'Credit Card number: XXXX 7105. Payment due date: 02/11/2026.',
    'Credit card no XX 7105. Due date - 02-11-2026.',
    'Credit card x7105. Due on: 02-11-2026.',
    'Card ending with 7105. Payment due on 02-11-2026.',
    'Credit Card No-****7105. Pay by 02-11-2026.',
  ]) {
    assert.equal(extractLast4(body), '7105', body);
  }
});

test('supports Axis statement wording with a colon after due on', () => {
  const body = [
    'Your statement for Axis Bank Credit Card no. XX7105 is generated.',
    'Due on: 02-11-26',
    'Total amt: INR Dr. 2147.00',
    'Min amt due: INR Dr. 100.00',
  ].join(' ');
  const result = extractDueDate(body);
  assert.equal(result.day, 2);
  assert.equal(result.date.getMonth(), 10);
  assert.equal(result.date.getFullYear(), 2026);
  assert.equal(extractLast4(body), '7105');
});

test('extracts a due date from a pay-by instruction', () => {
  const result = extractDueDate(
    'Please pay the minimum amount of Rs. 500 by 16/10/2026 to avoid late fees.',
  );
  assert.equal(result.day, 16);
  assert.equal(result.date.getMonth(), 9);
});

test('extracts a due date from keep-the-amount wording', () => {
  const result = extractDueDate(
    'Please keep the total amount payable ready on or before 16 Oct 2026.',
  );
  assert.equal(result.day, 16);
  assert.equal(result.date.getMonth(), 9);
});

test('extracts a due date from last-date-for-payment wording', () => {
  const result = extractDueDate('Last date for payment is 16/10/2026.');
  assert.equal(result.day, 16);
  assert.equal(result.date.getFullYear(), 2026);
});

test('extracts a due date when the message says make the payment by', () => {
  const result = extractDueDate('Please make the payment by 16/10/2026 to avoid fees.');
  assert.equal(result.day, 16);
});

test('extracts a due date when payment is made by a date', () => {
  const result = extractDueDate('The minimum amount should be paid by 16/10/2026.');
  assert.equal(result.day, 16);
});

test('extracts HDFC MoneyBack-style historical statement wording', () => {
  const messages = [
    'Your HDFC Bank MoneyBack+ Credit Card ending XX1234 statement is generated. Payment due date of your card is 16/10/2026.',
    'Payment due date for your HDFC Bank MoneyBack Credit Card ending XX1234 is 16 Oct 2026.',
    'Your HDFC Bank Credit Card ending XX1234 statement is generated. Please keep sufficient funds in your account for payment on 16/10/2026.',
  ];

  for (const body of messages) {
    const result = extractDueDate(body);
    assert.equal(result?.day, 16, body);
    assert.equal(extractLast4(body), '1234', body);
  }
});

test('does not interpret an ordinary transaction date as a due date', () => {
  assert.equal(
    extractDueDate('Spent Rs. 210 at QUALITY FUEL STATION on 02/10/2026.'),
    null,
  );
  assert.equal(extractDueDate('Payment received on 02/10/2026. Thank you.'), null);
});

test('rejects impossible dates', () => {
  assert.equal(extractDueDate('Payment due date: 31/02/2026.'), null);
});
