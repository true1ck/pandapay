#!/usr/bin/env node
'use strict';
const {createMaintenanceRetention}=require('./maintenanceRetention');
const {resolveDatabaseTls}=require('../utils/dbTls');
const CHECK_SQL=`SELECT r.rolsuper,r.rolbypassrls,r.rolcreatedb,r.rolcreaterole,r.rolreplication,
 current_user=session_user AS direct_login,
 (SELECT count(*)::integer FROM pg_catalog.pg_auth_members m WHERE m.member=r.oid) AS memberships,
 pg_catalog.pg_has_role(current_user,'pandapay_auth_retention_coordinator','USAGE') AS capability,
 EXISTS(SELECT 1 FROM pg_catalog.pg_auth_members m WHERE m.member='pandapay_auth_retention_coordinator'::regrole) AS nested_capability,
 EXISTS(SELECT 1 FROM pg_catalog.pg_roles c WHERE c.rolname='pandapay_auth_retention_coordinator' AND
  (c.rolcanlogin OR c.rolsuper OR c.rolbypassrls OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication OR c.rolinherit)) AS unsafe_capability,
 pg_catalog.has_schema_privilege(current_user,'maintenance','CREATE') AS ddl,
 EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'
 AND c.relkind IN ('r','p','v','m','f','S') AND
 (CASE WHEN c.relkind='S' THEN pg_catalog.has_sequence_privilege(current_user,c.oid,'USAGE,SELECT,UPDATE')
 ELSE pg_catalog.has_any_column_privilege(current_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES') OR
 pg_catalog.has_table_privilege(current_user,c.oid,'DELETE,TRUNCATE,TRIGGER') END)) AS raw_access
 FROM pg_catalog.pg_roles r WHERE r.rolname=current_user`;
async function main({args=process.argv.slice(2),env=process.env,write=x=>console.log(x),clientFactory,retentionFactory=createMaintenanceRetention}={}){
 if(args.length===1&&args[0]==='--help'){
  write('Usage: node auth/src/services/maintenanceCli.js --run --apply\nNo work without both explicit flags, AUTH_RETENTION_MAINTENANCE_ENABLED=true, an approved retention policy and enabled product job. AUTH_MAINTENANCE_DATABASE_URL uses an EXECUTE-only product-ledger coordinator; AUTH_RETENTION_DATABASE_URL uses a separate restricted auth maintenance login. Counts/status only; no messages are sent.');return;
 }
 if(args.length===0){write(JSON.stringify({status:'disabled',deleted:0}));return;}
 if(args.length!==2||!args.includes('--run')||!args.includes('--apply'))throw new Error('Explicit run/apply required');
 const work=retentionFactory({env,apply:true});
 if(!work){write(JSON.stringify({status:'disabled',deleted:0}));return;}
 if(!env.AUTH_MAINTENANCE_DATABASE_URL)throw new Error('Auth maintenance ledger is not configured');
 const resolved=resolveDatabaseTls(env.AUTH_MAINTENANCE_DATABASE_URL,env);
 const options={connectionString:resolved.connectionString,ssl:resolved.ssl,connectionTimeoutMillis:5000,statement_timeout:5000,query_timeout:6000,application_name:'pandapay-auth-retention-ledger'};
 const client=clientFactory?clientFactory(options):new(require('pg').Client)(options);
 let lease;
 try{
  await client.connect();
  const identity=(await client.query(CHECK_SQL)).rows;
  const r=identity?.[0];
  if(identity?.length!==1||!r||r.rolsuper||r.rolbypassrls||r.rolcreatedb||r.rolcreaterole||r.rolreplication||r.direct_login!==true||r.memberships!==1||r.capability!==true||r.nested_capability||r.unsafe_capability||r.ddl||r.raw_access)throw new Error('Auth maintenance coordinator is not restricted');
  const rows=(await client.query('SELECT * FROM maintenance.claim_auth_retention()')).rows;
  if(!Array.isArray(rows)||rows.length>1)throw new Error('Invalid maintenance claim');
  if(rows.length===0){write(JSON.stringify({status:'not_due',deleted:0}));return;}
  if(typeof rows[0].lease_token!=='string'||!/^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/i.test(rows[0].lease_token))throw new Error('Invalid maintenance lease');
  lease=rows[0].lease_token;
  const result=await work();
  if(!['completed','budget_exhausted','busy'].includes(result?.status)||!Number.isInteger(result.deleted)||result.deleted<0||result.deleted>1000||typeof result.more!=='boolean')throw new Error('Invalid auth retention result');
  const done=result.status==='busy'?
   await client.query('SELECT maintenance.defer_auth_retention($1::uuid) AS accepted',[lease]):
   await client.query('SELECT maintenance.finish_external($1::uuid,$2::integer,$3::boolean) AS accepted',[lease,result.deleted,result.more]);
  if(done.rows?.[0]?.accepted!==true)throw new Error('Auth maintenance lease expired');
  lease=null;write(JSON.stringify(result));
 }catch(error){
  if(lease)await client.query('SELECT maintenance.fail_auth_retention($1::uuid) AS accepted',[lease]).catch(()=>{});
  throw error;
 }finally{await client.end();}
}
if(require.main===module)main().catch(()=>{console.error('Auth maintenance failed; database details and row contents are not logged');process.exitCode=1;});
module.exports={main,CHECK_SQL};
