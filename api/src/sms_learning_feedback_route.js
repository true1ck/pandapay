const crypto = require('crypto');
const smsLearning = require('./sms_learning');
const { compileTemplate, deriveIssuerPrefix } = require('./sms_template_compiler');

const HEX64 = /^[0-9a-f]{64}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACTIONS = new Set(['confirmed', 'edited', 'category_changed', 'moved_to_review', 'dismissed', 'ai_auto_resolved']);
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

function proposalPattern(value, merchant) {
  let pattern = String(value || '');
  if (typeof merchant === 'string' && merchant.trim()) {
    const escaped = merchant.trim().replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    pattern = pattern.replace(new RegExp(escaped, 'gi'), '{MERCHANT}');
  }
  return pattern
    .replace(/https?:\/\/\S+/gi, '{url}')
    .replace(/\b[\w.+-]+@[\w.-]+\.[a-z]{2,}\b/gi, '{email}')
    .replace(/\b(Dear|Hi|Hello)\s+[A-Za-z][A-Za-z .]{1,60}(?=[,:])/gi, '$1 {name}')
    // Mask likely personal names when SMSes use non-greeting constructions.
    .replace(/\b(?:Mr\.?|Mrs\.?|Ms\.?|Miss|Shri|Smt\.?|[Cc]ustomer|[Aa]ccount holder|[Cc]ardholder|[Bb]eneficiary|[Rr]ecipient)\s+(?:[Nn]ame\s*[:=-]?\s*)?([A-Z][a-z]{1,30}(?:\s+[A-Z][a-z]{1,30}){0,2})\b/g, '{name}')
    .replace(/\b([A-Z][a-z]{2,30}(?:\s+[A-Z][a-z]{2,30}){0,2})\s*,?\s+(?=(?:your\b|you\b|has\b|have\b|payment\b|account\b|card\b|paid\b|spent\b|received\b|debited\b|credited\b|transferred\b|made\b))/g, '{name} ')
    .replace(/\b(?:from|to|for|by|of)\s+([A-Z][a-z]{2,30}(?:\s+[A-Z][a-z]{2,30}){0,2})\b/g, (match, name) =>
      `${match.slice(0, match.length - name.length)}{name}`)
    .replace(/\d+/g, '{n}')
    .trim().slice(0, 1201);
}

function proposalFields(fields) {
  const safe = sanitizeFields(fields);
  const result = {};
  for (const [key, value] of Object.entries(safe)) {
    if (typeof value === 'number') result[key] = 123.45;
    else if (key === 'occurredAt' || key === 'dueDate' || key === 'statementDate' || key === 'asOfAt') {
      result[key] = '2025-01-01';
    } else if (typeof value === 'string') result[key] = proposalPattern(value);
    else result[key] = value;
  }
  return result;
}

// The redactor above is a bounded regex pass, so it cannot promise that every
// personal name is caught. These are the residual leaks it leaves behind: a VPA
// or handle (no TLD, so the email rule misses it) and an ALL CAPS run inside an
// otherwise mixed-case message, which is how Indian bank SMS render a payer's
// name outside a greeting. Evidence still carrying one is withheld rather than
// shown to an admin.
const RESIDUAL_CAPS_RUN = /\b[A-Z]{2,30}(?:\s+[A-Z]{2,30})+\b/;

function residualIdentifierRisk(pattern) {
  const text = String(pattern || '');
  if (text.includes('@')) return 'contact_identifier';
  const letters = text.replace(/[^A-Za-z]/g, '');
  if (!letters) return null;
  // A message written entirely in caps gives casing no discriminating power, so
  // it is not screened here; see the documented limitation in
  // docs/sms-shared-learning-admin-approval-plan.md. Amounts, references,
  // account fragments and the classified merchant are still masked in it.
  const upperRatio = letters.replace(/[^A-Z]/g, '').length / letters.length;
  if (upperRatio < 0.8 && RESIDUAL_CAPS_RUN.test(text)) return 'unmasked_name';
  return null;
}

function personalNameSender(sender) {
  // Institutional sender IDs are single tokens ("AD-HDFCBK", "VK-SBI") or caps;
  // a Title Case two-word sender is a peer-to-peer payer's name.
  return /^[A-Z][a-z]{1,30}(?:\s+[A-Z][a-z]{1,30})+$/.test(String(sender || '').trim());
}

function aiTemplate(pattern, family) {
  const template = pattern
    .replace(/\{n\}[-/]\{n\}[-/]\{n\}/g, '{DATE}')
    // The typed AMOUNT slot already matches its currency prefix.
    .replace(/(?:₹|Rs\.?|INR)\s*\{n\}/gi, '{AMOUNT}')
    .replace(/\{n\}/g, '{REF}');
  if (template.length > 250) return null;
  return compileTemplate(template, { family }).valid ? template : null;
}

function registerSmsLearningFeedbackRoute(app, { requireAuth, requireAdmin, withUserClient }) {
  app.post('/sms/learning-feedback', requireAuth, async (req, res) => {
    const body = req.body || {};
    const {
      eventId, sourceKey, action, sender, sampleBody, resolvedKind,
      originalDecision, correctedFields, occurredAt, reason,
      consentPurpose, consentPolicyVersion, consentGrantedAt, aiConfidenceScore,
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
    if (action === 'ai_auto_resolved' &&
        (typeof sampleBody !== 'string' || sampleBody.trim().length < 3 ||
         consentPolicyVersion !== 'sms-shared-learning-v2' ||
         (aiConfidenceScore !== undefined &&
          (typeof aiConfidenceScore !== 'number' || !Number.isFinite(aiConfidenceScore) ||
           aiConfidenceScore < 0 || aiConfidenceScore > 1)))) {
      return res.status(400).json({ error: 'invalid AI proposal evidence or consent policy' });
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
        if (action === 'ai_auto_resolved') {
          if (consent.policy_version !== 'sms-shared-learning-v2') {
            return { acknowledged: true, recorded: false, learned: false,
              learningReason: 'consent_policy_mismatch' };
          }
          const pattern = proposalPattern(sampleBody, cleanOriginal.fields?.merchant);
          if (pattern.length < 3 || !family || !['posted_movement', 'balance_snapshot',
            'bill_obligation', 'bill_payment', 'mandate_lifecycle', 'ignore_noise'].includes(family)) {
            return { acknowledged: true, recorded: false, learned: false,
              learningReason: 'invalid_ai_proposal' };
          }
          if (residualIdentifierRisk(pattern) || personalNameSender(sender)) {
            // Withhold rather than generalize further: this proposal is only
            // admin review evidence, and the on-device action already happened.
            return { acknowledged: true, recorded: false, learned: false,
              learningReason: 'unsafe_evidence' };
          }
          // A delayed or retried AI upload must not resurrect evidence the user
          // has already corrected. The per-profile advisory lock taken above
          // makes this read and the insert below one atomic step, and the
          // before-insert trigger repeats the check so the guarantee does not
          // depend on the caller holding that lock.
          const superseding = await client.query(
            `SELECT 1 FROM public.sms_learning_feedback_events
              WHERE profile_id = $1 AND source_key_hash = $2 LIMIT 1`,
            [req.userId, sourceKey],
          );
          if (superseding.rows?.length) {
            return { acknowledged: true, recorded: false, learned: false,
              learningReason: 'superseded_by_user_feedback' };
          }
          const template = aiTemplate(pattern, family);
          const hmacKey = process.env.SMS_LEARNING_HMAC_KEY;
          const userHash = crypto.createHmac('sha256', hmacKey)
            .update(String(req.userId)).digest('hex');
          const inserted = await client.query(
            `INSERT INTO public.sms_ai_learning_proposals
               (profile_id, event_id, source_key_hash, sender_fingerprint, user_hash,
                issuer_prefix, sender_pattern, redacted_pattern, template_text,
                synthetic_sample, fact_family, resolved_kind, proposed_fields, ai_score,
                consent_policy_version, consent_granted_at)
             VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13::jsonb,$14,$15,$16::timestamptz)
             ON CONFLICT (profile_id, event_id) DO NOTHING RETURNING event_id`,
            [req.userId, eventId, sourceKey, fingerprint, userHash,
              deriveIssuerPrefix(sender), proposalPattern(sender), pattern, template,
              template ? smsLearning.anonymizedTrainingSample(template) : null,
              family, resolvedKind, JSON.stringify(proposalFields(cleanOriginal.fields)),
              aiConfidenceScore ?? null, consent.policy_version, consentGrantedAt],
          );
          return { acknowledged: true, recorded: inserted.rowCount === 1, learned: false,
            learningReason: inserted.rowCount === 1 ? 'admin_review_pending' : 'duplicate' };
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

        // Withhold the generalized message text when a name or handle survived
        // redaction. The structured event is still stored, so the user's
        // correction keeps counting; only the admin-visible sample is dropped.
        const patternEvidence = sampleBody ? proposalPattern(sampleBody) : null;
        const safePattern = patternEvidence && !residualIdentifierRisk(patternEvidence)
          ? patternEvidence : null;
        await client.query(
          `INSERT INTO public.sms_learning_feedback_events
             (profile_id, event_id, source_key_hash, sender_fingerprint, action,
              consent_purpose, consent_policy_version, consent_granted_at, merchant_key,
              category_slug, original_category_slug, resolved_kind,
              original_decision, corrected_fields, occurred_at, learned, learning_reason,
              redacted_pattern)
           VALUES ($1,$2,$3,$4,$5,$6,$7,$8::timestamptz,$9,$10,$11,$12,$13::jsonb,$14::jsonb,$15,$16,$17,$18)`,
          [req.userId, eventId, sourceKey, fingerprint, action, 'sms_shared_learning',
            consent.policy_version, consentGrantedAt, categoryMerchant, correctedCategory,
            originalCategory, resolvedKind, JSON.stringify(cleanOriginal),
            JSON.stringify(cleanCorrected), occurred, learned, learningReason,
            safePattern],
        );
        // Accepted explicit feedback outranks any AI-only proposal for this SMS.
        // Runs in the same transaction as the event insert, so a proposal can
        // never be visible as eligible between the two.
        await client.query(
          'SELECT pandapay.sms_supersede_ai_proposals($1, $2) AS superseded_count',
          [sourceKey, eventId],
        );
        return { acknowledged: true, recorded: true, learned, learningReason };
      });
      res.status(200).json(result);
    } catch (error) {
      console.error('POST /sms/learning-feedback error', error.message || error);
      res.status(503).json({ error: 'sms_learning_feedback_unavailable' });
    }
  });

  app.get('/admin/sms-learning/ai-proposals', requireAdmin, async (req, res) => {
    try {
      const proposals = await withUserClient(req.userId, async (client) => {
        const result = await client.query(
          `SELECT p.proposal_id, p.redacted_pattern, p.template_text, p.fact_family,
                  p.resolved_kind, p.proposed_fields, p.ai_score, p.status,
                  p.created_at, p.reviewed_at, p.review_reason
             FROM public.sms_ai_learning_proposals p
             JOIN LATERAL (
               SELECT c.granted, c.policy_version FROM public.user_consents c
                WHERE c.profile_id = p.profile_id AND c.purpose = 'sms_shared_learning'
                ORDER BY c.granted_at DESC, c.id DESC LIMIT 1
             ) consent ON consent.granted = true
                      AND consent.policy_version = 'sms-shared-learning-v2'
            ORDER BY (p.status = 'pending') DESC, p.created_at DESC
            LIMIT 100`,
        );
        return result.rows.map((row) => ({
          proposalId: row.proposal_id,
          redactedPattern: row.redacted_pattern,
          origin: 'ai_auto_resolved',
          evidenceStrength: 'unconfirmed_ai',
          proposedRule: {
            family: row.fact_family,
            template: row.template_text,
            fields: row.proposed_fields,
            resolvedKind: row.resolved_kind,
          },
          aiScore: row.ai_score,
          status: row.status,
          createdAt: row.created_at,
          reviewedAt: row.reviewed_at,
          reviewReason: row.review_reason,
        }));
      });
      res.status(200).json({ proposals });
    } catch (error) {
      console.error('GET /admin/sms-learning/ai-proposals error', error.message || error);
      res.status(500).json({ error: 'failed to load AI proposals' });
    }
  });

  app.post('/admin/sms-learning/ai-proposals/review', requireAdmin, async (req, res) => {
    const { proposalId, decision, reason } = req.body || {};
    if (typeof proposalId !== 'string' || !UUID.test(proposalId) ||
        !['approved', 'rejected'].includes(decision) ||
        typeof reason !== 'string' || reason.trim().length < 5 || reason.length > 500) {
      return res.status(400).json({ error: 'invalid AI proposal review' });
    }
    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        const first = await client.query(
          `SELECT profile_id FROM public.sms_ai_learning_proposals WHERE proposal_id = $1`,
          [proposalId],
        );
        const profileId = first.rows?.[0]?.profile_id;
        if (!profileId) return { missing: true };
        await client.query('SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
          [`sms-shared-learning-consent:${profileId}`]);
        const current = await client.query(
          `SELECT status, template_text, proposed_fields, source_key_hash, profile_id
             FROM public.sms_ai_learning_proposals
            WHERE proposal_id = $1 FOR UPDATE`, [proposalId],
        );
        const row = current.rows?.[0];
        if (!row) return { stale: true };
        if (row.status === 'superseded') return { superseded: true };
        if (row.status !== 'pending') return { stale: true };
        // Defence in depth for rows written before the supersede backfill: an
        // accepted explicit event for the same source outranks this AI evidence
        // even if the row was never demoted.
        const explicit = await client.query(
          `SELECT 1 FROM public.sms_learning_feedback_events
            WHERE profile_id = $1 AND source_key_hash = $2 LIMIT 1`,
          [row.profile_id, row.source_key_hash],
        );
        if (explicit.rows?.length) return { superseded: true };
        const consent = await smsLearning.getSmsSharedLearningConsent(client, profileId);
        if (consent?.granted !== true || consent.policy_version !== 'sms-shared-learning-v2') {
          return { stale: true };
        }
        const hasCategoryEvidence = typeof row.proposed_fields?.merchant === 'string' &&
          categorySlug(row.proposed_fields?.categorySlug) !== null;
        if (decision === 'approved' && !row.template_text && !hasCategoryEvidence) {
          return { noSafeTemplate: true };
        }
        await client.query(
          `UPDATE public.sms_ai_learning_proposals
              SET status = $2, reviewed_by = $3, reviewed_at = now(), review_reason = $4
            WHERE proposal_id = $1`,
          [proposalId, decision, req.userId, reason.trim()],
        );
        await client.query(
          `INSERT INTO admin_audit_log (admin_id, action, entity, entity_id, after_value, reason)
           VALUES ($1, 'review_sms_ai_learning_proposal', 'sms_ai_learning_proposals', $2, $3, $4)`,
          [req.userId, proposalId, JSON.stringify({ proposalId, decision }), reason.trim()],
        );
        return { ok: true };
      });
      if (outcome.missing) return res.status(404).json({ error: 'proposal_not_found' });
      if (outcome.superseded) {
        return res.status(409).json({ error: 'proposal_superseded_by_user_feedback' });
      }
      if (outcome.stale) return res.status(409).json({ error: 'proposal_changed_or_consent_revoked' });
      if (outcome.noSafeTemplate) return res.status(409).json({ error: 'no_safe_rule_template' });
      res.status(200).json({ ok: true, proposalId, decision });
    } catch (error) {
      console.error('POST /admin/sms-learning/ai-proposals/review error', error.message || error);
      res.status(500).json({ error: 'failed to review AI proposal' });
    }
  });
}

module.exports = { registerSmsLearningFeedbackRoute, sanitizeFields, merchantKey, categorySlug };
