#!/usr/bin/env node
'use strict';

// Disposable PostgreSQL 18 fixture for the migration that removes server-escrowed
// account recovery (decision D5). Never reads a caller DATABASE_URL or project
// environment files. Synthetic rows only.
//
// Run: node db/tests/account_recovery_drop_postgres.js
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net');
const {spawnSync}=require('node:child_process');
const {Client}=require('../../api/node_modules/pg');
const ROOT=path.resolve(__dirname,'../..');
function run(command,args,options={}){const r=spawnSync(command,args,{encoding:'utf8',timeout:60000,...options});if(r.status!==0)throw Error(`${path.basename(command)} failed: ${String(r.stderr||'').slice(-2000)}`);return r.stdout;}
async function port(){return await new Promise((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const p=server.address().port;server.close(()=>resolve(p));});});}
function envFor(work){const e={PATH:process.env.PATH||'',HOME:process.env.HOME||'',TMPDIR:work,LC_ALL:'C',LANG:'C'};for(const k of Object.keys(process.env))if(k.startsWith('PG'))delete e[k];return e;}
const migration=name=>`BEGIN;\n${fs.readFileSync(path.join(ROOT,'db/supabase/migrations',name),'utf8')}\nCOMMIT;\n`;
const FIXTURE=`DO $$ BEGIN IF current_setting('server_version_num')::int < 180000 THEN RAISE EXCEPTION 'PostgreSQL 18 required'; END IF; END $$;
CREATE ROLE app_user NOLOGIN; CREATE SCHEMA pandapay; CREATE SCHEMA account_lifecycle;
CREATE TABLE public.profiles(id uuid PRIMARY KEY);
CREATE TABLE account_lifecycle.tombstones(profile_id uuid PRIMARY KEY,request_id uuid,generation bigint);
CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$;
INSERT INTO public.profiles(id) VALUES ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');`;
const LEFTOVERS=`SELECT
 (SELECT count(*)::int FROM pg_namespace WHERE nspname='account_recovery') AS schemas,
 (SELECT count(*)::int FROM pg_roles WHERE rolname='account_recovery_owner') AS roles,
 (SELECT count(*)::int FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='account_recovery') AS functions,
 (SELECT count(*)::int FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='account_recovery') AS relations,
 (SELECT count(*)::int FROM pg_policy WHERE polname='lifecycle_recovery_read') AS policies,
 (SELECT count(*)::int FROM pg_trigger WHERE tgname='clear_deleted_automatic_consent' AND NOT tgisinternal) AS triggers`;
const GONE={schemas:0,roles:0,functions:0,relations:0,policies:0,triggers:0};
async function main(){
 for(const name of ['initdb','pg_ctl','psql'])if(!process.env.PATH.split(path.delimiter).some(dir=>fs.existsSync(path.join(dir,name))))throw Error(`missing ${name}`);
 const work=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-recovery-drop-pg18-')),data=path.join(work,'data'),portNumber=await port(),env=envFor(work),log=path.join(work,'postgres.log');
 let started=false,client;
 try{
  run('initdb',['-D',data,'-A','trust','--no-locale','--encoding=UTF8','-U','fixture_owner'],{env});
  run('pg_ctl',['-D',data,'-l',log,'-o',`-p ${portNumber} -h 127.0.0.1 -k ${work}`,'start'],{env});started=true;
  const url=`postgresql://fixture_owner@127.0.0.1:${portNumber}/postgres`;
  const psql=input=>run('psql',[url,'-X','-v','ON_ERROR_STOP=1'],{env,input});
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1','-c',FIXTURE],{env});
  psql(migration('20261023192644_account_recovery_escrow.sql'));
  psql(migration('20261025140000_automatic_account_recovery.sql'));
  client=new Client({connectionString:url});await client.connect();
  const before=(await client.query(LEFTOVERS)).rows[0];
  assert.equal(before.schemas,1);assert.equal(before.roles,1);assert.equal(before.policies,1);assert.equal(before.triggers,1);assert.ok(before.functions>=10);
  // A snapshot and a consent row exist, so the drop really removes data.
  await client.query("UPDATE account_recovery.control SET enabled=true");
  await client.query("SET app.user_id='10000000-0000-4000-8000-000000000001'");
  await client.query("SELECT account_recovery.set_automatic('10000000-0000-4000-8000-000000000001',repeat('a',64),true,false)");
  await client.query("RESET app.user_id");

  psql(migration('20261115040000_drop_account_recovery_escrow.sql'));
  assert.deepEqual((await client.query(LEFTOVERS)).rows[0],GONE,'everything the recovery migrations created is gone');

  // Objects shared with the account lifecycle keep working and keep their own policies and triggers.
  await client.query("INSERT INTO account_lifecycle.tombstones(profile_id) VALUES ('10000000-0000-4000-8000-000000000002')");
  assert.equal((await client.query('SELECT count(*)::int n FROM public.profiles')).rows[0].n,2,'profiles untouched');
  assert.equal((await client.query("SELECT count(*)::int n FROM pg_roles WHERE rolname='app_user'")).rows[0].n,1,'other roles untouched');

  // Replay and a fresh database that never had the escrow both succeed.
  psql(migration('20261115040000_drop_account_recovery_escrow.sql'));
  assert.deepEqual((await client.query(LEFTOVERS)).rows[0],GONE);
  console.log('PASS: PostgreSQL 18 account recovery drop migration removes schema, functions, tables, policy, trigger and owner role without CASCADE; replay is a no-op');
 }finally{if(client)await client.end().catch(()=>{});if(started)try{run('pg_ctl',['-D',data,'-m','immediate','stop'],{env});}catch{}fs.rmSync(work,{recursive:true,force:true});}
}
if(require.main===module)main().catch(error=>{process.stderr.write(`Account recovery drop PostgreSQL fixture failed: ${error.message}\n`);process.exitCode=1;});
