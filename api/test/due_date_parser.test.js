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

test('does not interpret an ordinary transaction date as a due date', () => {
  assert.equal(
    extractDueDate('Spent Rs. 210 at QUALITY FUEL STATION on 02/10/2026.'),
    null,
  );
});

test('rejects impossible dates', () => {
  assert.equal(extractDueDate('Payment due date: 31/02/2026.'), null);
});
