const crypto = require('crypto');
const smsLearning = require('./sms_learning');

const HEX64 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACTIONS = new Set(['confirmed', 'edited', 'category_changed', 'moved_to_review', 'dismissed']);
const RESOLVED_KINDS = new Set(['transaction', 'bill', 'mandate', 'dismissed', 'unresolved']);
const FAMILY_BY_KIND = {
  transaction: 'posted_movement',
  bill: 'bill_obligation',
  mandate: 'mandate_lifecycle',
  dismissed: 'ignore_noise',
};
const SAFE_FIELDS = new Set([
  'entryKind', 'instrument', 'amountInr', 'availableBalanceInr',
  'currentBalanceInr', 'amountDueInr', 'minimumDueInr', 'amountRole',
  'dueDate', 'statementDate', 'asOfAt', 'mandateStatus', 'merchant',
  'cadenceDays', 'limitInr', 'currency', 'categorySlug', 'occurredAt',
]);
const TRAINING_FIELDS = new Set([...SAFE_FIELDS].filter((field) => field !== 'categorySlug'));
const FIELD_MAX_LENGTH = 120;

function plainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function sanitizeFields(value, { training = false } = {}) {
  if (!plainObject(value)) return {};
  const allowed = training ? TRAINING_FIELDS : SAFE_FIELDS;
  const result = {};
  for (const [key, raw] of Object.entries(value)) {
    if (!allowed.has(key)) continue;
    if (typeof raw === 'number' && Number.isFinite(raw)) {
      result[key] = raw;
    } else if (typeof raw === 'boolean') {
      result[key] = raw;
    } else if (typeof raw === 'string' && raw.length <= FIELD_MAX_LENGTH) {
      // A field value could be copied from an SMS. Redact IDs, contact details,
      // and URLs even after its field name passed the allow-list.
      result[key] = smsLearning.redactBody(raw);
    }
  }
  return result;
}

function familyFor({ action, resolvedKind, originalDecision }) {
  const fromDecision = typeof originalDecision?.kind === 'string'
    ? originalDecision.kind : '';
  if (smsLearning.ALLOWED_FAMILIES.has(fromDecision)) return fromDecision;
  if (action === 'confirmed' && resolvedKind === 'dismissed') return 'ignore_noise';
  return FAMILY_BY_KIND[resolvedKind] || null;
}

function categorySlug(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toLowerCase();
  return /^[a-z0-9][a-z0-9_-]{0,63}$/.test(normalized) ? normalized : null;
}

function merchantKey(originalFields, correctedFields) {
  const raw = correctedFields?.merchant ?? correctedFields?.merchantName ??
    originalFields?.merchant ?? originalFields?.merchantName;
  if (typeof raw !== 'string' || raw.length > 120) return null;
  const normalized = smsLearning.redactBody(raw)
    .trim().replace(/\s+/g, ' ').toUpperCase();
  if (!normalized || ['UNKNOWN', 'OTHER', 'ONLINE'].includes(normalized)) return null;
  return normalized;
}

function registerSmsLearningFeedbackRoute(app, { requireAuth, withUserClient }) {
  app.post('/sms/learning-feedback', requireAuth, async (req, res) => {
    const body = req.body || {};
    const {
      eventId, sourceKey, action, sender, sampleBody, resolvedKind,
      originalDecision, correctedFields, occurredAt, reason,
      consentPurpose, consentPolicyVersion, consentGrantedAt,
    } = body;
    if (typeof eventId !== 'string' || !UUID.test(eventId)) {
      return res.status(400).json({ error: 'eventId must be a UUID' });
    }
    if (typeof sourceKey !== 'string' || !HEX64.test(sourceKey)) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256' });
    }
    if (!ACTIONS.has(action)) return res.status(400).json({ error: 'invalid action' });
    if (typeof sender !== 'string' || sender.trim().length < 1 || sender.length > 50) {
      return res.status(400).json({ error: 'sender must be 1 to 50 characters' });
    }
    if (!RESOLVED_KINDS.has(resolvedKind)) return res.status(400).json({ error: 'invalid resolvedKind' });
    if (sampleBody !== undefined && (typeof sampleBody !== 'string' || sampleBody.length > 1201)) {
      return res.status(400).json({ error: 'sampleBody must be at most 1201 characters' });
    }
    if (originalDecision !== undefined && !plainObject(originalDecision)) {
      return res.status(400).json({ error: 'originalDecision must be an object' });
    }
    if (correctedFields !== undefined && !plainObject(correctedFields)) {
      return res.status(400).json({ error: 'correctedFields must be an object' });
    }
    if (reason !== undefined && (typeof reason !== 'string' || reason.length > 200)) {
      return res.status(400).json({ error: 'reason must be at most 200 characters' });
    }
    if (consentPurpose !== undefined && consentPurpose !== 'sms_shared_learning') {
      return res.status(400).json({ error: 'consentPurpose must be sms_shared_learning' });
    }
    if (consentPolicyVersion !== undefined &&
        (typeof consentPolicyVersion !== 'string' || consentPolicyVersion.length > 80)) {
      return res.status(400).json({ error: 'consentPolicyVersion must be at most 80 characters' });
    }
    if (consentGrantedAt !== undefined &&
        (typeof consentGrantedAt !== 'string' || Number.isNaN(Date.parse(consentGrantedAt)))) {
      return res.status(400).json({ error: 'consentGrantedAt must be a valid timestamp' });
    }
    const occurred = occurredAt === undefined ? null : new Date(occurredAt);
    if (occurred && Number.isNaN(occurred.getTime())) {
      return res.status(400).json({ error: 'occurredAt must be a valid timestamp' });
    }

    const redactedSample = smsLearning.redactBody(sampleBody || '');
    if (/\b(?:otp|one[ .-]?time password|verification (?:code|number)|security code|access code|passcode|pin|cvv)\b/i.test(sampleBody || '')) {
      // The feedback action is already complete on device. Acknowledge it,
      // while keeping sensitive content out of all shared server tables.
      return res.status(200).json({
        acknowledged: true, recorded: false, learned: false,
        learningReason: 'sensitive_sms',
      });
    }
    const cleanOriginal = plainObject(originalDecision) ? {
      kind: typeof originalDecision.kind === 'string'
        ? originalDecision.kind.slice(0, 80) : null,
      fields: sanitizeFields(originalDecision.fields),
    } : {};
    const cleanCorrected = sanitizeFields(correctedFields);
    const family = familyFor({ action, resolvedKind, originalDecision: cleanOriginal });
    const trainingFields = {
      ...sanitizeFields(cleanOriginal.fields, { training: true }),
      ...sanitizeFields(cleanCorrected, { training: true }),
    };
    const correctedCategory = categorySlug(cleanCorrected.categorySlug);
    const originalCategory = categorySlug(cleanOriginal.fields?.categorySlug);
    const categoryMerchant = action === 'category_changed'
      ? merchantKey(cleanOriginal.fields, cleanCorrected) : null;
    const fingerprint = smsLearning.senderFingerprint(sender);
    if (!fingerprint) {
      return res.status(503).json({ error: 'sms_learning_unavailable' });
    }

    try {
      const result = await withUserClient(req.userId, async (client) => {
        // Serialize feedback and consent changes per profile. The /consents
        // route takes the same transaction-scoped lock before changing this
        // purpose, so opt-out cannot race a feedback insert/purge.
        await client.query(
          'SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
          [`sms-shared-learning-consent:${req.userId}`],
        );
        const consent = await smsLearning.getSmsSharedLearningConsent(client, req.userId);
        if (consent?.granted !== true) {
          // A missing or revoked purpose-specific consent is an acknowledged
          // local action, never a reason to upload to the older crowdsource path.
          return { acknowledged: true, recorded: false, learned: false, learningReason: 'consent_disabled' };
        }
        if (consentPolicyVersion && consentPolicyVersion !== consent.policy_version) {
          return { acknowledged: true, recorded: false, learned: false, learningReason: 'consent_policy_mismatch' };
        }
        if (!consentGrantedAt || !consent.granted_at) {
          return { acknowledged: true, recorded: false, learned: false, learningReason: 'consent_grant_mismatch' };
        }
        const sameGrant = await client.query(
          'SELECT $1::timestamptz = $2::timestamptz AS matches',
          [consentGrantedAt, consent.granted_at],
        );
        if (sameGrant.rows?.[0]?.matches !== true) {
          return { acknowledged: true, recorded: false, learned: false, learningReason: 'consent_grant_mismatch' };
        }
        const lockKey = `sms-feedback:${req.userId}:${eventId}`;
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))', [lockKey]);
        const existing = await client.query(
          `SELECT learned, learning_reason FROM public.sms_learning_feedback_events
            WHERE profile_id = $1 AND event_id = $2`,
          [req.userId, eventId],
        );
        if (existing.rows?.length) {
          const old = existing.rows[0];
          return {
            acknowledged: true, recorded: false, learned: old.learned === true,
            learningReason: old.learning_reason || 'duplicate',
          };
        }

        let learned = false;
        let learningReason = 'feedback_stored_only';
        const templateText = typeof body.templateText === 'string'
          ? smsLearning.redactBody(body.templateText).slice(0, 250)
          : (typeof body.template === 'string' ? smsLearning.redactBody(body.template).slice(0, 250) : undefined);
        const exampleFields = action === 'confirmed' || action === 'edited'
          ? trainingFields : {};
        const canLearnFinancial = (action === 'confirmed' || action === 'edited') &&
          family && family !== 'ignore_noise' && Object.keys(exampleFields).length > 0;

        if (canLearnFinancial) {
          const example = await smsLearning.recordLearningExample(client, {
            profileId: req.userId,
            sender,
            factFamily: family,
            templateText,
            sampleBody: redactedSample,
            extractedFields: exampleFields,
          });
          if (example.error) throw Object.assign(new Error('learning example insert failed'), { code: 'SMS_LEARNING_EXAMPLE_FAILED' });
          learned = example.recorded === 1 || example.exampleId === null;
          learningReason = learned ? (example.recorded ? 'recorded' : 'duplicate') : 'insufficient_correction';
        } else if (action === 'confirmed' && family === 'ignore_noise') {
          const example = await smsLearning.recordLearningExample(client, {
            profileId: req.userId,
            sender,
            factFamily: 'ignore_noise',
            templateText,
            sampleBody: redactedSample,
            extractedFields: { userConfirmedDismissal: true },
          });
          if (example.error) throw Object.assign(new Error('learning example insert failed'), { code: 'SMS_LEARNING_EXAMPLE_FAILED' });
          learned = example.recorded === 1 || example.exampleId === null;
          learningReason = learned ? (example.recorded ? 'recorded' : 'duplicate') : 'insufficient_correction';
        } else if (action === 'dismissed') {
          const outcome = await smsLearning.recordReviewDismissal(client, {
            profileId: req.userId,
            sender,
            body: redactedSample || templateText || '',
            reason: reason || 'user_dismissed',
            family: family || 'ignore_noise',
          });
          if (outcome.errors?.length) throw Object.assign(new Error('dismissal learning insert failed'), { code: 'SMS_LEARNING_EXAMPLE_FAILED' });
          learned = (outcome.examples?.length || 0) > 0;
          learningReason = learned ? (outcome.recorded > 0 ? 'recorded' : 'duplicate') : 'insufficient_correction';
        } else if (action === 'moved_to_review' && family && family !== 'ignore_noise') {
          const example = await smsLearning.recordLearningExample(client, {
            profileId: req.userId,
            sender,
            factFamily: family,
            templateText,
            sampleBody: redactedSample,
            extractedFields: trainingFields,
            isNegative: true,
            negativeReason: reason || 'user_moved_to_review',
          });
          if (example.error) throw Object.assign(new Error('learning example insert failed'), { code: 'SMS_LEARNING_EXAMPLE_FAILED' });
          learned = example.recorded === 1 || example.exampleId === null;
          learningReason = learned ? (example.recorded ? 'recorded' : 'duplicate') : 'insufficient_correction';
        } else if (action === 'category_changed') {
          // Category corrections are retained for the next category-rule
          // compiler; the current SMS regex learner only emits parse fields.
          learningReason = 'category_feedback_stored_no_shared_category_rule';
        }

        await client.query(
          `INSERT INTO public.sms_learning_feedback_events
             (profile_id, event_id, source_key_hash, sender_fingerprint, action,
              consent_purpose, consent_policy_version, consent_granted_at, merchant_key,
              category_slug, original_category_slug, resolved_kind,
              original_decision, corrected_fields, occurred_at, learned, learning_reason)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8::timestamptz,$9,$10,$11,$12,$13::jsonb,$14::jsonb,$15,$16,$17)`,
          [req.userId, eventId, sourceKey, fingerprint, action, 'sms_shared_learning',
            consent.policy_version, consentGrantedAt, categoryMerchant, correctedCategory,
            originalCategory, resolvedKind, JSON.stringify(cleanOriginal),
            JSON.stringify(cleanCorrected), occurred, learned, learningReason],
        );
        return { acknowledged: true, recorded: true, learned, learningReason };
      });
      res.status(200).json(result);
    } catch (error) {
      console.error('POST /sms/learning-feedback error', error.message || error);
      res.status(503).json({ error: 'sms_learning_feedback_unavailable' });
    }
  });
}

module.exports = { registerSmsLearningFeedbackRoute, sanitizeFields, merchantKey, categorySlug };
