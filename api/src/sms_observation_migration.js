/**
 * SMS intelligence Phase 7: Historical observation dry-run, shadow comparison,
 * staged feature-flag rollout, and rollback verification.
 *
 * Guarantees:
 * 1. Zero source key changes: historical observations keep their exact
 *    legacy source_key and body hash so existing receipts and dedup keys
 *    are never invalidated.
 * 2. Multi-fact projection separation: non-spend observations (balance,
 *    mandate, bill, alert) never inflate spend totals.
 * 3. User override preservation: fact_overrides are never touched or
 *    dropped by backfill or rollback.
 * 4. Staged rollout: deterministic per-profile feature flag percentage hashing
 *    per message family without cross-user leakage.
 * 5. Safe rollback: disabling feature flags restores legacy behavior while
 *    preserving all facts and overrides for future re-enablement.
 */

const crypto = require('crypto');
const smsFacts = require('./sms_facts');

/**
 * Maps a legacy parsed observation into canonical typed facts.
 * Pure mapping function; leaves persistence to upsertSmsSourceFacts.
 */
function extractFactsFromObservation(obs) {
  const parsed = obs.parsed || obs.parsed_data || {};
  const occurredAt = obs.occurredAt || obs.occurred_at || new Date().toISOString();
  const facts = [];

  // 1. Posted movement (spend, income, transfer)
  if (
    parsed.amountInr != null &&
    parsed.amountInr > 0 &&
    (parsed.entryKind === 'spend' || parsed.entryKind === 'income' || parsed.entryKind === 'transfer')
  ) {
    const payload = {
      amountRole: 'posted',
      entryKind: parsed.entryKind,
      amountInr: Number(parsed.amountInr),
      occurredAt,
    };
    if (parsed.merchant) payload.merchant = String(parsed.merchant).trim();
    if (parsed.last4) payload.last4 = String(parsed.last4);
    if (parsed.accountLast4) payload.accountLast4 = String(parsed.accountLast4);
    if (parsed.instrument) payload.instrument = parsed.instrument;
    if (parsed.reference) payload.reference = String(parsed.reference);
    if (parsed.transferParty) payload.transferParty = String(parsed.transferParty);
    if (parsed.entryKind !== 'spend' || payload.merchant) {
      facts.push({
        factType: 'posted_movement',
        payload,
        provenance: { source: 'observation_migration', version: 1 },
      });
    }
  }

  // 2. Balance snapshot
  if (parsed.availableBalanceInr != null && Number(parsed.availableBalanceInr) >= 0) {
    const payload = {
      availableBalanceInr: Number(parsed.availableBalanceInr),
      asOfAt: occurredAt,
    };
    if (parsed.accountLast4) payload.accountLast4 = String(parsed.accountLast4);
    if (parsed.last4) payload.last4 = String(parsed.last4);
    if (parsed.issuerName) payload.issuerName = String(parsed.issuerName);
    facts.push({
      factType: 'balance_snapshot',
      payload,
      provenance: { source: 'observation_migration', version: 1 },
    });
  }

  // 3. Bill obligations (role separated: due_total and due_minimum)
  if (parsed.amountDueInr != null && Number(parsed.amountDueInr) > 0 && parsed.dueDate) {
    const payload = {
      amountRole: 'due_total',
      amountDueInr: Number(parsed.amountDueInr),
      dueDate: parsed.dueDate,
    };
    if (parsed.statementDate) payload.statementDate = parsed.statementDate;
    if (parsed.last4) payload.last4 = String(parsed.last4);
    if (parsed.billerName) payload.billerName = String(parsed.billerName);
    facts.push({
      factType: 'bill_obligation',
      payload,
      provenance: { source: 'observation_migration', version: 1 },
    });
  }
  if (parsed.minimumDueInr != null && Number(parsed.minimumDueInr) > 0 && parsed.dueDate) {
    const payload = {
      amountRole: 'due_minimum',
      minimumDueInr: Number(parsed.minimumDueInr),
      dueDate: parsed.dueDate,
    };
    if (parsed.statementDate) payload.statementDate = parsed.statementDate;
    if (parsed.last4) payload.last4 = String(parsed.last4);
    if (parsed.billerName) payload.billerName = String(parsed.billerName);
    facts.push({
      factType: 'bill_obligation',
      payload,
      provenance: { source: 'observation_migration', version: 1 },
    });
  }

  // 4. Mandate lifecycle
  if (parsed.mandateStatus != null) {
    const payload = {
      mandateStatus: parsed.mandateStatus,
      asOfAt: occurredAt,
    };
    if (parsed.limitInr != null) payload.limitInr = Number(parsed.limitInr);
    if (parsed.merchant) payload.merchant = String(parsed.merchant);
    if (parsed.last4) payload.last4 = String(parsed.last4);
    if (parsed.instrument) payload.instrument = parsed.instrument;
    // registered mandate requires limitInr
    if (parsed.mandateStatus !== 'registered' || payload.limitInr != null) {
      facts.push({
        factType: 'mandate_lifecycle',
        payload,
        provenance: { source: 'observation_migration', version: 1 },
      });
    }
  }

  // 5. Pending / failed attempts
  if (parsed.attemptStatus != null) {
    const payload = {
      attemptStatus: parsed.attemptStatus,
      occurredAt,
    };
    if (parsed.merchant) payload.merchant = String(parsed.merchant);
    if (parsed.last4) payload.last4 = String(parsed.last4);
    facts.push({
      factType: 'pending_or_failed_attempt',
      payload,
      provenance: { source: 'observation_migration', version: 1 },
    });
  }

  // 6. Security or service alert
  if (parsed.alertKind != null) {
    const payload = {
      alertKind: parsed.alertKind,
      occurredAt,
    };
    facts.push({
      factType: 'security_or_service_alert',
      payload,
      provenance: { source: 'observation_migration', version: 1 },
    });
  }

  return facts;
}

/**
 * Compares projections for a single observation under legacy vs new fact models.
 */
function compareObservationProjections(obs) {
  const parsed = obs.parsed || obs.parsed_data || {};
  const facts = extractFactsFromObservation(obs);
  const validation = smsFacts.validateFactSet(facts);

  // Legacy projection: treated any observation with amountInr as spend
  let legacySpendInr = 0;
  if (parsed.amountInr != null && !parsed.alertKind && parsed.mandateStatus == null) {
    legacySpendInr = Number(parsed.amountInr) || 0;
  }

  // New projection: only posted_movement with entryKind === 'spend' posts money
  let newSpendInr = 0;
  for (const fact of facts) {
    if (fact.factType === 'posted_movement' && fact.payload?.entryKind === 'spend') {
      newSpendInr += fact.payload.amountInr || 0;
    }
  }

  const nonSpendFacts = facts.filter(
    (f) => f.factType !== 'posted_movement' || f.payload?.entryKind !== 'spend',
  );

  const delta = {
    sourceKey: obs.sourceKey || obs.source_key,
    legacySpendInr,
    newSpendInr,
    spendDifferenceInr: legacySpendInr - newSpendInr,
    factsProduced: facts.length,
    nonSpendFactsCount: nonSpendFacts.length,
    nonSpendTypes: nonSpendFacts.map((f) => f.factType),
    valid: validation.valid,
    validationErrors: validation.errors,
  };

  return {
    sourceKey: delta.sourceKey,
    facts,
    delta,
    isEqualSpend: Math.abs(legacySpendInr - newSpendInr) < 0.001,
    hasNewNonSpendFacts: nonSpendFacts.length > 0,
  };
}

/**
 * Runs a dry-run comparison over a batch of historical observations.
 */
function dryRunObservations(observations = []) {
  let totalLegacySpendInr = 0;
  let totalNewSpendInr = 0;
  let equalSpendCount = 0;
  let spendReductionCount = 0;
  let nonSpendFactsCount = 0;
  let invalidCount = 0;
  const deltas = [];

  for (const obs of observations) {
    const comparison = compareObservationProjections(obs);
    totalLegacySpendInr += comparison.delta.legacySpendInr;
    totalNewSpendInr += comparison.delta.newSpendInr;
    if (comparison.isEqualSpend) {
      equalSpendCount++;
    } else if (comparison.delta.spendDifferenceInr > 0) {
      spendReductionCount++;
    }
    nonSpendFactsCount += comparison.delta.nonSpendFactsCount;
    if (!comparison.delta.valid) {
      invalidCount++;
    }
    deltas.push(comparison.delta);
  }

  return {
    totalObservations: observations.length,
    totalLegacySpendInr: Math.round(totalLegacySpendInr * 100) / 100,
    totalNewSpendInr: Math.round(totalNewSpendInr * 100) / 100,
    netSpendDifferenceInr: Math.round((totalLegacySpendInr - totalNewSpendInr) * 100) / 100,
    equalSpendCount,
    spendReductionCount,
    nonSpendFactsExtracted: nonSpendFactsCount,
    invalidFactSetsCount: invalidCount,
    deltas,
  };
}

/**
 * Deterministic user bucket calculation for percentage rollouts (0-99).
 */
function hashProfileBucket(profileId, flagKey) {
  const hash = crypto
    .createHash('sha256')
    .update(`${String(profileId).toLowerCase()}:${String(flagKey).toLowerCase()}`)
    .digest();
  return hash.readUInt16BE(0) % 100;
}

/**
 * Evaluates whether a feature flag is active for a given profile.
 */
function evaluateFeatureFlag(flagConfig, profileId) {
  if (!flagConfig) return false;
  if (!flagConfig.is_enabled) return false;
  const percent = Number.isInteger(flagConfig.rollout_percent) ? flagConfig.rollout_percent : 100;
  if (percent >= 100) return true;
  if (percent <= 0) return false;
  if (!profileId) return false;
  const bucket = hashProfileBucket(profileId, flagConfig.key);
  return bucket < percent;
}

/**
 * Maps a list of feature flag rows to the SMS intelligence pipeline capabilities.
 */
function resolveSmsIntelligenceFlags(flagRows = [], profileId = null) {
  const flagsByKey = new Map((flagRows || []).map((row) => [row.key, row]));

  const masterFlag = flagsByKey.get('sms_facts_pipeline_enabled') || {
    key: 'sms_facts_pipeline_enabled',
    is_enabled: true,
    rollout_percent: 100,
  };

  const isMasterActive = evaluateFeatureFlag(masterFlag, profileId);
  if (!isMasterActive) {
    return {
      masterEnabled: false,
      spendFamilyEnabled: false,
      balanceFamilyEnabled: false,
      billFamilyEnabled: false,
      mandateFamilyEnabled: false,
      aiQueueEnabled: false,
    };
  }

  const check = (key, defaultEnabled = true) => {
    const flag = flagsByKey.get(key) || { key, is_enabled: defaultEnabled, rollout_percent: 100 };
    return evaluateFeatureFlag(flag, profileId);
  };

  return {
    masterEnabled: true,
    spendFamilyEnabled: check('sms_family_spend_enabled', true),
    balanceFamilyEnabled: check('sms_family_balance_enabled', true),
    billFamilyEnabled: check('sms_family_bill_enabled', true),
    mandateFamilyEnabled: check('sms_family_mandate_enabled', true),
    // Fail closed when rollout has not explicitly been configured. AI requests
    // contain sensitive message content and must never be enabled by absence.
    aiQueueEnabled: check('sms_ai_queue_enabled', false),
  };
}

/**
 * Idempotently backfills historical observations into sms_sources & sms_source_facts.
 * In dryRun mode, returns planned backfill metrics without writing to DB.
 */
async function backfillHistoricalObservations(
  client,
  profileId,
  { observations = [], dryRun = true },
) {
  const dryRunReport = dryRunObservations(observations);
  if (dryRun) {
    return {
      dryRun: true,
      report: dryRunReport,
      plannedSourcesCount: observations.length,
      plannedFactsCount: dryRunReport.deltas.reduce((acc, d) => acc + d.factsProduced, 0),
    };
  }

  // Live backfill within client transaction
  let migratedSources = 0;
  let replayedSources = 0;
  let migratedFacts = 0;

  for (const obs of observations) {
    const facts = extractFactsFromObservation(obs);
    if (facts.length === 0) continue;
    const validation = smsFacts.validateFactSet(facts);
    if (!validation.valid) continue;

    const sourceKey = obs.sourceKey || obs.source_key;
    const sender = obs.sender || null;
    const bodyHash = obs.bodyHash || obs.body_hash || crypto.createHash('sha256').update(sourceKey).digest('hex');
    const occurredAt = obs.occurredAt || obs.occurred_at ? new Date(obs.occurredAt || obs.occurred_at) : null;

    const result = await smsFacts.upsertSmsSourceFacts(client, profileId, {
      sender,
      bodyHash,
      sourceKey,
      facts,
      occurredAt,
      channel: 'sms',
    });

    if (result.replayed) {
      replayedSources++;
    } else {
      migratedSources++;
    }
    migratedFacts += result.factIds.length;
  }

  return {
    dryRun: false,
    report: dryRunReport,
    migratedSources,
    replayedSources,
    migratedFacts,
  };
}

module.exports = {
  extractFactsFromObservation,
  compareObservationProjections,
  dryRunObservations,
  hashProfileBucket,
  evaluateFeatureFlag,
  resolveSmsIntelligenceFlags,
  backfillHistoricalObservations,
};
