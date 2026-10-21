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
 */

const smsFacts = require('./sms_facts');
const importResolvers = require('./import_resolvers');
const smsLearning = require('./sms_learning');
const smsRuleBundle = require('./sms_rule_bundle');

const HEX64 = /^[0-9a-f]{64}$/;

function plainObject(value) {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
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
  let statementDayUpdated = false;
  let dueDayUpdated = false;
  let mandatePersisted = false;
  const seenDates = new Set();
  for (const fact of resolution.facts) {
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
    if (payload.statementDate) {
      // Several roles of one bill carry the same printed dates; heal each
      // distinct date once.
      const key = `s${istDayKey(payload.statementDate)}`;
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
    if (payload.dueDate) {
      const key = `d${istDayKey(payload.dueDate)}`;
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
  return { statementDayUpdated, dueDayUpdated, mandatePersisted };
}

function registerSmsFactsRoutes(app, {
  requireAuth,
  requireAdmin = requireAuth,
  withUserClient,
  persistSubscriptionMandate,
}) {
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
      console.error('POST /sms/facts error', error.message || error);
      res.status(500).json({ error: 'sms facts upsert failed' });
    }
  });

  app.post('/sms/facts/overrides', requireAuth, async (req, res) => {
    const { sourceKey, factIndex, patch, reason } = req.body || {};
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
        } catch (learningError) {
          // Learning is auxiliary. A learning-table outage must never undo
          // the user's correction or prevent the existing fact specialists.
          console.warn('SMS learning feedback skipped:', learningError.message || learningError);
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
      console.error('POST /sms/facts/overrides error', error.message || error);
      res.status(500).json({ error: 'override write failed' });
    }
  });

  smsLearning.registerSmsLearningAdminRoutes(app, { requireAdmin, withUserClient });
  smsRuleBundle.registerSmsRuleBundleRoutes(app, { requireAuth, requireAdmin, withUserClient });
}

module.exports = { registerSmsFactsRoutes, applyFactSpecialists };
