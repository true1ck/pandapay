'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const express=require('express'),http=require('node:http');
const {createLegacyAuthAdmission,retirementFlag}=require('../src/middleware/legacyAuthAdmission');
const {createVersionedOtpRouter}=require('../src/routes/versionedOtpRoutes');
test('retirement config is explicit, strict and defaults to compatible routes',()=>{
 for(const x of [undefined,'','false'])assert.equal(retirementFlag(x,'FLAG'),false);
 assert.equal(retirementFlag('true','FLAG'),true);
 for(const x of ['0','1','TRUE','maybe',true])assert.throws(()=>retirementFlag(x,'FLAG'));
 assert.throws(()=>createLegacyAuthAdmission({retireLegacyOtp:'false'}));
});
test('retirement refuses legacy protocol and lookup uniformly but keeps trusted v2 and unrelated routes',async t=>{
 const app=express(),legacy=express.Router();app.use(express.json());
 legacy.use(createLegacyAuthAdmission({retireLegacyOtp:true,retirePublicLookup:true}));
 for(const path of ['/request-otp','/request-email-otp','/verify-otp','/verify-email-otp','/check-user','/refresh','/signup'])legacy.post(path,(req,res)=>res.json({ok:true}));
 app.use('/auth/v2',createVersionedOtpRouter({legacyRouter:legacy}));app.use('/auth',legacy);
 const server=http.createServer(app);await new Promise(r=>server.listen(0,'127.0.0.1',r));
 t.after(()=>new Promise(r=>{server.closeAllConnections();server.close(r);}));const base=`http://127.0.0.1:${server.address().port}`;
 for(const path of ['request-otp','request-email-otp','verify-otp','verify-email-otp','check-user','CHECK-USER/']){
  const r=await fetch(`${base}/auth/${path}`,{method:'POST',headers:{'Content-Type':'application/json','X-Protocol-Version':'2'},body:JSON.stringify({protocol_version:2,email:'different@example.test'})});
  assert.equal(r.status,410);assert.equal(r.headers.get('cache-control'),'no-store');assert.deepEqual(await r.json(),{error:'client_update_required',message:'Please update PandaPay to continue signing in.'});
 }
 const modern=await fetch(`${base}/auth/v2/request-email-otp`,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({email:'proof@example.test',device_id:'test-device'})});assert.equal(modern.status,200);
 const refresh=await fetch(`${base}/auth/refresh`,{method:'POST'});assert.equal(refresh.status,200);
});
