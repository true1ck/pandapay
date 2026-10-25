'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createMaintenanceRetention}=require('../src/services/maintenanceRetention');
const {main,CHECK_SQL}=require('../src/services/maintenanceCli');
test('auth scheduled retention is opt-in and has no implicit policy',async()=>{
 assert.equal(createMaintenanceRetention({env:{},apply:true}),undefined);
 assert.equal(createMaintenanceRetention({env:{AUTH_RETENTION_MAINTENANCE_ENABLED:'true'},apply:false}),undefined);
 assert.throws(()=>createMaintenanceRetention({env:{AUTH_RETENTION_MAINTENANCE_ENABLED:'true'},apply:true}),/explicit/);
 const output=[];await main({args:[],env:{},write:x=>output.push(JSON.parse(x)),clientFactory:()=>assert.fail('disabled')});assert.equal(output[0].status,'disabled');
 await assert.rejects(main({args:['--run'],env:{}}),/Explicit/);
});
function fixture(identity={}){
 const calls=[];let ended=false;
 return{calls,get ended(){return ended;},async connect(){},async end(){ended=true;},async query(sql,args){calls.push({sql,args});
 if(sql===CHECK_SQL)return{rows:[{direct_login:true,memberships:1,capability:true,...identity}]};
 if(sql.includes('claim_auth_retention'))return{rows:[{lease_token:'11111111-1111-4111-8111-111111111111'}]};
 return{rows:[{accepted:true}]};}};
}
const env={AUTH_RETENTION_MAINTENANCE_ENABLED:'true',AUTH_MAINTENANCE_DATABASE_URL:'postgresql://synthetic:fixture@127.0.0.1/maintenance_test',NODE_ENV:'test',DB_SSL:'false'};
test('auth maintenance records bounded counts through separate product capability',async()=>{
 const f=fixture(),output=[];
 await main({args:['--run','--apply'],env,write:x=>output.push(JSON.parse(x)),clientFactory:()=>f,retentionFactory:()=>async()=>({status:'completed',deleted:2,more:false})});
 assert.equal(output[0].deleted,2);assert.deepEqual(f.calls.find(x=>x.sql.includes('finish_external')).args,['11111111-1111-4111-8111-111111111111',2,false]);assert.equal(f.ended,true);
});
test('busy auth session defers without claiming completed deletion',async()=>{
 const f=fixture();await main({args:['--run','--apply'],env,write:()=>{},clientFactory:()=>f,retentionFactory:()=>async()=>({status:'busy',deleted:0,more:false})});
 assert.ok(f.calls.some(x=>x.sql.includes('defer_auth_retention')));assert.equal(f.calls.some(x=>x.sql.includes('finish_external')),false);
});
test('auth coordinator rejects direct access, broad role and failed effect before receipt',async()=>{
 for(const mode of ['raw','role','effect']){
  const f=fixture(mode==='raw'?{raw_access:true}:mode==='role'?{rolsuper:true}:{});
  await assert.rejects(main({args:['--run','--apply'],env,write:()=>assert.fail('no success'),clientFactory:()=>f,retentionFactory:()=>async()=>{throw Error('synthetic-secret');}}));
  assert.equal(f.ended,true);assert.equal(f.calls.some(x=>x.sql.includes('claim_auth_retention')),mode==='effect');
  assert.equal(f.calls.some(x=>x.sql.includes('fail_auth_retention')),mode==='effect');
 }
});
