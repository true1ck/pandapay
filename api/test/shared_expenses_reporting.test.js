'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {readOverview,readContextTotals}=require('../src/shared_expenses/queries');
const actor='11111111-1111-4111-8111-111111111111',context='22222222-2222-4222-8222-222222222222';
test('overview uses exact current pair projections and keeps both gross directions',async()=>{
  const calls=[];
  const result=await readOverview({query:async(sql,args)=>{calls.push({sql,args});return {rows:[{owed_minor:'100',owing_minor:'100',context_count:'2',expense_count:'4'}]};}},actor);
  assert.deepEqual(result,{currency:'INR',owedMinor:'100',owingMinor:'100',netMinor:'0',contextCount:'2',expenseCount:'4'});
  assert.ok(calls[0].sql.includes('shared_expenses.pair_balances'));
  assert.ok(!calls[0].sql.includes('journal_entries'));
  assert.deepEqual(calls[0].args,[actor]);
});
test('reporting refuses out-of-range aggregate instead of losing a paisa',async()=>{
  await assert.rejects(readOverview({query:async()=>({rows:[{owed_minor:'9007199254740992',owing_minor:'0',context_count:'1',expense_count:'1'}]})},actor),{code:'AGGREGATE_LIMIT_EXCEEDED'});
});
test('context totals load complete materialized totals rather than a loaded page sum',async()=>{
  const calls=[];
  const result=await readContextTotals({query:async(sql,args)=>{
    calls.push({sql,args});
    if(sql.includes('_can_read_context'))return {rows:[{allowed:true}]};
    return {rows:[{total_minor:'120000',paid_minor:'0',share_minor:'40000',expense_count:'1',member_id:actor}]};
  }},actor,context);
  assert.deepEqual(result,{contextId:context,currency:'INR',sharedTotalMinor:'120000',yourPaidMinor:'0',yourShareMinor:'40000',expenseCount:'1',memberId:actor});
  assert.ok(calls[1].sql.includes('shared_expenses.context_totals'));
  assert.ok(calls[1].sql.includes('shared_expenses.member_totals'));
});
