'use strict';
const {isVersionedOtpRequest}=require('../routes/versionedOtpRoutes');
const OTP_PATHS=new Set(['/request-otp','/request-email-otp','/verify-otp','/verify-email-otp']);
function retirementFlag(value,name){
  if(value===undefined||value==='')return false;
  if(value!=='true'&&value!=='false')throw new Error(`${name} must be true or false`);
  return value==='true';
}
// Mount on the shared legacy router. Only the trusted v2 router marker may
// bypass legacy retirement; body/header/protocol selectors cannot do so.
function createLegacyAuthAdmission({retireLegacyOtp=false,retirePublicLookup=false}={}){
  if(typeof retireLegacyOtp!=='boolean'||typeof retirePublicLookup!=='boolean')throw new TypeError('Invalid auth compatibility policy');
  return (req,res,next)=>{
    const path=(req.path||'').toLowerCase().replace(/\/+$/,'');
    if(req.method==='POST'&&!isVersionedOtpRequest(req)&&
      ((retireLegacyOtp&&OTP_PATHS.has(path))||(retirePublicLookup&&path==='/check-user'))){
      res.setHeader('Cache-Control','no-store');
      return res.status(410).json({error:'client_update_required',message:'Please update PandaPay to continue signing in.'});
    }
    next();
  };
}
module.exports={createLegacyAuthAdmission,retirementFlag};
