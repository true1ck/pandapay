const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {bestDuplicate, MAX_TIME_DISTANCE_MS, AMOUNT_TOLERANCE_INR} = require('../src/transaction_dedup');
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
function extract(name, next) { return source.slice(source.indexOf(`async function ${name}(`), source.indexOf(`async function ${next}(`)); }
const detect = new Function('bestDuplicate', 'MAX_TIME_DISTANCE_MS', 'AMOUNT_TOLERANCE_INR', `${extract('detectDuplicates','loadUserCardForState')} return detectDuplicates;`)(bestDuplicate, MAX_TIME_DISTANCE_MS, AMOUNT_TOLERANCE_INR);
const incoming = {newTxnId:'new', amount:100, occurred:'2026-10-02T10:00:00Z', merchantName:'Shop', source:'statement', instrument:'credit_card', entryKind:'spend', userCardId:'card', bankReference:'ABC123456789'};
const existing = {id:'old', amount_inr:100, occurred_at:incoming.occurred, merchant_name:'Shop', source:'sms', instrument:'credit_card', entry_kind:'spend', user_card_id:'card', bank_reference:incoming.bankReference, status:'active'};
test('automatic reference match never creates a pending discrepancy', async () => {
  const calls=[];
  const client={query:async(sql)=>{calls.push(sql);return {rows:[existing]};}};
  const result=await detect(client,'profile',incoming);
  assert.equal(result.automatic,true);
  assert.equal(result.duplicateOf,'old');
  assert.equal(calls.length,1);
});
test('uncertain match creates review record with incoming row suppressed', async () => {
  const calls=[];
  const client={query:async(sql,params)=>{calls.push({sql,params});return {rows:sql.includes('INSERT INTO')?[{id:'review'}]:[{...existing,bank_reference:null}]};}};
  const result=await detect(client,'profile',{...incoming,bankReference:null});
  assert.equal(result.candidateId,'review');
  assert.equal(calls[1].params[5],'new');
});
test('automatic ingestion links source alias and never applies card state', async () => {
  const observations=[];const writes=[];
  const writer=new Function('recordTransactionObservation','detectDuplicates','loadUserCardForState','applyTransactionState',`${extract('insertTransactionAndUpdateState','importParsedMessage')} return insertTransactionAndUpdateState;`)(
    async(...args)=>observations.push(args),async()=>({automatic:true,duplicateOf:'old',transaction:existing}),async()=>({id:'card'}),async()=>{throw Error('must not apply state');});
  const client={query:async(sql,params)=>{writes.push({sql,params});if(sql.includes('INSERT INTO transactions'))return {rowCount:1,rows:[{id:'new'}]};return {rows:[]};}};
  const result=await writer(client,'profile',{...incoming,sourceKey:'key',observationMetadata:{bankReference:incoming.bankReference}});
  assert.equal(result.duplicateKind,'high_confidence');
  assert.equal(result.transaction.id,'old');
  assert.equal(observations.at(-1)[2],'old');
  assert.ok(writes.some(({sql})=>sql.includes("status = 'ignored'")));
});
