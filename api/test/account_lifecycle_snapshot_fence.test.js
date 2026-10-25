'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {acquireSnapshotFence,LOCK_SQL,UNLOCK_SQL}=require('../src/account_lifecycle_snapshot_fence');
test('snapshot fence holds exact UUID on its dedicated session until explicit release',async()=>{
 const calls=[];const client={query:async(sql,args)=>{calls.push([sql,args]);return {rows:[sql===LOCK_SQL?{locked:true}:{unlocked:true}]};}};
 const release=await acquireSnapshotFence(client,'same-uuid');assert.equal(calls.length,1);await release();
 assert.deepEqual(calls,[[LOCK_SQL,['same-uuid']],[UNLOCK_SQL,['same-uuid']]]);
});
test('busy or missing session fence is refused without a blocking wait',async()=>{
 for(const rows of [[],[{locked:false}]])await assert.rejects(acquireSnapshotFence({query:async()=>({rows})},'uuid'),/retry/);
 const release=await acquireSnapshotFence({query:async sql=>({rows:[sql===LOCK_SQL?{locked:true}:{unlocked:false}]})},'uuid');await assert.rejects(release(),/Uncertain/);
});
