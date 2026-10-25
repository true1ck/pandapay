'use strict';
const assert=require('node:assert/strict');const {test}=require('node:test');const crypto=require('node:crypto');
const {applyAccountDeletion,createAccountDeletionHandler,validDeletionJob,APPLY_SQL}=require('../src/services/accountLifecycle');
const job=()=>({request_id:crypto.randomUUID(),user_id:crypto.randomUUID(),generation:'1'});
const res=()=>({code:200,status(x){this.code=x;return this;},json(x){this.body=x;return this;}});
test('deletion job validation accepts stable UUID and safe bigint strings only',()=>{
  assert.equal(validDeletionJob(job()),true);
  for(const value of [null,[],{}, {...job(),password:'no'}, {...job(),generation:0}, {...job(),generation:'9223372036854775808'}, {...job(),generation:9007199254740992}, {...job(),generation:'1.1'}, {...job(),user_id:'invalid'}]) assert.equal(validDeletionJob(value),false);
});
test('auth deletion uses one atomic RPC and acknowledges repeats identically',async()=>{
  const value=job(),calls=[];const executor={query:async(sql,args)=>{calls.push([sql,args]);return{rows:[{first_application:false}]};}};
  for(let n=0;n<2;n++)assert.deepEqual(await applyAccountDeletion(executor,value),{applied:true});
  assert.deepEqual(calls[0],[APPLY_SQL,[value.request_id,value.user_id,'1']]);assert.deepEqual(calls[0],calls[1]);
});
test('auth deletion refuses invalid input before database use',async()=>{
  await assert.rejects(applyAccountDeletion({query(){throw Error('must not query');}},{}),error=>error.code==='invalid_deletion_job');
});
test('internal lifecycle handler is disabled by default and returns sanitized failures',async()=>{
  let response=res();await createAccountDeletionHandler({executor:{query(){throw Error('must not query');}}})({body:job()},response);assert.equal(response.code,503);
  response=res();await createAccountDeletionHandler({enabled:true,executor:{}})({body:{}},response);assert.equal(response.code,400);
  const logs=[];response=res();await createAccountDeletionHandler({enabled:true,executor:{query:async()=>{throw Error('secret contact');}},logger:{error:x=>logs.push(x)}})({body:job()},response);
  assert.equal(response.code,503);assert.ok(!JSON.stringify([logs,response.body]).includes('secret contact'));
});
