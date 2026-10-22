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

async function recordConfirmedCorrection(client, {
  profileId, sourceKey, sender, family, fields, hmacKey,
}) {
  const resolvedKey = getHmacKey(hmacKey);
  const fingerprint = senderFingerprint(sender, resolvedKey);
  if (!fingerprint || !Array.isArray(fields) || fields.length === 0) return { recorded: 0, disabled: !fingerprint };
  // Shared learning is an opt-in product contribution. Do not assume consent
  // to use a local correction for cross-user learning; fail closed if the
  // profile is missing or its existing contribution preference is off.
  const consent = await client.query(
    'SELECT contributions_opt_in FROM profiles WHERE id = $1',
    [profileId],
  );
  if (consent.rows?.[0]?.contributions_opt_in !== true) {
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
  const consent = await client.query(
    'SELECT contributions_opt_in FROM profiles WHERE id = $1',
    [profileId],
  );
  if (consent.rows?.[0]?.contributions_opt_in !== true) {
    return { recorded: 0, disabled: true };
  }

  const fingerprint = senderFingerprint(sender, hmacKey);
  if (!fingerprint) {
    return { recorded: 0, disabled: false, error: 'invalid_sender_fingerprint' };
  }

  const family = ALLOWED_FAMILIES.has(factFamily) ? factFamily : 'posted_movement';
  const issuerPrefix = deriveIssuerPrefix(sender);
  const userHash = crypto.createHmac('sha256', hmacKey).update(String(profileId)).digest('hex');

  // Redact sample body and synthesize template text if needed
  const rawBody = sampleBody || templateText || '';
  const cleanBody = redactBody(rawBody);
  const cleanTemplate = templateText && templateText.includes('{')
    ? templateText
    : synthesizeTemplate(cleanBody, extractedFields);

  if (!cleanTemplate) {
    return { recorded: 0, disabled: false, error: 'unable_to_synthesize_template' };
  }

  const insertRes = await client.query(
    `INSERT INTO public.sms_learning_examples (
       sender_fingerprint, issuer_prefix, fact_family, template_text,
       sample_body, extracted_fields, is_negative, negative_reason, user_hash
     ) VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9)
     ON CONFLICT (user_hash, sender_fingerprint, fact_family, template_text) DO NOTHING
     RETURNING id`,
    [
      fingerprint,
      issuerPrefix,
      family,
      cleanTemplate,
      cleanBody,
      JSON.stringify(extractedFields || {}),
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
 * Convenience method for recording a user dismissal / not-financial decision as a negative learning example.
 */
async function recordReviewDismissal(client, { profileId, sender, body, reason, family = 'ignore_noise', hmacKey }) {
  return recordLearningExample(client, {
    profileId,
    sender,
    factFamily: family,
    sampleBody: body,
    isNegative: true,
    negativeReason: reason || 'user_dismissed',
    hmacKey,
  });
}

/**
 * Deletes all learning examples associated with a user when they request data deletion or revoke consent.
 */
async function deleteLearningExamplesForUser(client, profileId, hmacKey = null) {
  if (!profileId) return 0;
  const key = getHmacKey(hmacKey);
  if (!key) return 0;
  const res = await client.query(
    'SELECT pandapay.sms_delete_learning_examples_for_user($1::uuid, $2) AS deleted',
    [profileId, key],
  );
  return Number(res.rows?.[0]?.deleted) || 0;
}

function registerSmsLearningAdminRoutes(app, { requireAdmin, withUserClient }) {
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
      const result = await withUserClient(req.userId, (client) => client.query(
        'SELECT pandapay.sms_learning_decide($1::uuid, $2, $3::uuid) AS outcome',
        [req.params.id, decision, req.userId],
      ));
      const outcome = result.rows[0]?.outcome;
      if (!outcome?.ok) return res.status(outcome?.reason === 'not_eligible' ? 409 : 404).json({ error: outcome?.reason || 'candidate unavailable' });
      res.status(200).json({ ok: true, decision: outcome.decision });
    } catch (error) {
      console.error('POST /admin/sms-learning/candidates/:id/decision error', error.message || error);
      res.status(500).json({ error: 'failed to record SMS learning decision' });
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
  recordConfirmedCorrection,
  recordLearningExample,
  recordReviewDismissal,
  deleteLearningExamplesForUser,
  registerSmsLearningAdminRoutes,
};
