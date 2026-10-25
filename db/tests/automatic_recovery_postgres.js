#!/usr/bin/env node
'use strict';

// Disposable PostgreSQL 18 integration fixture for the automatic recovery
// migration. Never reads a caller DATABASE_URL or project environment files.
const assert=require('node:assert/strict');
const fs=require('node:fs'),os=require('node:os'),path=require('node:path'),net=require('node:net');
const {spawnSync}=require('node:child_process');
const {Client}=require('../../api/node_modules/pg');
const ROOT=path.resolve(__dirname,'../..');
function run(command,args,options={}){const r=spawnSync(command,args,{encoding:'utf8',timeout:60000,...options});if(r.status!==0)throw Error(`${path.basename(command)} failed: ${String(r.stderr||'').slice(-2000)}`);return r.stdout;}
async function port(){return await new Promise((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const p=server.address().port;server.close(()=>resolve(p));});});}
function envFor(work){const e={PATH:process.env.PATH||'',HOME:process.env.HOME||'',TMPDIR:work,LC_ALL:'C',LANG:'C'};for(const k of Object.keys(process.env))if(k.startsWith('PG'))delete e[k];return e;}
function migrationSql(name){return `BEGIN;\n${fs.readFileSync(path.join(ROOT,'db/supabase/migrations',name),'utf8')}\nCOMMIT;\n`;}
async function main(){
 for(const name of ['initdb','pg_ctl','psql'])if(!process.env.PATH.split(path.delimiter).some(dir=>fs.existsSync(path.join(dir,name))))throw Error(`missing ${name}`);
 const work=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-auto-recovery-pg18-')),data=path.join(work,'data'),portNumber=await port(),env=envFor(work),log=path.join(work,'postgres.log');
 let started=false,client;
 try{
  run('initdb',['-D',data,'-A','trust','--no-locale','--encoding=UTF8','-U','fixture_owner'],{env});
  run('pg_ctl',['-D',data,'-l',log,'-o',`-p ${portNumber} -h 127.0.0.1 -k ${work}`,'start'],{env});started=true;
  const url=`postgresql://fixture_owner@127.0.0.1:${portNumber}/postgres`;
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1','-c',"DO $$ BEGIN IF current_setting('server_version_num')::int < 180000 THEN RAISE EXCEPTION 'PostgreSQL 18 required'; END IF; END $$; CREATE ROLE app_user NOLOGIN; CREATE SCHEMA pandapay; CREATE SCHEMA account_lifecycle; CREATE TABLE public.profiles(id uuid PRIMARY KEY); CREATE TABLE account_lifecycle.tombstones(profile_id uuid PRIMARY KEY,request_id uuid,generation bigint); CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$; INSERT INTO public.profiles(id) VALUES ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');"],{env});
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1'],{env,input:migrationSql('20261023192644_account_recovery_escrow.sql')});
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1'],{env,input:migrationSql('20261025140000_automatic_account_recovery.sql')});
  client=new Client({connectionString:url});await client.connect();
  await client.query("UPDATE account_recovery.control SET enabled=true");
  // Test visibility under the actual runtime role. Grant SELECT only in this
  // fixture to exercise RLS's default-deny behavior rather than mere ACL denial.
  await client.query('GRANT SELECT ON account_recovery.automatic_devices TO app_user');
  const u1='10000000-0000-4000-8000-000000000001',u2='10000000-0000-4000-8000-000000000002';
  const asUser=async(id,fn)=>{await client.query('BEGIN');try{await client.query('SET LOCAL ROLE app_user');await client.query("SELECT set_config('app.user_id',$1,true)",[id]);const out=await fn(client);await client.query('COMMIT');return out;}catch(e){await client.query('ROLLBACK');throw e;}};
  const dev=n=>n.toString(16).padStart(64,'0'),snapshot=n=>`20000000-0000-4000-8000-${n.toString().padStart(12,'0')}`;
  const consent=(id,d,on=true)=>asUser(id,c=>c.query('SELECT account_recovery.set_automatic($1,$2,$3,false)',[id,dev(d),on]));
  await consent(u1,1);await consent(u2,1);
  const ownerRows=await asUser(u1,c=>c.query('SELECT count(*)::int AS n FROM account_recovery.automatic_devices'));
  assert.equal(ownerRows.rows[0].n,0,'runtime role must not read automatic consent rows through RLS');
  await assert.rejects(asUser(u1,c=>c.query('SELECT account_recovery.get_automatic($1,$2)',[u2,dev(1)])),e=>e.code==='42501','profile id must remain bound to pandapay.uid()');

  // Eight-device policy is deterministic and bounded; ninth enrollment evicts
  // only the oldest consent record, not snapshots or recovery history.
  for(let n=2;n<=8;n++)await consent(u1,n);
  await client.query('UPDATE account_recovery.automatic_devices SET enrolled_at=clock_timestamp()-interval \'1 hour\' WHERE profile_id=$1 AND device_hash=$2',[u1,dev(2)]);
  await consent(u1,9);
  const enrolled=await client.query('SELECT device_hash,count(*) OVER()::int AS n FROM account_recovery.automatic_devices WHERE profile_id=$1',[u1]);
  assert.equal(enrolled.rows.length,8);assert.equal(enrolled.rows[0].n,8);assert.equal(enrolled.rows.some(r=>r.device_hash===dev(2)),false);assert.equal(enrolled.rows.some(r=>r.device_hash===dev(9)),true);

  const archive=Buffer.from('PDAR1'+'.'.repeat(41)),wrapped=Buffer.alloc(60,7),digest=require('node:crypto').createHash('sha256').update(archive).digest('hex');
  const consentId=async(id,d)=>(await client.query('SELECT consent_id FROM account_recovery.automatic_devices WHERE profile_id=$1 AND device_hash=$2',[id,dev(d)])).rows[0]?.consent_id || '99999999-9999-4999-8999-999999999999';
  const put=async(id,d,snap,captured)=>{const generation=captured||await consentId(id,d);return asUser(id,c=>c.query('SELECT account_recovery.put_automatic_snapshot($1,$2,$3,$4,$5,$6,$7,$8,false,true,$9)',[id,dev(d),generation,snap,wrapped,'fixture-key-v1',archive,digest,'account-recovery-v1']));};
  const first=snapshot(1);await put(u1,9,first);
  await assert.rejects(put(u1,9,snapshot(98)),e=>e.code==='P0001','automatic writers retain the 15-minute account cooldown');
  const activeConsent=await consentId(u1,9);
  await assert.rejects(asUser(u1,c=>c.query('SELECT account_recovery.put_automatic_snapshot($1,$2,$3,$4,$5,$6,$7,$8,true,true,$9)',[u1,dev(9),activeConsent,snapshot(97),wrapped,'fixture-key-v1',archive,digest,'account-recovery-v1'])),e=>e.code==='42501','receipt inclusion must match the exact explicit consent');

  const downloaded=await asUser(u1,c=>c.query('SELECT * FROM account_recovery.read_automatic_ciphertext($1,$2,$3)',[u1,dev(9),first]));
  assert.deepEqual(Object.keys(downloaded.rows[0]).sort(),['archive_sha256','encrypted_archive','snapshot_id']);
  assert.deepEqual(downloaded.rows[0].encrypted_archive,archive);

  // Disable and snapshot put serialize on the exact same advisory lock.
  const second=client;const contender=new Client({connectionString:url});await contender.connect();
  try{
   await client.query('BEGIN');await client.query('SET LOCAL ROLE app_user');await client.query("SELECT set_config('app.user_id',$1,true)",[u1]);await client.query('SELECT pg_catalog.pg_advisory_xact_lock(73614,1)');
   await contender.query('BEGIN');await contender.query('SET LOCAL ROLE app_user');await contender.query("SELECT set_config('app.user_id',$1,true)",[u1]);
   const disabling=contender.query('SELECT account_recovery.set_automatic($1,$2,false,false)',[u1,dev(9)]);
   await new Promise(resolve=>setTimeout(resolve,50));
   await client.query('COMMIT');await disabling;await contender.query('COMMIT');
   await assert.rejects(put(u1,9,snapshot(2)),e=>e.code==='42501','after disable commits, an automatic put is denied');
   const oldConsent=await consentId(u1,1);await consent(u1,1);assert.notEqual(await consentId(u1,1),oldConsent);
   await assert.rejects(put(u1,1,snapshot(99),oldConsent),e=>e.code==='42501');
   await consent(u1,9);
   // Snapshot rotation remains bounded to two and a discard revokes all
   // automatic writers atomically while keeping the established API contract.
   await client.query('UPDATE account_recovery.snapshots SET created_at=clock_timestamp()-interval \'1 hour\' WHERE profile_id=$1',[u1]);
   await put(u1,9,snapshot(3));
   await client.query('UPDATE account_recovery.snapshots SET created_at=clock_timestamp()-interval \'1 hour\' WHERE profile_id=$1',[u1]);
   await put(u1,9,snapshot(4));
   const retained=await client.query('SELECT count(*)::int n FROM account_recovery.snapshots WHERE profile_id=$1',[u1]);assert.equal(retained.rows[0].n,2);
   const removed=await asUser(u1,c=>c.query('SELECT account_recovery.remove_snapshots($1) n',[u1]));assert.equal(removed.rows[0].n,2);
   const afterDiscard=await client.query('SELECT count(*)::int n FROM account_recovery.automatic_devices WHERE profile_id=$1',[u1]);assert.equal(afterDiscard.rows[0].n,0);
   await assert.rejects(put(u1,9,snapshot(5)),e=>e.code==='42501');
   await consent(u1,9);await put(u1,9,snapshot(6));
   await client.query('INSERT INTO account_lifecycle.tombstones(profile_id,request_id,generation) VALUES ($1,$2,1)',[u1,'30000000-0000-4000-8000-000000000001']);
   const cleanup=await client.query('SELECT count(*)::int n FROM account_recovery.automatic_devices WHERE profile_id=$1',[u1]);assert.equal(cleanup.rows[0].n,0,'lifecycle tombstone removes automatic consent');
   const retainedAfterTombstone=await client.query('SELECT count(*)::int n FROM account_recovery.snapshots WHERE profile_id=$1',[u1]);assert.equal(retainedAfterTombstone.rows[0].n,1,'soft-delete retains snapshots according to existing policy');
  }finally{await contender.end();}
  console.log('PASS: PostgreSQL 18 automatic recovery migration, profile binding, RLS, bounded enrollment, ciphertext-only read, disable/put serialization, snapshot rotation/discard, and tombstone consent cleanup');
 }finally{if(client)await client.end().catch(()=>{});if(started)try{run('pg_ctl',['-D',data,'-m','immediate','stop'],{env});}catch{}fs.rmSync(work,{recursive:true,force:true});}
}
if(require.main===module)main().catch(error=>{process.stderr.write(`Automatic recovery PostgreSQL fixture failed: ${error.message}\n`);process.exitCode=1;});
