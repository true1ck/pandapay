'use strict';
const express=require('express');
// Only this router marks a live request. Body/header fields never select the
// protocol. WeakSet entries disappear with their request after completion.
const versionedRequests=new WeakSet();
const isVersionedOtpRequest=req=>versionedRequests.has(req);
const UUID=/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
function createVersionedOtpRouter({legacyRouter}){
  if(typeof legacyRouter!=='function')throw new TypeError('Existing OTP router is required');
  const router=express.Router();
  router.use((req,res,next)=>{res.setHeader('Cache-Control','no-store');res.setHeader('Pragma','no-cache');next();});
  for(const path of ['/request-otp','/request-email-otp','/verify-otp','/verify-email-otp']){
    router.post(path,(req,res,next)=>{
      const verify=path.startsWith('/verify-'),email=path.includes('email');
      const fields=[email?'email':'phone_number','device_id','recovery_only',...(verify?['code','challenge_id','device_info']:[])];
      const b=req.body;
      if(!b||typeof b!=='object'||Array.isArray(b)||Object.keys(b).some(k=>!fields.includes(k))||Object.keys(req.query||{}).length||
        typeof b.device_id!=='string'||!/^[A-Za-z0-9:_-]{4,128}$/.test(b.device_id)||
        (verify&&(typeof b.code!=='string'||!/^\d{6}$/.test(b.code)||!UUID.test(b.challenge_id||''))))return res.status(400).json({error:'invalid_v2_otp_request'});
      versionedRequests.add(req);
      legacyRouter(req,res,next);
    });
  }
  // Do not fall through to a legacy route, even with extra slashes/suffixes.
  router.use((req,res)=>res.status(404).json({error:'not_found'}));
  return router;
}
module.exports={createVersionedOtpRouter,isVersionedOtpRequest};
