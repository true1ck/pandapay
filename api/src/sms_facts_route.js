/**
 * SMS intelligence Phase 2/4: typed facts intake + user corrections.
 *
 * Devices mint validated facts for recognized non-spend financial messages
 * (balance snapshots, autopay mandate lifecycle, failed payment attempts,
 * bill obligations) and POST them here inside an envelope keyed by the same
 * legacy source key the /transactions/from-sms pipeline already produces.
 * No raw body ever arrives on this route — the body hash is the identity,
 * facts are content.
 *
 * Specialist applications run after the envelope is durable: bill facts
 * teach statement/due days (the same heal rules as the legacy SMS route),
 * and a mandate fact registers or cancels the recurring_series row through
 * the injected persistSubscriptionMandate, so every existing writer stays
 * in one place.
 *
 * Phase 4 adds POST /sms/facts/overrides: structured user corrections for
 * one fact of one source. The patch is validated by re-resolving the facts
 * with overrides applied, then the specialists re-run on the corrected
 * values. A later replay of POST /sms/facts with the original payload can
 * never resurrect the corrected base: the read path always applies
 * fact_overrides first (Phase 1 contract guarantee).
 *
 * Needs Review outcomes & dismissals are safely linked to consent-checked
 * learning examples for the autonomous worker.
 */

const smsFacts = require('./sms_facts');
const { safeErrorCode } = require('./safeErrorCode');
const centralProjection = require('./central_financial_projection');
const importResolvers = require('./import_resolvers');
const { importSourceKey } = require('./import_source_key');
const smsLearning = require('./sms_learning');
const smsRuleBundle = require('./sms_rule_bundle');

const HEX64 = /^[0-9a-f]{64}$/;
const CANDIDATE_ID = /^[A-Za-z0-9._:-]{3,128}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const SENSITIVE_SMS_EVIDENCE = /\b(?:otp|one[ .-]?time password|verification (?:code|number)|security code|access code|passcode|pin|cvv)\b/i;
// Kept in lockstep with the on-device baseline/candidate comparison contract.
// The worker also understands the historical aggregate labels used by older
// clients, so those remain accepted during the migration window.
const EXPOSURE_DELTAS = new Set([
  'unresolved', 'agreement_unresolved', 'candidate_miss', 'candidate_extra_financial',
  'agreement', 'wrong_family', 'disposition_mismatch', 'field_mismatch', 'wrong_amount', 'wrong_date',
  'invalid_fact', 'duplicate_risk', 'projection_mismatch',
  'candidate_worse', 'baseline_better', 'regression', 'same', 'improved', 'regressed', 'unknown',
]);

function plainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function normalizeDismissalSourceKey(value) {
  if (value === undefined) return null;
  if (typeof value !== 'string') return undefined;
  if (HEX64.test(value)) return value;
  const commitment = /^commitment:([0-9a-f]{64})$/.exec(value);
  return commitment?.[1];
}

function containsLearningRedaction(value) {
  return /\[(?:URL|EMAIL|PHONE)\]|XXXX\d{4}/i.test(String(value || ''));
}

function istDayKey(dateStr) {
  if (!dateStr) return '';
  const d = new Date(dateStr);
  if (Number.isNaN(d.getTime())) return dateStr;
  return new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
}

function syntheticMandateParse(fact) {
  const payload = fact.payload || {};
  if (!payload.merchant) return null;
  const fields = {
    merchant: payload.merchant,
    // Keep the typed fact's ceiling available to downstream projections. The
    // legacy mandate writer deliberately ignores amountInr when choosing a
    // recurring price, because this compatibility shape predates a separate
    // authorization-limit column.
    limitInr: payload.limitInr,
    amountInr: payload.limitInr,
    cadenceDays: payload.cadenceDays,
    cadenceExplicit: false,
    reference: payload.reference,
  };
  if (payload.last4 && payload.instrument === 'credit_card') {
    fields.last4 = payload.last4;
    fields.instrument = 'credit_card';
  }
  return {
    ok: true,
    lifecycle: payload.mandateStatus === 'cancelled' ? 'cancelled' : 'active',
    fields,
  };
}

/**
 * Statement/due-day healing + mandate persistence, shared by the facts
 * route and the overrides route so both feed the same projections. Each
 * distinct printed date heals once per envelope; a source persists its
 * mandate lifecycle once even when several lifecycle facts ride along.
 */
async function applyFactSpecialists(client, userId, resolution, {
  userCardId,
  occurred,
  persistSubscriptionMandate,
}) {
  // The projection table is additive and may be one migration behind during
  // a rolling deploy. Keep the existing specialists usable if that happens;
  // the savepoint prevents a missing table from aborting the surrounding
  // user transaction.
  let centralProjectionResult = {
    projectionVersion: centralProjection.PROJECTION_VERSION,
    projectionCount: 0,
    projectionKinds: [],
    projectionPersisted: false,
  };
  let savepoint = false;
  try {
    await client.query('SAVEPOINT sms_central_projection');
    savepoint = true;
    const persisted = await centralProjection.persistFinancialProjections(client, userId, {
      sourceId: resolution?.sourceId || null,
      sourceKey: resolution?.sourceKey || null,
      facts: resolution?.facts || [],
    });
    await client.query('RELEASE SAVEPOINT sms_central_projection');
    centralProjectionResult = {
      projectionVersion: persisted.projectionVersion,
      projectionCount: persisted.count,
      projectionKinds: persisted.kinds,
      projectionPersisted: true,
    };
  } catch (error) {
    if (savepoint) {
      await client.query('ROLLBACK TO SAVEPOINT sms_central_projection').catch(() => {});
      await client.query('RELEASE SAVEPOINT sms_central_projection').catch(() => {});
    }
    // Facts remain durable and the legacy domain writers remain available
    // while an additive migration rolls out across API instances.
    console.warn('central SMS projection skipped:', error.message || error);
  }
  let statementDayUpdated = false;
  let dueDayUpdated = false;
  let mandatePersisted = false;
  const seenDates = new Set();
  for (const fact of resolution.facts) {
    if (fact.status === 'superseded' || fact.status === 'discarded') continue;
    // A device replay can load AI suggestions already stored on this source.
    // Only an explicit saved correction promotes those suggestions to evidence.
    if (fact.provenance?.channel === 'ai' && !fact.overridden) continue;
    if (fact.factType === 'mandate_lifecycle' && !mandatePersisted) {
      const parsed = syntheticMandateParse(fact);
      if (parsed) {
        const persisted = await persistSubscriptionMandate(client, userId, {
          parsed,
          body: '',
          occurred: occurred || new Date(),
          patternIssuerId: null,
        });
        mandatePersisted = Boolean(persisted);
      }
    }
    const payload = fact.payload || {};
    const last4 = typeof payload.last4 === 'string' ? payload.last4 : null;
    // Only a card-bill obligation is evidence for recurring card days. Other
    // fact families may carry dates for their own lifecycle and must not heal
    // the card profile.
    const isCardBill = fact.factType === 'bill_obligation' &&
      (!payload.instrument || payload.instrument === 'credit_card') &&
      (!payload.cardType || payload.cardType === 'credit') &&
      payload.targetKind !== 'utility_or_other_bill';
    if (isCardBill && payload.statementDate) {
      // Several roles of one bill carry the same printed dates; heal each
      // distinct card/date once. Multiple cards can legitimately share a date.
      const key = `s:${last4 || userCardId || 'unmatched'}:${istDayKey(payload.statementDate)}`;
      if (!seenDates.has(key)) {
        seenDates.add(key);
        const sync = await importResolvers.syncStatementDayFromFact(client, userId, {
          statementDate: payload.statementDate,
          last4,
          patternIssuerId: null,
          explicitUserCardId: userCardId || null,
        });
        statementDayUpdated = statementDayUpdated || Boolean(sync?.updated);
      }
    }
    if (isCardBill && payload.dueDate) {
      const key = `d:${last4 || userCardId || 'unmatched'}:${istDayKey(payload.dueDate)}`;
      if (!seenDates.has(key)) {
        seenDates.add(key);
        const sync = await importResolvers.syncDueDayFromFact(client, userId, {
          dueDate: payload.dueDate,
          last4,
          patternIssuerId: null,
          explicitUserCardId: userCardId || null,
        });
        dueDayUpdated = dueDayUpdated || Boolean(sync?.updated);
      }
    }
  }
  return {
    statementDayUpdated,
    dueDayUpdated,
    mandatePersisted,
    ...centralProjectionResult,
  };
}

function registerSmsFactsRoutes(app, {
  requireAuth,
  requireAdmin = requireAuth,
  withUserClient,
  persistSubscriptionMandate,
}) {
  app.post('/sms/rule-exposures', requireAuth, async (req, res) => {
    const exposures = req.body?.exposures;
    if (!Array.isArray(exposures) || exposures.length < 1 || exposures.length > 100) {
      return res.status(400).json({ error: 'exposures must contain 1 to 100 items' });
    }
    for (const item of exposures) {
      if (!item || !CANDIDATE_ID.test(String(item.candidateId || '')) ||
          !HEX64.test(String(item.sourceKey || '')) ||
          !['shadow', 'limited', 'expanded', 'active'].includes(item.stage) ||
          !['accepted', 'review', 'ignored', 'unresolved'].includes(item.outcome || 'unresolved') ||
          (item.assignmentId !== undefined && !UUID.test(String(item.assignmentId))) ||
          (item.stageVersion !== undefined && (!Number.isInteger(item.stageVersion) || item.stageVersion < 1)) ||
          (item.deltaOutcome !== undefined && !EXPOSURE_DELTAS.has(item.deltaOutcome)) ||
          (item.baselineFamily !== undefined && (typeof item.baselineFamily !== 'string' || item.baselineFamily.length > 80)) ||
          (item.candidateFamily !== undefined && (typeof item.candidateFamily !== 'string' || item.candidateFamily.length > 80)) ||
          (item.baselineDisposition !== undefined && (typeof item.baselineDisposition !== 'string' || item.baselineDisposition.length > 80)) ||
          (item.candidateDisposition !== undefined && (typeof item.candidateDisposition !== 'string' || item.candidateDisposition.length > 80)) ||
          (item.exactFieldsEqual !== undefined && typeof item.exactFieldsEqual !== 'boolean') ||
          (item.factValid !== undefined && typeof item.factValid !== 'boolean') ||
          (item.invariantBreach !== undefined && typeof item.invariantBreach !== 'boolean')) {
        return res.status(400).json({ error: 'invalid rule exposure' });
      }
    }
    try {
      const recorded = await withUserClient(req.userId, async (client) => {
        if (!(await smsLearning.hasSmsSharedLearningConsent(client, req.userId))) {
          return { count: 0, consentEnabled: false };
        }
        let count = 0;
        for (const item of exposures) {
          // Exposure events are accepted only against a server issued
          // assignment epoch.  Missing assignments are treated as a stale
          // client event and acknowledged without recording it, so an old
          // device cannot forge a current cohort stage.
          if (!item.assignmentId || !item.stageVersion) continue;
          const write = await client.query(
            `INSERT INTO public.sms_rule_candidate_exposures
               (candidate_id, profile_id, source_key, stage, stage_version,
                assignment_id, assigned, matched, applied, outcome,
                delta_outcome, baseline_family, candidate_family,
                baseline_disposition, candidate_disposition, exact_fields_equal,
                fact_valid, invariant_breach)
             SELECT a.candidate_id, a.profile_id, $3, a.stage, a.stage_version,
                    a.assignment_id, true, $6, $7, $8,
                    $9, $10, $11, $12, $13, $14, $15, $16
               FROM public.sms_rule_candidate_assignments a
              WHERE a.assignment_id = $1
                AND a.profile_id = $2
                AND a.candidate_id = $4
                AND a.stage = $5
                AND a.stage_version = $17
                AND a.revoked_at IS NULL
             ON CONFLICT (candidate_id, profile_id, source_key, stage, stage_version)
             DO UPDATE SET matched = public.sms_rule_candidate_exposures.matched OR EXCLUDED.matched,
                           applied = public.sms_rule_candidate_exposures.applied OR EXCLUDED.applied,
                           outcome = CASE
                             WHEN public.sms_rule_candidate_exposures.outcome = 'unresolved'
                                  AND EXCLUDED.outcome <> 'unresolved' THEN EXCLUDED.outcome
                             ELSE public.sms_rule_candidate_exposures.outcome
                           END,
                           delta_outcome = COALESCE(public.sms_rule_candidate_exposures.delta_outcome, EXCLUDED.delta_outcome),
                           baseline_family = COALESCE(public.sms_rule_candidate_exposures.baseline_family, EXCLUDED.baseline_family),
                           candidate_family = COALESCE(public.sms_rule_candidate_exposures.candidate_family, EXCLUDED.candidate_family),
                           baseline_disposition = COALESCE(public.sms_rule_candidate_exposures.baseline_disposition, EXCLUDED.baseline_disposition),
                           candidate_disposition = COALESCE(public.sms_rule_candidate_exposures.candidate_disposition, EXCLUDED.candidate_disposition),
                           exact_fields_equal = COALESCE(public.sms_rule_candidate_exposures.exact_fields_equal, EXCLUDED.exact_fields_equal),
                           fact_valid = COALESCE(public.sms_rule_candidate_exposures.fact_valid, EXCLUDED.fact_valid),
                           invariant_breach = public.sms_rule_candidate_exposures.invariant_breach OR EXCLUDED.invariant_breach,
                           updated_at = now()`,
            [item.assignmentId, req.userId, item.sourceKey, item.candidateId, item.stage,
              Boolean(item.matched), Boolean(item.applied), item.outcome || 'unresolved',
              item.deltaOutcome || null, item.baselineFamily || null, item.candidateFamily || null,
              item.baselineDisposition || null, item.candidateDisposition || null,
              item.exactFieldsEqual === undefined ? null : item.exactFieldsEqual,
              item.factValid === undefined ? null : item.factValid,
              Boolean(item.invariantBreach), item.stageVersion],
          );
          count += write.rowCount || 0;
        }
        return { count, consentEnabled: true };
      });
      return res.status(200).json({ recorded: recorded.count, consentRequired: !recorded.consentEnabled });
    } catch (error) {
      console.error('POST /sms/rule-exposures error', safeErrorCode(error));
      return res.status(503).json({ error: 'rule exposure sync unavailable' });
    }
  });

  app.post('/sms/facts', requireAuth, async (req, res) => {
    const { sourceKey, sender, occurredAt, bodyHash, facts, userCardId } = req.body || {};
    if (typeof sourceKey !== 'string' || !HEX64.test(sourceKey)) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256' });
    }
    if (typeof bodyHash !== 'string' || !HEX64.test(bodyHash)) {
      return res.status(400).json({ error: 'bodyHash must be a hex sha256' });
    }
    if (!Array.isArray(facts) || facts.length === 0 || facts.length > 20) {
      return res.status(400).json({ error: 'facts must be a non-empty array (max 20)' });
    }
    const occurred = occurredAt === undefined ? null : new Date(occurredAt);
    if (occurred && Number.isNaN(occurred.getTime())) {
      return res.status(400).json({ error: 'occurredAt is not a valid date' });
    }

    const validation = smsFacts.validateFactSet(facts);
    if (!validation.valid) {
      // Abstain, never half-trust: the device drops invalid facts before
      // enqueue, so an invalid arrival is a contract bug worth a loud 400.
      return res.status(400).json({ error: 'invalid facts', details: validation.errors });
    }

    try {
      const result = await withUserClient(req.userId, async (client) => {
        const upsert = await smsFacts.upsertSmsSourceFacts(client, req.userId, {
          sender: typeof sender === 'string' ? sender : null,
          bodyHash,
          sourceKey,
          occurredAt: occurred,
          facts: facts.map((fact) => ({
            factType: fact.factType,
            payload: fact.payload,
            provenance: fact.provenance,
            status: fact.status,
          })),
        });

        const resolution = await smsFacts.loadSmsSourceFacts(client, req.userId, sourceKey);
        const specialists = await applyFactSpecialists(client, req.userId, resolution, {
          userCardId,
          occurred,
          persistSubscriptionMandate,
        });

        return {
          status: 200,
          sourceId: upsert.sourceId,
          factIds: upsert.factIds,
          replayed: upsert.replayed,
          ...specialists,
        };
      });
      res.status(result.status).json(result);
    } catch (error) {
      console.error('POST /sms/facts error', safeErrorCode(error));
      res.status(500).json({ error: 'sms facts upsert failed' });
    }
  });

  app.post('/sms/facts/overrides', requireAuth, async (req, res) => {
    const { sourceKey, factIndex, patch, reason, templateText, sampleBody } = req.body || {};
    if (typeof sourceKey !== 'string' || !HEX64.test(sourceKey)) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256' });
    }
    if (!Number.isInteger(factIndex) || factIndex < 0) {
      return res.status(400).json({ error: 'factIndex must be a non-negative integer' });
    }
    if (!plainObject(patch)) {
      return res.status(400).json({ error: 'patch must be an object' });
    }
    if (reason !== undefined && (typeof reason === 'string' ? reason.length > 200 : true)) {
      return res.status(400).json({ error: 'reason must be a short optional string' });
    }

    try {
      const result = await withUserClient(req.userId, async (client) => {
        const baseline = await smsFacts.loadSmsSourceFacts(client, req.userId, sourceKey);
        if (!baseline) {
          return { status: 404, error: 'unknown source' };
        }
        const target = baseline.facts.find((fact) => fact.factIndex === factIndex);
        if (!target) {
          return { status: 400, error: `no fact ${factIndex} on this source` };
        }
        // No fake success: the corrected payload must still satisfy the
        // contract, otherwise we refuse the override instead of applying a
        // half-trusted fact.
        const merged = smsFacts.resolveFactsWithOverrides({
          facts: baseline.facts,
          overrides: new Map([[factIndex, patch]]),
        });
        if (merged.errors.length > 0) {
          return { status: 400, error: 'override would produce invalid facts', details: merged.errors };
        }
        await smsFacts.writeSmsFactOverride(client, req.userId, {
          sourceId: baseline.sourceId,
          factIndex,
          patch,
          reason: typeof reason === 'string' ? reason : null,
        });
        await client.query(
          `UPDATE public.sms_rule_candidate_exposures
              SET correction = true, outcome = 'review', updated_at = now()
            WHERE profile_id = $1 AND source_key = $2
              AND EXISTS (SELECT 1 FROM public.user_consents c
                            WHERE c.profile_id = $1 AND c.purpose = 'sms_shared_learning'
                              AND c.granted
                              AND NOT EXISTS (SELECT 1 FROM public.user_consents newer
                                WHERE newer.profile_id = c.profile_id AND newer.purpose = c.purpose
                                  AND (newer.granted_at, newer.id) > (c.granted_at, c.id)))`,
          [req.userId, sourceKey],
        ).catch((error) => {
          // The exposure table is additive and may lag an API rollout. A
          // user's correction must remain successful without it.
          console.warn('SMS candidate correction telemetry skipped:', safeErrorCode(error));
        });
        // Re-resolve with the stored override (not the merged copy) so the
        // specialists consume exactly what future readers will see.
        const resolution = await smsFacts.loadSmsSourceFacts(client, req.userId, sourceKey);
        const corrected = resolution?.facts.find((fact) => fact.factIndex === factIndex);
        try {
          await smsLearning.recordConfirmedCorrection(client, {
            profileId: req.userId,
            sourceKey,
            sender: baseline.sender,
            family: target.factType,
            fields: smsLearning.changedSafeFields(target.payload, corrected?.payload),
          });
          // Also record structured learning example for autonomous learning
          if (baseline.sender) {
            await smsLearning.recordLearningExample(client, {
              profileId: req.userId,
              sender: baseline.sender,
              factFamily: target.factType,
              templateText,
              sampleBody,
              extractedFields: corrected?.payload || patch,
              isNegative: false,
            });
          }
        } catch (learningError) {
          // Learning is auxiliary. A learning-table outage must never undo
          // the user's correction or prevent the existing fact specialists.
          console.warn('SMS learning feedback skipped:', safeErrorCode(learningError));
        }
        const specialists = await applyFactSpecialists(client, req.userId, resolution, {
          userCardId: null,
          occurred: null,
          persistSubscriptionMandate,
        });
        return { status: 200, sourceId: baseline.sourceId, overridden: true, ...specialists };
      });
      res.status(result.status).json(result);
    } catch (error) {
      console.error('POST /sms/facts/overrides error', safeErrorCode(error));
      res.status(500).json({ error: 'override write failed' });
    }
  });

  app.post('/sms/dismiss', requireAuth, async (req, res) => {
    const { sourceKey, sender, sampleBody, templateText, reason } = req.body || {};
    const normalizedSourceKey = normalizeDismissalSourceKey(sourceKey);
    if (normalizedSourceKey === undefined) {
      return res.status(400).json({ error: 'sourceKey must be a hex sha256 when provided' });
    }
    if (sender !== undefined && (typeof sender !== 'string' || !sender.trim() || sender.length > 50)) {
      return res.status(400).json({ error: 'sender must be a string up to 50 chars' });
    }
    if (sampleBody !== undefined && (typeof sampleBody !== 'string' || sampleBody.length > 1201)) {
      return res.status(400).json({ error: 'sampleBody must be a string up to 1201 chars' });
    }
    if (templateText !== undefined && (typeof templateText !== 'string' || templateText.length > 1201)) {
      return res.status(400).json({ error: 'templateText must be a string up to 1201 chars' });
    }
    if (reason !== undefined && (typeof reason !== 'string' || reason.length > 200)) {
      return res.status(400).json({ error: 'reason must be a short optional string' });
    }
    // Older clients may still submit a credential-bearing message. A local
    // dismissal is valid, but this content must not enter shared learning or
    // an offline retry loop. Acknowledge it without persisting any evidence.
    if ([sampleBody, templateText].some(
      (value) => typeof value === 'string' && SENSITIVE_SMS_EVIDENCE.test(value),
    )) {
      return res.status(200).json({
        dismissed: true,
        sourceVerified: false,
        learningRecorded: false,
        learningReason: 'sensitive_sms',
      });
    }

    try {
      const outcome = await withUserClient(req.userId, async (client) => {
        let senderToUse = typeof sender === 'string' ? sender.trim() : null;
        let baseline = null;
        let sourceVerified = false;
        // Treat the client label as advisory only. A hard-negative financial
        // family is accepted only when the server can derive it from the
        // canonical source facts or a verified exposure record.
        let resolvedFamily = 'ignore_noise';
        if (normalizedSourceKey) {
          baseline = await smsFacts.loadSmsSourceFacts(client, req.userId, normalizedSourceKey);
          sourceVerified = Boolean(baseline);
          // A canonical sender belongs to the owned source. Never let a
          // request replace it before recording a server-derived negative.
          if (baseline?.sender) senderToUse = baseline.sender;

          // A key for an as-yet unsynced source can be checked when the body
          // is intact. Redacted bodies intentionally cannot reproduce the
          // original content hash and are accepted only as low-provenance
          // positive ignore evidence; they never create a source claim or a
          // hard negative. A mismatched unredacted key is an explicit foreign
          // or malformed ownership claim and remains rejected.
          if (!baseline && senderToUse && (sampleBody || templateText)) {
            const evidence = sampleBody || templateText;
            const expectedKey = importSourceKey(req.userId, senderToUse, evidence);
            if (expectedKey !== normalizedSourceKey && !containsLearningRedaction(evidence)) {
              return { status: 403, error: 'source_not_owned' };
            }
          }
          // The review screen deliberately sends the stable `ignore_noise`
          // label so older clients keep their wire contract. When the source
          // has a canonical fact, convert that fact to the suspected family
          // server-side and record hard-negative evidence for it in addition
          // to the positive ignore signal.
          if (baseline?.sender && resolvedFamily === 'ignore_noise') {
            const factFamily = (baseline.facts || [])
              .map((fact) => fact.factType)
              .find((value) => smsLearning.ALLOWED_FAMILIES.has(value) && value !== 'ignore_noise');
            if (factFamily) resolvedFamily = factFamily;
          }
          if (baseline?.sender && resolvedFamily === 'ignore_noise') {
            try {
              const exposureRows = await client.query(
                `SELECT candidate_family, baseline_family
                   FROM public.sms_rule_candidate_exposures
                  WHERE profile_id = $1 AND source_key = $2
                  ORDER BY updated_at DESC
                  LIMIT 20`,
                [req.userId, normalizedSourceKey],
              );
              const familyMap = {
                transaction: 'posted_movement',
                balance: 'balance_snapshot',
                bill: 'bill_obligation',
                autopay: 'mandate_lifecycle',
                failed: 'pending_or_failed_attempt',
              };
              const observed = (exposureRows.rows || [])
                .flatMap((row) => [row.candidate_family, row.baseline_family])
                .map((value) => familyMap[value] || value)
                .find((value) => smsLearning.ALLOWED_FAMILIES.has(value) && value !== 'ignore_noise');
              if (observed) resolvedFamily = observed;
            } catch (error) {
              console.warn('SMS dismissal family lookup skipped:', safeErrorCode(error));
            }
          }
        }

        if (!senderToUse) {
          return { status: 400, error: 'sender_required_when_source_unknown' };
        }

        if (sourceVerified) {
          await client.query(
            `UPDATE public.sms_rule_candidate_exposures
                SET false_discard = true, outcome = 'ignored', updated_at = now()
                WHERE profile_id = $1 AND source_key = $2
                  AND EXISTS (SELECT 1 FROM public.user_consents c
                                WHERE c.profile_id = $1 AND c.purpose = 'sms_shared_learning'
                                  AND c.granted
                                  AND NOT EXISTS (SELECT 1 FROM public.user_consents newer
                                    WHERE newer.profile_id = c.profile_id AND newer.purpose = c.purpose
                                      AND (newer.granted_at, newer.id) > (c.granted_at, c.id)))`,
            [req.userId, normalizedSourceKey],
          ).catch((error) => {
            console.warn('SMS candidate dismissal telemetry skipped:', safeErrorCode(error));
          });
        }

        if (!(await smsLearning.hasSmsSharedLearningConsent(client, req.userId))) {
          return {
            status: 200,
            dismissed: true,
            sourceVerified,
            learningRecorded: false,
            learningReason: 'consent_disabled',
          };
        }

        let learningOutcome = { recorded: 0 };
        try {
          if (sourceVerified) {
            learningOutcome = await smsLearning.recordReviewDismissal(client, {
              profileId: req.userId,
              sender: senderToUse,
              body: sampleBody || templateText || '',
              reason: reason || 'user_dismissed',
              family: resolvedFamily,
            });
          } else {
            const example = await smsLearning.recordLearningExample(client, {
              profileId: req.userId,
              sender: senderToUse,
              factFamily: 'ignore_noise',
              sampleBody: sampleBody || templateText || '',
              extractedFields: { feedbackProvenance: 'authenticated_unknown_source' },
              isNegative: false,
            });
            learningOutcome = {
              recorded: Number(example.recorded) || 0,
              disabled: example.disabled === true,
              errors: example.error ? [example.error] : [],
              examples: [example],
            };
          }
        } catch (learningError) {
          // Keep SQL details and message bodies off the client, while exposing
          // a stable code that makes a failed durable retry diagnosable.
          const code = /^[0-9A-Z]{5}$/.test(String(learningError.code || ''))
            ? learningError.code : 'unknown';
          const constraint = /^[a-zA-Z0-9_]{1,100}$/.test(String(learningError.constraint || ''))
            ? learningError.constraint : null;
          console.warn('SMS dismissal learning feedback skipped:', safeErrorCode(learningError));
          return { status: 503, error: 'dismissal_feedback_unavailable', learningReason: `database_${code}${constraint ? `_${constraint}` : ''}` };
        }

        const learningErrors = Array.isArray(learningOutcome?.errors)
          ? learningOutcome.errors.filter(Boolean)
          : (learningOutcome?.error ? [learningOutcome.error] : []);
        // An insert conflict means the same redacted example is already
        // durable. Any other zero-write result while consent is enabled must
        // remain retryable instead of silently dropping the user's signal.
        const durableOrDuplicate = learningErrors.length === 0 &&
          Array.isArray(learningOutcome?.examples) && learningOutcome.examples.length > 0;
        if (!(learningOutcome?.recorded > 0) && !durableOrDuplicate) {
          return {
            status: 503,
            error: 'dismissal_feedback_unavailable',
            learningReason: learningErrors[0] || 'not_recorded',
          };
        }

        return {
          status: 200,
          dismissed: true,
          sourceVerified,
          learningRecorded: Boolean(learningOutcome && learningOutcome.recorded > 0),
          learningReason: learningOutcome?.recorded > 0 ? null : 'already_recorded',
        };
      });
      res.status(outcome.status).json(outcome);
    } catch (error) {
      console.error('POST /sms/dismiss error', safeErrorCode(error));
      res.status(500).json({ error: 'dismissal record failed' });
    }
  });

  app.post('/admin/sms-learning/cycle', requireAdmin, async (req, res) => {
    // Publishing requires the dedicated worker role and its cross-user RLS
    // capability. An admin API request runs as app_user and must never start
    // part of a cycle that can fail later at the publication boundary.
    res.status(409).json({ error: 'autonomous_cycle_is_worker_only' });
  });

  smsLearning.registerSmsLearningAdminRoutes(app, { requireAdmin, withUserClient });
  smsRuleBundle.registerSmsRuleBundleRoutes(app, { requireAuth, requireAdmin, withUserClient });
}

module.exports = { registerSmsFactsRoutes, applyFactSpecialists };
