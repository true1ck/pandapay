'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { expenseRevisionDelta, settlementDelta, applyBalanceDelta, allocateSettlement } = require('../src/shared_expenses/journal');
const { SharedExpenseError } = require('../src/shared_expenses/domain');
const vectors = require('../../contracts/shared_expenses/v1/journal_vectors.json');

for (const vector of vectors.cases) test(vector.id, () => {
  let current = { contextId:vector.contextId,currency:'INR',members:[],pairs:[] };
  for (const step of vector.steps) {
    const input = structuredClone(step.input), before = JSON.stringify(input);
    const delta = step.kind === 'revision' ? expenseRevisionDelta(input) : settlementDelta(input);
    assert.equal(JSON.stringify(input), before);
    const currentBefore = JSON.stringify(current);
    const next = applyBalanceDelta({current,delta});
    assert.equal(JSON.stringify(current), currentBefore);
    current = next;
  }
  assert.deepEqual(current, vector.expected);
});
for (const vector of vectors.allocations) test(vector.id, () => {
  assert.deepEqual(allocateSettlement(vector.input),vector.expected);
});
function rejects(fn, code) {
  assert.throws(fn, e => e instanceof SharedExpenseError && e.code === code);
}
const envelope = () => ({contextId:'home',currency:'INR',members:[],pairs:[]});
const payment = () => ({contextId:'home',currency:'INR',payerId:'a',receiverId:'b',amountMinor:'100',direction:'confirm'});
test('settlement requires exact positive amount, different parties and explicit direction', () => {
  rejects(()=>settlementDelta({...payment(),receiverId:'a'}),'INVALID_SETTLEMENT');
  rejects(()=>settlementDelta({...payment(),direction:'paid'}),'INVALID_SETTLEMENT_DIRECTION');
  for(const amount of ['0','-1','1.1',100,null,'01']) rejects(()=>settlementDelta({...payment(),amountMinor:amount}),'INVALID_AMOUNT');
  rejects(()=>settlementDelta({...payment(),currency:'USD'}),'UNSUPPORTED_CURRENCY');
  rejects(()=>settlementDelta({...payment(),proof:'screenshot'}),'INVALID_INPUT');
});
test('unbalanced, malformed, cross-context and noncanonical pair states fail closed', () => {
  const delta = settlementDelta(payment());
  rejects(()=>applyBalanceDelta({current:{...envelope(),contextId:'other'},delta}),'CONTEXT_MISMATCH');
  rejects(()=>applyBalanceDelta({current:envelope(),delta:{...delta,members:[]}}),'BALANCE_MISMATCH');
  for(const balance of ['-0','01','+1','1\n',1,'-9007199254740992']) {
    rejects(()=>applyBalanceDelta({current:envelope(),delta:{...delta,members:[{memberId:'a',balanceMinor:balance}]}}), typeof balance === 'string' && balance.includes('900719') ? 'AGGREGATE_LIMIT_EXCEEDED':'INVALID_BALANCE');
  }
  rejects(()=>applyBalanceDelta({current:envelope(),delta:{...delta,pairs:[{lowMemberId:'b',highMemberId:'a',balanceMinor:'100'}]}}),'INVALID_BALANCE_PAIR');
  rejects(()=>applyBalanceDelta({current:envelope(),delta:{...delta,members:[...delta.members,delta.members[0]]}}),'DUPLICATE_MEMBER');
  rejects(()=>expenseRevisionDelta({contextId:'home',currency:'INR',previous:null,next:null}),'INVALID_INPUT');
});
test('projection overflows atomically and reverse is exact inverse', () => {
  const delta = settlementDelta(payment());
  const current = {contextId:'home',currency:'INR',members:[{memberId:'a',balanceMinor:'9007199254740990'},{memberId:'b',balanceMinor:'-9007199254740990'}],pairs:[{lowMemberId:'a',highMemberId:'b',balanceMinor:'9007199254740990'}]};
  rejects(()=>applyBalanceDelta({current,delta}),'AGGREGATE_LIMIT_EXCEEDED');
  const paid = applyBalanceDelta({current:envelope(),delta});
  const restored = applyBalanceDelta({current:paid,delta:settlementDelta({...payment(),direction:'reverse'})});
  assert.deepEqual(restored.pairs,[]);
  assert.ok(restored.members.every(row=>row.balanceMinor==='0'));
});
test('settlement allocation validates document and never silently changes selected obligations', () => {
  rejects(()=>allocateSettlement({amountMinor:'1',obligations:[],allocationOrder:[]}),'INVALID_OBLIGATION_COUNT');
  rejects(()=>allocateSettlement({amountMinor:'1',obligations:[{obligationId:'o',outstandingMinor:'1'},{obligationId:'o',outstandingMinor:'1'}],allocationOrder:['o','o']}),'DUPLICATE_MEMBER');
  rejects(()=>allocateSettlement({amountMinor:'1',obligations:[{obligationId:'o',outstandingMinor:'1'}],allocationOrder:['other']}),'INVALID_TIE_ORDER');
});

test('gross circular balances are bounded even when every member net is zero', () => {
  const high='4503599627370496';
  const current={contextId:'home',currency:'INR',members:[{memberId:'a',balanceMinor:'0'},{memberId:'b',balanceMinor:'0'},{memberId:'c',balanceMinor:'0'}],pairs:[
    {lowMemberId:'a',highMemberId:'b',balanceMinor:high},
    {lowMemberId:'a',highMemberId:'c',balanceMinor:'-'+high},
    {lowMemberId:'b',highMemberId:'c',balanceMinor:high},
  ]};
  rejects(()=>applyBalanceDelta({current,delta:envelope()}),'AGGREGATE_LIMIT_EXCEEDED');
});
