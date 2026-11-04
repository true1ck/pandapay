'use strict';

// Pure shared-obligation preview math. This module does not post bank or shared
// journal entries, accept a claim, authorize funding or confirm a payment.
const v = require('./validation');

function allocationRows(input) {
  const rows = input.participants;
  v.count(rows, 50, 'INVALID_PARTICIPANT_COUNT', 'participants');
  const exact = input.mode === 'exact', equal = input.mode === 'equal';
  const ids = new Set();
  return rows.map((row, index) => {
    const field = `participants[${index}]`;
    v.record(row, equal ? ['memberId'] : ['memberId', exact ? 'amountMinor' : 'weight'], field);
    const id = v.member(row.memberId, `${field}.memberId`);
    if (ids.has(id)) v.fail('DUPLICATE_MEMBER', `${field}.memberId`);
    ids.add(id);
    if (exact) return { id, value: v.amount(row.amountMinor, `${field}.amountMinor`) };
    if (equal) return { id, value: 1n };
    const bound = input.mode === 'percentage' ? 10000n : 1000000n;
    if (typeof row.weight !== 'string' || row.weight.length > 7 || !v.matches(/^(0|[1-9][0-9]*)$/, row.weight)) v.fail('INVALID_WEIGHT', `${field}.weight`);
    const weight = BigInt(row.weight);
    if (weight > bound) v.fail('INVALID_WEIGHT', `${field}.weight`);
    return { id, value: weight };
  });
}
function byId(a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; }

function allocateExpense(input) {
  v.record(input, ['currency', 'totalMinor', 'mode', 'participants', 'tieOrder']);
  v.currency(input.currency);
  const total = v.amount(input.totalMinor, 'totalMinor', { positive: true });
  if (!['equal', 'exact', 'percentage', 'shares'].includes(input.mode)) v.fail('INVALID_MODE', 'mode');
  const rows = allocationRows(input);
  const ranks = v.order(input.tieOrder, new Set(rows.map(row => row.id)), 'tieOrder');
  const sum = rows.reduce((value, row) => value + row.value, 0n);
  if (input.mode === 'exact') {
    if (sum !== total) v.fail('ALLOCATION_TOTAL_MISMATCH', 'participants');
    return { currency: 'INR', totalMinor: total.toString(), allocations: rows.sort(byId).map(row => ({ memberId: row.id, amountMinor: row.value.toString() })) };
  }
  if (sum === 0n || (input.mode === 'percentage' && sum !== 10000n)) v.fail('INVALID_WEIGHT', 'participants');
  const calculated = rows.map(row => ({ id: row.id, value: total * row.value / sum, remainder: total * row.value % sum }));
  const remaining = total - calculated.reduce((value, row) => value + row.value, 0n);
  calculated.sort((a, b) => a.remainder === b.remainder ? ranks.get(a.id) - ranks.get(b.id) : a.remainder > b.remainder ? -1 : 1);
  // Largest-remainder leftover is strictly less than participant count. Do not
  // perform a loop whose cost grows with the monetary total.
  for (let i = 0; i < Number(remaining); i++) calculated[i].value += 1n;
  return { currency: 'INR', totalMinor: total.toString(), allocations: calculated.sort(byId).map(row => ({ memberId: row.id, amountMinor: row.value.toString() })) };
}

function moneyRows(rows, field, max, code) {
  v.count(rows, max, code, field);
  const result = new Map();
  for (const [index, row] of rows.entries()) {
    v.record(row, ['memberId', 'amountMinor'], `${field}[${index}]`);
    const id = v.member(row.memberId, `${field}[${index}].memberId`);
    if (result.has(id)) v.fail('DUPLICATE_MEMBER', `${field}[${index}].memberId`);
    result.set(id, v.amount(row.amountMinor, `${field}[${index}].amountMinor`));
  }
  return result;
}
function projectExpense(input) {
  v.record(input, ['currency', 'totalMinor', 'contributions', 'shares', 'memberOrder']);
  v.currency(input.currency);
  const total = v.amount(input.totalMinor, 'totalMinor', { positive: true });
  const paid = moneyRows(input.contributions, 'contributions', 8, 'INVALID_PAYER_COUNT');
  const shares = moneyRows(input.shares, 'shares', 50, 'INVALID_PARTICIPANT_COUNT');
  if ([...paid.values()].reduce((a, b) => a + b, 0n) !== total) v.fail('CONTRIBUTION_TOTAL_MISMATCH', 'contributions');
  if ([...shares.values()].reduce((a, b) => a + b, 0n) !== total) v.fail('ALLOCATION_TOTAL_MISMATCH', 'shares');
  const members = new Set([...paid.keys(), ...shares.keys()]);
  v.order(input.memberOrder, members, 'memberOrder');
  const positions = [...members].sort().map(id => ({ memberId: id, paidMinor: (paid.get(id) || 0n).toString(), shareMinor: (shares.get(id) || 0n).toString(), balanceMinor: ((paid.get(id) || 0n) - (shares.get(id) || 0n)).toString() }));
  const creditors = [], debtors = [];
  for (const id of input.memberOrder) {
    const balance = (paid.get(id) || 0n) - (shares.get(id) || 0n);
    if (balance > 0n) creditors.push({ id, amount: balance });
    if (balance < 0n) debtors.push({ id, amount: -balance });
  }
  const obligations = [];
  let d = 0, c = 0;
  while (d < debtors.length && c < creditors.length) {
    const debit = debtors[d], credit = creditors[c];
    const amount = debit.amount < credit.amount ? debit.amount : credit.amount;
    obligations.push({ debtorId: debit.id, creditorId: credit.id, amountMinor: amount.toString() });
    debit.amount -= amount; credit.amount -= amount;
    if (debit.amount === 0n) d++;
    if (credit.amount === 0n) c++;
  }
  return { currency: 'INR', totalMinor: total.toString(), positions, obligations };
}
function personalCost(input) {
  v.record(input, ['sourceAmountMinor', 'linkedAmountMinor', 'shareMinor']);
  const source = v.amount(input.sourceAmountMinor, 'sourceAmountMinor');
  const linked = v.amount(input.linkedAmountMinor, 'linkedAmountMinor');
  const share = v.amount(input.shareMinor, 'shareMinor', { max: v.MAX_AGGREGATE_MINOR, overflow: 'AGGREGATE_LIMIT_EXCEEDED' });
  if (linked > source) v.fail('SOURCE_OVERALLOCATED', 'linkedAmountMinor');
  const residual = source - linked, cost = residual + share;
  if (cost > v.MAX_AGGREGATE_MINOR) v.fail('AGGREGATE_LIMIT_EXCEEDED', 'costMinor');
  return { residualMinor: residual.toString(), costMinor: cost.toString() };
}
// Boundary adapter for an already interpreted source Amount.minor integer.
// Numeric coercion is forbidden; source eligibility remains the caller's job.
function sourceIntToSharedMinor(value) {
  if (!Number.isSafeInteger(value) || value < 0) v.fail('INVALID_AMOUNT', 'sourceMinor');
  return v.amount(value.toString(), 'sourceMinor').toString();
}

module.exports = { allocateExpense, projectExpense, personalCost, sourceIntToSharedMinor, SharedExpenseError: v.SharedExpenseError };
