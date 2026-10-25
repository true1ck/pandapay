'use strict';
// Upload-only device consent. Restoring data and downloading escrowed keys
// continue through the original fresh-OTP recovery endpoints.
const crypto = require('node:crypto');
const express = require('express');
const {
  decodeUpload, wrapKey, wrappingKey, recentVerifiedSession, automaticDevice,
  MEDIA_TYPE, MAX_ARCHIVE_BYTES, AUTO_SET_SQL, AUTO_GET_SQL, AUTO_PUT_SQL, AUTO_READ_SQL,
} = require('./account_recovery_routes');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
function createAutomaticRecoveryHandlers({withUserClient, enabled=false, wrappingKeyBase64, wrappingKeyId, wrappingReadKeysJson, now=Date.now}) {
  const key = enabled ? wrappingKey(wrappingKeyBase64, wrappingKeyId, wrappingReadKeysJson) : null;
  function guard(req,res) {
    res.set?.('Cache-Control','no-store');
    if (!enabled) {res.status(503).json({error:'account_recovery_disabled'}); return null;}
    const device = automaticDevice(req);
    if (!device) {res.status(403).json({error:'active_device_required'}); return null;}
    return device;
  }
  function failure(error,res) {
    const codes = {P0001:[429,'account_recovery_rate_limited'],54000:[507,'account_recovery_storage_full'],55000:[503,'account_recovery_disabled'],23514:[409,'account_recovery_snapshot_conflict'],42501:[403,'automatic_recovery_not_enabled']};
    const [status,code] = codes[error?.code] || [503,'account_recovery_unavailable'];
    return res.status(status).json({error:code});
  }
  return {
    preflight(req,res,next) {
      if (!guard(req,res)) return;
      if (!req.is?.(MEDIA_TYPE)) return res.status(415).json({error:'unsupported_recovery_media'});
      if (req.get?.('content-encoding') && req.get('content-encoding') !== 'identity') return res.status(415).json({error:'unsupported_encoding'});
      next();
    },
    async settings(req,res) {
      const device=guard(req,res); if (!device) return;
      try {
        const row=(await withUserClient(req.userId,c=>c.query(AUTO_GET_SQL,[req.userId,device]))).rows[0];
        return res.json({enabled:!!row,include_receipts:row?.include_receipts===true,consent_id:row?.consent_id??null});
      } catch(error) {return failure(error,res);}
    },
    async consent(req,res) {
      const device=guard(req,res); if (!device) return;
      const body=req.body;
      if (!body || Array.isArray(body) || Object.keys(body).length!==3 ||
          Object.keys(body).some(k=>!['enabled','include_receipts','consent_version'].includes(k)) ||
          typeof body.enabled!=='boolean' || typeof body.include_receipts!=='boolean' ||
          body.consent_version!=='automatic-account-recovery-v1') return res.status(400).json({error:'explicit_automatic_consent_required'});
      if (body.enabled && !recentVerifiedSession(req,now)) return res.status(403).json({error:'recent_otp_required'});
      try {
        await withUserClient(req.userId,c=>c.query(AUTO_SET_SQL,[req.userId,device,body.enabled,body.include_receipts]));
        return res.json({enabled:body.enabled,include_receipts:body.enabled&&body.include_receipts});
      } catch(error) {return failure(error,res);}
    },
    async upload(req,res) {
      const device=guard(req,res); if (!device) return;
      const consentId=req.get?.('x-pandapay-recovery-consent-id');
      if (!UUID.test(consentId)) return res.status(400).json({error:'automatic_consent_identity_required'});
      let parsed;
      try {parsed=decodeUpload(req.body);} catch {return res.status(400).json({error:'invalid_recovery_payload'});}
      try {
        const {metadata:m,archiveKey,archive}=parsed;
        const hash=crypto.createHash('sha256').update(archive).digest('hex');
        const wrapped=wrapKey(archiveKey,req.userId,m.snapshot_id,key);
        await withUserClient(req.userId,c=>c.query(AUTO_PUT_SQL,[req.userId,device,consentId,m.snapshot_id,wrapped,key.keyId,archive,hash,m.include_receipts,m.include_unsynced,m.consent_version]));
        return res.status(201).json({snapshot_id:m.snapshot_id,archive_sha256:hash,encrypted_bytes:archive.length});
      } catch(error) {return failure(error,res);} finally {parsed.archiveKey.fill(0);}
    },
    async ciphertext(req,res) {
      const device=guard(req,res); if (!device) return;
      if (!UUID.test(req.params?.snapshotId)) return res.status(400).json({error:'invalid_snapshot_id'});
      try {
        const row=(await withUserClient(req.userId,c=>c.query(AUTO_READ_SQL,[req.userId,device,req.params.snapshotId]))).rows[0];
        if (!row) return res.status(404).json({error:'snapshot_not_found'});
        const hash=crypto.createHash('sha256').update(row.encrypted_archive).digest('hex');
        if (hash!==row.archive_sha256) throw Error('Integrity failure');
        return res.json({snapshot_id:row.snapshot_id,account_id:req.userId,archive_sha256:hash,encrypted_archive:row.encrypted_archive.toString('base64')});
      } catch(error) {return failure(error,res);}
    },
  };
}
function registerAutomaticRecoveryRoutes(app,options) {
  const h=createAutomaticRecoveryHandlers(options),auth=options.requireAuth;
  if (typeof auth!=='function') throw Error('requireAuth required');
  const base='/account/recovery/automatic';
  const parseError=(error,_req,res,_next)=>res.status(error?.type==='entity.too.large'?413:400).json({error:'invalid_recovery_payload'});
  app.get(base,auth,h.settings);
  app.put(base,auth,express.json({limit:1024,strict:true,inflate:false}),parseError,h.consent);
  app.post(base+'/snapshots',auth,h.preflight,express.raw({type:MEDIA_TYPE,limit:MAX_ARCHIVE_BYTES+2052,inflate:false}),parseError,h.upload);
  app.get(base+'/snapshots/:snapshotId',auth,h.ciphertext);
  return h;
}
module.exports={createAutomaticRecoveryHandlers,registerAutomaticRecoveryRoutes};
