'use strict';

// The Learning page of the console (learning-loop A7): counted, k-anonymous
// candidates from opted-in phones. A shop key or name appears only when at
// least K different attested people reported it (setting
// signals_min_distinct_users, from 1 to 20; 1 during the friends run). Smaller
// groups appear only as totals. Nothing here publishes anything: "Create rule" opens the existing
// category draft flow, and the admin publishes through the golden check.
const { HttpError } = require('./rules_admin_route');
const { readSettings, SETTINGS, USER_LIMIT_KEYS } = require('./settings');

const KINDS = ['category_choice', 'merchant_name', 'uncategorised'];
const KEY = /^[A-Z][A-Z0-9 &'.-]{1,59}$/;
const DAY_OPTIONS = { summary: 30, candidates: 90 };
const LIMIT = 200;

const cleanKey = (value) => String(value ?? '').trim().replace(/\s+/g, ' ').toUpperCase();
const num = (value) => (value === null || value === undefined ? 0 : Number(value));

function parseDays(raw, fallback) {
  if (raw === undefined) return fallback;
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!/^[0-9]{1,3}$/.test(String(text))) throw new HttpError(400, 'learning_days_invalid');
  const days = Number(text);
  if (days < 1 || days > 365) throw new HttpError(400, 'learning_days_invalid');
  return days;
}

// The shared bundle parts the status chips compare against.
async function readParts(client) {
  const rows = (await client.query(
    "SELECT part, body FROM sms_v2_bundle_parts WHERE part IN ('taxonomyVersion','categoryRules','merchantAliases')")).rows;
  const parts = Object.fromEntries(rows.map((row) => [row.part, row.body]));
  return {
    taxonomyVersion: Number.isInteger(parts.taxonomyVersion) ? parts.taxonomyVersion : 1,
    categoryRules: Array.isArray(parts.categoryRules) ? parts.categoryRules : [],
    merchantAliases: Array.isArray(parts.merchantAliases) ? parts.merchantAliases : [],
  };
}

// A dismissed candidate stays hidden until the number of people grows by at
// least max(3, half of those who had reported it).
const NOT_DISMISSED = (kind, users) => `NOT EXISTS (
  SELECT 1 FROM sms_v2_learning_decisions d
   WHERE d.kind = '${kind}' AND d.merchant_key = v.merchant_key AND d.value = v.value
     AND d.decision = 'dismissed'
     AND ${users} < d.users_at_decision + greatest(3, ceil(d.users_at_decision / 2.0)))`;

// Category choices and shop names: one row per shop key, led by the value the
// most people picked. K applies to the people who reported the key at all.
function valueSql(kind) {
  return `
WITH recent AS (
  SELECT * FROM sms_v2_learning_signals
   WHERE kind = '${kind}' AND eligible AND taxonomy_version = $3
     AND last_at > now() - make_interval(days => $2)
), per_value AS (
  SELECT merchant_key, value, count(DISTINCT profile_id) AS users,
         count(DISTINCT profile_id) FILTER (WHERE is_tester) AS tester_users,
         sum(times) AS times, max(last_at) AS last_at, array_agg(DISTINCT sender_brand) AS senders
    FROM recent GROUP BY 1, 2
), per_key AS (
  SELECT merchant_key, count(DISTINCT profile_id) AS key_users FROM recent GROUP BY 1
), split AS (
  SELECT merchant_key, jsonb_object_agg(value, users) AS split FROM per_value GROUP BY 1
), lead AS (
  SELECT DISTINCT ON (merchant_key) * FROM per_value ORDER BY merchant_key, users DESC, last_at DESC, value
)
SELECT v.merchant_key, v.value, v.users, v.tester_users, v.times, v.last_at, v.senders,
       k.key_users, s.split, round(v.users::numeric / k.key_users, 2) AS agreement,
       (SELECT d.decision FROM sms_v2_learning_decisions d
         WHERE d.kind = '${kind}' AND d.merchant_key = v.merchant_key AND d.value = v.value) AS decision
  FROM lead v JOIN per_key k USING (merchant_key) JOIN split s USING (merchant_key)
 WHERE k.key_users >= $1 AND ${NOT_DISMISSED(kind, 'k.key_users')}
 ORDER BY k.key_users DESC, v.last_at DESC
 LIMIT ${LIMIT}`;
}

const UNCATEGORISED_SQL = `
WITH v AS (
  SELECT merchant_key, '' AS value, count(DISTINCT profile_id) AS users,
         count(DISTINCT profile_id) FILTER (WHERE is_tester) AS tester_users,
         sum(times) AS times, max(last_at) AS last_at, array_agg(DISTINCT sender_brand) AS senders
    FROM sms_v2_learning_signals
   WHERE kind = 'uncategorised' AND eligible AND taxonomy_version = $3
     AND last_at > now() - make_interval(days => $2)
   GROUP BY merchant_key
)
SELECT v.merchant_key, v.value, v.users, v.tester_users, v.times, v.last_at, v.senders,
       (SELECT d.decision FROM sms_v2_learning_decisions d
         WHERE d.kind = 'uncategorised' AND d.merchant_key = v.merchant_key AND d.value = '') AS decision,
       (SELECT jsonb_build_object('category', m.category, 'confidence', m.confidence, 'why', m.why)
          FROM sms_v2_merchant_suggestions m WHERE m.merchant_key = v.merchant_key AND m.status = 'ready') AS suggestion
  FROM v
 WHERE v.users >= $1 AND ${NOT_DISMISSED('uncategorised', 'v.users')}
 ORDER BY v.users DESC, v.last_at DESC
 LIMIT ${LIMIT}`;

const rowBase = (row) => ({
  merchantKey: row.merchant_key,
  users: num(row.users),
  testerUsers: num(row.tester_users),
  times: num(row.times),
  lastAt: row.last_at,
  senders: row.senders || [],
  decision: row.decision || null,
});

// ---- candidate readers (also used by the summary's "new candidates" count)

async function categoryCandidates(client, { k, days, parts }) {
  const rows = (await client.query(valueSql('category_choice'), [k, days, parts.taxonomyVersion])).rows;
  return rows.map((row) => {
    const same = parts.categoryRules.filter((rule) => cleanKey(rule.merchantKey) === row.merchant_key);
    const status = same.length === 0 ? 'new'
      : same.some((rule) => rule.category === row.value) ? 'covered' : 'conflict';
    return {
      ...rowBase(row), category: row.value, keyUsers: num(row.key_users),
      agreement: Number(row.agreement), split: row.split, status,
    };
  });
}

async function merchantNameCandidates(client, { k, days, parts }) {
  const rows = (await client.query(valueSql('merchant_name'), [k, days, parts.taxonomyVersion])).rows;
  return rows.map((row) => {
    const same = parts.merchantAliases.filter((alias) => cleanKey(alias.alias) === row.merchant_key);
    const status = same.length === 0 ? 'new'
      : same.some((alias) => cleanKey(alias.merchantKey) === row.value) ? 'covered' : 'conflict';
    return {
      ...rowBase(row), name: row.value, keyUsers: num(row.key_users),
      agreement: Number(row.agreement), split: row.split, status,
    };
  });
}

async function uncategorisedCandidates(client, { k, days, parts }) {
  const rows = (await client.query(UNCATEGORISED_SQL, [k, days, parts.taxonomyVersion])).rows;
  return rows.map((row) => {
    const covered = parts.categoryRules.some((rule) => cleanKey(rule.merchantKey) === row.merchant_key);
    return { ...rowBase(row), status: covered ? 'covered' : 'new', suggestion: row.suggestion || null };
  });
}

async function candidateContext(client, req) {
  const settings = await readSettings(client);
  return {
    k: Math.max(1, settings.signals_min_distinct_users),
    days: parseDays(req.query.days, DAY_OPTIONS.candidates),
    parts: await readParts(client),
  };
}

// ---- summary: counts only

async function layoutCounts(client, days) {
  const r = (await client.query(
    `SELECT count(*) FILTER (WHERE first_seen > now() - make_interval(days => $1)) AS new_count,
            count(*) FILTER (WHERE ai_status = 'held') AS held,
            count(*) FILTER (WHERE ai_status = 'queued') AS queued,
            count(*) FILTER (WHERE ai_status = 'working') AS working,
            count(*) FILTER (WHERE ai_status = 'ready') AS ready,
            count(*) FILTER (WHERE ai_status = 'failed' AND failure_code IS DISTINCT FROM 'admin_rejected') AS failed,
            count(*) FILTER (WHERE ai_status = 'covered') AS covered,
            count(*) FILTER (WHERE ai_status = 'blocked') AS blocked,
            count(*) FILTER (WHERE failure_code = 'admin_rejected') AS rejected,
            count(*) FILTER (WHERE EXISTS (SELECT 1 FROM sms_v2_rules r WHERE r.rule_id = 'AI-' || t.template_hash)) AS drafted
       FROM sms_v2_unknown_templates t`, [days])).rows[0];
  return {
    new: num(r.new_count), held: num(r.held), queued: num(r.queued), working: num(r.working), ready: num(r.ready),
    failed: num(r.failed), covered: num(r.covered), drafted: num(r.drafted), rejected: num(r.rejected), blocked: num(r.blocked),
  };
}

async function aiCounts(client, days) {
  const usage = (await client.query(
    `SELECT count(*) AS calls, coalesce(sum(cost_usd), 0) AS cost
       FROM sms_v2_template_attempts WHERE started_at > now() - make_interval(days => $1)`, [days])).rows[0];
  const approved = num((await client.query(
    `SELECT count(*) AS n FROM sms_v2_rules WHERE rule_id LIKE 'AI-%' AND version = 1 AND status <> 'provisional'
        AND created_at > now() - make_interval(days => $1)`, [days])).rows[0].n);
  const notMoney = num((await client.query(
    `SELECT count(*) AS n FROM sms_v2_unknown_templates
      WHERE ai_status = 'ready' AND jsonb_typeof(ai_draft->'emit') = 'array' AND jsonb_array_length(ai_draft->'emit') > 0
        AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(ai_draft->'emit') e WHERE e->>'factType' <> 'info')`)).rows[0].n);
  const cost = Number(usage.cost);
  return {
    calls: num(usage.calls),
    costUsd: cost,
    approvedRules: approved,
    costPerApprovedRule: approved > 0 ? cost / approved : null,
    notMoneyDrafts: notMoney,
  };
}

async function coverage(client, days) {
  const r = (await client.query(
    `SELECT coalesce(sum(hits), 0) AS hits, coalesce(sum(to_review), 0) AS to_review, coalesce(sum(corrected), 0) AS corrected
       FROM sms_v2_rule_stats_daily WHERE day >= (now() AT TIME ZONE 'utc')::date - $1::int`, [days])).rows[0];
  const hits = num(r.hits), toReview = num(r.to_review);
  return {
    hits, toReview, corrected: num(r.corrected),
    readByRulesShare: hits + toReview > 0 ? hits / (hits + toReview) : null,
  };
}

async function trend(client, days) {
  const rows = (await client.query(
    `WITH d AS (SELECT generate_series((now() AT TIME ZONE 'utc')::date - ($1::int - 1), (now() AT TIME ZONE 'utc')::date, interval '1 day')::date AS day)
     SELECT d.day,
            (SELECT count(*) FROM sms_v2_template_attempts a WHERE (a.started_at AT TIME ZONE 'utc')::date = d.day) AS ai_calls,
            (SELECT count(*) FROM sms_v2_unknown_templates t WHERE (t.first_seen AT TIME ZONE 'utc')::date = d.day) AS new_layouts
       FROM d ORDER BY d.day`, [Math.min(days, 90)])).rows;
  return rows.map((row) => ({
    day: row.day instanceof Date ? row.day.toISOString().slice(0, 10) : String(row.day),
    aiCalls: num(row.ai_calls), newLayouts: num(row.new_layouts),
  }));
}

async function buildSummary(client, { days, k, parts }) {
  const aggregates = (await client.query('SELECT pandapay.sms_v2_learning_summary($1,$2) AS summary', [days, k])).rows[0].summary;
  const context = { k, days: DAY_OPTIONS.candidates, parts };
  // One client runs one query at a time.
  const categories = await categoryCandidates(client, context);
  const names = await merchantNameCandidates(client, context);
  const uncategorised = await uncategorisedCandidates(client, context);
  const waiting = (rows) => rows.filter((row) => row.status === 'new' && row.decision !== 'drafted').length;
  const optIn = aggregates.optIn;
  return {
    days,
    minUsers: k,
    layouts: await layoutCounts(client, days),
    ai: await aiCounts(client, days),
    corrections: aggregates.corrections,
    signals: aggregates.signals.map((row) => ({
      kind: row.kind, users: num(row.users),
      attestedShare: num(row.users) > 0 ? num(row.attestedUsers) / num(row.users) : null,
      belowThreshold: num(row.belowThreshold),
    })),
    coverage: await coverage(client, days),
    trend: await trend(client, days),
    optIn: {
      sharingNow: num(optIn.sharingNow),
      synced30d: num(optIn.synced30d),
      shareOfSynced: num(optIn.synced30d) > 0 ? num(optIn.syncedSharing30d) / num(optIn.synced30d) : null,
      perDay: optIn.perDay.map((row) => ({ day: row.day, on: num(row.on), off: num(row.off) })),
    },
    candidates: {
      categories: waiting(categories), merchantNames: waiting(names), uncategorised: waiting(uncategorised),
      total: waiting(categories) + waiting(names) + waiting(uncategorised),
    },
  };
}

// ---- decisions

async function recordDecision(client, { adminId, body }) {
  const allowed = ['kind', 'merchantKey', 'value', 'decision', 'reason'];
  if (!body || typeof body !== 'object' || Array.isArray(body) || Object.keys(body).some((key) => !allowed.includes(key))) {
    throw new HttpError(400, 'learning_decision_invalid');
  }
  const { kind, merchantKey, decision } = body;
  const value = body.value ?? '';
  const reason = typeof body.reason === 'string' ? body.reason.trim() : '';
  if (!KINDS.includes(kind) || typeof merchantKey !== 'string' || !KEY.test(merchantKey) ||
      typeof value !== 'string' || value.length > 40 || /[0-9@]/.test(value) ||
      (kind === 'uncategorised') !== (value === '') || !['dismissed', 'drafted'].includes(decision)) {
    throw new HttpError(400, 'learning_decision_invalid');
  }
  if (reason.length < 3 || reason.length > 500) throw new HttpError(400, 'reason_required');
  // The people who had reported this shop key when the decision was made; a
  // dismissed row comes back once that number grows enough (see NOT_DISMISSED).
  const { taxonomyVersion } = await readParts(client);
  const keyUsers = num((await client.query(
    `SELECT count(DISTINCT profile_id) AS n FROM sms_v2_learning_signals
      WHERE kind = $1 AND merchant_key = $2 AND eligible AND taxonomy_version = $3
        AND last_at > now() - interval '90 days'`, [kind, merchantKey, taxonomyVersion])).rows[0].n);
  const before = (await client.query(
    'SELECT decision, users_at_decision FROM sms_v2_learning_decisions WHERE kind=$1 AND merchant_key=$2 AND value=$3',
    [kind, merchantKey, value])).rows[0] || null;
  await client.query(
    `INSERT INTO sms_v2_learning_decisions (kind, merchant_key, value, decision, users_at_decision, reason, decided_by)
     VALUES ($1,$2,$3,$4,$5,$6,$7)
     ON CONFLICT (kind, merchant_key, value) DO UPDATE SET decision = EXCLUDED.decision,
       users_at_decision = EXCLUDED.users_at_decision, reason = EXCLUDED.reason,
       decided_by = EXCLUDED.decided_by, decided_at = clock_timestamp()`,
    [kind, merchantKey, value, decision, keyUsers, reason, adminId]);
  await client.query(
    'INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, before_value, after_value, reason) VALUES ($1,$2,$3,NULL,$4,$5,$6)',
    [adminId, 'sms_v2_learning_decision', 'sms_v2_learning_decision',
      before && JSON.stringify(before), JSON.stringify({ kind, merchantKey, value, decision, usersAtDecision: keyUsers }), reason]);
  return { recorded: true, decision, usersAtDecision: keyUsers };
}

// The accounts that sent the most to the loop recently, with the limits that
// apply to them and any override. Counts and the pseudonymous account id only.
async function reporters(client, days) {
  const top = (await client.query('SELECT * FROM pandapay.sms_v2_learning_reporters($1)', [days])).rows;
  const out = [];
  for (const row of top) {
    const effectiveLimits = {};
    for (const key of USER_LIMIT_KEYS) {
      effectiveLimits[key] = num((await client.query('SELECT pandapay.sms_v2_limit($1,$2,$3) AS n', [row.profile_id, key, SETTINGS[key].default])).rows[0].n);
    }
    const override = (await client.query(
      `SELECT key, value, expires_at AS "expiresAt" FROM sms_v2_user_limits
        WHERE profile_id = $1 AND expires_at > now() ORDER BY expires_at DESC LIMIT 1`, [row.profile_id])).rows[0] || null;
    out.push({
      profileId: row.profile_id, signals: num(row.signals), layouts: num(row.layouts), corrections: num(row.corrections),
      effectiveLimits, override,
    });
  }
  return out;
}

function registerPrivateLearningRoutes(api) {
  const register = (method, path, operation) =>
    api.route(method, path, async (req, res, ctx) => {
      try {
        return res.json(await operation(req, ctx));
      } catch (error) {
        if (error instanceof HttpError) return res.status(error.status).json({ error: error.code });
        if (error.code === 'ADMIN_PERMISSION_DENIED') return res.status(403).json({ error: 'admin_permission_required' });
        console.error('sms_v2 learning admin failed', error.code || error.name);
        return res.status(500).json({ error: 'learning_unavailable' });
      }
    });

  register('GET', '/admin/sms/v2/learning/summary', (req, ctx) => ctx.withAdminClient(async (client) => {
    const settings = await readSettings(client);
    return buildSummary(client, {
      days: parseDays(req.query.days, DAY_OPTIONS.summary),
      k: Math.max(1, settings.signals_min_distinct_users),
      parts: await readParts(client),
    });
  }));
  register('GET', '/admin/sms/v2/learning/categories', (req, ctx) => ctx.withAdminClient(async (client) => {
    const context = await candidateContext(client, req);
    return { minUsers: context.k, days: context.days, taxonomyVersion: context.parts.taxonomyVersion, candidates: await categoryCandidates(client, context) };
  }));
  register('GET', '/admin/sms/v2/learning/merchant-names', (req, ctx) => ctx.withAdminClient(async (client) => {
    const context = await candidateContext(client, req);
    return { minUsers: context.k, days: context.days, taxonomyVersion: context.parts.taxonomyVersion, candidates: await merchantNameCandidates(client, context) };
  }));
  register('GET', '/admin/sms/v2/learning/uncategorised', (req, ctx) => ctx.withAdminClient(async (client) => {
    const context = await candidateContext(client, req);
    return { minUsers: context.k, days: context.days, taxonomyVersion: context.parts.taxonomyVersion, candidates: await uncategorisedCandidates(client, context) };
  }));
  register('GET', '/admin/sms/v2/learning/reporters', (req, ctx) => ctx.withAdminClient(async (client) => {
    const days = parseDays(req.query.days, 7);
    if (days > 90) throw new HttpError(400, 'learning_days_invalid');
    return { days, reporters: await reporters(client, days) };
  }));
  register('POST', '/admin/sms/v2/learning/decisions', (req, ctx) =>
    ctx.withAdminClient((client) => recordDecision(client, { adminId: req.admin.userId, body: req.body })));
}

module.exports = {
  registerPrivateLearningRoutes, categoryCandidates, merchantNameCandidates, uncategorisedCandidates,
  buildSummary, recordDecision, readParts, reporters,
};
