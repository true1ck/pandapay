const test = require('node:test');
const assert = require('node:assert/strict');
const { parseSms, parseSmsAgainstPatterns, redactSmsShape } = require('../src/sms_parser');

// Realistic synthetic (not real customer) Indian bank SMS formats.

const HDFC_PATTERN = {
  id: 'p-hdfc-1',
  sender_pattern: 'HDFCBK',
  regex: 'Rs\\.?\\s?([\\d,]+\\.?\\d*) spent on your HDFC Bank Card ending (\\d{4}) at ([A-Za-z0-9 &._-]+?) on (\\d{2}-\\d{2}-\\d{2})',
  field_map: { amount: 1, last4: 2, merchant: 3, date: 4 },
};

const ICICI_PATTERN = {
  id: 'p-icici-1',
  sender_pattern: 'ICICIB',
  regex: 'INR ([\\d,]+\\.?\\d*) spent on ICICI Bank Card XX(\\d{4}) at ([A-Za-z0-9 &._-]+?) on (\\d{2}-[A-Za-z]{3}-\\d{2})',
  field_map: { amount: 1, last4: 2, merchant: 3, date: 4 },
};

test('successful parse: HDFC-style SMS extracts all fields', () => {
  const sms = {
    sender: 'VM-HDFCBK-S',
    body: 'Rs.1,499.00 spent on your HDFC Bank Card ending 4321 at AMAZON RETAIL on 04-08-26. Avl limit Rs.85,000.',
  };
  const result = parseSms(HDFC_PATTERN, sms);
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 1499);
  assert.equal(result.fields.last4, '4321');
  assert.equal(result.fields.merchant, 'AMAZON RETAIL');
  assert.equal(result.fields.date, '04-08-26');
});

test('successful parse: ICICI-style SMS with alphabetic month in date', () => {
  const sms = {
    sender: 'AD-ICICIB',
    body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  };
  const result = parseSms(ICICI_PATTERN, sms);
  assert.equal(result.ok, true);
  assert.equal(result.fields.amountInr, 250);
  assert.equal(result.fields.last4, '7788');
  assert.equal(result.fields.merchant, 'SWIGGY');
});

test('malformed/partial match: body missing the "spent on" clause fails cleanly', () => {
  const sms = {
    sender: 'VM-HDFCBK-S',
    body: 'Your HDFC Bank Card ending 4321 payment of Rs.500 is due on 10-08-26.',
  };
  const result = parseSms(HDFC_PATTERN, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_regex_match');
});

test('malformed: amount field captures non-numeric text -> unparseable_amount, never a fabricated guess', () => {
  const badPattern = {
    id: 'p-bad-1',
    sender_pattern: 'HDFCBK',
    regex: 'spent (\\w+) at ([A-Za-z ]+)',
    field_map: { amount: 1, merchant: 2 },
  };
  const sms = { sender: 'HDFCBK', body: 'spent MANY at CAFE COFFEE DAY' };
  const result = parseSms(badPattern, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'unparseable_amount');
});

test('wrong-issuer sender mismatch: ICICI pattern does not match an SBI sender', () => {
  const sms = {
    sender: 'SBIINB',
    body: 'INR 250 spent on ICICI Bank Card XX7788 at SWIGGY on 05-Aug-26.',
  };
  const result = parseSms(ICICI_PATTERN, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'sender_mismatch');
});

test('pattern with no sender_pattern configured matches any sender', () => {
  const openPattern = { ...HDFC_PATTERN, id: 'p-open', sender_pattern: null };
  const sms = {
    sender: 'RANDOM-SENDER',
    body: 'Rs.100 spent on your HDFC Bank Card ending 1111 at TEST STORE on 01-01-26.',
  };
  const result = parseSms(openPattern, sms);
  assert.equal(result.ok, true);
});

test('empty SMS body fails without throwing', () => {
  const result = parseSms(HDFC_PATTERN, { sender: 'HDFCBK', body: '   ' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'empty_body');
});

test('invalid pattern (no regex) fails cleanly', () => {
  const result = parseSms({ field_map: {} }, { sender: 'HDFCBK', body: 'Rs.10 spent' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'invalid_pattern');
});

test('field_map missing "amount" entirely is rejected even if regex matches', () => {
  const noAmountPattern = {
    id: 'p-noamount',
    sender_pattern: 'HDFCBK',
    regex: 'at ([A-Za-z ]+) on',
    field_map: { merchant: 1 },
  };
  const sms = { sender: 'HDFCBK', body: 'spent at TEST STORE on 01-01-26' };
  const result = parseSms(noAmountPattern, sms);
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_amount_field_mapped');
});

test('parseSmsAgainstPatterns tries candidates in order and returns the first match with its patternId', () => {
  const sms = {
    sender: 'AD-ICICIB',
    body: 'INR 999 spent on ICICI Bank Card XX1234 at ZOMATO on 06-Aug-26.',
  };
  const result = parseSmsAgainstPatterns([HDFC_PATTERN, ICICI_PATTERN], sms);
  assert.equal(result.ok, true);
  assert.equal(result.patternId, 'p-icici-1');
  assert.equal(result.fields.merchant, 'ZOMATO');
});

test('parseSmsAgainstPatterns returns ok:false with a reason when nothing matches', () => {
  const sms = { sender: 'AXISBK', body: 'Totally unrelated promotional message.' };
  const result = parseSmsAgainstPatterns([HDFC_PATTERN, ICICI_PATTERN], sms);
  assert.equal(result.ok, false);
  assert.ok(result.reason);
});

test('parseSmsAgainstPatterns with an empty pattern list fails with no_patterns_configured', () => {
  const result = parseSmsAgainstPatterns([], { sender: 'HDFCBK', body: 'Rs.10 spent' });
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'no_patterns_configured');
});

test('redactSmsShape strips digits to # and collapses letter runs to X, leaving no digits (matches parser_failures CHECK)', () => {
  const shape = redactSmsShape('Rs.1,499.00 spent on HDFC Card ending 4321 at AMAZON on 04-08-26');
  assert.doesNotMatch(shape, /\d/);
  assert.doesNotMatch(shape, /[A-Za-z]{2,}/);
});
