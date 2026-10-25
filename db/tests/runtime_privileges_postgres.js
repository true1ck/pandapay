'use strict';
// Run explicitly on a fresh, named loopback fixture. No .env or ambient URLs.
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path');
const execFile=require('node:util').promisify(require('node:child_process').execFile);
const {Client}=require('../../api/node_modules/pg');
const {auditRuntimePrivileges}=require('../scripts/audit_runtime_privileges');

async function main(){
 const raw=process.env.RUNTIME_PRIVILEGES_TEST_URL;
 if(!raw)throw new Error('RUNTIME_PRIVILEGES_TEST_URL is required');
 const url=new URL(raw);
 if(!['postgres:','postgresql:'].includes(url.protocol)||!['127.0.0.1','localhost','[::1]'].includes(url.hostname)||url.pathname!=='/runtime_privileges_test'||url.search||url.hash)throw new Error('A fresh loopback runtime_privileges_test is required');
 const admin=new Client({connectionString:raw,ssl:false,connectionTimeoutMillis:3000});await admin.connect();
 let login,policyDirectory;
 try{
  const existing=await admin.query("SELECT count(*)::int AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_' AND c.relkind IN ('r','p','v','m','S','f')");
  assert.equal(existing.rows[0].count,0,'fixture refuses nonempty database');
  const suffix=crypto.randomBytes(5).toString('hex'),schema='priv_fixture_'+suffix,runtime='priv_runtime_'+suffix,owner='priv_owner_'+suffix;
  const sentinel='Synthetic_customer_secret_'+crypto.randomBytes(8).toString('hex');
  const adminRole=(await admin.query('SELECT current_user AS name')).rows[0].name;
  const quotedAdmin='"'+adminRole.replaceAll('"','""')+'"';
  await admin.query(`CREATE ROLE ${runtime} LOGIN PASSWORD 'synthetic-no-secret' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION;
   CREATE ROLE ${owner} NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS NOREPLICATION;
   GRANT ${owner} TO ${quotedAdmin} WITH INHERIT TRUE,SET TRUE GRANTED BY ${quotedAdmin};
   CREATE SCHEMA ${schema} AUTHORIZATION ${owner};REVOKE ALL ON SCHEMA ${schema} FROM PUBLIC;
   REVOKE ALL ON SCHEMA public FROM PUBLIC;
   ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
   ALTER DEFAULT PRIVILEGES FOR ROLE ${owner} REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
   CREATE TABLE ${schema}.vault(id integer PRIMARY KEY,secret text);
   INSERT INTO ${schema}.vault VALUES(1,'${sentinel}');
   ALTER TABLE ${schema}.vault ENABLE ROW LEVEL SECURITY;ALTER TABLE ${schema}.vault FORCE ROW LEVEL SECURITY;
   CREATE POLICY fixture_reader ON ${schema}.vault FOR SELECT TO ${runtime} USING(true);
   CREATE TABLE ${schema}.schema_migrations(version text PRIMARY KEY);
   ALTER TABLE ${schema}.schema_migrations ENABLE ROW LEVEL SECURITY;ALTER TABLE ${schema}.schema_migrations FORCE ROW LEVEL SECURITY;
   GRANT USAGE ON SCHEMA ${schema} TO ${runtime};GRANT SELECT ON ${schema}.vault TO ${runtime};
   CREATE FUNCTION ${schema}.safe() RETURNS text LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT '${sentinel}'::text$$;
   ALTER FUNCTION ${schema}.safe() OWNER TO ${owner};REVOKE ALL ON FUNCTION ${schema}.safe() FROM PUBLIC;
   GRANT EXECUTE ON FUNCTION ${schema}.safe() TO ${runtime};
   GRANT USAGE,CREATE ON SCHEMA ${schema} TO ${quotedAdmin} WITH GRANT OPTION;
   REVOKE ${owner} FROM ${quotedAdmin} GRANTED BY ${quotedAdmin};`);
  const policy={format:'pandapay-runtime-privilege-policy-v1',scope:'fixture',managedSchemas:[schema],
   roles:[{name:runtime,kind:'runtime',required:true},{name:owner,kind:'owner',required:true}],
   ledgers:[`${schema}.schema_migrations`],memberships:[],restrictedRoles:[],requiredRoutineAccess:[{role:runtime,identity:`${schema}.safe()`}],acceptedFindings:[]};
  const healthy=await auditRuntimePrivileges(admin,{policy});
  assert.equal(healthy.strict_pass,true,healthy.findings.map(value=>value.code).join(','));
  assert.equal(JSON.stringify(healthy).includes(sentinel),false,'function source and customer values must not be emitted');
  const loginUrl=new URL(raw);loginUrl.username=runtime;loginUrl.password='synthetic-no-secret';
  login=new Client({connectionString:loginUrl.toString(),ssl:false,connectionTimeoutMillis:3000});await login.connect();
  const nonOwner=await auditRuntimePrivileges(login,{policy});
  assert.deepEqual(nonOwner.inventory,healthy.inventory,'catalog audit must work using a genuine non-owner LOGIN');
  assert.equal(nonOwner.strict_pass,true);
  policyDirectory=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-privilege-policy-'));
  const policyFile=path.join(policyDirectory,'policy.json');fs.writeFileSync(policyFile,JSON.stringify({...policy,scope:'product'}),{mode:0o600});
  const cliEnv=Object.fromEntries(['PATH','HOME','TMPDIR'].filter(key=>process.env[key]).map(key=>[key,process.env[key]]));
  Object.assign(cliEnv,{NODE_ENV:'test',PRIVILEGE_AUDIT_DB_SSL:'false',PRIVILEGE_AUDIT_DATABASE_URL:loginUrl.toString()});
  const cliArgs=[path.join(__dirname,'../scripts/audit_runtime_privileges.js'),'--policy',policyFile];
  const cliHealthy=await execFile(process.execPath,[...cliArgs,'--strict'],{env:cliEnv,timeout:30000,maxBuffer:2*1024*1024});assert.equal(JSON.parse(cliHealthy.stdout).strict_pass,true);
  await admin.query(`GRANT SELECT ON ${schema}.vault TO PUBLIC;
   GRANT UPDATE(secret) ON ${schema}.vault TO PUBLIC;
   GRANT SELECT ON ${schema}.schema_migrations TO ${runtime};
   ALTER TABLE ${schema}.vault NO FORCE ROW LEVEL SECURITY;ALTER TABLE ${schema}.vault DISABLE ROW LEVEL SECURITY;
   CREATE VIEW ${schema}.unsafe_view AS SELECT id FROM ${schema}.vault;
   GRANT SELECT ON ${schema}.unsafe_view TO ${runtime};
   GRANT ${owner} TO ${runtime} WITH INHERIT FALSE,SET TRUE,ADMIN TRUE;
   ALTER ROLE ${runtime} CREATEROLE;
   GRANT CREATE ON SCHEMA ${schema} TO ${runtime};
   ALTER DEFAULT PRIVILEGES IN SCHEMA ${schema} GRANT SELECT ON TABLES TO ${runtime};
   ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
   CREATE FUNCTION ${schema}.unsafe() RETURNS text LANGUAGE sql SECURITY DEFINER AS $$SELECT '${sentinel}'::text$$;`);
  const before=(await admin.query(`SELECT (SELECT count(*) FROM ${schema}.vault)::int AS rows,
   (SELECT md5(secret) FROM ${schema}.vault WHERE id=1) AS digest,
   (SELECT relacl::text FROM pg_class WHERE oid='${schema}.vault'::regclass) AS acl`)).rows[0];
  const unsafe=await auditRuntimePrivileges(login,{policy});
  const codes=new Set(unsafe.findings.map(value=>value.code));
  for(const code of ['privileged_role','unreviewed_membership','membership_admin_option','definer_owner_reachable','public_relation_grant','public_column_grant','runtime_migration_ledger_access','table_rls_disabled','table_force_rls_disabled','effective_access_without_rls','view_owner_execution','runtime_schema_create','broad_default_privileges','future_public_routine_execute','definer_search_path_unfixed','definer_owner_privileged','public_definer_execute'])assert.ok(codes.has(code),`missing ${code}`);
  assert.equal(unsafe.strict_pass,false);assert.equal(JSON.stringify(unsafe).includes(sentinel),false);
  await assert.rejects(execFile(process.execPath,[...cliArgs,'--strict'],{env:cliEnv,timeout:30000,maxBuffer:2*1024*1024}),error=>error.code===2&&JSON.parse(error.stdout).strict_pass===false);
  const advisory=await execFile(process.execPath,cliArgs,{env:cliEnv,timeout:30000,maxBuffer:2*1024*1024});assert.equal(JSON.parse(advisory.stdout).strict_pass,false,'advisory mode preserves current runtime behavior');
  const repeat=await auditRuntimePrivileges(admin,{policy});assert.deepEqual(repeat.inventory,unsafe.inventory);
  const after=(await admin.query(`SELECT (SELECT count(*) FROM ${schema}.vault)::int AS rows,
   (SELECT md5(secret) FROM ${schema}.vault WHERE id=1) AS digest,
   (SELECT relacl::text FROM pg_class WHERE oid='${schema}.vault'::regclass) AS acl`)).rows[0];
  assert.deepEqual(after,before,'audit must leave synthetic data and grants unchanged');
  await assert.rejects(auditRuntimePrivileges(login,{policy,limit:1}),/limit exceeded/);
  console.log('PASS: catalog-only audit under independent non-owner LOGIN; PUBLIC/column/default grants, RLS, owner/SET/admin paths, views, ledger and unsafe definers detected; CLI advisory succeeds and opt-in strict gate exits 2 on drift; bounded truncation fails closed; no row/body values emitted and grants/data unchanged');
 }finally{if(login)await login.end();await admin.end();if(policyDirectory)fs.rmSync(policyDirectory,{recursive:true});}
}
main().catch(error=>{console.error('Synthetic runtime privilege audit fixture failed',error.stack);process.exitCode=1;});
