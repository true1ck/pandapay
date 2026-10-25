'use strict';
const assert=require('node:assert/strict');const {test}=require('node:test');const crypto=require('node:crypto');
const {createAccountRecoveryHandlers,decodeUpload,wrapKey,unwrapKey,wrappingKey,recentVerifiedSession,PUT_SQL,READ_SQL}=require('../src/account_recovery_routes');
const user=crypto.randomUUID(),snapshot=crypto.randomUUID(),rawKey=crypto.randomBytes(32).toString('base64'),keyId='recovery-v1';
const configured=wrappingKey(rawKey,keyId),archiveKey=crypto.randomBytes(32),archive=Buffer.concat([Buffer.from('PDAR1'),crypto.randomBytes(80)]);
function payload(overrides={}){const metadata=Buffer.from(JSON.stringify({snapshot_id:snapshot,archive_key:archiveKey.toString('base64'),consent_version:'account-recovery-v1',include_receipts:true,include_unsynced:true,...overrides}));const size=Buffer.alloc(4);size.writeUInt32BE(metadata.length);return Buffer.concat([size,metadata,archive]);}
const req=()=>({userId:user,verifiedSession:{valid:true,guest:false,subject:user,authProof:{channel:'email',verified_at:Math.floor(Date.now()/1000)}},body:payload(),params:{snapshotId:snapshot}});
const res=()=>({code:200,headers:{},set(k,v){this.headers[k]=v;return this;},status(x){this.code=x;return this;},json(x){this.body=x;return this;}});
test('recovery key wrap binds account, snapshot and retained wrapping key',()=>{const wrapped=wrapKey(archiveKey,user,snapshot,configured);assert.equal(wrapped.length,60);assert.deepEqual(unwrapKey(wrapped,user,snapshot,keyId,configured),archiveKey);assert.throws(()=>unwrapKey(wrapped,crypto.randomUUID(),snapshot,keyId,configured));assert.throws(()=>unwrapKey(wrapped,user,crypto.randomUUID(),keyId,configured));assert.throws(()=>unwrapKey(wrapped,user,snapshot,'different',configured));const changed=Buffer.from(wrapped);changed[20]^=1;assert.throws(()=>unwrapKey(changed,user,snapshot,keyId,configured));});
test('retained wrapping key reads old snapshot by exact stored id after active key rotation',()=>{
 const oldKey=crypto.randomBytes(32),nextKey=crypto.randomBytes(32),oldId='recovery-old',nextId='recovery-new';
 const oldConfig=wrappingKey(oldKey.toString('base64'),oldId),wrapped=wrapKey(archiveKey,user,snapshot,oldConfig);
 const rotated=wrappingKey(nextKey.toString('base64'),nextId,JSON.stringify([[oldId,oldKey.toString('base64')]]));
 assert.deepEqual(unwrapKey(wrapped,user,snapshot,oldId,rotated),archiveKey);
 const current=wrapKey(archiveKey,user,snapshot,rotated);assert.deepEqual(unwrapKey(current,user,snapshot,nextId,rotated),archiveKey);
 assert.throws(()=>unwrapKey(wrapped,user,snapshot,'unknown',rotated));
 const wrong=wrappingKey(nextKey.toString('base64'),nextId,JSON.stringify([[oldId,crypto.randomBytes(32).toString('base64')]]));
 assert.throws(()=>unwrapKey(wrapped,user,snapshot,oldId,wrong));
});
test('wrapping config refuses missing or malformed key instead of inventing replacement',()=>{for(const value of ['',undefined,'x'.repeat(32),crypto.randomBytes(31).toString('base64')])assert.throws(()=>wrappingKey(value,keyId));});
test('retained wrapping key configuration is bounded, strict, duplicate-safe and prototype-safe',()=>{
 const k=crypto.randomBytes(32).toString('base64'),active='active';
 for(const raw of ['{}','{"__proto__":["x"]}','null','[{}]','[["bad.id","'+k+'"]]','[["old","not-base64"]]','[["old","'+k+'"],["old","'+k+'"]]','[["active","'+k+'"]]','['+Array(9).fill('["k","'+k+'"]')+']',' '.repeat(8193)])assert.throws(()=>wrappingKey(rawKey,active,raw));
 assert.equal(wrappingKey(rawKey,active).readKeys.size,0);assert.equal(wrappingKey(rawKey,active,null).readKeys.size,0);assert.equal(wrappingKey(rawKey,active,'[]').readKeys.size,0);
 const protoSafe=wrappingKey(rawKey,active,JSON.stringify([['__proto__',k]]));assert.deepEqual(protoSafe.readKeys.get('__proto__'),Buffer.from(k,'base64'));
});
test('binary upload parser enforces explicit consent, strict fields and bounds',()=>{assert.equal(decodeUpload(payload()).archive.length,archive.length);for(const buffer of [Buffer.alloc(3),Buffer.from([0,0,9,0]),payload({consent_version:'no'}),payload({password:'never'}),payload({include_unsynced:'true'}),payload({archive_key:'notbase64'})])assert.throws(()=>decodeUpload(buffer));});
test('recent OTP gate refuses stale, guest, wrong-account, Google-only and future proof',()=>{assert.equal(recentVerifiedSession(req()),true);for(const change of [{guest:true},{subject:crypto.randomUUID()},{authProof:{channel:'google',verified_at:Math.floor(Date.now()/1000)}},{authProof:{channel:'email',verified_at:1}},{authProof:{channel:'phone',verified_at:Math.floor(Date.now()/1000)+10}}])assert.equal(recentVerifiedSession({...req(),verifiedSession:{...req().verifiedSession,...change}}),false);});
test('recovery source defaults disabled without keys or database access',async()=>{const response=res();await createAccountRecoveryHandlers({withUserClient(){throw Error('must not query');}}).list(req(),response);assert.equal(response.code,503);assert.equal(response.headers['Cache-Control'],'no-store');});
test('upload stores only wrapped key and opaque encrypted archive, download recovers same key',async()=>{
 let row;const handlers=createAccountRecoveryHandlers({enabled:true,wrappingKeyBase64:rawKey,wrappingKeyId:keyId,withUserClient:async(id,fn)=>{assert.equal(id,user);return fn({query:async(sql,args)=>{if(sql===PUT_SQL){assert.ok(!args[2].equals(archiveKey));row={snapshot_id:args[1],wrapped_key:args[2],wrapping_key_id:args[3],encrypted_archive:Buffer.from(args[4]),archive_sha256:args[5],include_receipts:args[6],include_unsynced:args[7]};return{rows:[{created:true}]};}assert.equal(sql,READ_SQL);return{rows:[row]};}});}});
 const uploaded=res();await handlers.upload(req(),uploaded);assert.equal(uploaded.code,201);assert.equal(uploaded.body.encrypted_bytes,archive.length);assert.equal(row.wrapping_key_id,keyId);assert.deepEqual(unwrapKey(row.wrapped_key,user,snapshot,keyId,configured),archiveKey);const downloaded=res();await handlers.download(req(),downloaded);assert.equal(downloaded.body.archive_key,archiveKey.toString('base64'));assert.equal(downloaded.body.account_id,user);assert.equal(downloaded.body.encrypted_archive,archive.toString('base64'));
});
test('download reads retained key after active key changes and missing retained key returns safe 503 with no output',async()=>{
 const oldKey=crypto.randomBytes(32),oldId='before-rotation',oldConfig=wrappingKey(oldKey.toString('base64'),oldId);
 const wrapped=wrapKey(archiveKey,user,snapshot,oldConfig),row={snapshot_id:snapshot,wrapped_key:wrapped,wrapping_key_id:oldId,encrypted_archive:archive,archive_sha256:crypto.createHash('sha256').update(archive).digest('hex'),include_receipts:true,include_unsynced:true};
 const invoke=async(retained)=>{const h=createAccountRecoveryHandlers({enabled:true,wrappingKeyBase64:crypto.randomBytes(32).toString('base64'),wrappingKeyId:'after-rotation',wrappingReadKeysJson:retained,withUserClient:async(_id,fn)=>fn({query:async()=>({rows:[row]})})});const response=res();await h.download(req(),response);return response;};
 const retained=await invoke(JSON.stringify([[oldId,oldKey.toString('base64')]]));assert.equal(retained.code,200);assert.equal(retained.body.archive_key,archiveKey.toString('base64'));
 const absent=await invoke(undefined);assert.equal(absent.code,503);assert.deepEqual(absent.body,{error:'account_recovery_unavailable'});assert.equal('archive_key' in (absent.body||{}),false);
});
test('quota and database failures expose fixed responses without keys or contacts',async()=>{for(const [code,status]of[['54000',507],['23514',409],['42501',403],['unexpected',503]]){const logs=[],handler=createAccountRecoveryHandlers({enabled:true,wrappingKeyBase64:rawKey,wrappingKeyId:keyId,logger:{error:x=>logs.push(x)},withUserClient:async()=>{throw Object.assign(Error('secret contact'),{code});}});const response=res();await handler.list(req(),response);assert.equal(response.code,status);assert.ok(!JSON.stringify([logs,response.body]).includes('secret contact'));}});
test('real recovery HTTP keeps ordinary JSON bound and rejects oversized raw uploads before DB use',async()=>{
 const express=require('express'),{jsonBodyParser,jsonBodyErrorHandler}=require('../src/request_limits');
 const {registerAccountRecoveryRoutes,MEDIA_TYPE,MAX_ARCHIVE_BYTES}=require('../src/account_recovery_routes');
 const app=express();app.use(jsonBodyParser,jsonBodyErrorHandler);let calls=0;
 registerAccountRecoveryRoutes(app,{enabled:true,wrappingKeyBase64:rawKey,wrappingKeyId:keyId,withUserClient:async()=>{calls++;throw Error('must not query');},requireAuth:(request,response,next)=>{
  if(request.get('authorization')!=='Bearer synthetic-otp')return response.status(401).json({error:'session_invalid'});
  Object.assign(request,req());next();
 }});
 app.post('/ordinary-json',(_request,response)=>response.json({ok:true}));
 const server=await new Promise(resolve=>{const owned=app.listen(0,'127.0.0.1',()=>resolve(owned));});
 try{
  const origin=`http://127.0.0.1:${server.address().port}`;
  let response=await fetch(origin+'/account/recovery/snapshots',{method:'POST',headers:{'content-type':MEDIA_TYPE},body:Buffer.from('ignored')});assert.equal(response.status,401);
  response=await fetch(origin+'/account/recovery/snapshots',{method:'POST',headers:{authorization:'Bearer synthetic-otp','content-type':'text/plain'},body:'ignored'});assert.equal(response.status,415);
  response=await fetch(origin+'/account/recovery/snapshots',{method:'POST',headers:{authorization:'Bearer synthetic-otp','content-type':MEDIA_TYPE},body:Buffer.alloc(MAX_ARCHIVE_BYTES+2053)});assert.equal(response.status,413);assert.deepEqual(await response.json(),{error:'payload_too_large'});
  response=await fetch(origin+'/ordinary-json',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify({value:'x'.repeat(101*1024)})});assert.equal(response.status,413);assert.equal(calls,0);
 }finally{await new Promise(resolve=>server.close(resolve));}
});
