'use strict';

// Pure scoped deltas; applying one twice is NOT idempotent. The command service
// must bind every application to a durable operation/effect receipt transaction.
const v = require('./validation');
const { projectExpense } = require('./domain');
const ZERO = 0n;
const MAX_MEMBERS = 200;
const MAX_PAIRS = MAX_MEMBERS * (MAX_MEMBERS - 1) / 2;

function signed(value, field) {
  if (typeof value !== 'string' || value.length > 17 || !v.matches(/^(0|-?[1-9][0-9]*)$/, value)) v.fail('INVALID_BALANCE', field);
  const result = BigInt(value);
  bounded(result, field);
  return result;
}
function bounded(value, field) {
  if (value > v.MAX_AGGREGATE_MINOR || value < -v.MAX_AGGREGATE_MINOR) v.fail('AGGREGATE_LIMIT_EXCEEDED', field);
  return value;
}
function scope(input) {
  v.member(input.contextId, 'contextId');
  v.currency(input.currency);
}
function empty(contextId) { return { contextId, currency:'INR', members:new Map(), pairs:new Map() }; }
function pairKey(low, high) { return `${low}:${high}`; } // member grammar excludes colon
function addMember(state, id, amount) {
  state.members.set(id, bounded((state.members.get(id) ?? ZERO) + amount, 'members'));
}
function addPair(state, creditor, debtor, amount) {
  const low = creditor < debtor ? creditor : debtor, high = creditor < debtor ? debtor : creditor;
  const key = pairKey(low, high), delta = creditor === low ? amount : -amount;
  const current = state.pairs.get(key)?.amount ?? ZERO;
  state.pairs.set(key, {low,high,amount:bounded(current + delta, 'pairs')});
}
function output(state, omitZeroMembers = false) {
  // Bound gross as well as net: a zero-net circular graph still has payable
  // obligations and must remain exactly representable by current Money/UI DTOs.
  bounded([...state.pairs.values()].reduce((sum,row)=>sum+(row.amount<ZERO?-row.amount:row.amount),ZERO),'grossMinor');
  const paired = new Set([...state.pairs.values()].filter(row=>row.amount!==ZERO).flatMap(row=>[row.low,row.high]));
  return {
    contextId:state.contextId,currency:'INR',
    members:[...state.members].sort(([a],[b]) => a < b ? -1 : a > b ? 1 : 0)
      .filter(([id,amount]) => !omitZeroMembers || amount !== ZERO || paired.has(id))
      .map(([memberId,amount]) => ({memberId,balanceMinor:amount.toString()})),
    pairs:[...state.pairs.values()].filter(row => row.amount !== ZERO)
      .sort((a,b) => a.low < b.low ? -1 : a.low > b.low ? 1 : a.high < b.high ? -1 : a.high > b.high ? 1 : 0)
      .map(row => ({lowMemberId:row.low,highMemberId:row.high,balanceMinor:row.amount.toString()})),
  };
}
function parseEnvelope(input, field) {
  v.record(input,['contextId','currency','members','pairs'],field);
  scope(input);
  if (!Array.isArray(input.members) || input.members.length > MAX_MEMBERS) v.fail('INVALID_PARTICIPANT_COUNT',`${field}.members`);
  if (!Array.isArray(input.pairs) || input.pairs.length > MAX_PAIRS) v.fail('INVALID_BALANCE_PAIR',`${field}.pairs`);
  const state = empty(input.contextId), incidence = new Map();
  for (const [i,row] of input.members.entries()) {
    const path = `${field}.members[${i}]`;
    v.record(row,['memberId','balanceMinor'],path);
    const id = v.member(row.memberId,`${path}.memberId`);
    if (state.members.has(id)) v.fail('DUPLICATE_MEMBER',`${path}.memberId`);
    state.members.set(id,signed(row.balanceMinor,`${path}.balanceMinor`));
  }
  for (const [i,row] of input.pairs.entries()) {
    const path = `${field}.pairs[${i}]`;
    v.record(row,['lowMemberId','highMemberId','balanceMinor'],path);
    const low = v.member(row.lowMemberId,`${path}.lowMemberId`), high = v.member(row.highMemberId,`${path}.highMemberId`);
    if (low >= high) v.fail('INVALID_BALANCE_PAIR',path);
    const key = pairKey(low,high), amount = signed(row.balanceMinor,`${path}.balanceMinor`);
    if (state.pairs.has(key)) v.fail('INVALID_BALANCE_PAIR',path);
    state.pairs.set(key,{low,high,amount});
    incidence.set(low,(incidence.get(low) ?? ZERO) + amount);
    incidence.set(high,(incidence.get(high) ?? ZERO) - amount);
  }
  for (const id of new Set([...incidence.keys(),...state.members.keys()])) {
    if (!state.members.has(id) || (incidence.get(id) ?? ZERO) !== state.members.get(id)) v.fail('BALANCE_MISMATCH',field);
  }
  bounded([...state.pairs.values()].reduce((sum,row)=>sum+(row.amount<ZERO?-row.amount:row.amount),ZERO),'grossMinor');
  return state;
}
function expenseRevisionDelta(input) {
  v.record(input,['contextId','currency','previous','next']);
  scope(input);
  if (input.previous === null && input.next === null) v.fail('INVALID_INPUT','$');
  const result = empty(input.contextId);
  for (const [snapshot,sign] of [[input.previous,-1n],[input.next,1n]]) {
    if (snapshot === null) continue;
    const projected = projectExpense(snapshot);
    for (const row of projected.positions) addMember(result,row.memberId,BigInt(row.balanceMinor)*sign);
    for (const edge of projected.obligations) addPair(result,edge.creditorId,edge.debtorId,BigInt(edge.amountMinor)*sign);
  }
  return output(result,true);
}
function settlementDelta(input) {
  v.record(input,['contextId','currency','payerId','receiverId','amountMinor','direction']);
  scope(input);
  const payer = v.member(input.payerId,'payerId'), receiver = v.member(input.receiverId,'receiverId');
  if (payer === receiver) v.fail('INVALID_SETTLEMENT','receiverId');
  if (!['confirm','reverse'].includes(input.direction)) v.fail('INVALID_SETTLEMENT_DIRECTION','direction');
  const amount = v.amount(input.amountMinor,'amountMinor',{positive:true}) * (input.direction === 'confirm' ? 1n : -1n);
  const result = empty(input.contextId);
  addMember(result,payer,amount); addMember(result,receiver,-amount);
  addPair(result,payer,receiver,amount);
  return output(result,true);
}
function applyBalanceDelta(input) {
  v.record(input,['current','delta']);
  const current = parseEnvelope(input.current,'current'), delta = parseEnvelope(input.delta,'delta');
  if (current.contextId !== delta.contextId) v.fail('CONTEXT_MISMATCH','delta.contextId');
  for (const [id,amount] of delta.members) addMember(current,id,amount);
  if (current.members.size > MAX_MEMBERS) v.fail('INVALID_PARTICIPANT_COUNT','members');
  for (const row of delta.pairs.values()) addPair(current,row.low,row.high,row.amount);
  return output(current);
}
function allocateSettlement(input) {
  v.record(input,['amountMinor','obligations','allocationOrder']);
  const total = v.amount(input.amountMinor,'amountMinor',{positive:true});
  v.count(input.obligations,100,'INVALID_OBLIGATION_COUNT','obligations');
  const rows = new Map();
  for (const [i,row] of input.obligations.entries()) {
    const path = `obligations[${i}]`;
    v.record(row,['obligationId','outstandingMinor'],path);
    const id = v.member(row.obligationId,`${path}.obligationId`);
    if (rows.has(id)) v.fail('DUPLICATE_MEMBER',`${path}.obligationId`);
    rows.set(id,v.amount(row.outstandingMinor,`${path}.outstandingMinor`,{max:v.MAX_AGGREGATE_MINOR,overflow:'AGGREGATE_LIMIT_EXCEEDED'}));
  }
  v.order(input.allocationOrder,new Set(rows.keys()),'allocationOrder');
  let remaining = total;
  const allocations = [];
  for (const id of input.allocationOrder) {
    const available = rows.get(id), amount = available < remaining ? available : remaining;
    if (amount > ZERO) allocations.push({obligationId:id,amountMinor:amount.toString()});
    remaining -= amount;
  }
  return {allocations,creditMinor:remaining.toString()};
}
module.exports = {expenseRevisionDelta,settlementDelta,applyBalanceDelta,allocateSettlement};
