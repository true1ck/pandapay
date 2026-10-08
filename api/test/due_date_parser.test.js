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
