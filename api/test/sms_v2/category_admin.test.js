'use strict';
const test=require('node:test');const assert=require('node:assert/strict');const crypto=require('node:crypto');
const full=require('../../../contracts/sms/v2/fixtures/valid/bundle/full.json');
const {MemoryStore}=require('../../src/sms_v2/rules_store');
const {createSigner}=require('../../src/sms_v2/signer');
const {importBundle,saveDraft,publishVersion}=require('../../src/sms_v2/rules_admin_route');
const {saveCategoryDraft,categoryCandidates,publishCategory}=require('../../src/sms_v2/category_admin_route');
const {COHORTS,contentSha256}=require('../../src/sms_v2/bundle_builder');
const {routeManifest}=require('../../src/admin/route_manifest');
const now=new Date('2026-11-04T12:00:00Z'),adminId='00000000-0000-4000-8000-000000000001',id='00000000-0000-4000-8000-000000000002';
const kp=crypto.generateKeyPairSync('ed25519');const signer=createSigner({privateKeyPem:kp.privateKey.export({format:'pem',type:'pkcs8'}),keyId:'category-test'});
const ctx={now,adminId,signer,gates:{m1:{captureRecall:{min:0.99}}}};
const category=()=>({merchantKey:'SYNTHETIC SHOP',match:'exact',senders:['HDFCBK'],context:[],category:'dining',priority:100,source:'shared'});
const report=hash=>({bundleSha256:hash,counts:{cases:1,casesPassed:1,scenarios:1,scenariosPassed:1,scenariosEvaluated:true},metrics:{captureRecall:{value:1,status:'ok'}}});
async function fixture(){const store=new MemoryStore();await store.tx(adminId,s=>importBundle(s,full,ctx));return store;}
async function candidateReports(store,revision=1){const result=await store.tx(adminId,s=>categoryCandidates(s,id,revision,ctx));return Object.fromEntries(result.candidates.map(candidate=>[candidate.cohort,report(candidate.contentSha256)]));}
test('global category publication gates every exact cohort, changes real bundle parts, preserves fact versions',async()=>{
 const store=await fixture();const rule=full.rules[0];
 const saved=await store.tx(adminId,s=>saveDraft(s,rule.id,{...rule,confidence:0.98},ctx));
 // Different extraction versions make the cohort candidate identities differ.
 await store.tx(adminId,async s=>{
  const {candidateBundle,buildManifest}=require('../../src/sms_v2/bundle_builder');
  const rows=(await s.allRules()).map(row=>row.version===saved.version?{...row,status:'active'}:row);
  const cohorts=[...await s.allCohorts(),{ruleId:rule.id,version:saved.version,cohort:'testers',pausedAt:null}];
  const parts=await s.getParts();const candidate=candidateBundle({manifest:buildManifest('testers',rows,cohorts,parts),rules:rows,parts,now});
  await publishVersion(s,rule.id,{version:saved.version,cohort:'testers',goldenReport:report(contentSha256(candidate))},ctx);
 });
 const factsBefore=structuredClone(store.state.rules),cohortsBefore=structuredClone(store.state.cohorts);
 await store.tx(adminId,s=>saveCategoryDraft(s,id,category(),ctx));
 const reports=await candidateReports(store);assert.notEqual(reports.testers.bundleSha256,reports.all.bundleSha256);
 const bad=structuredClone(reports);bad.pct5.bundleSha256='0'.repeat(64);
 const before=JSON.stringify(store.state.parts);
 await assert.rejects(store.tx(adminId,s=>publishCategory(s,id,{revision:1,reason:'review',goldenReports:bad},ctx)),{code:'golden_report_hash_mismatch'});
 assert.equal(JSON.stringify(store.state.parts),before);assert.equal(store.state.categoryDrafts[0].status,'draft');
 const published=await store.tx(adminId,s=>publishCategory(s,id,{revision:1,reason:'Reviewed synthetic merchant correction',goldenReports:reports},ctx));
 assert.equal(published.bundles.length,4);assert.deepEqual(store.state.rules,factsBefore);assert.deepEqual(store.state.cohorts,cohortsBefore);
 for(const cohort of COHORTS){const row=await store.tx(adminId,s=>s.latestBundle(cohort));assert.ok(row.body.categoryRules.some(rule=>rule.merchantKey==='SYNTHETIC SHOP'&&rule.category==='dining'));assert.deepEqual(row.goldenReport,reports[cohort]);}
 assert.equal(store.state.audit.at(-1).reason,'Reviewed synthetic merchant correction');assert.equal(store.state.audit.at(-1).entity,'sms_v2_category_rule');
 await assert.rejects(store.tx(adminId,s=>publishCategory(s,id,{revision:1,reason:'again',goldenReports:reports},ctx)),{code:'category_draft_not_publishable'});
});
test('category draft revisions and bundle changes invalidate old reports and never partially publish',async()=>{
 const store=await fixture();await store.tx(adminId,s=>saveCategoryDraft(s,id,category(),ctx));const stale=await candidateReports(store);
 await store.tx(adminId,s=>saveCategoryDraft(s,id,{...category(),category:'groceries'},ctx));
 await assert.rejects(store.tx(adminId,s=>categoryCandidates(s,id,1,ctx)),{code:'category_draft_stale'});
 await assert.rejects(store.tx(adminId,s=>publishCategory(s,id,{revision:2,reason:'stale',goldenReports:stale},ctx)),{code:'golden_report_hash_mismatch'});
 const reports=await candidateReports(store,2);reports.all.metrics.captureRecall.value=0;
 await assert.rejects(store.tx(adminId,s=>publishCategory(s,id,{revision:2,reason:'failing',goldenReports:reports},ctx)),{code:'golden_report_gate_failed'});
 const valid=await candidateReports(store,2);await assert.rejects(store.tx(adminId,s=>publishCategory(s,id,{revision:2,reason:'no signer',goldenReports:valid},{...ctx,signer:null})),{code:'signing_unavailable'});
 assert.ok(!store.state.parts.categoryRules.some(rule=>rule.merchantKey==='SYNTHETIC SHOP'));
 assert.ok(store.state.categoryDrafts.every(row=>row.status==='draft'));
});
test('category drafts reject wrong contract, unknown taxonomy and unknown sender',async()=>{
 const store=await fixture();for(const body of [{...category(),source:'ai'},{...category(),id:'not-in-contract'},{...category(),category:'made_up'},{...category(),senders:['UNKNOWN']},{...category(),merchantKey:'  '}])await assert.rejects(store.tx(adminId,s=>saveCategoryDraft(s,id,body,ctx)));
 assert.equal(store.state.categoryDrafts.length,0);
});
test('category drafts cannot be reached without existing private permissions and fresh MFA',()=>{
 const rows=routeManifest.filter(row=>row.path.startsWith('/admin/sms/v2/category-rules'));
 assert.equal(rows.length,4);for(const row of rows){assert.equal(row.permission,row.method==='GET'?'learning.read':'learning.publish');if(row.method!=='GET')assert.equal(row.freshMfa,true);}
});

test('revising a published draft replaces its previous matching scope instead of retaining a broad rule',async()=>{
 const store=await fixture();await store.tx(adminId,s=>saveCategoryDraft(s,id,{...category(),match:'contains'},ctx));
 await store.tx(adminId,async s=>publishCategory(s,id,{revision:1,reason:'broad review',goldenReports:await candidateReports(store)},ctx));
 await store.tx(adminId,s=>saveCategoryDraft(s,id,category(),ctx));
 const candidates=await store.tx(adminId,s=>categoryCandidates(s,id,2,ctx));
 for(const candidate of candidates.candidates){const mine=candidate.bundle.categoryRules.filter(rule=>rule.merchantKey==='SYNTHETIC SHOP'&&rule.source==='shared');assert.equal(mine.length,1);assert.equal(mine[0].match,'exact');}
 const reports=await candidateReports(store,2);await store.tx(adminId,s=>publishCategory(s,id,{revision:2,reason:'narrow to exact',goldenReports:reports},ctx));
 for(const cohort of COHORTS){const row=await store.tx(adminId,s=>s.latestBundle(cohort));const mine=row.body.categoryRules.filter(rule=>rule.merchantKey==='SYNTHETIC SHOP'&&rule.source==='shared');assert.equal(mine.length,1);assert.equal(mine[0].match,'exact');}
 assert.equal(store.state.categoryDrafts[0].body.match,'contains');
});
