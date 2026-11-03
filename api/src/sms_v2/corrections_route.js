'use strict';

const crypto = require('node:crypto');
const { validateRequest } = require('./contracts');
const { canonicalize } = require('./signer');
const { createRequireSmsV2 } = require('./guard');

const denied = value => value === false || value?.ok === false;
const digest = value => crypto.createHash('sha256').update(value).digest('hex');
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function stageFor(kind, trace, corrected = {}) {
  switch (kind) {
    case 'preference_only': return null;
    case 'not_financial': return trace.stage === 'gate' ? 'gate' : 'extraction';
    case 'wrong_instrument': return trace.stage === 'extraction' ? 'extraction' : 'instrument';
    case 'wrong_link': case 'duplicate': return 'linking';
    case 'wrong_category': return 'category';
    case 'missing': return 'gate';
    default: return 'extraction';
  }
}

// Wire template text is a skeleton already produced from redacted values.
// The hash is independently derived from its normalized brand and exact text.
function templateMetadata(body) {
  if (!body.redactedTemplate) return null;
  const metadata = body.corrected?._template;
  if (!metadata || typeof metadata.senderBrand !== 'string' ||
      !/^[A-Z0-9_-]{2,32}$/.test(metadata.senderBrand) ||
      typeof metadata.hash !== 'string' ||
      typeof metadata.observedAt !== 'string' || !Number.isFinite(Date.parse(metadata.observedAt)) ||
      body.redactedTemplate.length > 20000 ||
      /\d/.test(body.redactedTemplate) ||
      /@|https?:\/\//i.test(body.redactedTemplate)) {
    throw Object.assign(new Error('redacted_template_invalid'), { status: 400 });
  }
  const hash = digest(metadata.senderBrand + '\n' + body.redactedTemplate);
  if (hash !== metadata.hash) throw Object.assign(new Error('template_hash_mismatch'), { status: 400 });
  return { hash, senderBrand: metadata.senderBrand, observedAt: metadata.observedAt };
}

async function submitCorrection(client, profileId, body, { sharedLearningEligible = false } = {}) {
  const check = validateRequest('corrections', body);
  if (!check.ok) throw Object.assign(new Error(check.errors[0].code), { status: 400 });
  if (body.correctionKind === 'preference_only') throw Object.assign(new Error('preference_only_local'), { status: 400 });
  const stage = stageFor(body.correctionKind, body.trace, body.corrected);
  if (body.trace.stage !== stage) throw Object.assign(new Error('correction_stage_mismatch'), { status: 400 });
  // A signed-in account may report only its own persisted facts/events.
  if (body.factIds.length) {
    const owned = await client.query('SELECT fact_id,source_key FROM sms_v2_facts WHERE profile_id=$1 AND fact_id=ANY($2::text[])', [profileId, body.factIds]);
    if (new Set(owned.rows.map(row => row.fact_id)).size !== new Set(body.factIds).size ||
        owned.rows.some(row => row.source_key !== body.sourceKey))
      throw Object.assign(new Error('correction_facts_not_found'), { status: 400 });
  }
  if (body.eventId) {
    const event = await client.query('SELECT event_id FROM sms_v2_events WHERE profile_id=$1 AND event_id=$2', [profileId, body.eventId]);
    if (!event.rows.length) throw Object.assign(new Error('correction_event_not_found'), { status: 400 });
  }
  await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text,0))',
    ['sms-shared-learning-consent:' + profileId]);
  const consent = await client.query(
    "SELECT granted FROM user_consents WHERE profile_id=$1 AND purpose='sms_shared_learning' ORDER BY granted_at DESC,granted ASC,id DESC LIMIT 1",
    [profileId],
  );
  const shared = consent.rows[0]?.granted === true;
  const metadata = shared ? templateMetadata(body) : null;
  const corrected = shared ? { ...body.corrected } : {};
  delete corrected._template;
  const payload = { ...body, corrected, ...(metadata ? {} : { redactedTemplate: undefined }) };
  const requestHash = digest(canonicalize(payload));
  const row = await client.query(
    `INSERT INTO sms_v2_correction_cases
      (profile_id,source_key,fact_ids,event_id,correction_kind,stage,trace,corrected,
       template_hash,sender_brand,redacted_template,is_tester,shared_learning_eligible,request_hash)
     VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,pandapay.sms_v2_is_tester(),$12,$13)
     ON CONFLICT(profile_id,request_hash) DO UPDATE SET request_hash=excluded.request_hash RETURNING case_id`,
    [profileId, body.sourceKey, body.factIds, body.eventId || null, body.correctionKind, stage,
      body.trace, corrected, metadata?.hash || null, metadata?.senderBrand || null,
      metadata ? body.redactedTemplate : null, shared && sharedLearningEligible, requestHash],
  );
  return { caseId: row.rows[0].case_id };
}

function createCorrectionsHandler({ withUserClient, hooks }) {
  return async (req, res) => {
    try {
      if (denied(await hooks.security.verifyAttestation(req))) return res.status(403).json({ error: 'attestation_required' });
      if (denied(await hooks.security.checkRate(req, 'corrections', 1))) return res.status(429).json({ error: 'rate_limited' });
      const response = await withUserClient(req.userId, client => submitCorrection(client, req.userId, req.body, {
        sharedLearningEligible: req.smsV2Security?.sharedLearningEligible === true,
      }));
      return res.status(200).json(response);
    } catch (error) {
      if (error.status) return res.status(error.status).json({ error: error.message });
      console.error('sms_v2 corrections failed', error?.code || 'internal');
      return res.status(503).json({ error: 'corrections_unavailable' });
    }
  };
}

async function correctionStatusSince(withUserClient, profileId, cursor) {
  const seq = cursor == null ? 0 : Number(cursor);
  if (!Number.isSafeInteger(seq) || seq < 0) throw new Error('correction_cursor_invalid');
  return withUserClient(profileId, async client => {
    const result = await client.query(
      `SELECT case_id,source_key,status,decision,reason,change_seq FROM sms_v2_correction_cases
       WHERE profile_id=$1 AND change_seq>$2 ORDER BY change_seq LIMIT 1000`, [profileId, seq]);
    return { items: result.rows.map(row => ({
      caseId: row.case_id, sourceKey: row.source_key, status: row.status,
      ...(row.decision ? { decision: row.decision } : {}),
      ...(row.reason ? { reason: row.reason } : {}),
    })), cursor: result.rows.length ? String(result.rows.at(-1).change_seq) : String(seq) };
  });
}

function patternFromSkeleton(text) {
  let index = 0;
  const groups = {};
  const pattern = text.split(/(<[A-Z_]+>|#)/).map(part => {
    if (/^(?:<[A-Z_]+>|#)$/.test(part)) {
      const name = 'field' + (++index);
      groups[part] ||= [];
      groups[part].push(name);
      const capture = part === '<AMT>' ? '[0-9,]+(?:\\.[0-9]{1,2})?' :
        part === '#' ? '[0-9]' : '[^\\r\\n]{1,120}';
      return `(?<${name}>${capture})`;
    }
    return part.replace(/[.*+?^\${}()|[\]\\]/g, '\\$&');
  }).join('');
  return { pattern: '^' + pattern + '$', groups };
}

function decisionOutput(row, decision) {
  if (decision === 'not_a_bug') return {};
  if (!row.redacted_template) throw Object.assign(new Error('redacted_template_required'), { status: 409 });
  if (decision === 'data_fix') {
    if (row.stage === 'category') return { categoryDraft: {
      id: 'CORRECTION-' + row.case_id, priority: 100, category: row.corrected.category,
      counterpartyKeys: row.corrected.merchantKey ? [row.corrected.merchantKey] : [],
    } };
    return { ruleDraft: {
      status: 'draft', senders: [row.sender_brand], ...patternFromSkeleton(row.redacted_template),
      correctedRoles: row.corrected, requiresReview: true,
    } };
  }
  // A skeleton without synthetic concrete values cannot be executed by the
  // golden harness. Explicit reviewed synthetic examples are required.
  const example = row.corrected.goldenExample;
  if (!example || typeof example.body !== 'string' || !example.expect ||
      typeof example.expect !== 'object' || !Array.isArray(example.expect.facts))
    throw Object.assign(new Error('redacted_expectation_required'), { status: 409 });
  return { goldenCase: {
    id: row.case_id, templateHash: row.template_hash, weight: 1, source: 'synthetic',
    messages: [{ sender: row.sender_brand, body: example.body, observedAt: example.observedAt || '2026-11-01T12:00:00Z' }],
    expect: example.expect,
  } };
}

function validateSyntheticExample(body) {
  const fail = () => { throw Object.assign(new Error('synthetic_example_invalid'), { status:400 }); };
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).sort().join(',') !== 'body,expect,observedAt,source' ||
      body.source !== 'synthetic' || typeof body.body !== 'string' ||
      !body.body.trim() || body.body.length > 20000 ||
      typeof body.observedAt !== 'string' ||
      !/^\d{4}-\d{2}-\d{2}T.*Z$/.test(body.observedAt) ||
      !Number.isFinite(Date.parse(body.observedAt)) ||
      !body.expect || typeof body.expect !== 'object' || Array.isArray(body.expect) ||
      !Array.isArray(body.expect.facts) || body.expect.facts.length > 20 ||
      Object.keys(body.expect).some(key => !['facts','unknown','ignore'].includes(key)) ||
      ['unknown','ignore'].some(key => body.expect[key] !== undefined && typeof body.expect[key] !== 'boolean') ||
      body.expect.unknown === true && body.expect.ignore === true ||
      body.expect.facts.length === 0 && body.expect.unknown !== true && body.expect.ignore !== true ||
      body.expect.facts.length > 0 && (body.expect.unknown === true || body.expect.ignore === true)) fail();
  const types = new Set(['movement','attempt','hold','balance_snapshot','limit_change',
    'bill_due','mandate','reward','info','instrument_hint']);
  const amountRoles = new Set(['posted','held','released','scheduled','due_total','due_minimum',
    'outstanding','available_balance','available_credit','credit_limit','ceiling',
    'points_earned','points_redeemed','points_balance','cash_value']);
  const fields = new Set(['factType','instrument','counterparty','amounts','attrs',
    'references','confidence','occurredAt']);
  for (const fact of body.expect.facts) {
    if (!fact || typeof fact !== 'object' || Array.isArray(fact) ||
        !types.has(fact.factType) || Object.keys(fact).some(key => !fields.has(key))) fail();
    if (fact.amounts !== undefined && (!Array.isArray(fact.amounts) ||
        fact.amounts.length > 20 || fact.amounts.some(amount =>
          !amount || typeof amount !== 'object' || Array.isArray(amount) ||
          Object.keys(amount).sort().join(',') !== 'minor,role,unit' ||
          !amountRoles.has(amount.role) ||
          !Number.isSafeInteger(amount.minor) || amount.minor < 0 ||
          !['INR','POINTS'].includes(amount.unit)))) fail();
    if (fact.confidence !== undefined &&
        (typeof fact.confidence !== 'number' || fact.confidence < 0 || fact.confidence > 1)) fail();
    if (fact.occurredAt !== undefined && fact.occurredAt !== null &&
        (typeof fact.occurredAt !== 'string' || !Number.isFinite(Date.parse(fact.occurredAt)))) fail();
    for (const key of ['instrument','counterparty','attrs','references']) {
      if (fact[key] !== undefined && fact[key] !== null &&
          (typeof fact[key] !== 'object' || Array.isArray(fact[key]))) fail();
    }
  }
  if (Buffer.byteLength(JSON.stringify(body.expect)) > 32768) fail();
  return { body:body.body, observedAt:body.observedAt, expect:body.expect };
}

async function saveSyntheticExample(client, caseId, body, actorId) {
  if (!uuid.test(caseId)) throw Object.assign(new Error('case_id_invalid'), {status:400});
  const example = validateSyntheticExample(body);
  const found = await client.query('SELECT * FROM sms_v2_correction_cases WHERE case_id=$1 FOR UPDATE', [caseId]);
  const row = found.rows[0];
  if (!row) throw Object.assign(new Error('case_not_found'), {status:404});
  if (!row.sender_brand) throw Object.assign(new Error('sender_brand_required'), {status:409});
  if (row.status !== 'open') throw Object.assign(new Error('case_already_decided'), {status:409});
  await client.query(
    "UPDATE sms_v2_correction_cases SET corrected=jsonb_set(corrected,'{goldenExample}',$2::jsonb),updated_at=clock_timestamp() WHERE case_id=$1",
    [caseId,JSON.stringify(example)]);
  await client.query(
    "INSERT INTO admin_audit_log(admin_id,action,entity,entity_id,after_value,reason) VALUES($1,'sms_v2_correction_example','sms_v2_correction_cases',$2,$3,'Reviewed synthetic regression example')",
    [actorId,caseId,{source:'synthetic',exampleSha256:digest(canonicalize(example))}]);
  return { caseId, readyForCodeFix:true };
}

async function listCases(client, query) {
  const groupBy = query.groupBy || 'template';
  if (!['template', 'stage'].includes(groupBy) ||
      (query.status && !['open', 'decided'].includes(query.status)))
    throw Object.assign(new Error('correction_query_invalid'), { status: 400 });
  const rows = await client.query(
    `SELECT case_id,source_key,correction_kind,stage,trace,corrected,template_hash,sender_brand,
     redacted_template,is_tester,shared_learning_eligible,status,decision,reason,created_at
     FROM sms_v2_correction_cases WHERE ($1::text IS NULL OR status=$1)
     ORDER BY is_tester DESC,created_at DESC,case_id LIMIT 500`, [query.status || null]);
  const groups = new Map();
  for (const row of rows.rows) {
    const key = groupBy === 'template' && row.template_hash ? row.template_hash : row.stage;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(row);
  }
  return { groups: [...groups].map(([key, cases]) => ({ key, cases })) };
}

async function decideCase(client, caseId, body, actorId) {
  if (!uuid.test(caseId)) throw Object.assign(new Error('case_id_invalid'), { status: 400 });
  const check = validateRequest('admin_correction_decision', body);
  if (!check.ok || typeof body.reason !== 'string' || !body.reason.trim())
    throw Object.assign(new Error('decision_invalid'), { status: 400 });
  const found = await client.query('SELECT * FROM sms_v2_correction_cases WHERE case_id=$1 FOR UPDATE', [caseId]);
  const row = found.rows[0];
  if (!row) throw Object.assign(new Error('case_not_found'), { status: 404 });
  const output = decisionOutput(row, body.decision);
  await client.query(
    `UPDATE sms_v2_correction_cases SET status='decided',decision=$2,reason=$3,
       output=$4,updated_at=clock_timestamp(),change_seq=nextval('sms_v2_correction_change_seq')
       WHERE case_id=$1`, [caseId, body.decision, body.reason, output]);
  await client.query(
    `INSERT INTO admin_audit_log(admin_id,action,entity,entity_id,before_value,after_value,reason)
     VALUES($1,'sms_v2_correction_decision','sms_v2_correction_cases',$2,$3,$4,$5)`,
    [actorId, caseId, { status: row.status, decision: row.decision }, { decision: body.decision }, body.reason]);
  return output;
}

function registerCorrections(app, { requireSmsV2, requireMember, withUserClient, hooks }) {
  app.post('/sms/v2/corrections', requireSmsV2, requireMember, createCorrectionsHandler({ withUserClient, hooks }));
  hooks.correctionStatusSince = (profileId, cursor) => correctionStatusSince(withUserClient, profileId, cursor);
}

function registerPrivateCorrections(api) {
  function route(method, path, action) {
    api.route(method, path, async (req, res, ctx) => {
      const withClient = (_id, operation) => ctx.withAdminClient(operation);
      const gate = createRequireSmsV2({ withUserClient: withClient, cacheMs: 0 });
      return gate(req, res, async () => {
        try { res.json(await ctx.withAdminClient(client => action(client, req))); }
        catch (error) { res.status(error.status || 503).json({ error: error.status ? error.message : 'corrections_unavailable' }); }
      });
    });
  }
  route('get', '/admin/sms/v2/corrections', (client, req) => listCases(client, req.query));
  route('put', '/admin/sms/v2/corrections/:caseId/example', (client, req) =>
    saveSyntheticExample(client, req.params.caseId, req.body, req.admin.userId));
  route('post', '/admin/sms/v2/corrections/:caseId/decision', (client, req) =>
    decideCase(client, req.params.caseId, req.body, req.admin.userId));
  route('get', '/admin/sms/v2/corrections/:caseId/export', async (client, req) => {
    if (!uuid.test(req.params.caseId)) throw Object.assign(new Error('case_id_invalid'), { status: 400 });
    const row = (await client.query("SELECT output FROM sms_v2_correction_cases WHERE case_id=$1 AND decision='code_fix'", [req.params.caseId])).rows[0];
    if (!row) throw Object.assign(new Error('case_not_found'), { status: 404 });
    return row.output.goldenCase;
  });
}

module.exports = { stageFor, templateMetadata, submitCorrection, correctionStatusSince,
  patternFromSkeleton, decisionOutput, validateSyntheticExample, saveSyntheticExample, listCases, decideCase,
  createCorrectionsHandler, registerCorrections, registerPrivateCorrections };
