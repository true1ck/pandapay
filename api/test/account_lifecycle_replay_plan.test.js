'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),crypto=require('node:crypto');
const {collectRetainedTombstones}=require('../src/account_lifecycle_replay_plan');
const value=()=>({request_id:crypto.randomUUID(),user_id:crypto.randomUUID(),generation:'2'});
const db=rows=>({query:async()=>({rows})});
test('complete replay review includes existing database denials before journal bootstrap',async()=>{
 const a=value(),b=value(),c=value();
 const rows=await collectRetainedTombstones({product:db([{...a,profile_id:a.user_id}]),auth:db([b]),retained:[a,c]});
 assert.equal(rows.length,3);assert.deepEqual(new Set(rows.map(r=>r.user_id)),new Set([a,b,c].map(r=>r.user_id)));
});
test('conflicting account/request/generation history is refused before replay',async()=>{
 const a=value();
 for(const bad of [{...a,generation:'3'},{...a,request_id:crypto.randomUUID()},{...a,user_id:crypto.randomUUID()}])await assert.rejects(collectRetainedTombstones({product:db([]),auth:db([bad]),retained:[a]}),/Conflicting/);
});
test('capacity and malformed record bounds fail closed',async()=>{
 await assert.rejects(collectRetainedTombstones({product:db([]),auth:db([]),retained:[{}]}),/Invalid/);
 await assert.rejects(collectRetainedTombstones({product:db([]),auth:db([]),retained:[value(),value()],maxRecords:1}),/capacity/);
});
