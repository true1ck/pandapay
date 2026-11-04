'use strict';
const v=require('./validation');
const {canonicalJson,commandHash}=require('./canonical');
const {projectExpense}=require('./domain');
const {parseSharedExpenseSourceReference}=require('./source_reference');
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
function uuid(value,field) {if(!v.matches(UUID,value))v.fail('INVALID_INPUT',field);return value;}
function text(value,field,max) {if(typeof value!=='string'||!value.trim()||value.length>max||/[\u0000-\u001f\u007f]/.test(value))v.fail('INVALID_INPUT',field);}
function day(value,field) {
  if(!v.matches(/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/,value)||value.startsWith('0000'))v.fail('INVALID_INPUT',field);
  const parsed=new Date(`${value}T00:00:00.000Z`);
  if(!Number.isFinite(parsed.getTime())||parsed.toISOString().slice(0,10)!==value)v.fail('INVALID_INPUT',field);
}
function requireEnum(value,choices,field) {if(!choices.includes(value))v.fail('INVALID_INPUT',field);}
function validateSnapshot(snapshot) {
  projectExpense(snapshot);
  for(const key of ['contributions','shares'])for(const [i,row] of snapshot[key].entries())uuid(row.memberId,`payload.snapshot.${key}[${i}].memberId`);
  for(const [i,id] of snapshot.memberOrder.entries())uuid(id,`payload.snapshot.memberOrder[${i}]`);
}
function proposal(p) {
  v.record(p,['contextId','expenseId','revisionId','expectedHeadRevisionId','snapshot','title','occurredOn','sources','void'],'payload');
  uuid(p.expenseId,'payload.expenseId');uuid(p.revisionId,'payload.revisionId');
  if(p.expectedHeadRevisionId!==null)uuid(p.expectedHeadRevisionId,'payload.expectedHeadRevisionId');
  text(p.title,'payload.title',200);day(p.occurredOn,'payload.occurredOn');
  if(typeof p.void!=='boolean'||(p.void?p.snapshot!==null:p.snapshot===null))v.fail('INVALID_INPUT','payload.snapshot');
  if(!p.void)validateSnapshot(p.snapshot);
  if(!Array.isArray(p.sources)||p.sources.length>8||(p.void&&p.sources.length))v.fail('INVALID_INPUT','payload.sources');
  const sources=new Map(),paid=new Map((p.snapshot?.contributions??[]).map(row=>[row.memberId,BigInt(row.amountMinor)]));
  for(const [i,row] of p.sources.entries()) {
    const path=`payload.sources[${i}]`;
    v.record(row,['payerMemberId','amountMinor','reference'],path);
    uuid(row.payerMemberId,`${path}.payerMemberId`);
    const amount=v.amount(row.amountMinor,`${path}.amountMinor`,{positive:true});
    parseSharedExpenseSourceReference(row.reference);
    if(row.reference.sourceVersion!==undefined&&!v.matches(/^[a-f0-9]{64}$/,row.reference.sourceVersion))v.fail('INVALID_SOURCE_REFERENCE',`${path}.reference.sourceVersion`);
    sources.set(row.payerMemberId,(sources.get(row.payerMemberId)??0n)+amount);
    if(!paid.has(row.payerMemberId)||sources.get(row.payerMemberId)>paid.get(row.payerMemberId))v.fail('SOURCE_OVERALLOCATED',path);
  }
}
function validateCommand(value) {
  // A defensive detached snapshot prevents an in-process caller from changing
  // the financial request after its hash has been derived.
  const serialized=canonicalJson(value),input=JSON.parse(serialized);
  v.record(input,['schemaVersion','operationId','kind','payload']);
  if(input.schemaVersion!==1)v.fail('INVALID_INPUT','schemaVersion');
  uuid(input.operationId,'operationId');
  const p=input.payload;
  v.record(p,['contextId'],'payload','INVALID_INPUT',Object.keys(p??{}).filter(key=>key!=='contextId'));
  uuid(p.contextId,'payload.contextId');
  switch(input.kind) {
    case 'context.create':
      v.record(p,['contextId','contextKind','name'],'payload');requireEnum(p.contextKind,['group','direct'],'payload.contextKind');text(p.name,'payload.name',120);break;
    case 'membership.respond':
      v.record(p,['contextId','memberId','accept'],'payload');uuid(p.memberId,'payload.memberId');if(typeof p.accept!=='boolean')v.fail('INVALID_INPUT','payload.accept');break;
    case 'member.invite':
      v.record(p,['contextId','memberId','displayName'],'payload','INVALID_INPUT',['profileId']);uuid(p.memberId,'payload.memberId');text(p.displayName,'payload.displayName',120);if(Object.hasOwn(p,'profileId'))uuid(p.profileId,'payload.profileId');break;
    case 'expense.propose':proposal(p);break;
    case 'expense.respond':
      v.record(p,['contextId','expenseId','revisionId','decision'],'payload');uuid(p.expenseId,'payload.expenseId');uuid(p.revisionId,'payload.revisionId');requireEnum(p.decision,['approve','reject'],'payload.decision');break;
    case 'settlement.report':
      v.record(p,['contextId','settlementId','payerMemberId','receiverMemberId','amountMinor','currency','method','paidOn'],'payload','INVALID_INPUT',['reference']);
      for(const key of ['settlementId','payerMemberId','receiverMemberId'])uuid(p[key],`payload.${key}`);
      if(p.payerMemberId===p.receiverMemberId)v.fail('INVALID_SETTLEMENT','payload.receiverMemberId');
      v.amount(p.amountMinor,'payload.amountMinor',{positive:true});v.currency(p.currency);requireEnum(p.method,['upi','cash','bank'],'payload.method');day(p.paidOn,'payload.paidOn');
      if(Object.hasOwn(p,'reference')&&(typeof p.reference!=='string'||p.reference.length>128||!v.matches(/^[A-Za-z0-9][A-Za-z0-9:._-]*$/,p.reference)))v.fail('INVALID_INPUT','payload.reference');break;
    case 'settlement.respond':
      v.record(p,['contextId','settlementId','decision'],'payload');uuid(p.settlementId,'payload.settlementId');requireEnum(p.decision,['confirm','reject'],'payload.decision');break;
    default:v.fail('INVALID_COMMAND','kind');
  }
  return {command:input,requestHash:commandHash(input)};
}
const JSON_COMMANDS=Object.freeze({
  'member.invite':'invite_member',
  'expense.propose':'submit_proposal','expense.respond':'respond_expense',
  'settlement.report':'report_settlement','settlement.respond':'respond_settlement',
});
async function executeCommand(client,value) {
  const {command,requestHash}=validateCommand(value),p=command.payload;
  let query,params;
  if(command.kind==='context.create') {
    query='SELECT shared_expenses.create_context($1::uuid,$2::text,$3::text,$4::uuid,$5::text) AS result';
    params=[p.contextId,p.contextKind,p.name,command.operationId,requestHash];
  } else if(command.kind==='membership.respond') {
    query='SELECT shared_expenses.respond_membership($1::uuid,$2::uuid,$3::boolean,$4::uuid,$5::text) AS result';
    params=[p.contextId,p.memberId,p.accept,command.operationId,requestHash];
  } else {
    query=`SELECT shared_expenses.${JSON_COMMANDS[command.kind]}($1::jsonb,$2::uuid,$3::text) AS result`;
    params=[JSON.stringify(p),command.operationId,requestHash];
  }
  const result=await client.query(query,params);
  if(!result.rows[0]||result.rows[0].result===null||typeof result.rows[0].result!=='object')throw new Error('shared_command_result_invalid');
  return {operationId:command.operationId,kind:command.kind,requestHash,contextId:p.contextId,result:result.rows[0].result,state:'committed'};
}
function validateSourceIdentity(value) {
  const input=JSON.parse(canonicalJson(value));
  v.record(input,['kind','ownerAccountId'],'$','INVALID_SOURCE_REFERENCE',['canonicalTransactionId','eventId','foreignPaymentId','localProjectionId']);
  uuid(input.ownerAccountId,'ownerAccountId');
  if(input.kind==='legacy_transaction') {
    v.record(input,['kind','ownerAccountId','canonicalTransactionId'],'$','INVALID_SOURCE_REFERENCE');uuid(input.canonicalTransactionId,'canonicalTransactionId');
  } else if(input.kind==='sms_v2_event') {
    v.record(input,['kind','ownerAccountId','eventId'],'$','INVALID_SOURCE_REFERENCE',['canonicalTransactionId','localProjectionId']);
    if(!v.matches(/^[a-f0-9]{64}$/,input.eventId))v.fail('INVALID_SOURCE_REFERENCE','eventId');
    if(Object.hasOwn(input,'canonicalTransactionId'))uuid(input.canonicalTransactionId,'canonicalTransactionId');
    if(Object.hasOwn(input,'localProjectionId')&&input.localProjectionId!==`v2:${input.eventId}`)v.fail('INVALID_SOURCE_REFERENCE','localProjectionId');
  } else if(input.kind==='confirmed_foreign_payment') {
    v.record(input,['kind','ownerAccountId','foreignPaymentId','canonicalTransactionId'],'$','INVALID_SOURCE_REFERENCE');uuid(input.foreignPaymentId,'foreignPaymentId');uuid(input.canonicalTransactionId,'canonicalTransactionId');
  } else v.fail('INVALID_SOURCE_REFERENCE','kind');
  return input;
}
module.exports={UUID,uuid,validateCommand,executeCommand,validateSourceIdentity};
