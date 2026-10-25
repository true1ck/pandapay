'use strict';
const crypto=require('node:crypto');
const express=require('express');
const MEDIA_TYPE='application/vnd.pandapay.account-recovery+octet-stream';
const MAX_ARCHIVE_BYTES=5*1024*1024,MAX_METADATA_BYTES=2048;
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PUT_SQL='SELECT account_recovery.put_snapshot($1::uuid,$2::uuid,$3::bytea,$4::text,$5::bytea,$6::text,$7::boolean,$8::boolean,$9::text) AS created';
const READ_SQL='SELECT * FROM account_recovery.read_snapshot($1::uuid,$2::uuid)';
const LIST_SQL='SELECT * FROM account_recovery.list_snapshots($1::uuid)';
const DELETE_SQL='SELECT account_recovery.remove_snapshots($1::uuid) AS removed';
const AUTO_SET_SQL='SELECT account_recovery.set_automatic($1::uuid,$2::text,$3::boolean,$4::boolean) AS enabled';
const AUTO_GET_SQL='SELECT * FROM account_recovery.get_automatic($1::uuid,$2::text)';
const AUTO_PUT_SQL='SELECT account_recovery.put_automatic_snapshot($1::uuid,$2::text,$3::uuid,$4::uuid,$5::bytea,$6::text,$7::bytea,$8::text,$9::boolean,$10::boolean,$11::text) AS created';
const AUTO_READ_SQL='SELECT * FROM account_recovery.read_automatic_ciphertext($1::uuid,$2::text,$3::uuid)';
// Only locally signature-verified claims on an authoritatively active session
// supply this binding. Never accept an arbitrary request header/body device.
function automaticDevice(req){const s=req.verifiedSession,d=req.authClaims?.device_id;return s?.valid===true&&s.active===true&&s.revoked!==true&&s.guest!==true&&s.subject===req.userId&&UUID.test(req.userId)&&typeof d==='string'&&/^[A-Za-z0-9:_-]{4,128}$/.test(d)?crypto.createHash('sha256').update('pandapay-automatic-recovery-v1\0'+d).digest('hex'):null;}
function base64(value,bytes){if(typeof value!=='string'||!value||! /^[A-Za-z0-9+/]*={0,2}$/.test(value))throw Error('invalid_base64');const out=Buffer.from(value,'base64');if(out.toString('base64')!==value||(bytes!==undefined&&out.length!==bytes))throw Error('invalid_base64');return out;}
const WRAPPING_KEY_ID=/^[A-Za-z0-9_-]{1,64}$/;
const MAX_RETAINED_WRAPPING_KEYS=8,MAX_RETAINED_WRAPPING_KEYS_BYTES=8192;
function parseWrappingReadKeys(rawJson,activeKeyId){
 if(rawJson===undefined||rawJson===null||rawJson==='')return new Map();
 if(typeof rawJson!=='string'||Buffer.byteLength(rawJson,'utf8')>MAX_RETAINED_WRAPPING_KEYS_BYTES)throw Error('Invalid recovery wrapping key read configuration');
 let pairs;try{pairs=JSON.parse(rawJson);}catch{throw Error('Invalid recovery wrapping key read configuration');}
 if(!Array.isArray(pairs)||pairs.length>MAX_RETAINED_WRAPPING_KEYS)throw Error('Invalid recovery wrapping key read configuration');
 const keys=new Map();
 for(const pair of pairs){
  if(!Array.isArray(pair)||pair.length!==2)throw Error('Invalid recovery wrapping key read configuration');
  const [id,encoded]=pair;
  if(typeof id!=='string'||!WRAPPING_KEY_ID.test(id)||id===activeKeyId||keys.has(id))throw Error('Invalid recovery wrapping key read configuration');
  keys.set(id,base64(encoded,32));
 }
 return keys;
}
function wrappingKey(raw,keyId,wrappingReadKeysJson){if(typeof keyId!=='string'||!WRAPPING_KEY_ID.test(keyId))throw Error('Invalid recovery wrapping key id');return{key:base64(raw,32),keyId,readKeys:parseWrappingReadKeys(wrappingReadKeysJson,keyId)};}
const aad=(user,snapshot,id)=>Buffer.from(`pandapay-account-recovery-key-v1\0${user.toLowerCase()}\0${snapshot.toLowerCase()}\0${id}`,'utf8');
function wrapKey(archiveKey,user,snapshot,configured){const nonce=crypto.randomBytes(12),cipher=crypto.createCipheriv('aes-256-gcm',configured.key,nonce);cipher.setAAD(aad(user,snapshot,configured.keyId));const encrypted=Buffer.concat([cipher.update(archiveKey),cipher.final()]);return Buffer.concat([nonce,cipher.getAuthTag(),encrypted]);}
function unwrapKey(wrapped,user,snapshot,keyId,configured){if(!configured||typeof keyId!=='string'||!Buffer.isBuffer(wrapped)||wrapped.length!==60)throw Error('Recovery wrapping key unavailable');const key=keyId===configured.keyId?configured.key:configured.readKeys?.get(keyId);if(!Buffer.isBuffer(key)||key.length!==32)throw Error('Recovery wrapping key unavailable');const decipher=crypto.createDecipheriv('aes-256-gcm',key,wrapped.subarray(0,12));decipher.setAAD(aad(user,snapshot,keyId));decipher.setAuthTag(wrapped.subarray(12,28));return Buffer.concat([decipher.update(wrapped.subarray(28)),decipher.final()]);}
function decodeUpload(body){
 if(!Buffer.isBuffer(body)||body.length<4||body.length>MAX_ARCHIVE_BYTES+MAX_METADATA_BYTES+4)throw Error('invalid_recovery_payload');
 const length=body.readUInt32BE(0);if(length<1||length>MAX_METADATA_BYTES||body.length<4+length+46)throw Error('invalid_recovery_payload');
 let metadata;try{metadata=JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(body.subarray(4,4+length)));}catch{throw Error('invalid_recovery_payload');}
 const keys=['snapshot_id','archive_key','consent_version','include_receipts','include_unsynced'];
 if(!metadata||typeof metadata!=='object'||Array.isArray(metadata)||Object.keys(metadata).length!==keys.length||Object.keys(metadata).some(k=>!keys.includes(k))||!UUID.test(metadata.snapshot_id)||metadata.consent_version!=='account-recovery-v1'||typeof metadata.include_receipts!=='boolean'||typeof metadata.include_unsynced!=='boolean')throw Error('invalid_recovery_payload');
 const archiveKey=base64(metadata.archive_key,32),archive=body.subarray(4+length);
 if(archive.length>MAX_ARCHIVE_BYTES||archive.subarray(0,5).toString('ascii')!=='PDAR1')throw Error('invalid_recovery_payload');
 return{metadata,archiveKey,archive};
}
function recentVerifiedSession(req,now=Date.now){const session=req.verifiedSession,proof=session?.authProof,verified=Number(proof?.verified_at);return session?.valid===true&&session.guest!==true&&session.subject===req.userId&&['phone','email'].includes(proof?.channel)&&Number.isSafeInteger(verified)&&verified>0&&Math.floor(now()/1000)-verified>=0&&Math.floor(now()/1000)-verified<=300;}
function createAccountRecoveryHandlers({withUserClient,enabled=false,wrappingKeyBase64,wrappingKeyId,wrappingReadKeysJson,logger=console,now=Date.now}){
 let configured=null;if(enabled)configured=wrappingKey(wrappingKeyBase64,wrappingKeyId,wrappingReadKeysJson);
 const guard=(req,res)=>{res.set?.('Cache-Control','no-store');if(!enabled){res.status(503).json({error:'account_recovery_disabled'});return false;}if(!UUID.test(req.userId)||!recentVerifiedSession(req,now)){res.status(403).json({error:'recent_otp_required'});return false;}return true;};
 const failure=(error,res)=>{if(error.code==='P0001')return res.status(429).json({error:'account_recovery_rate_limited'});if(error.code==='54000')return res.status(507).json({error:'account_recovery_storage_full'});if(error.code==='55000')return res.status(503).json({error:'account_recovery_disabled'});if(error.code==='23514')return res.status(409).json({error:'account_recovery_snapshot_conflict'});if(error.code==='42501')return res.status(403).json({error:'account_access_denied'});logger.error?.('Account recovery unavailable');return res.status(503).json({error:'account_recovery_unavailable'});};
 return{
  preflight(req,res,next){if(!guard(req,res))return;if(!req.is?.(MEDIA_TYPE))return res.status(415).json({error:'unsupported_recovery_media'});if(req.get?.('content-encoding')&&req.get('content-encoding')!=='identity')return res.status(415).json({error:'unsupported_encoding'});next();},
  async upload(req,res){if(!guard(req,res))return;let parsed;try{parsed=decodeUpload(req.body);}catch{return res.status(400).json({error:'invalid_recovery_payload'});}try{
   const {metadata:m,archiveKey,archive}=parsed;const digest=crypto.createHash('sha256').update(archive).digest('hex');const wrapped=wrapKey(archiveKey,req.userId,m.snapshot_id,configured);
   await withUserClient(req.userId,client=>client.query(PUT_SQL,[req.userId,m.snapshot_id,wrapped,configured.keyId,archive,digest,m.include_receipts,m.include_unsynced,m.consent_version]));
   return res.status(201).json({snapshot_id:m.snapshot_id,archive_sha256:digest,encrypted_bytes:archive.length});
  }catch(error){return failure(error,res);}finally{parsed.archiveKey.fill(0);}},
  async list(req,res){if(!guard(req,res))return;try{return res.json({snapshots:(await withUserClient(req.userId,client=>client.query(LIST_SQL,[req.userId]))).rows});}catch(error){return failure(error,res);}},
  async download(req,res){if(!guard(req,res))return;if(!UUID.test(req.params?.snapshotId))return res.status(400).json({error:'invalid_snapshot_id'});let key;try{
   const row=(await withUserClient(req.userId,client=>client.query(READ_SQL,[req.userId,req.params.snapshotId]))).rows[0];if(!row)return res.status(404).json({error:'snapshot_not_found'});
   const digest=crypto.createHash('sha256').update(row.encrypted_archive).digest('hex');if(digest!==row.archive_sha256)throw Error('Recovery archive integrity failure');
   key=unwrapKey(row.wrapped_key,req.userId,row.snapshot_id,row.wrapping_key_id,configured);return res.json({snapshot_id:row.snapshot_id,account_id:req.userId,archive_key:key.toString('base64'),encrypted_archive:row.encrypted_archive.toString('base64'),archive_sha256:digest,include_receipts:row.include_receipts,include_unsynced:row.include_unsynced});
  }catch(error){return failure(error,res);}finally{key?.fill(0);}},
  async remove(req,res){if(!guard(req,res))return;if(req.get?.('x-pandapay-recovery-consent')!=='discard-recovery-v1')return res.status(400).json({error:'explicit_discard_required'});try{return res.json({removed:(await withUserClient(req.userId,client=>client.query(DELETE_SQL,[req.userId]))).rows[0].removed});}catch(error){return failure(error,res);}},
 };
}
function registerAccountRecoveryRoutes(app,options){const handlers=createAccountRecoveryHandlers(options);const auth=options.requireAuth;if(typeof auth!=='function')throw Error('requireAuth required');const base='/account/recovery/snapshots';app.post(base,auth,handlers.preflight,express.raw({type:MEDIA_TYPE,limit:MAX_ARCHIVE_BYTES+MAX_METADATA_BYTES+4,inflate:false}),(error,_req,res,_next)=>res.status(error?.type==='entity.too.large'?413:error?.type==='encoding.unsupported'?415:400).json({error:error?.type==='entity.too.large'?'payload_too_large':'invalid_recovery_payload'}),handlers.upload);app.get(base,auth,handlers.list);app.get(base+'/:snapshotId',auth,handlers.download);app.delete(base,auth,handlers.remove);require('./automatic_account_recovery').registerAutomaticRecoveryRoutes(app,options);return handlers;}
module.exports={createAccountRecoveryHandlers,registerAccountRecoveryRoutes,decodeUpload,wrapKey,unwrapKey,wrappingKey,recentVerifiedSession,MEDIA_TYPE,MAX_ARCHIVE_BYTES,PUT_SQL,READ_SQL,LIST_SQL,DELETE_SQL,automaticDevice,AUTO_SET_SQL,AUTO_GET_SQL,AUTO_PUT_SQL,AUTO_READ_SQL};
