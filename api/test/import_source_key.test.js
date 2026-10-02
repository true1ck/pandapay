const test = require('node:test');
const assert = require('node:assert');
const { importSourceKey, normalizeMessagePart } = require('../src/import_source_key');

test('message normalization removes delivery-format differences', () => {
  assert.strictEqual(
    normalizeMessagePart('  Rs. 23.45\r\n spent\t at LIVEPAYTEST  '),
    'Rs. 23.45 spent at LIVEPAYTEST',
  );
});

test('the same SMS has one key even when delivery timestamps differ', () => {
  const first = importSourceKey(
    'profile-1',
    ' jd-hdfcbk-s ',
    'Spent Rs.23.45 at LIVEPAYTEST on 2026-10-02. UPI Ref 990000000023',
    new Date('2026-10-02T10:00:00.000Z'),
  );
  const replay = importSourceKey(
    'profile-1',
    'JD-HDFCBK-S',
    'Spent Rs.23.45 at LIVEPAYTEST on 2026-10-02. UPI Ref 990000000023',
    new Date('2026-10-02T10:05:37.000Z'),
  );

  assert.strictEqual(first, replay);
});

test('different SMS bodies remain distinct even on the same day', () => {
  const first = importSourceKey('profile-1', 'JD-HDFCBK-S', 'Spent Rs.23.45 at SHOP-A on 2026-10-02');
  const second = importSourceKey('profile-1', 'JD-HDFCBK-S', 'Spent Rs.23.45 at SHOP-B on 2026-10-02');
  assert.notStrictEqual(first, second);
});

test('the same bank message is isolated between profiles', () => {
  const first = importSourceKey('profile-1', 'JD-HDFCBK-S', 'Spent Rs.23.45 at SHOP-A');
  const second = importSourceKey('profile-2', 'JD-HDFCBK-S', 'Spent Rs.23.45 at SHOP-A');
  assert.notStrictEqual(first, second);
});
