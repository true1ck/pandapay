const test = require('node:test');
const assert = require('node:assert');
const { parseTransactionDate } = require('../src/sms_parser');

/**
 * `parseSms` leaves `fields.date` as the bank's own text; this is the half
 * that turns it into a real Date.
 *
 * Getting this wrong is expensive in a specific, non-obvious way: a
 * mis-dated transaction lands in the wrong week and month, AND it falls
 * outside the ±1-day window cross-channel duplicate detection uses, so the
 * matching bank SMS is never recognised as the same swipe and the
 * transaction is counted twice. That is why every uncertain case returns
 * null rather than a best guess.
 */
const REF = new Date(2026, 7, 25); // 25 Aug 2026, the reference "now"

function ymd(d) {
  return d === null ? null : `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

test('day-first numeric formats', () => {
  assert.strictEqual(ymd(parseTransactionDate('03-04-26', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('3/4/2026', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('03.04.2026', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('15-01-26', REF)), '2026-1-15');
});

test('day-first is not month-first — this is an Indian-bank parser', () => {
  // 03/04/26 must be 3 April. Reading it as 4 March would misfile spend for
  // two-thirds of the year while looking entirely plausible.
  const d = parseTransactionDate('03/04/26', REF);
  assert.strictEqual(d.getMonth(), 3, 'April');
  assert.strictEqual(d.getDate(), 3);
});

test('ISO format is read as written, not day-first', () => {
  assert.strictEqual(ymd(parseTransactionDate('2026-04-03', REF)), '2026-4-3');
});

test('month-name formats', () => {
  assert.strictEqual(ymd(parseTransactionDate('03-Apr-26', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('3 Apr 2026', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('03Apr26', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('Apr 03, 2026', REF)), '2026-4-3');
  assert.strictEqual(ymd(parseTransactionDate('03-APRIL-2026', REF)), '2026-4-3');
});

test('two-digit years resolve to this century', () => {
  assert.strictEqual(parseTransactionDate('03-04-26', REF).getFullYear(), 2026);
});

test('an impossible date is rejected, not rolled forward', () => {
  // JS silently turns 31 Feb into 3 March. A round-trip check catches it.
  assert.strictEqual(parseTransactionDate('31-02-26', REF), null);
  assert.strictEqual(parseTransactionDate('32-01-26', REF), null);
  assert.strictEqual(parseTransactionDate('01-13-26', REF), null);
});

test('a future date is a misparse and is rejected', () => {
  assert.strictEqual(parseTransactionDate('25-08-27', REF), null);
});

test('a date one day ahead is allowed, for timezone skew', () => {
  assert.notStrictEqual(parseTransactionDate('26-08-26', REF), null);
});

test('unreadable input returns null rather than today', () => {
  // Falling back to "today" is what produced mis-dated email imports; the
  // caller decides the fallback, this function never invents one.
  assert.strictEqual(parseTransactionDate('', REF), null);
  assert.strictEqual(parseTransactionDate(null, REF), null);
  assert.strictEqual(parseTransactionDate('yesterday', REF), null);
  assert.strictEqual(parseTransactionDate('03-04', REF), null);
  assert.strictEqual(parseTransactionDate('03-Xyz-26', REF), null);
});
