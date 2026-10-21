/**
 * Privacy-minimizing shared-learning signals from user-confirmed SMS fixes.
 *
 * This module stores only an HMAC sender fingerprint, fact family, corrected
 * field names and per-profile/source dedupe identity. It never stores the SMS,
 * the correction value, account data, or the user's free-text reason. Signals
 * are review candidates; they never become executable parser rules here.
 */

const crypto = require('crypto');

const SAFE_FIELDS = new Set([
  'entryKind', 'instrument', 'amountInr', 'availableBalanceInr',
  'currentBalanceInr', 'amountDueInr', 'minimumDueInr', 'amountRole',
  'dueDate', 'statementDate', 'asOfAt', 'mandateStatus', 'merchant',
  'cadenceDays', 'limitInr', 'accountLast4', 'last4', 'currency',
]);

function senderFingerprint(sender, key = process.env.SMS_LEARNING_HMAC_KEY) {
  if (typeof key !== 'string' || key.length < 32 || typeof sender !== 'string' || !sender.trim()) {
    return null;
  }
  const normalized = sender.normalize('NFKC').trim().toLowerCase().replace(/\s+/g, ' ');
  return crypto.createHmac('sha256', key).update(normalized).digest('hex');
}

function changedSafeFields(before, after) {
  const fields = new Set([...Object.keys(before || {}), ...Object.keys(after || {})]);
  return [...fields].filter((field) => SAFE_FIELDS.has(field) &&
    JSON.stringify(before?.[field]) !== JSON.stringify(after?.[field]));
}

async function recordConfirmedCorrection(client, {
  profileId, sourceKey, sender, family, fields,
}) {
  const fingerprint = senderFingerprint(sender);
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

module.exports = { SAFE_FIELDS, senderFingerprint, changedSafeFields, recordConfirmedCorrection, registerSmsLearningAdminRoutes };
