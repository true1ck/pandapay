'use strict';

// Category rules are shared bundle parts, not extraction Rule versions. Every
// cohort candidate must pass before the global part is changed atomically.
const { createPgStore } = require('./rules_store');
const { createRequireSmsV2 } = require('./guard');
const { signerFromEnv } = require('./signer');
const { validateBundle } = require('./contracts');
const { COHORTS, buildManifest, candidateBundle, contentSha256, mintBundles } = require('./bundle_builder');
const { HttpError, checkGoldenReport, loadGates } = require('./rules_admin_route');
const { canonicalize } = require('./signer');
const { SPEND_CATEGORIES } = require('../sms_facts');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const cleanKey = value => value.trim().replace(/\s+/g, ' ').toUpperCase();
const identity = rule => canonicalize({ merchantKey: cleanKey(rule.merchantKey), match: rule.match,
  senders: rule.senders.map(cleanKey).sort(), context: rule.context.map(cleanKey).sort(), source: rule.source });
function withCategory(parts, body, previousPublishedBody = null) {
  const replaced = new Set([identity(body)]);
  if (previousPublishedBody) replaced.add(identity(previousPublishedBody));
  return { ...parts, categoryRules: [...(parts.categoryRules || []).filter(rule => !replaced.has(identity(rule))), body] };
}
function assertObject(body, keys) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !keys.includes(key)) || keys.some(key => body[key] === undefined)) {
    throw new HttpError(400, 'category_request_invalid');
  }
}
function validateCategory(body, parts, now) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new HttpError(400, 'category_rule_invalid');
  if (body.source !== 'shared') throw new HttpError(422, 'category_source_must_be_shared');
  if (parts.minEngineVersion === undefined) throw new HttpError(409, 'bundle_parts_missing');
  const bundle = candidateBundle({ manifest: {}, rules: [], parts: {...parts, categoryRules: [body]}, now });
  const check = validateBundle(bundle);
  if (!check.ok) throw new HttpError(422, 'category_rule_invalid', check.errors.map(error => `${error.code}@${error.path}`).join(', '));
  if (parts.taxonomyVersion !== 1 || !SPEND_CATEGORIES.includes(body.category)) throw new HttpError(422,'category_taxonomy_unknown');
  const known = new Set(parts.senders.flatMap(sender => [sender.brand, ...sender.aliases]).map(cleanKey));
  if (body.senders.some(sender => sender !== '*' && !known.has(cleanKey(sender)))) throw new HttpError(422, 'category_sender_unknown');
  if (body.merchantKey.length > 200 || body.merchantKey.trim().length === 0) throw new HttpError(422, 'category_merchant_key_invalid');
}
async function saveCategoryDraft(s, id, body, { adminId, now }) {
  await s.lock();
  validateCategory(body, await s.getParts(), now);
  const latest = await s.categoryDraft(id);
  const revision = latest ? latest.revision + 1 : 1;
  await s.insertCategoryDraft({id, revision, body, status:'draft', createdBy: adminId, createdAt: now.toISOString()});
  await s.audit({adminId,action:'sms_v2_category_draft',entity:'sms_v2_category_rule',before:latest ? {id,revision:latest.revision} : null,after:{id,revision,body}});
  return {id,revision,status:'draft'};
}
async function categoryCandidates(s, id, revision, { now }) {
  const draft = await s.categoryDraft(id,revision);
  if (!draft) throw new HttpError(404,'category_draft_not_found');
  if (draft.status !== 'draft') throw new HttpError(409,'category_draft_not_publishable');
  const latest = await s.categoryDraft(id);
  if (latest.revision !== revision) throw new HttpError(409,'category_draft_stale');
  const existing = await s.getParts();
  validateCategory(draft.body,existing,now);
  const previous = await s.previousPublishedCategoryDraft(id,revision);
  const parts = withCategory(existing,draft.body,previous?.body), rules = await s.allRules(), cohorts = await s.allCohorts();
  return {draft,parts,candidates:COHORTS.map(cohort => {
    const bundle = candidateBundle({manifest:buildManifest(cohort,rules,cohorts,parts),rules,parts,now});
    return {cohort,bundle,contentSha256:contentSha256(bundle)};
  })};
}
async function publishCategory(s, id, {revision,reason,goldenReports}, {adminId,now,signer,gates}) {
  await s.lock();
  const {draft,parts,candidates} = await categoryCandidates(s,id,revision,{now});
  for (const candidate of candidates) {
    const refusal = checkGoldenReport(goldenReports[candidate.cohort],candidate.contentSha256,gates);
    if (refusal) throw new HttpError(422,refusal.code,`${candidate.cohort}: ${refusal.detail || refusal.code}`);
  }
  await s.setParts(parts);
  // Each stored bundle retains its own exact candidate report.
  const minted = await mintBundles(s,{signer,now,publishedBy:String(adminId),goldenReport:null,
    goldenReportsByCohort:goldenReports});
  await s.publishCategoryDraft(id,revision);
  await s.audit({adminId,action:'sms_v2_category_publish',entity:'sms_v2_category_rule',before:{id,revision,status:draft.status},after:{id,revision,body:draft.body,bundles:minted.map(row=>row.bundleVersion)},reason});
  return {id,revision,status:'published',bundles:minted.map(row=>({bundleVersion:row.bundleVersion,cohort:row.cohort}))};
}
function registerPrivateCategoryRoutes(api,deps={}) {
  let signer=deps.signer;
  if (signer === undefined) { try { signer=signerFromEnv(); } catch { signer=null; } }
  const now=deps.now || (()=>new Date());
  const register=(method,path,fn)=>api.route(method,`/admin/sms/v2${path}`,async(req,res,ctx)=>{
    const withPrivateClient=(_actor,operation)=>ctx.withAdminClient(operation);
    const guard=createRequireSmsV2({withUserClient:withPrivateClient,cacheMs:0});
    return guard(req,res,async()=>{
      try {
        if (req.params.id && !UUID.test(req.params.id)) throw new HttpError(400,'category_id_invalid');
        const store=deps.store || createPgStore({withUserClient:withPrivateClient});
        const out=await store.tx(req.admin.userId,s=>fn(req,s,{adminId:req.admin.userId,now:now(),signer,gates:(deps.getGates || loadGates)()}));
        return res.json(out);
      } catch(error) {
        if (error instanceof HttpError) return res.status(error.status).json({error:error.code,...(error.detail?{detail:error.detail}:{})});
        if (error.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({error:'admin_permission_required'});
        if (error.code === 'signing_unavailable') return res.status(503).json({error:'signing_unavailable'});
        if (error.code === 'bundle_invalid') return res.status(422).json({error:'bundle_invalid'});
        console.error('sms_v2 category admin failed',error.code || error.name);
        return res.status(500).json({error:'category_unavailable'});
      }
    });
  });
  register('GET','/category-rules',async(_req,s)=>({rules:(await s.getParts()).categoryRules || [],drafts:await s.listCategoryDrafts()}));
  register('PUT','/category-rules/:id/draft',(req,s,ctx)=>saveCategoryDraft(s,req.params.id,req.body,ctx));
  register('GET','/category-rules/:id/candidate',async(req,s,ctx)=>{
    const revision=Number(req.query.revision);
    if (!Number.isInteger(revision) || revision<1) throw new HttpError(400,'category_revision_invalid');
    return {candidates:(await categoryCandidates(s,req.params.id,revision,ctx)).candidates};
  });
  register('POST','/category-rules/:id/publish',(req,s,ctx)=>{
    assertObject(req.body,['revision','reason','goldenReports']);
    const {revision,reason,goldenReports}=req.body;
    if (!Number.isInteger(revision) || revision<1 || typeof reason !== 'string' || !reason.trim() || reason.length>2000 || !goldenReports || typeof goldenReports !== 'object' || Array.isArray(goldenReports) || Object.keys(goldenReports).length!==4 || COHORTS.some(cohort=>!Object.hasOwn(goldenReports,cohort))) throw new HttpError(400,'category_publish_invalid');
    return publishCategory(s,req.params.id,{revision,reason,goldenReports},ctx);
  });
}
module.exports={registerPrivateCategoryRoutes,saveCategoryDraft,categoryCandidates,publishCategory,withCategory,identity};
