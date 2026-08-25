const test = require('node:test');
const assert = require('node:assert');
const { csvField, csvRow, csvDocument } = require('../src/csv');

/**
 * Two of these rules are the difference between a usable export and a
 * corrupt or dangerous one, and both are the kind of thing that gets left
 * out of a "just join with commas" implementation.
 */
test('plain values pass through unchanged', () => {
  assert.strictEqual(csvField('Swiggy'), 'Swiggy');
  assert.strictEqual(csvField(1234.5), '1234.5');
});

test('null and undefined become empty, not the strings "null"/"undefined"', () => {
  assert.strictEqual(csvField(null), '');
  assert.strictEqual(csvField(undefined), '');
});

test('a value containing a comma is quoted', () => {
  // Merchant names are free text from bank messages and regularly contain
  // commas. Unquoted, one shifts every later column on that row.
  assert.strictEqual(csvField('BigBasket, Bengaluru'), '"BigBasket, Bengaluru"');
});

test('embedded quotes are doubled inside a quoted field', () => {
  assert.strictEqual(csvField('The "Good" Cafe'), '"The ""Good"" Cafe"');
});

test('newlines are quoted rather than breaking the row', () => {
  assert.strictEqual(csvField('line one\nline two'), '"line one\nline two"');
});

test('a formula-looking value is neutralised', () => {
  // Excel, LibreOffice and Sheets all execute a leading =, +, - or @. The
  // merchant string comes from SMS and email we do not control, so this is
  // a real path from an attacker-influenced field to code execution.
  assert.strictEqual(csvField('=cmd|calc'), "'=cmd|calc");
  assert.strictEqual(csvField('+1234'), "'+1234");
  assert.strictEqual(csvField('-1+1'), "'-1+1");
  assert.strictEqual(csvField('@SUM(A1)'), "'@SUM(A1)");
});

test('a formula that also needs quoting gets both treatments', () => {
  assert.strictEqual(csvField('=HYPERLINK("a","b")'), '"\'=HYPERLINK(""a"",""b"")"');
});

test('a negative number is still readable after the guard', () => {
  // The guard prefixes a quote, which spreadsheets strip on display — the
  // cell reads as text rather than a formula. Documented here because it is
  // a real, accepted trade-off: correctness over a numeric-typed cell.
  assert.strictEqual(csvField('-450.00'), "'-450.00");
});

test('a row joins fields with commas', () => {
  assert.strictEqual(csvRow(['2026-08-25', '450.00', 'Swiggy']), '2026-08-25,450.00,Swiggy');
});

test('the document starts with a UTF-8 BOM and ends with a newline', () => {
  const doc = csvDocument(['A'], [['x']]);
  assert.ok(doc.startsWith('﻿'), 'Excel on Windows needs the BOM to read ₹ correctly');
  assert.ok(doc.endsWith('\n'));
  assert.strictEqual(doc, '﻿A\nx\n');
});
