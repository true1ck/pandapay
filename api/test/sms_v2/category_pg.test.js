'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const crypto=require('node:crypto');
const {createAdminApiApp}=require('../../src/admin/app');
const {createAdminDbHelpers}=require('../../src/admin/server');
const {registerPrivateCategoryRoutes}=require('../../src/sms_v2/category_admin_route');
const {createSigner,verifyBundle}=require('../../src/sms_v2/signer');
const {createPgStore}=require('../../src/sms_v2/rules_store');
const {importBundle}=require('../../src/sms_v2/rules_admin_route');
const {routeManifest}=require('../../src/admin/route_manifest');
const full=require('../../../contracts/sms/v2/fixtures/valid/bundle/full.json');
const url=process.env.SMS_V2_TEST_DATABASE_URL,adminUrl=process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;
test('private category review publishes signed global parts on a fully migrated real database',{skip:!url||!adminUrl},async t=>{
 const {Pool}=require('pg');const pool=new Pool({connectionString:url}),privatePool=new Pool({connectionString:adminUrl});
 const actor=crypto.randomUUID(),id=crypto.randomUUID();let server;
 const priorFlag=(await pool.query("SELECT is_enabled,rollout_percent FROM feature_flags WHERE key='sms_pipeline_v2_enabled'")).rows[0];
 t.after(async()=>{if(server){server.closeAllConnections();await new Promise(resolve=>server.close(resolve));}
  await pool.query('DELETE FROM sms_v2_category_drafts WHERE draft_id=$1',[id]);
  for(const table of ['sms_v2_rule_cohorts','sms_v2_bundles','sms_v2_bundle_parts','sms_v2_rules']) await pool.query(`DELETE FROM ${table}`);
  await pool.query('DELETE FROM admin_audit_log WHERE admin_id=$1',[actor]);await pool.query('DELETE FROM admin_users WHERE id=$1',[actor]);
  if(priorFlag)await pool.query("UPDATE feature_flags SET is_enabled=$1,rollout_percent=$2 WHERE key='sms_pipeline_v2_enabled'",[priorFlag.is_enabled,priorFlag.rollout_percent]);
  else await pool.query("DELETE FROM feature_flags WHERE key='sms_pipeline_v2_enabled'");
  await Promise.all([pool.end(),privatePool.end()]);
 });
 for(const table of ['sms_v2_rule_cohorts','sms_v2_bundles','sms_v2_bundle_parts','sms_v2_rules'])await pool.query(`DELETE FROM ${table}`);
 await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')",[actor,`${actor}@example.invalid`]);
 await pool.query("INSERT INTO feature_flags(key,is_enabled,rollout_percent) VALUES('sms_pipeline_v2_enabled',true,100) ON CONFLICT(key) DO UPDATE SET is_enabled=true,rollout_percent=100");
 const helpers=createAdminDbHelpers(privatePool),now=new Date('2026-11-04T12:00:00Z');
 const kp=crypto.generateKeyPairSync('ed25519'),signer=createSigner({privateKeyPem:kp.privateKey.export({type:'pkcs8',format:'pem'}),keyId:'category-pg'});
 const store=createPgStore({withUserClient:(admin,fn)=>helpers.withAdminClient(admin,'learning.publish',fn)});
 await store.tx(actor,s=>importBundle(s,full,{signer,adminId:actor,now}));
 let fresh=true;
 const app=createAdminApiApp({routeManifest:routeManifest.filter(row=>row.path.startsWith('/admin/sms/v2/category-rules')),
  introspectAdminSession:async()=>({active:true,userId:actor,sessionId:'category-fixture',assurance:'email+webauthn-uv',mfaVerifiedAt:new Date(Date.now()-(fresh?0:3600000)),expiresAt:new Date(Date.now()+60000)}),
  loadPermissions:helpers.loadPermissions,withAdminClient:helpers.withAdminClient,
  registerRoutes:api=>registerPrivateCategoryRoutes(api,{signer,now:()=>now,getGates:()=>({m1:{}})})});
 server=app.listen(0,'127.0.0.1');await new Promise(resolve=>server.once('listening',resolve));
 const call=async(method,path,body)=>{const response=await fetch(`http://127.0.0.1:${server.address().port}/admin/sms/v2${path}`,{method,headers:{authorization:`Bearer ${'x'.repeat(43)}`,'content-type':'application/json'},body:body===undefined?undefined:JSON.stringify(body)});return {status:response.status,body:await response.json()};};
 const body={merchantKey:'SYNTHETIC SHOP',match:'exact',senders:['HDFCBK'],context:[],category:'dining',priority:100,source:'shared'};
 fresh=false;assert.equal((await call('PUT',`/category-rules/${id}/draft`,body)).status,403);fresh=true;
 const saved=await call('PUT',`/category-rules/${id}/draft`,body);assert.equal(saved.status,200,JSON.stringify(saved.body));assert.equal(saved.body.revision,1);
 await helpers.withAdminClient(actor,'learning.read',async client=>{const updated=await client.query("UPDATE sms_v2_category_drafts SET status='published' WHERE draft_id=$1",[id]);assert.equal(updated.rowCount,0);});
 const result=await call('GET',`/category-rules/${id}/candidate?revision=1`);assert.equal(result.status,200,JSON.stringify(result.body));assert.equal(result.body.candidates.length,4);
 const reports=Object.fromEntries(result.body.candidates.map(candidate=>[candidate.cohort,{bundleSha256:candidate.contentSha256,counts:{cases:1,casesPassed:1},metrics:{}}]));
 const bad=structuredClone(reports);bad.testers.bundleSha256='0'.repeat(64);
 assert.equal((await call('POST',`/category-rules/${id}/publish`,{revision:1,reason:'review',goldenReports:bad})).status,422);
 assert.equal((await store.tx(actor,s=>s.categoryDraft(id))).status,'draft');
 const published=await call('POST',`/category-rules/${id}/publish`,{revision:1,reason:'Reviewed synthetic golden category case',goldenReports:reports});assert.equal(published.status,200,JSON.stringify(published.body));assert.equal(published.body.bundles.length,4);
 for(const cohort of ['testers','pct5','pct25','all']){const row=await store.tx(actor,s=>s.latestBundle(cohort));assert.ok(row.body.categoryRules.some(rule=>rule.merchantKey==='SYNTHETIC SHOP'&&rule.category==='dining'));assert.ok(verifyBundle({...row.body,signature:{alg:'Ed25519',keyId:row.keyId,value:row.signature}},signer.publicKeyPem));assert.deepEqual(row.goldenReport,reports[cohort]);}
 assert.equal((await store.tx(actor,s=>s.categoryDraft(id))).status,'published');
 const audit=(await pool.query("SELECT reason,entity FROM admin_audit_log WHERE admin_id=$1 AND action='sms_v2_category_publish'",[actor])).rows[0];assert.equal(audit.reason,'Reviewed synthetic golden category case');assert.equal(audit.entity,'sms_v2_category_rule');
});
