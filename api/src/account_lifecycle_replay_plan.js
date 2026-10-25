'use strict';
const {PRODUCT_LIST_SQL}=require('./account_lifecycle_recovery');
const AUTH_LIST_SQL='SELECT * FROM auth_private.list_deletion_tombstones($1::uuid,$2::integer)';
const UUID=/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i;
// Validate the complete bounded plan before any external append or DB replay.
// Existing DB tombstones are included in the external journal on first setup.
async function collectRetainedTombstones({product,auth,retained=[],maxRecords=4096}){
 if(!product?.query||!auth?.query||!Array.isArray(retained)||!Number.isInteger(maxRecords)||maxRecords<1||maxRecords>4096)throw Error('Invalid tombstone review');
 const users=new Map(),requests=new Map();
 function add(value){
  if(!value||Object.keys(value).sort().join(',')!=='generation,request_id,user_id'||!UUID.test(value.user_id)||!UUID.test(value.request_id)||! /^[1-9][0-9]{0,18}$/.test(String(value.generation))||BigInt(value.generation)>9223372036854775807n)throw Error('Invalid tombstone history');
  const row={request_id:value.request_id.toLowerCase(),user_id:value.user_id.toLowerCase(),generation:String(value.generation)},prior=users.get(row.user_id),owner=requests.get(row.request_id);
  if((prior&&JSON.stringify(prior)!==JSON.stringify(row))||(owner&&owner!==row.user_id))throw Error('Conflicting tombstone history');
  users.set(row.user_id,row);requests.set(row.request_id,row.user_id);if(users.size>maxRecords)throw Error('Tombstone journal capacity exceeded');
 }
 for(const row of retained)add(row);
 for(const side of ['product','auth']){
  let cursor=null,finished=false;
  for(let page=0;page<42;page++){
   const result=await (side==='product'?product:auth).query(side==='product'?PRODUCT_LIST_SQL:AUTH_LIST_SQL,[cursor,100]);
   if(!Array.isArray(result.rows)||result.rows.length>100)throw Error('Invalid tombstone page');
   for(const row of result.rows){const user=side==='product'?row.profile_id:row.user_id;if(!UUID.test(user||'')||(cursor&&user.toLowerCase()<=cursor.toLowerCase()))throw Error('Invalid tombstone cursor');add({request_id:row.request_id,user_id:user,generation:String(row.generation)});cursor=user;}
   if(result.rows.length<100){finished=true;break;}
  }
  if(!finished)throw Error('Tombstone journal page limit exceeded');
 }
 return [...users.values()].sort((a,b)=>a.user_id.localeCompare(b.user_id));
}
module.exports={collectRetainedTombstones};
