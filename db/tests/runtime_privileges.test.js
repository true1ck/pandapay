'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const {evaluatePolicy,auditRuntimePrivileges,parseArgs,loadPolicy,validatePolicy,connectionOptions,QUERIES}=require('../scripts/audit_runtime_privileges');

function policy(){return {format:'pandapay-runtime-privilege-policy-v1',scope:'fixture',managedSchemas:['private'],
 roles:[{name:'runtime_test',kind:'runtime',required:true},{name:'definer_owner_test',kind:'owner',required:false}],
 ledgers:['private.schema_migrations'],memberships:[],restrictedRoles:[],requiredRoutineAccess:[],acceptedFindings:[]};}
function inventory(){return Object.fromEntries(Object.keys(QUERIES).map(key=>[key,key==='metadata'?{server_version_num:180004,read_only:'on',isolation:'repeatable read'}:key==='roles'?[{name:'runtime_test',login:true},{name:'definer_owner_test',login:false}]:[]]));}
function codes(report){return report.findings.map(value=>value.code);}

test('reviewed healthy role inventory passes without altering source policy',()=>{
 const p=policy(),i=inventory(),before=JSON.stringify(p);assert.equal(evaluatePolicy(i,p).strict_pass,true);assert.equal(JSON.stringify(p),before);
});
test('explicit forbidden routine access fails for effective inherited/direct/PUBLIC execution, even without a PUBLIC ACL',()=>{
 const p=policy(),i=inventory();p.roles.push({name:'anonymous_fixture',kind:'exposure',required:false});
 p.forbiddenRoutineAccess=[{role:'anonymous_fixture',identity:'private.backend_rpc()'}];
 i.roles.push({name:'anonymous_fixture',login:false});
 i.routines=[{schema:'private',name:'backend_rpc',identity:'private.backend_rpc()',security_definer:false,acl:[]}];
 i.effectiveRoutines=[{role:'anonymous_fixture',schema:'private',identity:'private.backend_rpc()',execute:true}];
 assert.ok(codes(evaluatePolicy(i,p)).includes('forbidden_routine_execute'));
 i.effectiveRoutines[0].execute=false;assert.equal(evaluatePolicy(i,p).strict_pass,true);
 p.forbiddenRoutineAccess=[{role:'unknown',identity:'private.backend_rpc()'}];assert.throws(()=>validatePolicy(p));
 p.forbiddenRoutineAccess='invalid';assert.throws(()=>validatePolicy(p));
});
test('PUBLIC relation and column access and effective migration-ledger access are blocking',()=>{
 const i=inventory();i.relations=[{schema:'private',name:'schema_migrations',kind:'r',rls:true,force_rls:true,acl:[{grantee:'PUBLIC',privilege:'SELECT'}]}];
 i.columns=[{schema:'private',relation:'schema_migrations',name:'checksum',acl:[{grantee:'PUBLIC',privilege:'UPDATE'}]}];
 i.effectiveRelations=[{role:'runtime_test',schema:'private',relation:'schema_migrations',privileges:['SELECT']}];
 const result=evaluatePolicy(i,policy());for(const code of ['public_relation_grant','public_column_grant','runtime_migration_ledger_access'])assert.ok(codes(result).includes(code));assert.equal(result.strict_pass,false);
});
test('owner/superuser/RLS/view and DDL-like grants are inventoried as failures',()=>{
 const i=inventory();i.roles[0].bypass_rls=true;i.relations=[{schema:'private',name:'data',kind:'r',owner:'runtime_test',rls:false,force_rls:false,acl:[]},{schema:'private',name:'visible',kind:'v',security_invoker:false,acl:[]}];
 i.effectiveSchemas=[{role:'runtime_test',schema:'private',create:true}];i.effectiveDatabase=[{role:'runtime_test',create:true}];
 i.effectiveRelations=[{role:'runtime_test',schema:'private',relation:'data',privileges:['TRUNCATE','SELECT']}];
 const result=evaluatePolicy(i,policy());for(const code of ['privileged_role','runtime_owns_relation','table_rls_disabled','table_force_rls_disabled','view_owner_execution','runtime_schema_create','runtime_database_create','runtime_ddl_like_privilege','effective_access_without_rls'])assert.ok(codes(result).includes(code),code);
});
test('nested membership and SET/ADMIN permission to definer owners fail',()=>{
 const i=inventory();i.memberships=[{member:'runtime_test',role:'definer_owner_test',inherit:false,can_set:true,admin:true,parent_superuser:true}];
 const result=evaluatePolicy(i,policy());for(const code of ['unreviewed_membership','membership_admin_option','privileged_membership','definer_owner_reachable'])assert.ok(codes(result).includes(code));
});
test('definer bodies remain fingerprints; unsafe ownership/search paths/PUBLIC execution fail',()=>{
 const i=inventory();i.routines=[{schema:'private',name:'secret',identity:'private.secret()',security_definer:true,owner:'unreviewed_owner',search_path:null,acl:[{grantee:'PUBLIC',privilege:'EXECUTE'}],body_fingerprint:'0'.repeat(32)}];
 const result=evaluatePolicy(i,policy());for(const code of ['definer_owner_unreviewed','definer_search_path_unfixed','public_definer_execute'])assert.ok(codes(result).includes(code));
 i.routines[0].owner='definer_owner_test';i.routines[0].search_path='search_path=public';assert.ok(codes(evaluatePolicy(i,policy())).includes('definer_search_path_requires_review'));
 i.routines[0].search_path='search_path=""';i.routines[0].acl=[];assert.equal(evaluatePolicy(i,policy()).strict_pass,true);
});
test('explicit and implicit future PUBLIC defaults and runtime table defaults require review',()=>{
 const i=inventory();i.defaults=[{schema:null,kind:'r',owner:'deployment_admin',acl:[{grantee:'runtime_test',privilege:'DELETE'}]}];
 i.routineCreationDefaults=[{schema:'private',owner:'deployment_admin',acl:[{grantee:'PUBLIC',privilege:'EXECUTE'}]}];
 const result=evaluatePolicy(i,policy());assert.ok(codes(result).includes('broad_default_privileges'));assert.ok(codes(result).includes('future_public_routine_execute'));
});
test('dedicated service roles cannot gain unexpected direct table/column or routine access',()=>{
 const p=policy(),i=inventory();p.restrictedRoles=[{role:'runtime_test',relations:[],routines:['private.allowed()']}];p.requiredRoutineAccess=[{role:'runtime_test',identity:'private.allowed()'}];
 i.effectiveColumns=[{role:'runtime_test',schema:'private',relation:'data',column:'secret',privileges:['SELECT']}];i.effectiveRoutines=[{role:'runtime_test',schema:'private',identity:'private.unreviewed()',execute:true}];
 const result=evaluatePolicy(i,p);for(const code of ['capability_direct_relation_access','capability_unreviewed_execute','required_routine_access_missing'])assert.ok(codes(result).includes(code));
});
test('exceptions are exact, expiring and invalidated by object/body drift',()=>{
 const i=inventory(),p=policy(),now=Date.parse('2026-10-24T00:00:00.000Z');i.routines=[{schema:'private',identity:'private.secret()',security_definer:true,owner:'definer_owner_test',search_path:'search_path=""',acl:[{grantee:'PUBLIC',privilege:'EXECUTE'}],body_fingerprint:'0'.repeat(32)}];
 const first=evaluatePolicy(i,p,now);p.acceptedFindings=[{fingerprint:first.findings[0].fingerprint,reason:'Temporary reviewed compatibility exception.',expiresAt:'2026-10-25T00:00:00.000Z'}];
 assert.equal(evaluatePolicy(i,p,now).strict_pass,true);assert.equal(evaluatePolicy(i,p,now+86400000).strict_pass,false);i.routines[0].body_fingerprint='1'.repeat(32);assert.equal(evaluatePolicy(i,p,now).strict_pass,false);
});
test('audit uses a bounded repeatable-read read-only transaction and catalog-only queries',async()=>{
 const i=inventory(),calls=[];const client={async query(sql,params){calls.push({sql,params});const entry=Object.entries(QUERIES).find(([,query])=>sql.endsWith(query));return {rows:entry?entry[0]==='metadata'?[i.metadata]:i[entry[0]]:[]};}};
 const result=await auditRuntimePrivileges(client,{policy:policy(),now:0});assert.equal(result.complete,true);assert.equal(result.strict_pass,true);
 assert.match(calls[0].sql,/READ ONLY/);assert.equal(calls.at(-1).sql,'COMMIT');assert.ok(calls.some(call=>/statement_timeout='5000ms'/.test(call.sql)));
 for(const call of calls.filter(value=>value.params?.length))assert.equal(call.params[1],10001);
 assert.ok(!calls.some(call=>/pg_get_functiondef|FROM public\.|FROM private\./.test(call.sql)));
});
test('truncated catalog inventory fails closed and rolls back',async()=>{
 const calls=[];const client={async query(sql){calls.push(sql);if(sql===QUERIES.metadata)return {rows:[{server_version_num:180004,read_only:'on',isolation:'repeatable read'}]};if(sql.endsWith(QUERIES.databases))return {rows:[{},{}]};return {rows:[]};}};
 await assert.rejects(auditRuntimePrivileges(client,{policy:policy(),limit:1}),/limit exceeded/);assert.equal(calls.at(-1),'ROLLBACK');assert.ok(!calls.includes('COMMIT'));
});
test('database errors roll back and do not produce a partial report',async()=>{
 const calls=[];const client={async query(sql){calls.push(sql);if(sql===QUERIES.metadata)throw new Error('synthetic failure');return {rows:[]};}};
 await assert.rejects(auditRuntimePrivileges(client,{policy:policy()}),/synthetic failure/);assert.equal(calls.at(-1),'ROLLBACK');
});
test('invalid/missing roles, policy exceptions and arguments fail safely',()=>{
 assert.throws(()=>parseArgs(['--runtime-role','PUBLIC']));assert.throws(()=>parseArgs(['--database-url','secret']));assert.throws(()=>parseArgs(['--scope','other']));
 const p=policy();p.roles.push({...p.roles[0]});assert.throws(()=>validatePolicy(p));assert.ok(codes(evaluatePolicy({...inventory(),roles:[]},policy())).includes('required_role_missing'));
 const p2=policy();p2.acceptedFindings=[{fingerprint:'*',reason:'wildcard'}];assert.throws(()=>validatePolicy(p2));
});
test('repository policies are explicit, require separate auth runtime configuration and grant no exceptions',()=>{
 for(const scope of ['product','auth']){const result=loadPolicy(parseArgs(['--scope',scope,...(scope==='auth'?['--runtime-role','actual_auth_login']:[])]));assert.equal(result.acceptedFindings.length,0);assert.ok(result.managedSchemas.includes('public'));}
 assert.throws(()=>parseArgs(['--scope','auth']),/deployed auth login/);
 const result=loadPolicy(parseArgs(['--scope','auth','--runtime-role','actual_auth_login']));assert.ok(result.roles.some(value=>value.name==='actual_auth_login'&&value.required));
 assert.throws(()=>loadPolicy(parseArgs(['--runtime-role','partner_webhook_owner'])),/conflicts/);
});
test('runtime grant options and maintenance permissions cannot hide in ordinary grants',()=>{
 const i=inventory();i.relations=[{schema:'private',name:'data',kind:'r',rls:true,force_rls:true,acl:[{grantee:'runtime_test',privilege:'SELECT',grantable:true}]}];
 i.effectiveRelations=[{role:'runtime_test',schema:'private',relation:'data',privileges:['MAINTAIN']}];
 const result=evaluatePolicy(i,policy());assert.ok(codes(result).includes('runtime_grant_option'));assert.ok(codes(result).includes('runtime_ddl_like_privilege'));
});
test('audit TLS cannot be disabled for remote production and never uses ambient DB credentials',()=>{
 assert.throws(()=>connectionOptions({DATABASE_URL:'postgresql://secret@host/database'}),/required/);
 assert.throws(()=>connectionOptions({PRIVILEGE_AUDIT_DATABASE_URL:'postgresql://user:secret@example.test/db',PRIVILEGE_AUDIT_DB_SSL:'false',NODE_ENV:'test'}),/local/);
 const result=connectionOptions({PRIVILEGE_AUDIT_DATABASE_URL:'postgresql://user:synthetic@127.0.0.1/db',PRIVILEGE_AUDIT_DB_SSL:'false',NODE_ENV:'test'});assert.equal(result.ssl,false);assert.equal(result.connectionTimeoutMillis,5000);
});
