'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {validateCommand,executeCommand,validateSourceIdentity}=require('../src/shared_expenses/commands');
const actor='11111111-1111-4111-8111-111111111111',context='22222222-2222-4222-8222-222222222222',op='33333333-3333-4333-8333-333333333333';
const member='44444444-4444-4444-8444-444444444444';
const command=()=>({schemaVersion:1,operationId:op,kind:'context.create',payload:{contextId:context,contextKind:'group',name:'Flatmates'}});
test('closed command retains exact canonical envelope and deterministic full-envelope hash',()=>{
  const before=command(),result=validateCommand(before);
  assert.deepEqual(result.command,before);
  assert.match(result.requestHash,/^[a-f0-9]{64}$/);
  assert.notEqual(validateCommand({...before,operationId:member}).requestHash,result.requestHash);
  assert.notEqual(result.command,before);
});
test('reject wrong schema/kind/UUID, unknown properties and invalid names before SQL',()=>{
  for(const input of [null,[],{...command(),schemaVersion:2},{...command(),unknown:true},{...command(),kind:'balance.patch'},{...command(),operationId:'v2:'+'a'.repeat(64)},{...command(),payload:{...command().payload,name:' '}},{...command(),payload:{...command().payload,name:'x'.repeat(121)}},{...command(),payload:{...command().payload,name:'bad\u0000name'}},{...command(),payload:{...command().payload,name:'bad\nname'}}]) {
    assert.throws(()=>validateCommand(input));
  }
});
test('expense boundary validates UUID members, sums, exact dates and source payer funding',()=>{
  const input={...command(),kind:'expense.propose',payload:{contextId:context,expenseId:op,revisionId:member,expectedHeadRevisionId:null,snapshot:{currency:'INR',totalMinor:'100',contributions:[{memberId:actor,amountMinor:'100'}],shares:[{memberId:member,amountMinor:'100'}],memberOrder:[actor,member]},title:'Dinner',occurredOn:'2026-11-04',sources:[],void:false}};
  assert.equal(validateCommand(input).command.payload.snapshot.totalMinor,'100');
  for(const payload of [{...input.payload,occurredOn:'2026-02-30'},{...input.payload,snapshot:{...input.payload.snapshot,totalMinor:100}},{...input.payload,snapshot:{...input.payload.snapshot,contributions:[{memberId:'friend',amountMinor:'100'}]}},{...input.payload,sources:[{payerMemberId:actor,amountMinor:'101',reference:{kind:'legacy_transaction',ownerAccountId:actor,canonicalTransactionId:op,sourceVersion:'a'.repeat(64)}}]}]) {
    assert.throws(()=>validateCommand({...input,payload}));
  }
});
test('settlement is reported, never confirmed from an arbitrary callback',()=>{
  const input={...command(),kind:'settlement.report',payload:{contextId:context,settlementId:op,payerMemberId:actor,receiverMemberId:member,amountMinor:'30000',currency:'INR',method:'upi',paidOn:'2026-11-04'}};
  assert.equal(validateCommand(input).command.payload.amountMinor,'30000');
  assert.throws(()=>validateCommand({...input,payload:{...input.payload,status:'success'}}));
  assert.throws(()=>validateCommand({...input,payload:{...input.payload,receiverMemberId:actor}}));
});
test('dispatch calls only a fixed function with parameterized input and returns a bound receipt',async()=>{
  const calls=[];
  const client={query:async(sql,params)=>{calls.push({sql,params});return {rows:[{result:{contextId:context,status:'created'}}]};}};
  const result=await executeCommand(client,command());
  assert.equal(calls.length,1);assert.match(calls[0].sql,/shared_expenses\.create_context\(/);
  assert.equal(calls[0].params[0],context);assert.equal(calls[0].params[2],'Flatmates');
  assert.deepEqual(result,{operationId:op,kind:'context.create',requestHash:validateCommand(command()).requestHash,contextId:context,result:{contextId:context,status:'created'},state:'committed'});
});
test('source discovery has closed identity-only shapes and never fabricates a local UUID',()=>{
  assert.deepEqual(validateSourceIdentity({kind:'sms_v2_event',ownerAccountId:actor,eventId:'a'.repeat(64)}),{kind:'sms_v2_event',ownerAccountId:actor,eventId:'a'.repeat(64)});
  assert.throws(()=>validateSourceIdentity({kind:'legacy_transaction',ownerAccountId:actor,canonicalTransactionId:'v2:'+'a'.repeat(64)}));
  assert.throws(()=>validateSourceIdentity({kind:'sms_v2_event',ownerAccountId:actor,eventId:'a'.repeat(64),rawSms:'secret'}));
});
test('member invitation is a bounded identity proposal, never implicit debt acceptance',()=>{
  const input={...command(),kind:'member.invite',payload:{contextId:context,memberId:member,displayName:'Rahul',profileId:actor}};
  assert.equal(validateCommand(input).command.kind,'member.invite');
  assert.throws(()=>validateCommand({...input,payload:{...input.payload,phone:'+919999999999'}}));
});

test('member.rename validates its closed payload and the shared label rules', () => {
  const base={schemaVersion:1,operationId:op,kind:'member.rename'};
  const ok={contextId:context,memberId:member,displayName:'  Rahul   K '};
  assert.equal(validateCommand({...base,payload:ok}).command.kind,'member.rename');
  for(const displayName of ['','   ','\n\t',7,null,'x'.repeat(401)])assert.throws(()=>validateCommand({...base,payload:{...ok,displayName}}),{code:'INVALID_INPUT'},String(displayName).slice(0,10));
  assert.throws(()=>validateCommand({...base,payload:{contextId:context,memberId:member}}),{code:'INVALID_INPUT'});
  assert.throws(()=>validateCommand({...base,payload:{...ok,extra:1}}),{code:'INVALID_INPUT'});
  assert.throws(()=>validateCommand({...base,payload:{...ok,memberId:'nope'}}),{code:'INVALID_INPUT'});
  assert.equal(validateCommand({...base,payload:{...ok,displayName:'x'.repeat(200)}}).command.payload.displayName.length,200,'long text is accepted here and capped to 40 by the database');
});
