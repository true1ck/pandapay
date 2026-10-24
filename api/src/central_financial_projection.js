/**
 * Central, additive projections for typed SMS facts.
 *
 * Facts are evidence. This module turns the evidence into small, independently
 * addressable domain decisions without creating transactions. In particular,
 * a mandate ceiling is kept on the mandate projection and can never become a
 * posted amount or a subscription price.
 */

const { brandFor } = require('./brand_catalog');

const PROJECTION_VERSION = 1;

const PROJECTION_KINDS = Object.freeze([
  'movement',
  'account_observation',
  'bill_obligation',
  'bill_payment',
  'mandate',
  'subscription',
]);

const MANDATE_TARGET_KINDS = Object.freeze([
  'card_bill',
  'utility_or_other_bill',
  'service_merchant',
  'unknown',
]);

const MANDATE_STATUSES = Object.freeze({
  registered: 'active',
  scheduled: 'active',
  paused: 'paused',
  cancelled: 'cancelled',
  failed: 'payment_issue',
});

const SUBSCRIPTION_STATUSES = new Set([
  'candidate', 'active', 'renewal_unverified', 'ended', 'payment_issue',
  'cancelled', 'paused', 'unknown',
]);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function object(value) {
  return value && typeof value === 'object' && !Array.isArray(value) ? value : {};
}

function finiteNumber(value, { positive = false, nonnegative = false } = {}) {
  // Number(null) is zero. A missing SMS amount must stay missing, especially
  // when the value is later used as a subscription price.
  if (value === null || value === undefined || value === '' || !Number.isFinite(value)) return null;
  if (positive && value <= 0) return null;
  if (nonnegative && value < 0) return null;
  return value;
}

function normalizeIdentity(value) {
  return String(value || '')
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function dateOnly(value) {
  if (!value) return null;
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString().slice(0, 10);
}

function factPayload(fact) {
  return object(fact?.payload);
}

function factIdOf(fact) {
  return fact?.id || null;
}

function explicitSubscription(payload) {
  return payload.explicitSubscription === true ||
    payload.userAsserted === true ||
    ['explicit', 'user_asserted'].includes(payload.subscriptionEvidence);
}

function serviceName(payload) {
  return payload.serviceName || payload.merchant || payload.billerName || null;
}

function mandateTargetKind(payload) {
  if (MANDATE_TARGET_KINDS.includes(payload.targetKind)) return payload.targetKind;
  if (payload.cardBill === true || payload.targetKind === 'card_bill') return 'card_bill';
  if (payload.billerName && !payload.merchant) return 'utility_or_other_bill';
  if (payload.merchant || payload.serviceName) return 'service_merchant';
  return 'unknown';
}

function mandateKey(payload) {
  const reference = payload.mandateReference || payload.reference;
  if (reference) return `reference:${normalizeIdentity(reference)}`;
  const merchant = normalizeIdentity(payload.merchant || payload.serviceName || payload.billerName);
  const target = mandateTargetKind(payload);
  const card = payload.last4 ? `:card${payload.last4}` : '';
  return `target:${target}:${merchant || 'unknown'}${card}`;
}

function billLikeMandate(payload, targetKind) {
  if (targetKind === 'card_bill' || targetKind === 'utility_or_other_bill' || payload.cardBill === true) return true;
  const labels = [payload.merchant, payload.serviceName, payload.billerName].filter(Boolean).join(' ');
  return /\b(?:credit\s*card|card)\s*bill\b|\bbill\s*(?:payment|statement|due)\b/i.test(labels);
}

function subscriptionKey(payload) {
  const rawService = serviceName(payload);
  const service = normalizeIdentity(brandFor(rawService)?.name || rawService);
  if (!service) return null;
  const plan = normalizeIdentity(payload.planName || payload.plan || '');
  return `service:${service}${plan ? `:plan${plan}` : ''}`;
}

function knownSubscriptionMerchant(payload) {
  // A mandate's merchant field is only a service-presence signal when the
  // catalog recognizes it. Generic merchants can authorize recurring card
  // debits too, but that does not establish a subscription on its own.
  return Boolean(brandFor(serviceName(payload)));
}

function legacyMandateSetupRow(row) {
  const detectionSource = row?.detectionSource ?? row?.detection_source;
  if (detectionSource !== 'mandate') return null;
  const displayName = String(row?.displayName ?? row?.display_name ?? '').trim();
  const brand = brandFor(displayName);
  if (!brand || billLikeMandate({ merchant: displayName }, 'unknown') ||
      /\b(?:utility|electricity|water|gas|broadband|telecom|recharge|postpaid|prepaid|fiber|internet)\b/i.test(displayName)) {
    return null;
  }
  return {
    ...row,
    __legacyMandateSetup: true,
    display_name: brand.name,
    typical_amount_inr: null,
    cadence_days: null,
    occurrence_count: 0,
    first_seen_on: null,
    last_seen_on: null,
    next_expected_on: null,
  };
}

function sourceEvidence(fact, sourceId, sourceKey) {
  return {
    sourceId: sourceId || null,
    sourceKey: sourceKey || null,
    factId: factIdOf(fact),
    factIndex: Number.isInteger(fact?.factIndex) ? fact.factIndex : null,
    factType: fact?.factType || null,
  };
}

function decision(kind, key, status, data, fact, sourceId, sourceKey) {
  return {
    projectionKind: kind,
    projectionKey: key,
    status,
    data: { ...data, evidence: sourceEvidence(fact, sourceId, sourceKey) },
    sourceId: sourceId || null,
    sourceKey: sourceKey || null,
    factIds: factIdOf(fact) ? [factIdOf(fact)] : [],
  };
}

function movementDecision(fact, sourceId, sourceKey) {
  const payload = factPayload(fact);
  const amount = finiteNumber(payload.amountInr, { positive: true });
  if (payload.amountRole !== 'posted' || amount === null) return null;
  const merchant = serviceName(payload);
  return decision('movement', `fact:${factIdOf(fact) || fact.factIndex}`, 'posted', {
    amountRole: 'posted',
    amountInr: amount,
    entryKind: payload.entryKind || null,
    merchant: merchant || null,
    instrument: payload.instrument || null,
    occurredAt: payload.occurredAt || null,
  }, fact, sourceId, sourceKey);
}

function accountDecision(fact, sourceId, sourceKey) {
  const payload = factPayload(fact);
  const balance = finiteNumber(payload.availableBalanceInr, { nonnegative: true });
  if (balance === null || !payload.asOfAt) return null;
  const account = payload.accountLast4 ? `account:${payload.accountLast4}` : 'account:unknown';
  return decision('account_observation', `${account}:${dateOnly(payload.asOfAt) || 'unknown'}`, 'observed', {
    availableBalanceInr: balance,
    asOfAt: payload.asOfAt,
    accountLast4: payload.accountLast4 || null,
  }, fact, sourceId, sourceKey);
}

function billDecision(fact, sourceId, sourceKey) {
  const payload = factPayload(fact);
  const amountRole = payload.amountRole;
  const amountField = amountRole === 'due_total' ? 'amountDueInr' :
    amountRole === 'due_minimum' ? 'minimumDueInr' :
      amountRole === 'outstanding' ? 'outstandingInr' : null;
  const amount = amountField ? finiteNumber(payload[amountField], { positive: true }) : null;
  if (!amountField || amount === null || (!payload.dueDate && amountRole !== 'outstanding')) return null;
  const biller = normalizeIdentity(payload.billerName || payload.merchant) || 'unknown';
  const card = payload.last4 ? `:card${payload.last4}` : '';
  const date = dateOnly(payload.statementDate || payload.dueDate || payload.asOfAt) || 'unknown';
  return decision('bill_obligation', `bill:${biller}${card}:${date}:${amountRole}`, 'open', {
    amountRole,
    amountInr: amount,
    dueDate: payload.dueDate || null,
    statementDate: payload.statementDate || null,
    billerName: payload.billerName || payload.merchant || null,
    last4: payload.last4 || null,
  }, fact, sourceId, sourceKey);
}

function billPaymentDecision(fact, sourceId, sourceKey) {
  const payload = factPayload(fact);
  const amount = finiteNumber(payload.amountInr, { positive: true });
  if (payload.amountRole !== 'posted' || amount === null) return null;
  const ref = normalizeIdentity(payload.reference) || `fact${factIdOf(fact) || fact.factIndex}`;
  return decision('bill_payment', `payment:${ref}`, 'posted', {
    amountRole: 'posted', amountInr: amount,
    occurredAt: payload.occurredAt || null, last4: payload.last4 || null,
  }, fact, sourceId, sourceKey);
}

function mandateDecision(fact, sourceId, sourceKey) {
  const payload = factPayload(fact);
  if (!payload.mandateStatus) return null;
  const targetKind = mandateTargetKind(payload);
  const data = {
    targetKind,
    lifecycle: payload.mandateStatus,
    authorizationLimitInr: finiteNumber(payload.limitInr, { positive: true }),
    activationAmountInr: finiteNumber(payload.activationAmountInr, { nonnegative: true }),
    instrument: payload.instrument || null,
    last4: payload.last4 || null,
    merchant: payload.merchant || payload.serviceName || null,
    billerName: payload.billerName || null,
    mandateReference: payload.mandateReference || payload.reference || null,
    asOfAt: payload.asOfAt || null,
  };
  return decision('mandate', `mandate:${mandateKey(payload)}`, MANDATE_STATUSES[payload.mandateStatus] || 'unknown', data, fact, sourceId, sourceKey);
}

function subscriptionDecision(fact, sourceId, sourceKey, { fromMandate = false } = {}) {
  const payload = factPayload(fact);
  const key = subscriptionKey(payload);
  const targetKind = fromMandate ? mandateTargetKind(payload) : null;
  const mandateSetup = fromMandate && targetKind === 'service_merchant' &&
    knownSubscriptionMerchant(payload) && !explicitSubscription(payload);
  // A merchant debit is not a subscription by itself. A named service
  // merchant mandate is the one setup exception: it establishes presence but
  // carries no paid amount, renewal, or due-date claim. Card-bill and utility
  // mandates remain mandate-only records.
  if (!key || (fromMandate && billLikeMandate(payload, targetKind)) ||
      (!explicitSubscription(payload) && !mandateSetup)) return null;
  const renewalMode = !mandateSetup && ['one_time', 'automatic', 'manual', 'unknown'].includes(payload.renewalMode)
    ? payload.renewalMode : 'unknown';
  const statedAmount = mandateSetup ? null : finiteNumber(payload.nextPaymentAmountInr, { nonnegative: true });
  const postedAmount = finiteNumber(payload.amountInr, { positive: true });
  const hasLifecycle = payload.subscriptionStatus !== null && payload.subscriptionStatus !== undefined;
  const lifecycle = hasLifecycle ? String(payload.subscriptionStatus).trim().toLowerCase() : null;
  const mandateLifecycle = fromMandate ? MANDATE_STATUSES[payload.mandateStatus] || 'unknown' : null;
  const status = mandateSetup
    ? (['active', 'paused', 'cancelled', 'payment_issue'].includes(mandateLifecycle)
      ? mandateLifecycle === 'active' ? 'candidate' : mandateLifecycle
      : 'unknown')
    : SUBSCRIPTION_STATUSES.has(lifecycle)
      ? lifecycle
      : (hasLifecycle ? 'unknown' : (fromMandate ? mandateLifecycle : 'active'));
  const posted = fact.factType === 'posted_movement' && payload.amountRole === 'posted' && postedAmount !== null
    ? { amountInr: postedAmount, occurredAt: payload.occurredAt || null }
    : null;
  return decision('subscription', key, status, {
    serviceName: serviceName(payload),
    planName: payload.planName || payload.plan || null,
    explicitSubscription: explicitSubscription(payload),
    // A named service AutoPay authorization establishes service presence, but
    // it does not establish a paid amount, cadence, or renewal date.
    setupConfirmed: mandateSetup,
    subscriptionEvidence: mandateSetup ? 'mandate_authorization' : (payload.subscriptionEvidence || null),
    renewalMode,
    cadenceDays: mandateSetup ? null : (Number.isInteger(payload.cadenceDays) && payload.cadenceDays > 0 ? payload.cadenceDays : null),
    cadenceExplicit: mandateSetup ? false : payload.cadenceExplicit === true,
    accessEndDate: mandateSetup ? null : (payload.accessEndDate || null),
    lastPostedPayment: posted,
    statedNextPaymentDate: mandateSetup ? null : (payload.nextPaymentDate || null),
    statedNextPaymentAmountInr: statedAmount,
    estimatedNextPaymentDate: null,
    estimatedNextPaymentAmountInr: null,
    lifecycleReason: mandateSetup
      ? 'mandate_authorization_setup'
      : fromMandate ? 'explicit_subscription_evidence' : 'posted_or_explicit_fact',
    mandateKey: fromMandate ? `mandate:${mandateKey(payload)}` : null,
  }, fact, sourceId, sourceKey);
}

function projectionIdentity(item) {
  return `${item.projectionKind}\u0000${item.projectionKey}`;
}

/**
 * One source can contain a mandate, a service alert, and a posted payment for
 * the same service. They are separate facts but one materialized subscription
 * row. Keep the latest non-null values and retain all fact IDs for replay and
 * correction reconciliation.
 */
function coalesceDecisions(decisions) {
  const byKey = new Map();
  for (const item of decisions) {
    const key = projectionIdentity(item);
    const previous = byKey.get(key);
    if (!previous) {
      byKey.set(key, {
        ...item,
        factIds: [...new Set(item.factIds || [])],
        data: { ...item.data },
      });
      continue;
    }
    const previousEvidence = previous.data?.evidence;
    const currentEvidence = item.data?.evidence;
    const evidenceSources = [
      ...(previous.data?.evidenceSources || (previousEvidence ? [previousEvidence] : [])),
      ...(currentEvidence ? [currentEvidence] : []),
    ];
    const data = { ...previous.data, ...item.data };
    // A later fact without a payment/date must not erase one already observed
    // in this source. Null still represents unknown when no earlier value is
    // available.
    for (const field of [
      'lastPostedPayment', 'statedNextPaymentDate', 'statedNextPaymentAmountInr',
      'estimatedNextPaymentDate', 'estimatedNextPaymentAmountInr', 'mandateKey',
    ]) {
      if ((item.data?.[field] === null || item.data?.[field] === undefined) &&
          previous.data?.[field] !== null && previous.data?.[field] !== undefined) {
        data[field] = previous.data[field];
      }
    }
    if (evidenceSources.length > 1) data.evidenceSources = evidenceSources;
    byKey.set(key, {
      ...previous,
      ...item,
      data,
      factIds: [...new Set([...(previous.factIds || []), ...(item.factIds || [])])],
    });
  }
  return [...byKey.values()];
}

/**
 * Builds decisions without database access. This is intentionally conservative:
 * card-bill and utility mandates remain mandate-only; a named service mandate
 * yields an unpriced setup candidate.
 */
function buildProjectionDecisions({ facts = [], sourceId = null, sourceKey = null } = {}) {
  const decisions = [];
  for (const fact of facts) {
    if (!fact || fact.status === 'superseded' || fact.status === 'discarded') continue;
    // The same builder serves live intake and read-time backfill. Neither may
    // materialize a review-only AI suggestion before a user confirms it.
    if (fact.provenance?.channel === 'ai' && !fact.overridden) continue;
    let projected = null;
    if (fact.factType === 'posted_movement') {
      projected = movementDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
      const subscription = subscriptionDecision(fact, sourceId, sourceKey);
      if (subscription) decisions.push(subscription);
    } else if (fact.factType === 'balance_snapshot') {
      projected = accountDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
    } else if (fact.factType === 'bill_obligation') {
      projected = billDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
    } else if (fact.factType === 'bill_payment') {
      projected = billPaymentDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
    } else if (fact.factType === 'mandate_lifecycle') {
      projected = mandateDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
      const subscription = subscriptionDecision(fact, sourceId, sourceKey, { fromMandate: true });
      if (subscription) decisions.push(subscription);
    } else if (fact.factType === 'security_or_service_alert' && explicitSubscription(factPayload(fact))) {
      projected = subscriptionDecision(fact, sourceId, sourceKey);
      if (projected) decisions.push(projected);
    }
  }
  return decisions;
}

async function persistFinancialProjections(client, profileId, {
  sourceId = null, sourceKey = null, facts = [],
} = {}) {
  const decisions = coalesceDecisions(
    buildProjectionDecisions({ facts, sourceId, sourceKey }),
  );
  const currentKeys = new Set(decisions.map(projectionIdentity));
  // A correction can change the merchant or service identity. Remove only
  // rows last materialized from this source, leaving projections that have
  // since been refreshed by another source untouched.
  const reconciliationColumn = sourceId ? 'source_id' : sourceKey ? 'source_key' : null;
  const reconciliationValue = sourceId || sourceKey || null;
  if (reconciliationColumn) {
    const prior = await client.query(
      `SELECT projection_kind, projection_key, source_fact_ids
         FROM financial_projections
        WHERE profile_id = $1 AND ${reconciliationColumn} = $2`,
      [profileId, reconciliationValue],
    );
    // A stable domain key can be supported by more than one SMS source. The
    // upsert keeps the first source_id as the row's primary lineage while
    // accumulating every valid fact id. Before removing a row during source
    // replay, resolve those fact ids back to their source owners so replaying
    // source A cannot delete a subscription still evidenced by source B.
    const priorFactIds = [...new Set((prior.rows || [])
      .flatMap((row) => Array.isArray(row.source_fact_ids) ? row.source_fact_ids : [])
      .filter((id) => UUID.test(String(id))))];
    const factSourceRows = priorFactIds.length && sourceId
      ? await client.query(
        `SELECT id, source_id
           FROM sms_source_facts
          WHERE profile_id = $1 AND id = ANY($2::uuid[])`,
        [profileId, priorFactIds],
      )
      : { rows: [] };
    const factSourceById = new Map((factSourceRows.rows || [])
      .map((row) => [String(row.id), String(row.source_id)]));
    for (const row of prior.rows || []) {
      const key = `${row.projection_kind}\u0000${row.projection_key}`;
      const hasOtherSourceEvidence = sourceId && (Array.isArray(row.source_fact_ids)
        ? row.source_fact_ids
        : [])
        .some((factId) => {
          const owner = factSourceById.get(String(factId));
          return owner && owner !== String(sourceId);
        });
      if (!currentKeys.has(key) && !hasOtherSourceEvidence) {
        await client.query(
          `DELETE FROM financial_projections
            WHERE profile_id = $1 AND ${reconciliationColumn} = $2
              AND projection_kind = $3 AND projection_key = $4`,
          [profileId, reconciliationValue, row.projection_kind, row.projection_key],
        );
      }
    }
  }
  for (const item of decisions) {
    // sms_source_facts.id is UUID in production. Filtering here keeps a
    // malformed or hand-built fact from turning an otherwise valid envelope
    // into a failed PostgreSQL array cast.
    const factIds = (item.factIds || []).filter((id) => UUID.test(String(id)));
    await client.query(
      `INSERT INTO financial_projections
         (profile_id, projection_kind, projection_key, status, projection,
          source_id, source_key, source_fact_ids, projection_version)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8::uuid[], $9)
       ON CONFLICT (profile_id, projection_kind, projection_key)
       DO UPDATE SET status = CASE
                       -- A named-service mandate only establishes setup
                       -- presence. It must not downgrade a payment-backed or
                       -- explicit service projection written by another SMS.
                       WHEN financial_projections.projection_kind = 'subscription'
                         AND EXCLUDED.status IN ('candidate', 'unknown')
                         AND EXCLUDED.projection->>'setupConfirmed' = 'true'
                         AND (
                           financial_projections.projection->>'setupConfirmed' = 'true'
                           OR financial_projections.projection->>'explicitSubscription' = 'true'
                           OR financial_projections.projection->>'lastPostedPayment' IS NOT NULL
                           OR financial_projections.projection->>'subscriptionEvidence' IN (
                             'explicit', 'user_asserted', 'posted', 'historical', 'brand_prior'
                           )
                         )
                       THEN financial_projections.status
                       ELSE EXCLUDED.status
                     END,
                     projection = CASE
                       WHEN financial_projections.projection_kind = 'subscription'
                         AND EXCLUDED.projection->>'setupConfirmed' = 'true'
                         AND (
                           financial_projections.projection->>'setupConfirmed' = 'true'
                           OR financial_projections.projection->>'explicitSubscription' = 'true'
                           OR financial_projections.projection->>'lastPostedPayment' IS NOT NULL
                           OR financial_projections.projection->>'subscriptionEvidence' IN (
                             'explicit', 'user_asserted', 'posted', 'historical', 'brand_prior'
                           )
                         )
                       THEN financial_projections.projection
                       ELSE EXCLUDED.projection
                     END,
                     source_id = CASE
                       WHEN financial_projections.source_id IS NULL
                         OR financial_projections.source_id = EXCLUDED.source_id
                       THEN EXCLUDED.source_id
                       ELSE financial_projections.source_id
                     END,
                     source_key = CASE
                       WHEN financial_projections.source_id IS NULL
                         OR financial_projections.source_id = EXCLUDED.source_id
                       THEN EXCLUDED.source_key
                       ELSE financial_projections.source_key
                     END,
                     source_fact_ids = CASE
                       WHEN financial_projections.source_id IS NULL
                         OR financial_projections.source_id = EXCLUDED.source_id
                       THEN EXCLUDED.source_fact_ids
                       ELSE ARRAY(
                         SELECT DISTINCT fact_id
                           FROM unnest(financial_projections.source_fact_ids || EXCLUDED.source_fact_ids) AS ids(fact_id)
                       )
                     END,
                     projection_version = EXCLUDED.projection_version,
                     updated_at = now()`,
      [profileId, item.projectionKind, item.projectionKey, item.status,
        JSON.stringify(item.data), item.sourceId, item.sourceKey,
        factIds, PROJECTION_VERSION],
    );
  }
  if (sourceId) {
    await client.query(
      `UPDATE sms_sources
          SET projection_version = $3
        WHERE profile_id = $1 AND id = $2`,
      [profileId, sourceId, PROJECTION_VERSION],
    );
  }
  return {
    projectionVersion: PROJECTION_VERSION,
    count: decisions.length,
    kinds: [...new Set(decisions.map((item) => item.projectionKind))],
    decisions,
  };
}

/** Materialize older stored facts once per source, including sources with no
 * projectable facts. Their checkpoint prevents repeated work on every read. */
async function backfillFinancialProjections(client, profileId, { limit = 100 } = {}) {
  const smsFacts = require('./sms_facts');
  const pending = await client.query(
    `SELECT id, source_key
       FROM sms_sources
      WHERE profile_id = $1 AND projection_version < $2
      ORDER BY first_seen_at DESC, id DESC
      LIMIT $3`,
    [profileId, PROJECTION_VERSION, limit],
  );
  for (const source of pending.rows || []) {
    const resolved = await smsFacts.loadSmsSourceFacts(client, profileId, source.source_key);
    if (!resolved) continue;
    await persistFinancialProjections(client, profileId, {
      sourceId: source.id,
      sourceKey: source.source_key,
      facts: resolved.facts || [],
    });
  }
  return (pending.rows || []).length;
}

module.exports = {
  PROJECTION_VERSION,
  PROJECTION_KINDS,
  MANDATE_TARGET_KINDS,
  SUBSCRIPTION_STATUSES: [...SUBSCRIPTION_STATUSES],
  explicitSubscription,
  mandateTargetKind,
  normalizeIdentity,
  legacyMandateSetupRow,
  buildProjectionDecisions,
  coalesceDecisions,
  persistFinancialProjections,
  backfillFinancialProjections,
};
