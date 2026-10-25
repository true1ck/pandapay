'use strict';
// A repeatable-read export must acquire its session-level UUID fence BEFORE
// BEGIN establishes the snapshot. A transaction lock acquired after that
// snapshot could otherwise miss a deletion committed while it was waiting.
const LOCK_SQL='SELECT pg_catalog.pg_try_advisory_lock_shared(pg_catalog.hashtextextended($1::text,73612)) AS locked';
const UNLOCK_SQL='SELECT pg_catalog.pg_advisory_unlock_shared(pg_catalog.hashtextextended($1::text,73612)) AS unlocked';
async function acquireSnapshotFence(client,id){
 const result=await client.query(LOCK_SQL,[id]);
 if(result.rows[0]?.locked!==true)throw Error('Account lifecycle snapshot must retry');
 return async()=>{const result=await client.query(UNLOCK_SQL,[id]);if(result.rows[0]?.unlocked!==true)throw Error('Uncertain account snapshot fence');};
}
module.exports={acquireSnapshotFence,LOCK_SQL,UNLOCK_SQL};
