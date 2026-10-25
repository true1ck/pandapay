'use strict';
const assert = require('node:assert/strict');
const { test } = require('node:test');
const crypto = require('node:crypto');
const { createAccountLifecycleHandlers, REQUEST_SQL, CANCEL_SQL } = require('../src/account_lifecycle_routes');
const { createAccountLifecycleWorker, createAuthDeletionClient, CLAIM_SQL } = require('../src/account_lifecycle_worker');
function workerFixture(options){
  if(!options.enabled)return createAccountLifecycleWorker(options);
  let checkpoint={journal_id:'a'.repeat(64),sequence:0,head:'b'.repeat(64)};
  const underlying=options.pool;
  const pool={query:(...args)=>underlying.query(...args),connect:async()=>({release(){},query:async(sql,args)=>{
    if(sql.includes('journal_checkpoint'))return {rows:[{...checkpoint}]};
    if(sql.includes('advance_journal')){checkpoint={journal_id:args[0],sequence:Number(args[1])+1,head:args[3]};return {rows:[]};}
    if(['BEGIN','COMMIT','ROLLBACK'].includes(sql)||sql.startsWith('SET LOCAL'))return {rows:[]};
    return underlying.query(sql,args);
  }})};
  return createAccountLifecycleWorker({...options,pool,journal:{inspect:async()=>({...checkpoint}),append:async(_,old)=>({...old,sequence:old.sequence+1,head:'c'.repeat(64)})}});
}
const job = () => ({ request_id:crypto.randomUUID(),profile_id:crypto.randomUUID(),lease_token:crypto.randomUUID(),generation:'1' });
const response = () => ({ code:200,status(code){this.code=code;return this;},json(body){this.body=body;return this;} });
test('account lifecycle routes preserve existing payload and default legacy behavior', async () => {
  const calls=[]; const row={deletion_requested_at:'date',deletion_due_at:'later',private:'never return'};
  const handlers=createAccountLifecycleHandlers({withUserClient:async (id,fn)=>fn({query:async(sql,args)=>{calls.push([id,sql,args]);return{rows:[row]};}})});
  const res=response();await handlers.requestDeletion({userId:'uuid'},res);
  assert.deepEqual(res.body,{profile:{deletion_requested_at:'date',deletion_due_at:'later'}});
  assert.match(calls[0][1],/UPDATE profiles/);assert.deepEqual(calls[0][2],['uuid']);
});
test('enabled deletion request and cancellation use UUID-scoped durable RPCs',async()=>{
  const calls=[];const handlers=createAccountLifecycleHandlers({enabled:true,withUserClient:async(id,fn)=>fn({query:async(sql,args)=>{calls.push([sql,args]);return{rows:[]};}})});
  const req={userId:crypto.randomUUID()};for(const fn of [handlers.requestDeletion,handlers.cancelDeletion]){const res=response();await fn(req,res);assert.deepEqual(res.body,{profile:null});}
  assert.deepEqual(calls,[[REQUEST_SQL,[req.userId]],[CANCEL_SQL,[req.userId]]]);
});
test('deletion errors expose fixed status only, not database contacts or credentials',async()=>{
  for(const [code,status] of [['55000',409],['42501',403],['unexpected',500]]){
    const logs=[];const handler=createAccountLifecycleHandlers({enabled:true,logger:{error:x=>logs.push(x)},withUserClient:async()=>{throw Object.assign(new Error('secret phone'),{code});}}).cancelDeletion;
    const res=response();await handler({userId:'uuid'},res);assert.equal(res.code,status);assert.ok(!JSON.stringify([res.body,logs]).includes('secret phone'));
  }
});
test('worker disabled by default never touches databases or auth',async()=>{
  assert.equal((await workerFixture({pool:{query(){throw Error('called');}}})()).skipped,'disabled');
});
test('worker claims each job immediately, applies stable identity and acknowledges after success',async()=>{
  const first=job(),calls=[];let claimed=0;
  const pool={query:async(sql,args)=>{calls.push([sql,args]);return sql===CLAIM_SQL?{rows:claimed++===0?[first]:[]}:{rows:[{acknowledged:true}]};}};
  const worker=workerFixture({pool,enabled:true,applyAuthDeletion:async data=>{assert.deepEqual(data,{request_id:first.request_id,user_id:first.profile_id,generation:'1'});return{applied:true};}});
  assert.deepEqual(await worker(),{claimed:1,completed:1,failed:0,deferred:0});assert.deepEqual(calls[0][1],[1]);assert.equal(calls[1][1][2],true);
});
test('worker converts remote failure to bounded retry without recording remote error details',async()=>{
  const first=job(),calls=[],logs=[];let n=0;const worker=workerFixture({enabled:true,pool:{query:async(sql,args)=>{calls.push(args);return sql===CLAIM_SQL?{rows:n++===0?[first]:[]}:{rows:[{acknowledged:true}]};}},applyAuthDeletion:async()=>{throw Error('provider secret');},logger:{warn:x=>logs.push(x)}});
  const result=await worker();assert.equal(result.failed,1);assert.equal(calls[1][2],false);assert.ok(!JSON.stringify(logs).includes('provider secret'));
});
test('worker limits each cycle to 25 jobs and rejects malformed database results',async()=>{
  let count=0;const worker=workerFixture({enabled:true,pool:{query:async sql=>sql===CLAIM_SQL?{rows:[job()]}:{rows:[{acknowledged:true}]}},applyAuthDeletion:async()=>{count++;return{applied:true};}});
  assert.equal((await worker()).claimed,25);assert.equal(count,25);
  await assert.rejects(workerFixture({enabled:true,pool:{query:async()=>({rows:[{},{}]})},applyAuthDeletion:async()=>{}})(),/Invalid lifecycle batch/);
});
test('worker does not overlap cycles and releases running fence after database error',async()=>{
  let release;const hold=new Promise(resolve=>{release=resolve;});let first=true;
  const worker=workerFixture({enabled:true,pool:{query:async()=>{if(first){first=false;await hold;}return{rows:[]};}},applyAuthDeletion:async()=>{}});
  const pending=worker();assert.equal((await worker()).skipped,'already_running');release();await pending;assert.equal((await worker()).claimed,0);
});
test('worker checks five-minute budget between jobs',async()=>{
  let ticks=0;const worker=workerFixture({enabled:true,now:()=>ticks++*300000,pool:{query:async()=>{throw Error('must not claim');}},applyAuthDeletion:async()=>{}});
  assert.equal((await worker()).claimed,0);
});
test('private auth client has timeout, fixed endpoint, secret header and redirect refusal',async()=>{
  const client=createAuthDeletionClient({baseUrl:'http://auth:3001',serviceSecret:'x'.repeat(32),fetchImpl:async(url,options)=>{
    assert.equal(url,'http://auth:3001/internal/account/deletion/apply');assert.equal(options.redirect,'error');assert.equal(options.headers['x-auth-service-secret'],'x'.repeat(32));assert.ok(options.signal);return{ok:true,json:async()=>({applied:true,extra:'ignored'})};
  }});assert.deepEqual(await client({}),{applied:true});
  assert.throws(()=>createAuthDeletionClient({baseUrl:'https://user:secret@auth',serviceSecret:'x'.repeat(32)}),/Invalid/);
});
const {reconcileAccountLifecycleTombstones,PRODUCT_LIST_SQL,PRODUCT_REPLAY_SQL}=require('../src/account_lifecycle_recovery');
const AUTH_LIST_SQL='SELECT * FROM auth_private.list_deletion_tombstones($1::uuid,$2::integer)';
const APPLY_SQL='SELECT auth_private.apply_account_deletion($1::uuid,$2::uuid,$3::bigint) AS first_application';
test('recovery refuses running services and replays latest external journal plus both databases',async()=>{
  await assert.rejects(reconcileAccountLifecycleTombstones({}),/quiesced/);
  const a=job(),b=job(),external={request_id:crypto.randomUUID(),user_id:crypto.randomUUID(),generation:'4'},calls=[];
  const product={query:async(sql,args)=>{calls.push(['product',sql,args]);return{rows:sql===PRODUCT_LIST_SQL?[{request_id:a.request_id,profile_id:a.profile_id,generation:a.generation}]:[]};}};
  const auth={query:async(sql,args)=>{calls.push(['auth',sql,args]);return{rows:sql===AUTH_LIST_SQL?[{request_id:b.request_id,user_id:b.profile_id,generation:b.generation}]:[]};}};
  const result=await reconcileAccountLifecycleTombstones({product,auth,quiesced:true,additionalTombstones:[external]});
  assert.deepEqual(result,{journalRecords:1,productRecords:1,authRecords:1});
  assert.equal(calls.filter(x=>x[1]===PRODUCT_REPLAY_SQL).length,3);assert.equal(calls.filter(x=>x[1]===APPLY_SQL).length,3);
});
test('recovery rejects malformed records and non-progressing pagination',async()=>{
  const product={query:async()=>({rows:[]})},auth={query:async()=>({rows:[]})};
  await assert.rejects(reconcileAccountLifecycleTombstones({product,auth,quiesced:true,additionalTombstones:[{}]}),/Invalid retained/);
  const ids=Array.from({length:100},()=>crypto.randomUUID()).sort();const rows=ids.map(id=>({profile_id:id,request_id:crypto.randomUUID(),generation:'1'}));
  product.query=async sql=>({rows:sql===PRODUCT_LIST_SQL?rows:[]});
  await assert.rejects(reconcileAccountLifecycleTombstones({product,auth,quiesced:true,maxPages:2}),/ordering/);
});
