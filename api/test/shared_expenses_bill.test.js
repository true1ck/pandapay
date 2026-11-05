'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {validateCommand}=require('../src/shared_expenses/commands');
const {validateBill}=require('../src/shared_expenses/bill');
const a='11111111-1111-4111-8111-111111111111',b='22222222-2222-4222-8222-222222222222',c='33333333-3333-4333-8333-333333333333';
const snapshot={currency:'INR',totalMinor:'120000',contributions:[{memberId:a,amountMinor:'120000'}],shares:[{memberId:a,amountMinor:'40000'},{memberId:b,amountMinor:'40000'},{memberId:c,amountMinor:'40000'}],memberOrder:[a,b,c]};
const bill=()=>({currency:'INR',totalMinor:'140000',contributions:[{memberId:a,amountMinor:'140000'}],allocation:{mode:'equal',participants:[{memberId:a},{memberId:b},{memberId:c}],tieOrder:[a,b,c]}});
const command=(full=bill())=>({schemaVersion:1,operationId:c,kind:'expense.propose',payload:{contextId:b,expenseId:c,revisionId:a,expectedHeadRevisionId:null,title:'Dinner',occurredOn:'2026-11-04',snapshot,sources:[],void:false,bill:full}});
test('full bill stays separate from shared total and participates in immutable consent hash',()=>{
 assert.doesNotThrow(()=>validateBill(bill(),snapshot));
 const first=validateCommand(command());
 const changed=bill(); changed.totalMinor='150000'; changed.contributions[0].amountMinor='150000';
 assert.notEqual(first.requestHash,validateCommand(command(changed)).requestHash);
 assert.equal(first.command.payload.bill.totalMinor,'140000');
});
test('bill rejects unknown, duplicate, unsafe, incomplete and mismatched payer amounts',()=>{
 const cases=[{...bill(),unknown:true},{...bill(),totalMinor:140000},{...bill(),totalMinor:'119999'},
 {...bill(),contributions:[{memberId:a,amountMinor:'139999'}]},
 {...bill(),contributions:[{memberId:a,amountMinor:'70000'},{memberId:a,amountMinor:'70000'}]},
 {...bill(),contributions:[{memberId:a,amountMinor:'119999'},{memberId:b,amountMinor:'20001'}]},
 {...bill(),contributions:[{memberId:'friend',amountMinor:'140000'}]},
 {...bill(),contributions:[{memberId:a,amountMinor:'140000',source:'private'}]}];
 for(const value of cases)assert.throws(()=>validateBill(value,snapshot));
});
test('allocation metadata must reproduce approved shares, including zero and remainder shares',()=>{
 for(const mode of ['exact','percentage','shares']){
  const value=bill(); value.allocation.mode=mode;
  value.allocation.participants=[a,b,c].map(memberId=>({memberId,[mode==='exact'?'amountMinor':'weight']:mode==='exact'?'40000':mode==='percentage'?(memberId===a?'3334':'3333'):'1'}));
  if(mode==='percentage')assert.throws(()=>validateBill(value,snapshot));
  else assert.doesNotThrow(()=>validateBill(value,snapshot));
 }
 const value=bill();value.allocation.tieOrder=[a,a,c];assert.throws(()=>validateBill(value,snapshot));
 value.allocation={...bill().allocation,unknown:true};assert.throws(()=>validateBill(value,snapshot));
});
test('void cannot smuggle replacement bill metadata into a financial reversal',()=>{
 const input=command(); input.payload.snapshot=null;input.payload.void=true;input.payload.expectedHeadRevisionId=b;
 assert.throws(()=>validateCommand(input));
});
