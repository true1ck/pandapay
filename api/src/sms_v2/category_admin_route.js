'use strict';

// Category rules and shop-name aliases are shared bundle parts, not extraction
// Rule versions. Every cohort candidate must pass before the global part is
// changed atomically. Both parts use the same draft, candidate and publish
// steps (makePartService); only validation and merging differ.
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
function assertObject(body, keys, code = "category_request_invalid") {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some(key => !keys.includes(key)) || keys.some(key => body[key] === undefined)) {
    throw new HttpError(400, code);
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
const ALIAS_NAME = /^[A-Z][A-Z0-9 &'.-]{1,59}$/;
const normalizeAlias = body => body && typeof body === 'object' && !Array.isArray(body) && typeof body.alias === 'string' && typeof body.merchantKey === 'string'
  ? { ...body, alias: cleanKey(body.alias), merchantKey: cleanKey(body.merchantKey) } : body;
function validateAlias(body, parts, now, previousBody) {
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).sort().join() !== 'alias,kind,merchantKey') throw new HttpError(400, 'alias_rule_invalid');
  if (body.kind !== 'learned') throw new HttpError(422, 'alias_kind_must_be_learned');
  if (parts.minEngineVersion === undefined) throw new HttpError(409, 'bundle_parts_missing');
  if (typeof body.alias !== 'string' || typeof body.merchantKey !== 'string') throw new HttpError(400, 'alias_rule_invalid');
  if (body.alias === body.merchantKey) throw new HttpError(422, 'alias_equals_key');
  // Either side with a run of four digits could be a terminal, account or phone number.
  if (!ALIAS_NAME.test(body.alias) || !ALIAS_NAME.test(body.merchantKey) || /\d{4,}/.test(body.alias) || /\d{4,}/.test(body.merchantKey)) {
    throw new HttpError(422, 'alias_key_invalid');
  }
  const own = previousBody ? cleanKey(previousBody.alias) : null;
  const conflict = (parts.merchantAliases || []).find(row => cleanKey(row.alias) === body.alias && cleanKey(row.merchantKey) !== body.merchantKey && cleanKey(row.alias) !== own);
  if (conflict) throw new HttpError(409, 'alias_conflict');
  const bundle = candidateBundle({ manifest: {}, rules: [], parts: { ...parts, merchantAliases: [body] }, now });
  const check = validateBundle(bundle);
  if (!check.ok) throw new HttpError(422, 'alias_rule_invalid', check.errors.map(error => `${error.code}@${error.path}`).join(', '));
}
const aliasIdentity = row => cleanKey(row.alias);
function withAlias(parts, body, previousPublishedBody = null) {
  const replaced = new Set([aliasIdentity(body)]);
  if (previousPublishedBody) replaced.add(aliasIdentity(previousPublishedBody));
  return { ...parts, merchantAliases: [...(parts.merchantAliases || []).filter(row => !replaced.has(aliasIdentity(row))), body] };
}

// One draft -> candidates -> publish service per shared part.
function makePartService({ tag, entity, drafts, validate, merge, normalize = body => body }) {
  async function saveDraft(s, id, body, { adminId, now }) {
    await s.lock();
    body = normalize(body);
    const latest = await s[drafts.get](id);
    const revision = latest ? latest.revision + 1 : 1;
    validate(body, await s.getParts(), now, (await s[drafts.previous](id, revision))?.body);
    await s[drafts.insert]({id, revision, body, status:'draft', createdBy: adminId, createdAt: now.toISOString()});
    await s.audit({adminId,action:`sms_v2_${tag}_draft`,entity,before:latest ? {id,revision:latest.revision} : null,after:{id,revision,body}});
    return {id,revision,status:'draft'};
  }
  async function candidates(s, id, revision, { now }) {
    const draft = await s[drafts.get](id,revision);
    if (!draft) throw new HttpError(404,`${tag}_draft_not_found`);
    if (draft.status !== 'draft') throw new HttpError(409,`${tag}_draft_not_publishable`);
    const latest = await s[drafts.get](id);
    if (latest.revision !== revision) throw new HttpError(409,`${tag}_draft_stale`);
    const existing = await s.getParts();
    const previous = await s[drafts.previous](id,revision);
    validate(draft.body,existing,now,previous?.body);
    const parts = merge(existing,draft.body,previous?.body), rules = await s.allRules(), cohorts = await s.allCohorts();
    return {draft,parts,candidates:COHORTS.map(cohort => {
      const bundle = candidateBundle({manifest:buildManifest(cohort,rules,cohorts,parts),rules,parts,now});
      return {cohort,bundle,contentSha256:contentSha256(bundle)};
    })};
  }
  async function publish(s, id, {revision,reason,goldenReports}, {adminId,now,signer,gates}) {
    await s.lock();
    const {draft,parts,candidates:list} = await candidates(s,id,revision,{now});
    for (const candidate of list) {
      const refusal = checkGoldenReport(goldenReports[candidate.cohort],candidate.contentSha256,gates);
      if (refusal) throw new HttpError(422,refusal.code,`${candidate.cohort}: ${refusal.detail || refusal.code}`);
    }
    await s.setParts(parts);
    // Each stored bundle retains its own exact candidate report.
    const minted = await mintBundles(s,{signer,now,publishedBy:String(adminId),goldenReport:null,
      goldenReportsByCohort:goldenReports});
    await s[drafts.publish](id,revision);
    await s.audit({adminId,action:`sms_v2_${tag}_publish`,entity,before:{id,revision,status:draft.status},after:{id,revision,body:draft.body,bundles:minted.map(row=>row.bundleVersion)},reason});
    return {id,revision,status:'published',bundles:minted.map(row=>({bundleVersion:row.bundleVersion,cohort:row.cohort}))};
  }
  return { saveDraft, candidates, publish };
}
const categories = makePartService({
  tag: 'category', entity: 'sms_v2_category_rule', validate: validateCategory, merge: withCategory,
  drafts: { get: 'categoryDraft', previous: 'previousPublishedCategoryDraft', insert: 'insertCategoryDraft', publish: 'publishCategoryDraft' },
});
const aliases = makePartService({
  tag: 'alias', entity: 'sms_v2_merchant_alias', validate: validateAlias, merge: withAlias, normalize: normalizeAlias,
  drafts: { get: 'aliasDraft', previous: 'previousPublishedAliasDraft', insert: 'insertAliasDraft', publish: 'publishAliasDraft' },
});
const { saveDraft: saveCategoryDraft, candidates: categoryCandidates, publish: publishCategory } = categories;
const { saveDraft: saveAliasDraft, candidates: aliasCandidates, publish: publishAlias } = aliases;

function routeKit(api,deps) {
  let signer=deps.signer;
  if (signer === undefined) { try { signer=signerFromEnv(); } catch { signer=null; } }
  const now=deps.now || (()=>new Date());
  const register=(tag,method,path,fn)=>api.route(method,`/admin/sms/v2${path}`,async(req,res,ctx)=>{
    const withPrivateClient=(_actor,operation)=>ctx.withAdminClient(operation);
    const guard=createRequireSmsV2({withUserClient:withPrivateClient,cacheMs:0});
    return guard(req,res,async()=>{
      try {
        if (req.params.id && !UUID.test(req.params.id)) throw new HttpError(400,`${tag}_id_invalid`);
        const store=deps.store || createPgStore({withUserClient:withPrivateClient});
        const out=await store.tx(req.admin.userId,s=>fn(req,s,{adminId:req.admin.userId,now:now(),signer,gates:(deps.getGates || loadGates)()}));
        return res.json(out);
      } catch(error) {
        if (error instanceof HttpError) return res.status(error.status).json({error:error.code,...(error.detail?{detail:error.detail}:{})});
        if (error.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({error:'admin_permission_required'});
        if (error.code === 'signing_unavailable') return res.status(503).json({error:'signing_unavailable'});
        if (error.code === 'bundle_invalid') return res.status(422).json({error:'bundle_invalid'});
        console.error(`sms_v2 ${tag} admin failed`,error.code || error.name);
        return res.status(500).json({error:`${tag}_unavailable`});
      }
    });
  });
  // The three steps every shared part has: save a draft, read its four cohort
  // candidates, publish them with their golden reports.
  const registerPart=(tag,segment,service)=>{
    register(tag,'PUT',`/${segment}/:id/draft`,(req,s,ctx)=>service.saveDraft(s,req.params.id,req.body,ctx));
    register(tag,'GET',`/${segment}/:id/candidate`,async(req,s,ctx)=>{
      const revision=Number(req.query.revision);
      if (!Number.isInteger(revision) || revision<1) throw new HttpError(400,`${tag}_revision_invalid`);
      return {candidates:(await service.candidates(s,req.params.id,revision,ctx)).candidates};
    });
    register(tag,'POST',`/${segment}/:id/publish`,(req,s,ctx)=>{
      assertObject(req.body,['revision','reason','goldenReports'],`${tag}_request_invalid`);
      const {revision,reason,goldenReports}=req.body;
      if (!Number.isInteger(revision) || revision<1 || typeof reason !== 'string' || !reason.trim() || reason.length>2000 || !goldenReports || typeof goldenReports !== 'object' || Array.isArray(goldenReports) || Object.keys(goldenReports).length!==4 || COHORTS.some(cohort=>!Object.hasOwn(goldenReports,cohort))) throw new HttpError(400,`${tag}_publish_invalid`);
      return service.publish(s,req.params.id,{revision,reason,goldenReports},ctx);
    });
  };
  return {register,registerPart};
}
function registerPrivateCategoryRoutes(api,deps={}) {
  const {register,registerPart}=routeKit(api,deps);
  register('category','GET','/category-rules',async(_req,s)=>({rules:(await s.getParts()).categoryRules || [],drafts:await s.listCategoryDrafts()}));
  registerPart('category','category-rules',categories);
}
// Shop names learned from people (learning-loop A8): the same three steps.
function registerPrivateAliasRoutes(api,deps={}) {
  const {registerPart}=routeKit(api,deps);
  registerPart('alias','merchant-aliases',aliases);
}
module.exports={registerPrivateCategoryRoutes,registerPrivateAliasRoutes,saveCategoryDraft,categoryCandidates,publishCategory,saveAliasDraft,aliasCandidates,publishAlias,withCategory,withAlias,identity};
