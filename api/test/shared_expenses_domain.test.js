'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vectors = require('../../contracts/shared_expenses/v1/domain_vectors.json');
const { allocateExpense, projectExpense, personalCost, sourceIntToSharedMinor, SharedExpenseError } = require('../src/shared_expenses/domain');

for (const [kind, fn] of [['allocation', allocateExpense], ['projection', projectExpense], ['personalCost', personalCost], ['sourceInt', sourceIntToSharedMinor]]) {
  for (const vector of vectors[kind]) test(`${kind}: ${vector.id}`, () => {
    const before = JSON.stringify(vector.input);
    assert.deepEqual(fn(vector.input), vector.expected);
    assert.equal(JSON.stringify(vector.input), before, 'caller input must remain unchanged');
  });
}
const base = () => structuredClone(vectors.allocation[0].input);
function errorCode(fn, code) {
  assert.throws(fn, error => error instanceof SharedExpenseError && error.code === code && typeof error.field === 'string');
}

test('source integer adapter rejects strings, fractional/coerced/unsafe values and capped purchases', () => {
  for (const value of ['1', true, null, 1n, 0.01, NaN, Infinity, -1, Number.MAX_SAFE_INTEGER + 1]) {
    errorCode(() => sourceIntToSharedMinor(value), 'INVALID_AMOUNT');
  }
  errorCode(() => sourceIntToSharedMinor(1000000001), 'AMOUNT_LIMIT_EXCEEDED');
});
test('invalid amounts fail closed without coercion or sub-paisa rounding', () => {
  for (const amount of [0, 1, 1n, true, null, '', '00', '01', '+1', '-1', '1.0', '1e2', ' 1', '1 ', '١', '1\n', '9'.repeat(10000)]) {
    errorCode(() => allocateExpense({ ...base(), totalMinor: amount }), 'INVALID_AMOUNT');
  }
  errorCode(() => allocateExpense({ ...base(), totalMinor: '0' }), 'INVALID_AMOUNT');
  errorCode(() => allocateExpense({ ...base(), totalMinor: '1000000001' }), 'AMOUNT_LIMIT_EXCEEDED');
});
test('reject unknown shapes, unsupported modes and currency', () => {
  for (const input of [null, [], 'value', { ...base(), injected: true }]) errorCode(() => allocateExpense(input), 'INVALID_INPUT');
  errorCode(() => allocateExpense({ ...base(), currency: 'USD' }), 'UNSUPPORTED_CURRENCY');
  errorCode(() => allocateExpense({ ...base(), mode: 'guess' }), 'INVALID_MODE');
  errorCode(() => allocateExpense({ ...base(), participants: [{ memberId: 'you', amountMinor: '5' }] }), 'INVALID_INPUT');
});
test('reject duplicate or invalid members, invalid permutations and count overflow', () => {
  errorCode(() => allocateExpense({ ...base(), participants: [{ memberId: 'a' }, { memberId: 'a' }] }), 'DUPLICATE_MEMBER');
  for (const id of ['', ' two', '__proto__', 'x'.repeat(65), 'a\n']) {
    errorCode(() => allocateExpense({ ...base(), participants: [{ memberId: id }] }), 'INVALID_MEMBER_ID');
  }
  for (const order of [null, [], ['you', 'you', 'priya'], ['you', 'rahul', 'other'], ['you', 'rahul', 'priya', 'other']]) {
    errorCode(() => allocateExpense({ ...base(), tieOrder: order }), 'INVALID_TIE_ORDER');
  }
  errorCode(() => allocateExpense({ ...base(), participants: [] }), 'INVALID_PARTICIPANT_COUNT');
  errorCode(() => allocateExpense({ ...base(), participants: Array.from({ length: 51 }, (_, i) => ({ memberId: `m${i}` })) }), 'INVALID_PARTICIPANT_COUNT');
});
test('mode validation enforces exact totals, percentage scale and bounded positive weights', () => {
  const input = { currency: 'INR', totalMinor: '10', tieOrder: ['a', 'b'] };
  errorCode(() => allocateExpense({ ...input, mode: 'exact', participants: [{ memberId: 'a', amountMinor: '5' }, { memberId: 'b', amountMinor: '4' }] }), 'ALLOCATION_TOTAL_MISMATCH');
  for (const mode of ['shares', 'percentage']) {
    errorCode(() => allocateExpense({ ...input, mode, participants: [{ memberId: 'a', weight: '0' }, { memberId: 'b', weight: '0' }] }), 'INVALID_WEIGHT');
    for (const weight of [1, '01', '-1', '1.1', '1e3', '1000001', '1\n']) {
      errorCode(() => allocateExpense({ ...input, mode, participants: [{ memberId: 'a', weight }, { memberId: 'b', weight: '1' }] }), 'INVALID_WEIGHT');
    }
  }
  errorCode(() => allocateExpense({ ...input, mode: 'percentage', participants: [{ memberId: 'a', weight: '5000' }, { memberId: 'b', weight: '4999' }] }), 'INVALID_WEIGHT');
});
test('projection rejects unbalanced money, duplicate funding and excess payer rows', () => {
  const input = structuredClone(vectors.projection[0].input);
  errorCode(() => projectExpense({ ...input, contributions: [{ memberId: 'you', amountMinor: '119999' }] }), 'CONTRIBUTION_TOTAL_MISMATCH');
  errorCode(() => projectExpense({ ...input, shares: [{ memberId: 'you', amountMinor: '1' }] }), 'ALLOCATION_TOTAL_MISMATCH');
  errorCode(() => projectExpense({ ...input, contributions: [...input.contributions, ...input.contributions] }), 'DUPLICATE_MEMBER');
  errorCode(() => projectExpense({ ...input, contributions: Array.from({ length: 9 }, (_, i) => ({ memberId: `m${i}`, amountMinor: '1' })) }), 'INVALID_PAYER_COUNT');
  errorCode(() => projectExpense({ ...input, memberOrder: ['you', 'rahul'] }), 'INVALID_TIE_ORDER');
});
test('source residual and aggregate cost are bounded and never over-allocate', () => {
  errorCode(() => personalCost({ sourceAmountMinor: '1', linkedAmountMinor: '2', shareMinor: '0' }), 'SOURCE_OVERALLOCATED');
  errorCode(() => personalCost({ sourceAmountMinor: '1', linkedAmountMinor: '0', shareMinor: '9007199254740991' }), 'AGGREGATE_LIMIT_EXCEEDED');
  errorCode(() => personalCost({ sourceAmountMinor: '0', linkedAmountMinor: '0', shareMinor: '9007199254740992' }), 'AGGREGATE_LIMIT_EXCEEDED');
});
test('persisted tie order is stable under display reordering and repeated expenses have no drift', () => {
  const input = base();
  const expected = allocateExpense(input);
  input.participants.reverse();
  assert.deepEqual(allocateExpense(input), expected);
  let sum = 0n;
  for (let i = 0; i < 100; i++) sum += allocateExpense(input).allocations.reduce((value, row) => value + BigInt(row.amountMinor), 0n);
  assert.equal(sum, 1000000n);
});
test('deterministic randomized allocations and multiple payers preserve exact invariants', () => {
  let seed = 723;
  const next = max => { seed = (seed * 48271) % 2147483647; return seed % max; };
  for (let n = 0; n < 500; n++) {
    const count = 1 + next(50), total = 1 + next(1000000000);
    const members = Array.from({ length: count }, (_, i) => `m${i}`);
    const weights = members.map(memberId => ({ memberId, weight: String(next(1000000)) }));
    weights[0].weight = '1';
    const shares = allocateExpense({ currency: 'INR', totalMinor: String(total), mode: 'shares', participants: weights, tieOrder: [...members].reverse() }).allocations;
    assert.equal(shares.reduce((sum, row) => sum + BigInt(row.amountMinor), 0n), BigInt(total));
    const first = next(total + 1);
    const contributions = count > 1 ? [{ memberId: members[0], amountMinor: String(first) }, { memberId: members[1], amountMinor: String(total - first) }] : [{ memberId: members[0], amountMinor: String(total) }];
    const result = projectExpense({ currency: 'INR', totalMinor: String(total), contributions, shares, memberOrder: members });
    assert.equal(result.positions.reduce((sum, row) => sum + BigInt(row.balanceMinor), 0n), 0n);
    const reconstructed = new Map(result.positions.map(row => [row.memberId, 0n]));
    for (const edge of result.obligations) {
      assert.ok(BigInt(edge.amountMinor) > 0n);
      reconstructed.set(edge.debtorId, reconstructed.get(edge.debtorId) - BigInt(edge.amountMinor));
      reconstructed.set(edge.creditorId, reconstructed.get(edge.creditorId) + BigInt(edge.amountMinor));
    }
    for (const row of result.positions) assert.equal(reconstructed.get(row.memberId), BigInt(row.balanceMinor));
    assert.ok(result.obligations.length <= result.positions.length - 1);
  }
});
