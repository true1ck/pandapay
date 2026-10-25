#!/usr/bin/env node
'use strict';

// Disposable native PostgreSQL proof for retained account recovery wrapping
// keys. Uses only synthetic data and never reads caller database URLs/env files.
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const net=require('node:net');
const {spawnSync}=require('node:child_process');
const {Client}=require('../../api/node_modules/pg');
const {createAccountRecoveryHandlers}=require('../../api/src/account_recovery_routes');
const ROOT=path.resolve(__dirname,'../..');
const PG_PATH='/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin';

function run(command,args,options={}){
 const result=spawnSync(command,args,{encoding:'utf8',timeout:60000,env:options.env,...options});
 if(result.status!==0)throw Error(`${path.basename(command)} failed`);
 return result.stdout;
}
async function freePort(){return new Promise((resolve,reject)=>{const server=net.createServer();server.once('error',reject);server.listen(0,'127.0.0.1',()=>{const value=server.address().port;server.close(()=>resolve(value));});});}
function sqlFile(name){return `BEGIN;\n${fs.readFileSync(path.join(ROOT,'db/supabase/migrations',name),'utf8')}\nCOMMIT;\n`;}
function safeEnv(work){return{PATH:PG_PATH,HOME:work,TMPDIR:work,LC_ALL:'C',LANG:'C'};}
function response(){return{statusCode:200,headers:{},set(name,value){this.headers[name]=value;return this;},status(code){this.statusCode=code;return this;},json(value){this.body=value;return this;}};}
function request(userId,snapshotId,body){return{userId,params:{snapshotId},body,verifiedSession:{valid:true,guest:false,subject:userId,authProof:{channel:'email',verified_at:Math.floor(Date.now()/1000)}}};}
function uploadBody(snapshotId,key,archive){const metadata=Buffer.from(JSON.stringify({snapshot_id:snapshotId,archive_key:key.toString('base64'),consent_version:'account-recovery-v1',include_receipts:false,include_unsynced:true}));const size=Buffer.alloc(4);size.writeUInt32BE(metadata.length);return Buffer.concat([size,metadata,archive]);}
function handlers(client,userId,wrappingKeyBase64,wrappingKeyId,wrappingReadKeysJson){
 const withUserClient=async(id,callback)=>{
  await client.query('BEGIN');
  try{
   await client.query('SET LOCAL ROLE app_user');
   await client.query("SELECT pg_catalog.set_config('app.user_id',$1,true)",[id]);
   const value=await callback(client);await client.query('COMMIT');return value;
  }catch(error){await client.query('ROLLBACK').catch(()=>{});throw error;}
 };
 return createAccountRecoveryHandlers({enabled:true,wrappingKeyBase64,wrappingKeyId,wrappingReadKeysJson,withUserClient,logger:{error(){}}});
}
async function storedRows(client){return(await client.query('SELECT snapshot_id,profile_id,wrapped_key,wrapping_key_id,encrypted_archive,archive_sha256,include_receipts,include_unsynced,consent_version,created_at FROM account_recovery.snapshots ORDER BY profile_id,snapshot_id')).rows;}
async function main(){
 const tools=['initdb','pg_ctl','psql','pg_dump','pg_restore'];
 for(const tool of tools)if(!fs.existsSync(path.join('/opt/homebrew/bin',tool)))throw Error('Required PostgreSQL 18 tools are unavailable');
 const work=fs.mkdtempSync(path.join(os.tmpdir(),'pandapay-retained-recovery-pg18-'));
 const data=path.join(work,'data'),dump=path.join(work,'recovery.dump'),port=await freePort(),env=safeEnv(work),log=path.join(work,'postgres.log');
 let started=false,client,restored;
 try{
  run('initdb',['-D',data,'-A','trust','--no-locale','--encoding=UTF8','-U','fixture_owner'],{env});
  run('pg_ctl',['-D',data,'-l',log,'-o',`-p ${port} -h 127.0.0.1 -k ${work}`,'start'],{env});started=true;
  const url=`postgresql://fixture_owner@127.0.0.1:${port}/postgres`;
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1','-c',"DO $$ BEGIN IF current_setting('server_version_num')::int < 180000 THEN RAISE EXCEPTION 'PostgreSQL 18 required'; END IF; END $$; CREATE ROLE app_user NOLOGIN; CREATE SCHEMA pandapay; CREATE SCHEMA account_lifecycle; CREATE TABLE public.profiles(id uuid PRIMARY KEY); CREATE TABLE account_lifecycle.tombstones(profile_id uuid PRIMARY KEY,request_id uuid,generation bigint); CREATE FUNCTION pandapay.uid() RETURNS uuid LANGUAGE sql STABLE AS $$ SELECT nullif(current_setting('app.user_id',true),'')::uuid $$; INSERT INTO public.profiles(id) VALUES ('10000000-0000-4000-8000-000000000001'),('10000000-0000-4000-8000-000000000002');"],{env});
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1'],{env,input:sqlFile('20261023192644_account_recovery_escrow.sql')});
  client=new Client({connectionString:url});await client.connect();
  await client.query('UPDATE account_recovery.control SET enabled=true');

  const u1='10000000-0000-4000-8000-000000000001',u2='10000000-0000-4000-8000-000000000002';
  const s1='20000000-0000-4000-8000-000000000001',s2='20000000-0000-4000-8000-000000000002';
  const oldId='recovery-old-v1',newId='recovery-current-v2';
  const oldKey=crypto.randomBytes(32),newKey=crypto.randomBytes(32),archiveKey1=crypto.randomBytes(32),archiveKey2=crypto.randomBytes(32);
  const archive1=Buffer.concat([Buffer.from('PDAR1'),crypto.randomBytes(96)]),archive2=Buffer.concat([Buffer.from('PDAR1'),crypto.randomBytes(104)]);
  const oldHandler=handlers(client,u1,oldKey.toString('base64'),oldId);
  const uploadOld=response();await oldHandler.upload(request(u1,s1,uploadBody(s1,archiveKey1,archive1)),uploadOld);
  assert.equal(uploadOld.statusCode,201,'old-key upload should persist');
  const beforeRotation=await storedRows(client);assert.equal(beforeRotation.length,1);
  assert.equal(beforeRotation[0].wrapping_key_id,oldId);assert.equal(beforeRotation[0].wrapped_key.length,60);

  const retainedJson=JSON.stringify([[oldId,oldKey.toString('base64')]]);
  const rotated=handlers(client,u1,newKey.toString('base64'),newId,retainedJson);
  const reopened=response();await rotated.download(request(u1,s1),reopened);
  assert.equal(reopened.statusCode,200);assert.equal(reopened.body.archive_key,archiveKey1.toString('base64'));
  assert.equal(reopened.body.encrypted_archive,archive1.toString('base64'));

  const noOldReader=handlers(client,u1,newKey.toString('base64'),newId);
  const missing=response();await noOldReader.download(request(u1,s1),missing);
  assert.equal(missing.statusCode,503);assert.deepEqual(missing.body,{error:'account_recovery_unavailable'});
  assert.equal(Object.hasOwn(missing.body,'archive_key'),false);assert.equal(Object.hasOwn(missing.body,'encrypted_archive'),false);

  const crossAccount=response();await handlers(client,u2,newKey.toString('base64'),newId,retainedJson).download(request(u2,s1),crossAccount);
  assert.equal(crossAccount.statusCode,404);assert.deepEqual(crossAccount.body,{error:'snapshot_not_found'});

  const newHandler=handlers(client,u2,newKey.toString('base64'),newId,retainedJson);
  const uploadNew=response();await newHandler.upload(request(u2,s2,uploadBody(s2,archiveKey2,archive2)),uploadNew);
  assert.equal(uploadNew.statusCode,201);
  const afterUploads=await storedRows(client);assert.equal(afterUploads.length,2);
  const newRow=afterUploads.find(row=>row.snapshot_id===s2);assert.ok(newRow);
  assert.equal(newRow.wrapping_key_id,newId);assert.equal(newRow.wrapped_key.length,60);
  assert.deepEqual(afterUploads.find(row=>row.snapshot_id===s1),beforeRotation[0]);

  const afterReads=await storedRows(client);assert.deepEqual(afterReads,afterUploads,'reader requests must not mutate old or current stored rows');
  run('pg_dump',['--format=custom','--file',dump,url],{env});
  const restoredDb='retained_recovery_restore';
  run('psql',[url,'-X','-v','ON_ERROR_STOP=1','-c',`CREATE DATABASE ${restoredDb}`],{env});
  run('pg_restore',['--exit-on-error','--dbname',`postgresql://fixture_owner@127.0.0.1:${port}/${restoredDb}`,dump],{env});
  const restoreUrl=`postgresql://fixture_owner@127.0.0.1:${port}/${restoredDb}`;
  restored=new Client({connectionString:restoreUrl});await restored.connect();
  const restoredRows=await storedRows(restored);assert.deepEqual(restoredRows,afterUploads,'pg_dump restore must preserve snapshot IDs and all escrow/archive fields');

  const restoreReader1=handlers(restored,u1,newKey.toString('base64'),newId,retainedJson);
  const restoreOld=response();await restoreReader1.download(request(u1,s1),restoreOld);
  assert.equal(restoreOld.statusCode,200);assert.equal(restoreOld.body.archive_key,archiveKey1.toString('base64'));
  const restoreReader2=handlers(restored,u2,newKey.toString('base64'),newId,retainedJson);
  const restoreNew=response();await restoreReader2.download(request(u2,s2),restoreNew);
  assert.equal(restoreNew.statusCode,200);assert.equal(restoreNew.body.archive_key,archiveKey2.toString('base64'));
  assert.deepEqual(await storedRows(restored),afterUploads,'restored reads must leave every row unchanged');
  process.stdout.write('PASS: PostgreSQL 18 retained wrapping-key upload/read, missing-key and cross-account rejection, active-key writes, immutable rows, and pg_dump/restore reopen\n');
 }finally{
  if(restored)await restored.end().catch(()=>{});
  if(client)await client.end().catch(()=>{});
  if(started)try{run('pg_ctl',['-D',data,'-m','immediate','stop'],{env});}catch{}
  fs.rmSync(work,{recursive:true,force:true});
 }
}
if(require.main===module)main().catch(()=>{process.stderr.write('Retained recovery PostgreSQL fixture failed; no synthetic key material was emitted.\n');process.exitCode=1;});
