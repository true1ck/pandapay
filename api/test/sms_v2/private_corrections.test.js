'use strict';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test=require('node:test');
const assert=require('node:assert/strict');
const {createAdminApiApp}=require('../../src/admin/app');
const {routeManifest}=require('../../src/admin/route_manifest');
const {registerPrivateCorrections}=require('../../src/sms_v2/corrections_route');

const caseId='00000000-0000-4000-8000-000000000001';
const token='x'.repeat(43);
test('private corrections enforce read/publish, fresh MFA, feature flag and audit decisions',async t=>{
 const state={permissions:['learning.read','learning.publish'],enabled:true,mfa:new Date(),audits:0};
 const client={query:async(sql,args)=>{
  if(sql.includes('feature_flags'))return{rows:[{key:'sms_pipeline_v2_enabled',is_enabled:state.enabled,rollout_percent:100}]};
  if(sql.includes('SELECT * FROM sms_v2_correction_cases'))return{rows:[{case_id:caseId,stage:'gate',status:'open',corrected:{}}]};
  if(sql.includes('FROM sms_v2_correction_cases'))return{rows:[]};
  if(sql.includes('INSERT INTO admin_audit_log'))state.audits++;
  return{rows:[]};
 }};
 const app=createAdminApiApp({
  routeManifest:routeManifest.filter(row=>row.path.startsWith('/admin/sms/v2/corrections')),
  introspectAdminSession:async()=>({active:true,userId:'actor',sessionId:'session',assurance:'email+webauthn-uv',mfaVerifiedAt:state.mfa,expiresAt:new Date(Date.now()+60000)}),
  loadPermissions:async()=>({active:true,userId:'actor',role:'owner',permissions:state.permissions}),
  withAdminClient:async(actor,permission,operation)=>operation(client),
  registerRoutes:registerPrivateCorrections,
 });
 const server=app.listen(0,'127.0.0.1');
 await new Promise(resolve=>server.once('listening',resolve));
 t.after(()=>{server.closeAllConnections();server.close();});
 const origin='http://127.0.0.1:'+server.address().port;
 const headers={authorization:'Bearer '+token,'content-type':'application/json'};
 assert.equal((await fetch(origin+'/admin/sms/v2/corrections')).status,401);
 assert.equal((await fetch(origin+'/admin/sms/v2/corrections',{headers})).status,200);
 state.permissions=['learning.read'];
 const prepare=()=>fetch(origin+'/admin/sms/v2/corrections/'+caseId+'/example',
  {method:'PUT',headers,body:JSON.stringify({source:'synthetic',body:'Rs.10 spent',
    observedAt:'2026-11-01T12:00:00Z',expect:{facts:[{factType:'movement'}]}})});
 const post=()=>fetch(origin+'/admin/sms/v2/corrections/'+caseId+'/decision',
  {method:'POST',headers,body:JSON.stringify({decision:'not_a_bug',reason:'Synthetic confirmation'})});
 assert.equal((await post()).status,403);
 assert.equal((await prepare()).status,403);
 state.permissions=['learning.read','learning.publish'];
 state.mfa=new Date(Date.now()-600000);
 assert.equal((await post()).status,403);
 state.mfa=new Date();
 assert.equal((await post()).status,200);
 assert.equal(state.audits,1);
 state.enabled=false;
 assert.equal((await fetch(origin+'/admin/sms/v2/corrections',{headers})).status,404);
});
