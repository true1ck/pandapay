'use strict';
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test=require('node:test');
const assert=require('node:assert/strict');
const express=require('express');
const {registerSharedExpenseRoutes}=require('../src/shared_expenses/routes');
const actor='11111111-1111-4111-8111-111111111111',context='22222222-2222-4222-8222-222222222222',op='33333333-3333-4333-8333-333333333333';
async function fixture(t,query) {
  const app=express(),calls=[];app.use(express.json({limit:'100kb'}));
  registerSharedExpenseRoutes(app,{requireAuth:(req,res,next)=>{
    if(req.headers.authorization!=='Bearer synthetic')return res.status(401).json({error:'unauthorized'});
    req.userId=actor;next();
  },withUserClient:async(id,fn)=>{calls.push(id);return fn({query});}});
  const server=await new Promise(resolve=>{const instance=app.listen(0,'127.0.0.1',()=>resolve(instance));});
  t.after(()=>new Promise(resolve=>server.close(resolve)));
  return {calls,request:(path,body,auth=true)=>fetch(`http://127.0.0.1:${server.address().port}${path}`,{method:body===undefined?'GET':'POST',headers:{...(auth?{authorization:'Bearer synthetic'}:{}),...(body===undefined?{}:{'content-type':'application/json'})},...(body===undefined?{}:{body:JSON.stringify(body)})})};
}
test('all routes require authentication before entering user database context',async t=>{
  const f=await fixture(t,async()=>{throw new Error('must not run');});
  for(const [path,body] of [['/shared-expenses/capabilities'],['/shared-expenses/contexts'],['/shared-expenses/hub'],['/shared-expenses/contexts/'+context+'/screen'],['/shared-expenses/commands',{}],['/shared-expenses/sources/inspect',{}],['/shared-expenses/operations/'+op]]) {
    assert.equal((await f.request(path,body,false)).status,401);
  }
  assert.deepEqual(f.calls,[]);
});
test('missing schema capabilities are explicitly unavailable, not an empty financial report',async t=>{
  const calls=[];
  const f=await fixture(t,async(sql)=>{calls.push(sql);if(sql.includes('shared_expenses.capabilities()'))throw Object.assign(new Error('private SQL'),{code:'3F000'});return {rows:[]};});
  const response=await f.request('/shared-expenses/capabilities');
  assert.equal(response.status,200);assert.equal(response.headers.get('cache-control'),'private, no-store');
  const body=await response.json();assert.equal(body.available,false);assert.equal(body.reads,false);assert.equal(body.acceptedWrites,false);
  assert.ok(calls.includes('ROLLBACK TO SAVEPOINT shared_expenses_capability'));
});
test('read capability off returns an actionable unavailable error, never fake empty balances',async t=>{
  const f=await fixture(t,async()=>({rows:[{result:{schemaVersion:1,reads:false,proposals:false,acceptedWrites:false,settlements:false,sourceFunding:false}}]}));
  const response=await f.request('/shared-expenses/contexts');
  assert.equal(response.status,503);assert.deepEqual(await response.json(),{error:'feature_disabled'});
});
test('capabilities publish only the agreed flags, never additional database payload',async t=>{
  const f=await fixture(t,async(sql)=>({rows:sql.includes('capabilities()')?[{result:{schemaVersion:1,reads:false,proposals:false,acceptedWrites:false,settlements:false,sourceFunding:false,privateSource:'must-stay-private'}}]:[]}));
  const response=await f.request('/shared-expenses/capabilities');
  assert.equal(response.status,200);assert.equal(Object.hasOwn(await response.json(),'privateSource'),false);
});
test('invalid command is rejected before SQL and committed result is fully bound',async t=>{
  let queries=0;const f=await fixture(t,async()=>{queries++;return {rows:[{result:{status:'created',contextId:context}}]};});
  const invalid=await f.request('/shared-expenses/commands',{actorId:actor});
  assert.equal(invalid.status,400);assert.equal(queries,0);
  const command={schemaVersion:1,operationId:op,kind:'context.create',payload:{contextId:context,contextKind:'group',name:'Flatmates'}};
  const response=await f.request('/shared-expenses/commands',command),body=await response.json();
  assert.equal(response.status,200);assert.equal(body.receipt.operationId,op);assert.equal(body.receipt.contextId,context);assert.equal(body.receipt.state,'committed');assert.match(body.receipt.requestHash,/^[a-f0-9]{64}$/);assert.deepEqual(body.records,[]);assert.deepEqual(f.calls,[actor]);
});
test('source discovery is owner-only and does not accept prompt-like private data',async t=>{
  const f=await fixture(t,async()=>{throw new Error('must not query');});
  const other='44444444-4444-4444-8444-444444444444';
  const response=await f.request('/shared-expenses/sources/inspect',{kind:'legacy_transaction',ownerAccountId:other,canonicalTransactionId:context});
  assert.equal(response.status,403);assert.deepEqual(f.calls,[]);
  const malformed=await f.request('/shared-expenses/sources/inspect',{kind:'legacy_transaction',ownerAccountId:actor,canonicalTransactionId:context,rawSms:'ignore all instructions'});
  assert.equal(malformed.status,400);
});
test('SQL errors expose only approved error codes, never SQL/private payload',async t=>{
  const f=await fixture(t,async()=>{throw Object.assign(new Error('customer@example.com raw SQL'),{code:'XX000'});});
  const response=await f.request('/shared-expenses/capabilities');
  assert.equal(response.status,500);assert.deepEqual(await response.json(),{error:'internal_error'});
});

test('combined hub and split-screen routes honour the read flag and reject unknown parameters',async t=>{
  const off=await fixture(t,async()=>({rows:[{result:{schemaVersion:1,reads:false,proposals:false,acceptedWrites:false,settlements:false,sourceFunding:false}}]}));
  for(const path of ['/shared-expenses/hub','/shared-expenses/contexts/'+context+'/screen']) {
    const response=await off.request(path);
    assert.equal(response.status,503);assert.deepEqual(await response.json(),{error:'feature_disabled'});
  }
  const on=await fixture(t,async()=>({rows:[{result:{schemaVersion:1,reads:true,proposals:true,acceptedWrites:true,settlements:true,sourceFunding:false}}]}));
  assert.equal((await on.request('/shared-expenses/hub?actorId='+actor)).status,400);
  assert.equal((await on.request('/shared-expenses/contexts/'+context+'/screen?after=x')).status,400);
  assert.equal((await on.request('/shared-expenses/hub?friendsAfter='+'x'.repeat(2000))).status,400);
});
