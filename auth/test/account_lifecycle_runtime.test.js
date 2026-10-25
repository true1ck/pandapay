'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createAccountLifecycleRuntime}=require('../src/services/accountLifecycleRuntime');
const {configureAuthLifecycleLogin}=require('../scripts/authLifecyclePermissions');
const valid={bounded:true,can_apply:true,can_list:true,direct_users:false,can_create:false,unsafe_capability:false,unsafe_membership:false};
function fixture(row=valid){
 let options,ended=false,errorHandler;
 class PoolClass{constructor(value){options=value;}on(name,handler){assert.equal(name,'error');errorHandler=handler;}async query(){return {rows:row?[row]:[]};}async end(){ended=true;}}
 const messages=[];
 const runtime=createAccountLifecycleRuntime({env:{ACCOUNT_LIFECYCLE_ENABLED:'true',AUTH_LIFECYCLE_DATABASE_URL:'postgresql://fixture:synthetic@127.0.0.1/auth_test',DB_SSL:'false',NODE_ENV:'test'},PoolClass,logger:{error:(...args)=>messages.push(args)}});
 return {runtime,get options(){return options;},get ended(){return ended;},error:()=>errorHandler(new Error('private credential must never escape')),messages};
}
test('auth lifecycle runtime is opt-in and requires a dedicated database',()=>{
 assert.equal(createAccountLifecycleRuntime({env:{}}),null);
 assert.throws(()=>createAccountLifecycleRuntime({env:{ACCOUNT_LIFECYCLE_ENABLED:'true'}}),/Dedicated/);
});
test('auth lifecycle runtime bounds connections, sanitizes errors and closes its own pool',async()=>{
 const f=fixture();assert.equal(f.options.max,2);assert.equal(f.options.statement_timeout,5000);
 await f.runtime.readiness();f.error();assert.doesNotMatch(JSON.stringify(f.messages),/private credential/);
 await f.runtime.close();assert.equal(f.ended,true);
});
test('auth lifecycle readiness rejects missing permissions and broadened identities',async()=>{
 for(const key of Object.keys(valid)){const f=fixture({...valid,[key]:!valid[key]});await assert.rejects(f.runtime.readiness(),/Unsafe/);await f.runtime.close();}
 const f=fixture(null);await assert.rejects(f.runtime.readiness(),/Unsafe/);await f.runtime.close();
});
function bootstrap({existing=false,unsafe=false,memberships=[],nested=false}={}){
 const calls=[];
 return {calls,async query(sql,args){calls.push({sql,args});
  if(sql.includes("WHERE rolname='pandapay_auth_lifecycle'"))return {rows:[{rolcanlogin:false,rolsuper:unsafe,rolbypassrls:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false}]};
  if(sql.includes("WHERE member='pandapay_auth_lifecycle'"))return {rows:nested?[{}]:[]};
  if(sql.includes("WHERE rolname='auth_lifecycle_runtime'"))return {rows:existing?[{rolcanlogin:true,rolinherit:true,rolsuper:false,rolbypassrls:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false}]:[]};
  if(sql.startsWith('SELECT pg_catalog.quote_literal'))return {rows:[{value:"'synthetic-only-password'"}]};
  if(sql.includes('SELECT p.rolname'))return {rows:memberships.map(rolname=>({rolname}))};
  if(sql.startsWith('SELECT current_database'))return {rows:[{name:'auth_fixture'}]};
  return {rows:[]};
 }};
}
test('auth lifecycle bootstrap blank config does nothing; malformed secrets are refused',async()=>{
 const client=bootstrap();assert.equal(await configureAuthLifecycleLogin(client,{}),false);assert.equal(client.calls.length,0);
 for(const value of ['short','a'.repeat(32)+'\0'])await assert.rejects(configureAuthLifecycleLogin(client,{AUTH_LIFECYCLE_DB_PASSWORD:value}),/invalid/);
});
test('auth lifecycle bootstrap creates only the dedicated login and never rotates an existing password',async()=>{
 for(const existing of [false,true]){const client=bootstrap({existing});assert.equal(await configureAuthLifecycleLogin(client,{AUTH_LIFECYCLE_DB_PASSWORD:'a'.repeat(32)}),true);
 assert.equal(client.calls.filter(c=>c.sql.startsWith('CREATE ROLE')).length,existing?0:1);
 assert.equal(client.calls.some(c=>c.sql.startsWith('ALTER ROLE')),false);
 assert.ok(client.calls.some(c=>c.sql==='GRANT pandapay_auth_lifecycle TO auth_lifecycle_runtime'));
 assert.equal(client.calls.some(c=>/GRANT.*public\./.test(c.sql)),false);}
});
test('auth lifecycle bootstrap refuses broad capability and unexpected memberships',async()=>{
 for(const options of [{unsafe:true},{nested:true},{existing:true,memberships:['app_user']}])await assert.rejects(configureAuthLifecycleLogin(bootstrap(options),{AUTH_LIFECYCLE_DB_PASSWORD:'a'.repeat(32)}),/unsafe|unreviewed|Unreviewed/);
});
