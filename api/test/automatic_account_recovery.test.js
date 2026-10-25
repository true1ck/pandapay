'use strict';
const {test}=require('node:test');
const assert=require('node:assert/strict');
const crypto=require('node:crypto');
const {createAutomaticRecoveryHandlers}=require('../src/automatic_account_recovery');
const {automaticDevice,AUTO_SET_SQL,AUTO_PUT_SQL,AUTO_READ_SQL,wrappingKey,unwrapKey}=require('../src/account_recovery_routes');
const user=crypto.randomUUID(),snapshot=crypto.randomUUID();
const now=()=>1700000000000;
function req(){return {userId:user,authClaims:{device_id:'signed-device:123'},verifiedSession:{valid:true,active:true,guest:false,subject:user,authProof:{channel:'email',verified_at:now()/1000}},get:name=>name==='x-pandapay-recovery-consent-id'?snapshot:undefined,body:{enabled:true,include_receipts:true,consent_version:'automatic-account-recovery-v1'},params:{snapshotId:snapshot}};}
function res(){return {code:200,set(){},status(x){this.code=x;return this;},json(x){this.body=x;return this;}};}
function handlers(query,wrappingReadKeysJson){return createAutomaticRecoveryHandlers({enabled:true,wrappingKeyBase64:Buffer.alloc(32,7).toString('base64'),wrappingKeyId:'test',wrappingReadKeysJson,now,withUserClient:async(id,fn)=>{assert.equal(id,user);return fn({query});}});}
function payload(){const archive=Buffer.concat([Buffer.from('PDAR1'),Buffer.alloc(50,4)]),key=Buffer.alloc(32,2);const m=Buffer.from(JSON.stringify({snapshot_id:snapshot,archive_key:key.toString('base64'),consent_version:'account-recovery-v1',include_receipts:true,include_unsynced:true})),head=Buffer.alloc(4);head.writeUInt32BE(m.length);return Buffer.concat([head,m,archive]);}
test('automatic consent is current signed-device bound and requires a recent OTP only to enable',async()=>{
 let calls=0;const h=handlers(async(sql,args)=>{calls++;assert.equal(sql,AUTO_SET_SQL);assert.equal(args[1],automaticDevice(req()));return {rows:[]};});
 const stale=req();stale.verifiedSession.authProof.verified_at-=301;
 const denied=res();await h.consent(stale,denied);assert.equal(denied.code,403);assert.equal(calls,0);
 stale.body.enabled=false;const stopped=res();await h.consent(stale,stopped);assert.equal(stopped.body.enabled,false);assert.equal(calls,1);
 const enabled=res();await h.consent(req(),enabled);assert.equal(enabled.body.enabled,true);assert.equal(calls,2);
 for(const change of [{active:false},{guest:true},{revoked:true},{subject:crypto.randomUUID()}]){const bad=req();Object.assign(bad.verifiedSession,change);const response=res();await h.consent(bad,response);assert.equal(response.code,403);}
 const spoof=req();spoof.authClaims={};spoof.body.device_id='signed-device:123';assert.equal(automaticDevice(spoof),null);
});
test('automatic endpoint fails closed by default and validates exact explicit consent',async()=>{
 const response=res();await createAutomaticRecoveryHandlers({withUserClient(){throw Error('no query');}}).settings(req(),response);assert.equal(response.code,503);
 const h=handlers(()=>{throw Error('no query');});for(const body of [{},null,{...req().body,extra:true},{...req().body,include_receipts:'yes'}]){const r=req();r.body=body;const s=res();await h.consent(r,s);assert.equal(s.code,400);}
});
test('automatic upload uses SQL atomic consent check and never retrieves an escrow key',async()=>{
 let archive;
 const h=handlers(async(sql,args)=>{
  if(sql===AUTO_PUT_SQL){assert.equal(args[1],automaticDevice(req()));assert.equal(args[4].length,60);assert.equal(args[5],'test');assert.deepEqual(unwrapKey(args[4],user,snapshot,args[5],wrappingKey(Buffer.alloc(32,7).toString('base64'),'test')),Buffer.alloc(32,2));assert.equal(args[2],snapshot);archive=Buffer.from(args[6]);return {rows:[{created:true}]};}
  assert.equal(sql,AUTO_READ_SQL);return {rows:[{snapshot_id:snapshot,encrypted_archive:archive,archive_sha256:crypto.createHash('sha256').update(archive).digest('hex'),wrapped_key:Buffer.alloc(60)}]};
 },JSON.stringify([['retired',Buffer.alloc(32,8).toString('base64')]]));
 const r=req();r.verifiedSession.authProof.verified_at-=86400;r.body=payload();const uploaded=res();await h.upload(r,uploaded);assert.equal(uploaded.code,201);
 const read=res();await h.ciphertext(req(),read);assert.equal(read.body.encrypted_archive,archive.toString('base64'));assert.equal('archive_key' in read.body,false);assert.equal('wrapped_key' in read.body,false);
});
test('revoked consent and unavailable storage return fixed safe responses',async()=>{
 for(const [code,status] of [['42501',403],['P0001',429],['54000',507],['55000',503],['23514',409],['other',503]]){const h=handlers(async()=>{throw Object.assign(Error('sensitive contact/key'),{code});});const r=req();r.body=payload();const s=res();await h.upload(r,s);assert.equal(s.code,status);assert.equal(JSON.stringify(s.body).includes('sensitive'),false);}
});
