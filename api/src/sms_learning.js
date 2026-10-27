/**
 * Privacy-minimizing shared-learning signals from user-confirmed SMS fixes.
 *
 * This module stores only an HMAC sender fingerprint, fact family, corrected
 * field names and per-profile/source dedupe identity. It never stores raw unredacted SMS,
 * credentials, account numbers, or user secrets. Signals are review candidates;
 * they feed the autonomous worker only after passing consent and evaluation checks.
 */

const crypto = require('crypto');
const { deriveIssuerPrefix, synthesizeTemplate } = require('./sms_template_compiler');

function getHmacKey(explicitKey) {
  if (explicitKey !== undefined && explicitKey !== null) {
    return (typeof explicitKey === 'string' && explicitKey.length >= 32) ? explicitKey : null;
  }
  if (typeof process.env.SMS_LEARNING_HMAC_KEY === 'string' && process.env.SMS_LEARNING_HMAC_KEY.length >= 32) {
    return process.env.SMS_LEARNING_HMAC_KEY;
  }
  return null;
}

const SAFE_FIELDS = new Set([
  'entryKind', 'instrument', 'amountInr', 'availableBalanceInr',
  'currentBalanceInr', 'amountDueInr', 'minimumDueInr', 'amountRole',
  'dueDate', 'statementDate', 'asOfAt', 'mandateStatus', 'merchant',
  'cadenceDays', 'limitInr', 'accountLast4', 'last4', 'currency',
]);

const ALLOWED_FAMILIES = new Set([
  'posted_movement', 'pending_or_failed_attempt', 'balance_snapshot',
  'bill_obligation', 'bill_payment', 'mandate_lifecycle',
  'card_identity_hint', 'security_or_service_alert', 'promotion', 'ignore_noise',
]);

/**
 * Redacts high-risk identifiers from SMS sample bodies before storage.
 */
function redactBody(body) {
  return String(body || '')
    .replace(/https?:\/\/\S+/gi, '[URL]')
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, '[EMAIL]')
    .replace(/\b(?:\+?91|0)?[6-9]\d{9}\b/g, '[PHONE]')
    .replace(/(?<!\d)(?:\d[ -]?){11,18}\d(?!\d)/g, (val) => {
      const digits = val.replace(/\D/g, '');
      return `XXXX${digits.slice(-4)}`;
    });
}

function senderFingerprint(sender, key = process.env.SMS_LEARNING_HMAC_KEY) {
  const resolvedKey = (key !== undefined && key !== null)
    ? (typeof key === 'string' && key.length >= 32 ? key : null)
    : getHmacKey();
  if (!resolvedKey || typeof sender !== 'string' || !sender.trim()) {
    return null;
  }
  const normalized = sender.normalize('NFKC').trim().toLowerCase().replace(/\s+/g, ' ');
  return crypto.createHmac('sha256', resolvedKey).update(normalized).digest('hex');
}

function changedSafeFields(before, after) {
  const fields = new Set([...Object.keys(before || {}), ...Object.keys(after || {})]);
  return [...fields].filter((field) => SAFE_FIELDS.has(field) &&
    JSON.stringify(before?.[field]) !== JSON.stringify(after?.[field]));
}

// Generate a validation sample from the structural template rather than
// retaining numbers from the user's SMS. Stable example values let the rule
// evaluator exercise its parser contract while removing amounts, timestamps,
// references, account fragments and other numeric identifiers from samples.
function anonymizedTrainingSample(template) {
  const structural = String(template || '').replace(/\{[A-Z0-9_]+\}|\d[\d,./:-]*/g, (part) =>
    part.startsWith('{') ? part : '{REF}');
  return structural
    .replace(/\{AMOUNT\}/g, 'Rs. 123.45')
    .replace(/\{BAL\}/g, 'Rs. 9,876.54')
    .replace(/\{DUE_DATE\}/g, '01-01-2025')
    .replace(/\{DATE\}/g, '01-01-2025')
    .replace(/\{LAST4\}/g, '1234')
    .replace(/\{REF\}/g, 'TESTREF123456')
    .replace(/\{MERCHANT\}/g, 'MerchantTest')
    .slice(0, 1201);
}

function anonymizedTrainingFields(fields, template) {
  const safe = {};
  for (const [key, value] of Object.entries(fields || {})) {
    if (SAFE_FIELDS.has(key) && (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean')) {
      safe[key] = value;
    }
  }
  const has = (slot) => template.includes(`{${slot}}`);
  if (has('AMOUNT')) {
    for (const field of ['amount', 'amountInr', 'amountDue', 'amountDueInr', 'minimumDue', 'minimumDueInr']) {
      if (field in safe) safe[field] = 123.45;
    }
    if ('amountPaise' in safe) safe.amountPaise = 12345;
    if ('amountDuePaise' in safe) safe.amountDuePaise = 12345;
  }
  if (has('BAL')) {
    for (const field of ['availableBalance', 'availableBalanceInr', 'currentBalance', 'currentBalanceInr']) {
      if (field in safe) safe[field] = 9876.54;
    }
    if ('availableBalancePaise' in safe) safe.availableBalancePaise = 987654;
    if ('currentBalancePaise' in safe) safe.currentBalancePaise = 987654;
  }
  if (has('LAST4')) {
    if ('last4' in safe) safe.last4 = '1234';
    if ('accountLast4' in safe) safe.accountLast4 = '1234';
  }
  if (has('MERCHANT') && 'merchant' in safe) safe.merchant = 'MerchantTest';
  if (has('DATE')) {
    if ('asOf' in safe) safe.asOf = '01-01-2025';
    if ('asOfAt' in safe) safe.asOfAt = '2025-01-01T00:00:00.000Z';
  }
  if (has('DUE_DATE')) {
    if ('dueDate' in safe) safe.dueDate = '01-01-2025';
  }
  if (has('REF') && 'reference' in safe) safe.reference = 'TESTREF123456';
  return safe;
}

async function recordConfirmedCorrection(client, {
  profileId, sourceKey, sender, family, fields, hmacKey,
}) {
  const resolvedKey = getHmacKey(hmacKey);
  const fingerprint = senderFingerprint(sender, resolvedKey);
  if (!fingerprint || !Array.isArray(fields) || fields.length === 0) return { recorded: 0, disabled: !fingerprint };
  // Shared learning is an opt-in product contribution. Do not assume consent
  // to use a local correction for cross-user learning; fail closed if the
  // profile is missing or its existing contribution preference is off.
  if (!(await hasSmsSharedLearningConsent(client, profileId))) {
    return { recorded: 0, disabled: true };
  }
  let recorded = 0;
  for (const field of new Set(fields)) {
    if (!SAFE_FIELDS.has(field)) continue;
    await client.query(
      `INSERT INTO sms_learning_feedback
         (profile_id, source_key_hash, sender_fingerprint, fact_family, corrected_field)
       VALUES ($1, $2, $3, $4, $5)
       ON CONFLICT (profile_id, source_key_hash, fact_family, corrected_field) DO NOTHING`,
      [profileId, sourceKey, fingerprint, family, field],
    );
    recorded += 1;
  }
  return { recorded, disabled: false };
}

async function hasSmsSharedLearningConsent(client, profileId) {
  return (await getSmsSharedLearningConsent(client, profileId))?.granted === true;
}

async function getSmsSharedLearningConsent(client, profileId) {
  if (!profileId) return null;
  const consent = await client.query(
    `SELECT granted, policy_version, granted_at FROM public.user_consents
      WHERE profile_id = $1 AND purpose = 'sms_shared_learning'
      ORDER BY granted_at DESC, id DESC LIMIT 1`,
    [profileId],
  );
  return consent.rows?.[0] || null;
}

/**
 * Records a structured positive or negative learning example into sms_learning_examples.
 * Strictly enforces user consent (contributions_opt_in) and privacy redaction.
 *
 * @param {object} client - PostgreSQL client
 * @param {object} params
 * @returns {Promise<{ recorded: number, disabled?: boolean, userHash?: string, exampleId?: string }>}
 */
async function recordLearningExample(client, {
  profileId,
  sender,
  factFamily,
  templateText,
  sampleBody,
  extractedFields = {},
  isNegative = false,
  negativeReason = null,
  hmacKey: explicitHmacKey,
}) {
  const hmacKey = getHmacKey(explicitHmacKey);
  if (!hmacKey) {
    return { recorded: 0, disabled: true, error: 'missing_hmac_secret' };
  }

  if (!profileId || !sender) {
    return { recorded: 0, disabled: false, error: 'missing_profile_or_sender' };
  }

  // 1. Consent check: fail closed if opt-in is false or missing
  if (!(await hasSmsSharedLearningConsent(client, profileId))) {
    return { recorded: 0, disabled: true };
  }

  const fingerprint = senderFingerprint(sender, hmacKey);
  if (!fingerprint) {
    return { recorded: 0, disabled: false, error: 'invalid_sender_fingerprint' };
  }

  if (!ALLOWED_FAMILIES.has(factFamily)) {
    return { recorded: 0, disabled: false, error: 'unsupported_fact_family' };
  }
  const family = factFamily;
  const issuerPrefix = deriveIssuerPrefix(sender);
  const userHash = crypto.createHmac('sha256', hmacKey).update(String(profileId)).digest('hex');

  // Redact sample body and synthesize template text if needed
  const rawBody = sampleBody || templateText || '';
  if (/\b(?:otp|one.time.password|verification code|cvv|pin)\b/i.test(rawBody)) {
    return { recorded: 0, disabled: true, error: 'sensitive_sms' };
  }
  const cleanBody = redactBody(rawBody);
  const rawTemplate = (templateText && templateText.includes('{')
    ? templateText
    : synthesizeTemplate(cleanBody, extractedFields));
  const cleanTemplate = rawTemplate.replace(/\{[A-Z0-9_]+\}|\d[\d,./:-]*/g, (part) =>
    part.startsWith('{') ? part : '{REF}');

  if (!cleanTemplate) {
    return { recorded: 0, disabled: false, error: 'unable_to_synthesize_template' };
  }

  // Production can have an older learning table without the intended unique
  // index. Serialize this exact example and check for it before inserting so
  // retries stay idempotent even on that schema. ON CONFLICT without a target
  // still handles any available unique index without requiring one to exist.
  const dedupValues = [userHash, fingerprint, family, cleanTemplate];
  const dedupLock = crypto.createHash('sha256')
    .update(JSON.stringify(dedupValues)).digest('hex');
  await client.query(
    'SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
    [dedupLock],
  );
  const existing = await client.query(
    `SELECT id FROM public.sms_learning_examples
      WHERE user_hash = $1 AND sender_fingerprint = $2
        AND fact_family = $3 AND template_text = $4 LIMIT 1`,
    dedupValues,
  );
  if (existing.rows?.length) {
    return { recorded: 0, disabled: false, userHash, issuerPrefix, exampleId: null };
  }

  const insertRes = await client.query(
    `INSERT INTO public.sms_learning_examples (
       profile_id, sender_fingerprint, issuer_prefix, fact_family, template_text,
       sample_body, extracted_fields, is_negative, negative_reason, user_hash
     ) VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $10)
     ON CONFLICT DO NOTHING
     RETURNING id`,
    [
      profileId,
      fingerprint,
      issuerPrefix,
      family,
      cleanTemplate,
      anonymizedTrainingSample(cleanTemplate),
      JSON.stringify(anonymizedTrainingFields(extractedFields, cleanTemplate)),
      Boolean(isNegative),
      negativeReason || null,
      userHash,
    ],
  );

  const exampleId = insertRes.rows?.[0]?.id || null;
  return {
    recorded: exampleId ? 1 : 0,
    disabled: false,
    userHash,
    issuerPrefix,
    exampleId,
  };
}

/**
 * Convenience method for recording a user dismissal / not-financial decision
 * as positive ignore_noise evidence (and, when applicable, negative evidence
 * for the previously suspected financial family).
 */
async function recordReviewDismissal(client, { profileId, sender, body, reason, family = 'ignore_noise', hmacKey }) {
  // A dismissal means that the message is positive evidence for the noise
  // classifier.  The old implementation stored it as a negative
  // `ignore_noise` example, which gave the learner the opposite signal and
  // could never produce a reusable ignore rule.  When the review card carries
  // a suspected financial family, retain a negative example for that family
  // as well so the candidate evaluator learns both sides of the decision.
  const suspectedFamily = ALLOWED_FAMILIES.has(family) ? family : 'ignore_noise';
  const outcomes = [];
  if (suspectedFamily !== 'ignore_noise') {
    outcomes.push(await recordLearningExample(client, {
      profileId,
      sender,
      factFamily: suspectedFamily,
      sampleBody: body,
      isNegative: true,
      negativeReason: reason || 'user_dismissed',
      hmacKey,
    }));
  }
  outcomes.push(await recordLearningExample(client, {
    profileId,
    sender,
    factFamily: 'ignore_noise',
    sampleBody: body,
    isNegative: false,
    negativeReason: null,
    hmacKey,
  }));

  return {
    recorded: outcomes.reduce((sum, outcome) => sum + (Number(outcome.recorded) || 0), 0),
    disabled: outcomes.some((outcome) => outcome.disabled === true),
    errors: outcomes.map((outcome) => outcome.error).filter(Boolean),
    examples: outcomes,
  };
}

/**
 * Deletes all learning examples associated with a user when they request data deletion or revoke consent.
 */
async function deleteLearningExamplesForUser(client, profileId, hmacKey = null) {
  if (!profileId) return 0;
  const key = getHmacKey(hmacKey);
  const res = await client.query(
    'SELECT pandapay.sms_delete_learning_examples_for_user($1::uuid, $2) AS deleted',
    [profileId, key || null],
  );
  return Number(res.rows?.[0]?.deleted) || 0;
}

function registerSmsLearningAdminRoutes(app, { requireAdmin, withUserClient }) {
  // Operational view for autonomous learning.  It contains rule metadata and
  // aggregate outcomes only; SMS bodies and extracted values are never sent to
  // the console.
  app.get('/admin/sms-learning/operations', requireAdmin, async (req, res) => {
    const limit = Math.min(200, Math.max(1, Number.parseInt(req.query?.limit, 10) || 100));
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const candidates = await client.query(
          `SELECT c.candidate_id, c.family, c.issuer, c.sender_pattern, c.state,
                  c.confidence, c.bundle_version, c.min_client_ver,
                  c.stage_metrics, c.created_at, c.updated_at,
                  COALESCE(count(e.*) FILTER (WHERE e.outcome <> 'unresolved'), 0)::int AS exposures,
                  COALESCE(count(e.*) FILTER (WHERE e.correction), 0)::int AS corrections,
                  COALESCE(count(e.*) FILTER (WHERE e.false_discard), 0)::int AS false_discards,
                  COALESCE(count(e.*) FILTER (
                    WHERE e.baseline_family IS NOT NULL
                      AND e.candidate_family IS NOT NULL
                      AND e.delta_outcome IS NOT NULL
                      AND e.outcome <> 'unresolved'), 0)::int AS comparisons,
                  COALESCE(count(DISTINCT e.profile_id), 0)::int AS distinct_users
             FROM public.sms_rule_candidates c
             LEFT JOIN public.sms_rule_candidate_exposures e
               ON e.candidate_id = c.candidate_id
            GROUP BY c.candidate_id
            ORDER BY c.updated_at DESC NULLS LAST, c.created_at DESC
            LIMIT $1`,
          [limit],
        );
        const activeBundle = await client.query(
          `SELECT bundle_version, sha256, min_client_ver, published_at
             FROM public.sms_rule_bundles
            WHERE is_active = true
            ORDER BY bundle_version DESC
            LIMIT 1`,
        );
        let worker = null;
        try {
          const workerResult = await client.query(
            `SELECT status, started_at, finished_at, details
               FROM public.sms_learning_worker_runs
              ORDER BY started_at DESC
              LIMIT 20`,
          );
          worker = { runs: workerResult.rows || [] };
        } catch (_) {
          // The health table is introduced independently so an older database
          // continues to serve the rest of the admin operations page.
        }
        return {
          candidates: candidates.rows || [],
          activeBundle: activeBundle.rows?.[0] || null,
          worker,
        };
      });
      res.status(200).json(result);
    } catch (error) {
      console.error('GET /admin/sms-learning/operations error', error.message || error);
      res.status(500).json({ error: 'failed to fetch SMS learning operations' });
    }
  });

  app.get('/admin/sms-learning/candidates', requireAdmin, async (req, res) => {
    const limit = Math.min(200, Math.max(1, Number.parseInt(req.query?.limit, 10) || 100));
    try {
      const result = await withUserClient(req.userId, (client) =>
        client.query('SELECT pandapay.sms_learning_candidates($1) AS candidates', [limit]));
      res.status(200).json({ candidates: result.rows[0]?.candidates || [] });
    } catch (error) {
      console.error('GET /admin/sms-learning/candidates error', error.message || error);
      res.status(500).json({ error: 'failed to fetch SMS learning candidates' });
    }
  });

  app.post('/admin/sms-learning/candidates/:id/decision', requireAdmin, async (req, res) => {
    const { decision } = req.body || {};
    if (typeof req.params.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(req.params.id)) {
      return res.status(400).json({ error: 'candidate id must be a UUID' });
    }
    if (!['manual_pattern_authoring', 'reject'].includes(decision)) {
      return res.status(400).json({ error: 'decision must be manual_pattern_authoring or reject' });
    }
    try {
      const result = await withUserClient(req.userId, async (client) => {
        const outcome = await client.query(
          'SELECT pandapay.sms_learning_decide($1::uuid, $2, $3::uuid) AS outcome',
          [req.params.id, decision, req.userId],
        );
        if (outcome.rows[0]?.outcome?.ok) {
          await client.query(
            `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
             VALUES ($1, 'decide_sms_learning_candidate', 'sms_learning_candidates', NULL, $2, $3)`,
            [
              req.userId,
              JSON.stringify({ candidateId: req.params.id, decision }),
              req.body?.reason || null,
            ],
          );
        }
        return outcome;
      });
      const outcome = result.rows[0]?.outcome;
      if (!outcome?.ok) return res.status(outcome?.reason === 'not_eligible' ? 409 : 404).json({ error: outcome?.reason || 'candidate unavailable' });
      res.status(200).json({ ok: true, decision: outcome.decision });
    } catch (error) {
      console.error('POST /admin/sms-learning/candidates/:id/decision error', error.message || error);
      res.status(500).json({ error: 'failed to record SMS learning decision' });
    }
  });

  const autonomousCandidateId = (id) => typeof id === 'string' && /^[A-Za-z0-9._:-]{3,128}$/.test(id);

  const auditCandidateChange = (client, adminId, action, candidate, reason) => client.query(
    `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
     VALUES ($1, $2, 'sms_rule_candidates', NULL, $3, $4)`,
    [adminId, action, JSON.stringify(candidate), reason],
  );

  app.post('/admin/sms-learning/candidates/:id/pause', requireAdmin, async (req, res) => {
    if (!autonomousCandidateId(req.params.id)) return res.status(400).json({ error: 'invalid candidate id' });
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'paused',
                  stage_version = stage_version + 1,
                  stage_metrics = stage_metrics || jsonb_build_object(
                    'pause_reason', 'admin_paused', 'paused_at', now()),
                  updated_at = now()
            WHERE candidate_id = $1
              AND state IN ('proposed', 'evaluated', 'shadow', 'limited', 'expanded', 'active')
          RETURNING candidate_id, state`,
          [req.params.id],
        );
        const candidate = result.rows?.[0] || null;
        if (candidate) {
          await auditCandidateChange(client, req.userId, 'pause_sms_learning_candidate', candidate, 'admin_paused');
        }
        return candidate;
      });
      if (!outcome) return res.status(404).json({ error: 'candidate not found or already terminal' });
      res.status(200).json({ ok: true, candidate: outcome });
    } catch (error) {
      console.error('POST /admin/sms-learning/candidates/:id/pause error', error.message || error);
      res.status(500).json({ error: 'failed to pause SMS learning candidate' });
    }
  });

  app.post('/admin/sms-learning/candidates/:id/resume', requireAdmin, async (req, res) => {
    if (!autonomousCandidateId(req.params.id)) return res.status(400).json({ error: 'invalid candidate id' });
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `UPDATE public.sms_rule_candidates
              SET state = 'shadow',
                  stage_version = stage_version + 1,
                  stage_metrics = stage_metrics || jsonb_build_object(
                    'resume_reason', 'admin_resumed', 'resumed_at', now(),
                    'window_start', now(), 'exposures', 0, 'corrections', 0,
                    'false_discards', 0, 'comparisons', 0, 'comparison_errors', 0),
                  updated_at = now()
            WHERE candidate_id = $1 AND state = 'paused'
          RETURNING candidate_id, state`,
          [req.params.id],
        );
        const candidate = result.rows?.[0] || null;
        if (candidate) {
          await auditCandidateChange(client, req.userId, 'resume_sms_learning_candidate', candidate, 'admin_resumed_shadow');
        }
        return candidate;
      });
      if (!outcome) return res.status(404).json({ error: 'paused candidate not found' });
      res.status(200).json({ ok: true, candidate: outcome });
    } catch (error) {
      console.error('POST /admin/sms-learning/candidates/:id/resume error', error.message || error);
      res.status(500).json({ error: 'failed to resume SMS learning candidate' });
    }
  });
}

module.exports = {
  SAFE_FIELDS,
  ALLOWED_FAMILIES,
  getHmacKey,
  redactBody,
  senderFingerprint,
  changedSafeFields,
  anonymizedTrainingSample,
  anonymizedTrainingFields,
  recordConfirmedCorrection,
  hasSmsSharedLearningConsent,
  getSmsSharedLearningConsent,
  recordLearningExample,
  recordReviewDismissal,
  deleteLearningExamplesForUser,
  registerSmsLearningAdminRoutes,
};
