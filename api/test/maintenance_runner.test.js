'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const {createMaintenanceRunner,READINESS_SQL,CLAIM_SQL,BATCH_SQL,YIELD_SQL,FAIL_SQL,JOBS}=require('../src/maintenance/runner');
const lease='11111111-1111-4111-8111-111111111111';
const safe={direct_login:true,memberships:1,capability:true,nested_capability:false,unsafe_capability:false,ddl:false,customer_access:false,protected_tables:2};
function fixture({identity=safe,failBatch=false,more=false,claim=true}={}){
 const calls=[];let ended=false;
 return{calls,get ended(){return ended;},async connect(){},async end(){ended=true;},async query(sql,args){
  calls.push({sql,args});
  if(sql===READINESS_SQL)return{rows:[identity]};
  if(sql===CLAIM_SQL)return{rows:claim?[{lease_token:lease,generation:'1'}]:[]};
  if(sql===BATCH_SQL){if(failBatch)throw Error('synthetic-private-provider-value');return{rows:[{processed:more?100:2,more}]};}
  if(sql===YIELD_SQL||sql===FAIL_SQL)return{rows:[{accepted:true}]};
  return{rows:[]};
 }};
}
test('maintenance defaults off and never creates a connection',async()=>{
 assert.equal((await createMaintenanceRunner({clientFactory:()=>assert.fail('no connect')})()).status,'disabled');
});
test('bounded product jobs use dedicated restricted identity and close connection',async()=>{
 const f=fixture();const result=await createMaintenanceRunner({enabled:true,clientFactory:()=>f})();
 assert.deepEqual(result,{status:'completed',claimed:3,processed:6,failed:0,deferred:0});
 assert.deepEqual(f.calls.filter(x=>x.sql===CLAIM_SQL).map(x=>x.args[0]),JOBS);assert.equal(f.ended,true);
});
test('batches with more work yield durable lease rather than looping forever',async()=>{
 const f=fixture({more:true});const result=await createMaintenanceRunner({enabled:true,clientFactory:()=>f})();
 assert.equal(result.deferred,3);assert.equal(f.calls.filter(x=>x.sql===BATCH_SQL).length,3);assert.equal(f.calls.filter(x=>x.sql===YIELD_SQL).length,3);
});
test('job failure records only fixed notices and preserves next-job isolation',async()=>{
 const f=fixture({failBatch:true}),logs=[];const result=await createMaintenanceRunner({enabled:true,clientFactory:()=>f,logger:{warn:x=>logs.push(x)}})();
 assert.equal(result.failed,3);assert.equal(f.calls.filter(x=>x.sql===FAIL_SQL).length,3);assert.equal(JSON.stringify(logs).includes('synthetic-private'),false);assert.equal(f.ended,true);
});
test('unsafe maintenance identities fail before claim or effects',async()=>{
 for(const change of [{rolsuper:true},{rolbypassrls:true},{memberships:2},{capability:false},{nested_capability:true},{ddl:true},{customer_access:true},{protected_tables:1}]){
  const f=fixture({identity:{...safe,...change}});
  await assert.rejects(createMaintenanceRunner({enabled:true,clientFactory:()=>f})(),/restricted/);
  assert.equal(f.calls.some(x=>x.sql===CLAIM_SQL),false);assert.equal(f.ended,true);
 }
});
test('job budget exhaustion stops before starting a new claim',async()=>{
 const f=fixture(),times=[0,2000];const result=await createMaintenanceRunner({enabled:true,clientFactory:()=>f,maxDurationMs:1000,now:()=>times.shift()??2000})();
 assert.equal(result.status,'budget_exhausted');assert.equal(result.claimed,0);assert.equal(f.ended,true);
});
test('unrecordable failure and malformed results refuse success and close the connection',async()=>{
 for(const mode of ['lease','count','failure']){
  const f=fixture({failBatch:mode==='failure'}),query=f.query.bind(f);
  f.query=async(sql,args)=>sql===CLAIM_SQL&&mode==='lease'?{rows:[{lease_token:'wrong',generation:'1'}]}:sql===BATCH_SQL&&mode==='count'?{rows:[{processed:101,more:false}]}:sql===FAIL_SQL?{rows:[{accepted:false}]}:query(sql,args);
  await assert.rejects(createMaintenanceRunner({enabled:true,clientFactory:()=>f})());assert.equal(f.ended,true);
 }
});

test('disabled one-shot CLI does not require a URL or open any connection',async()=>{
 const {main}=require('../src/maintenance/cli');const output=[];
 await main({args:['--run'],env:{},write:x=>output.push(JSON.parse(x)),clientFactory:()=>assert.fail('must not connect')});
 assert.equal(output[0].status,'disabled');
});

test('maintenance schema creation grant is revoked by the migration identity after owner role reset',()=>{
 const fs=require('node:fs'),path=require('node:path');
 const source=fs.readFileSync(path.join(__dirname,'../../db/supabase/migrations/20261024111632_bounded_operational_maintenance.sql'),'utf8');
 const reset=source.indexOf("select pg_catalog.set_config('role',pg_catalog.current_setting('pandapay.maintenance_migration_role'),true)");
 const revoke=source.indexOf('revoke create on schema maintenance from maintenance_owner;');
 assert.ok(reset>0&&revoke>reset);
});
