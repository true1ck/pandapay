const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizePhone, phoneHash, planBackfill } = require('../scripts/backfillSplitDirectory');

const SECRET = 'x'.repeat(32);

test('normalises like the API: bare 10-digit Indian mobile gets +91, junk is rejected', () => {
  assert.equal(normalizePhone('7030445936'), '+917030445936');
  assert.equal(normalizePhone('+91 70304-45936'), '+917030445936');
  assert.equal(normalizePhone('917030445936'), null); // no plus, 12 digits: the API rejects it too
  assert.equal(normalizePhone('abc'), null);
  assert.equal(normalizePhone(null), null);
});

test('hash matches the API formula', () => {
  assert.match(phoneHash(SECRET, '+917030445936'), /^[a-f0-9]{64}$/);
  assert.notEqual(phoneHash(SECRET, '+917030445936'), phoneHash(SECRET, '+917030445937'));
});

test('plans writes, prefers the first usable number, skips duplicates and already-registered', () => {
  const h = (p) => phoneHash(SECRET, p);
  const rows = [
    { id: 'a', displayName: 'A', phones: [null, '7030445936'] },
    { id: 'b', displayName: 'B', phones: ['garbage', null] },
    { id: 'c', displayName: 'C', phones: ['+919999999999', null] },
    { id: 'd', displayName: 'D', phones: ['+918888888888', null] },
    { id: 'e', displayName: 'E', phones: ['8888888888', null] },
    { id: 'f', displayName: 'F', phones: ['+917777777777', '+916666666666'] },
  ];
  const existing = new Map([['c', h('+919999999999')], ['f', h('+910000000000')]]);
  const { writes, stats } = planBackfill(rows, SECRET, existing);
  assert.deepEqual(writes.map((w) => w.id).sort(), ['a', 'f']);
  assert.equal(writes.find((w) => w.id === 'f').hash, h('+917777777777'));
  assert.deepEqual(stats, {
    considered: 6, no_usable_number: 1, duplicate_number_skipped: 2, already_registered: 1, to_write: 2,
  });
});
