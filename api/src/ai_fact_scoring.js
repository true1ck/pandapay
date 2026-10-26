/**
 * Multi-signal composite confidence scoring for AI-extracted SMS facts.
 *
 * S = 0.25*S_model + 0.35*S_evidence + 0.25*S_completeness + 0.15*S_disambiguation
 *
 * The score never invents certainty the message does not carry: every evidence
 * component is anchored to text actually present in the redacted body, while
 * completeness and disambiguation measure whether the extracted fact has the
 * attributes needed for a downstream projection.
 */

const {
  MOVEMENT_VERBS,
  hasCompletionEvidence,
  moneyInMessage,
  amountInCompletedTransaction,
  amountInPostedTransaction,
} = require('./ai_fact_evidence');
const { SPEND_CATEGORIES, INSTRUMENTS, AMOUNT_FIELD_BY_ROLE } = require('./sms_facts');

const AUTO_RESOLVE = 0.85;
const NEEDS_REVIEW = 0.45;

const WEIGHTS = {
  model: 0.25,
  evidence: 0.35,
  completeness: 0.25,
  disambiguation: 0.15,
};

/** Fact types that may gate auto-resolution; informational facts never do. */
const ACTIONABLE_FACT_TYPES = new Set([
  'posted_movement',
  'bill_obligation',
  'bill_payment',
  'mandate_lifecycle',
]);

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function round4(value) {
  return Math.round(value * 10000) / 10000;
}

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function unitScore(value) {
  if (!isFiniteNumber(value)) return 0;
  return Math.min(1, Math.max(0, value));
}

function shortText(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function validDate(value) {
  return typeof value === 'string' && !Number.isNaN(new Date(value).getTime());
}

function modelScore(payload) {
  const confidence = payload.confidence;
  if (isFiniteNumber(confidence) && confidence >= 0 && confidence <= 1) return confidence;
  return 0.8;
}

/**
 * Verbatim amount evidence. Accepts Indian grouping ("1,45,000") and decimal
 * spelling differences, but never a number that only appears inside a longer
 * identifier.
 */
function amountAppears(body, amount) {
  if (!isFiniteNumber(amount) || amount <= 0) return false;
  if (moneyInMessage(body).some((printed) => Math.abs(printed - amount) < 0.005)) return true;
  const compact = body.replace(/,/g, '');
  const variants = new Set([String(amount)]);
  if (Number.isInteger(amount)) variants.add(amount.toFixed(2));
  for (const variant of variants) {
    let index = compact.indexOf(variant);
    while (index !== -1) {
      const before = compact[index - 1];
      const after = compact[index + variant.length];
      const startsAtDigitBoundary = !(before && /\d/.test(before));
      const endsAtDigitBoundary = !(after && /\d/.test(after));
      if (startsAtDigitBoundary && endsAtDigitBoundary) return true;
      index = compact.indexOf(variant, index + 1);
    }
  }
  return false;
}

function amountForPayload(payload) {
  const roleField = AMOUNT_FIELD_BY_ROLE[payload.amountRole];
  if (roleField && isFiniteNumber(payload[roleField]) && payload[roleField] > 0) {
    return payload[roleField];
  }
  for (const field of Object.values(AMOUNT_FIELD_BY_ROLE)) {
    if (isFiniteNumber(payload[field]) && payload[field] > 0) return payload[field];
  }
  return null;
}

/**
 * Anchor-date evidence across the formats Indian SMS actually print:
 * dd-mm-yy, dd/mm/yy, dd Mon yyyy, ISO, plus the plain "24 Oct" form.
 * Dates are commonly stored as IST midnight (18:30Z of the prior day), so
 * both the UTC and IST calendars are treated as plausible.
 */
function dateVariants(date) {
  const day = String(date.getUTCDate()).padStart(2, '0');
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const year = String(date.getUTCFullYear());
  const shortYear = year.slice(-2);
  const monthName = MONTHS[date.getUTCMonth()];
  return [
    `${year}-${month}-${day}`,
    `${day}-${month}-${shortYear}`,
    `${day}/${month}/${shortYear}`,
    `${day}-${month}-${year}`,
    `${day}/${month}/${year}`,
    `${day} ${monthName} ${year}`,
    `${day}-${monthName}-${year}`,
    `${day} ${monthName} ${shortYear}`,
    `${day}-${monthName}-${shortYear}`,
    `${day} ${monthName}`,
  ];
}

function dateAppears(body, anchor) {
  if (!anchor) return false;
  const date = anchor instanceof Date ? anchor : new Date(anchor);
  if (Number.isNaN(date.getTime())) return false;
  const istDate = new Date(date.getTime() + 330 * 60 * 1000);
  const variants = [...dateVariants(date), ...dateVariants(istDate)];
  const lower = String(body || '').toLowerCase();
  return variants.some((variant) => lower.includes(variant.toLowerCase()));
}

function anchorForPayload(payload) {
  return payload.occurredAt || payload.dueDate || payload.asOfAt ||
    payload.statementDate || payload.proposedAt || payload.nextPaymentDate || null;
}

function evidenceScore(fact, body, receivedAt = null) {
  const payload = fact.payload || {};
  let score = 0;
  const amount = amountForPayload(payload);
  const exactAmountEvidence = fact.factType === 'bill_payment'
    ? amountInCompletedTransaction(body, payload.amountInr)
    : fact.factType === 'posted_movement'
      ? amountInPostedTransaction(body, payload.amountInr)
      : amountAppears(body, amount);
  if (exactAmountEvidence) score += 0.40;
  const suffix = payload.last4 || payload.accountLast4;
  if (suffix && body.includes(String(suffix))) score += 0.25;
  const anchor = anchorForPayload(payload);
  const hasReceiptTime = ['posted_movement', 'bill_payment'].includes(fact.factType) &&
    validDate(anchor) && validDate(receivedAt) &&
    Math.abs(new Date(anchor).getTime() - new Date(receivedAt).getTime()) <= 5 * 60 * 1000;
  if (dateAppears(body, anchor) || hasReceiptTime) score += 0.20;
  if (fact.factType === 'posted_movement' || fact.factType === 'bill_payment') {
    if (hasCompletionEvidence(body)) score += 0.15;
  } else if (fact.factType === 'bill_obligation' || fact.factType === 'mandate_lifecycle') {
    if (/\b(bill|due|mandate|autopay|auto.pay)\b/i.test(body)) score += 0.15;
  }
  return round4(Math.min(1, score));
}

function hasValidInstrument(payload) {
  return INSTRUMENTS.includes(payload.instrument);
}

function hasValidCategory(payload) {
  return SPEND_CATEGORIES.includes(payload.category);
}

function completenessScore(fact) {
  const payload = fact.payload || {};
  switch (fact.factType) {
    case 'posted_movement': {
      let score = 0;
      if (isFiniteNumber(payload.amountInr) && payload.amountInr > 0) score += 0.25;
      if (hasValidInstrument(payload)) score += 0.25;
      if (shortText(payload.merchant)) score += 0.25;
      if (hasValidCategory(payload)) score += 0.25;
      return score;
    }
    case 'bill_obligation': {
      let score = 0;
      if (isFiniteNumber(payload.amountDueInr) && payload.amountDueInr > 0) score += 0.35;
      if (validDate(payload.dueDate)) score += 0.35;
      if (shortText(payload.billerName)) score += 0.30;
      return score;
    }
    case 'mandate_lifecycle': {
      let score = 0;
      if (isFiniteNumber(payload.limitInr) && payload.limitInr > 0) score += 0.40;
      if (shortText(payload.serviceName) || shortText(payload.merchant)) score += 0.30;
      if (shortText(payload.mandateStatus)) score += 0.30;
      return score;
    }
    case 'bill_payment': {
      let score = 0;
      if (isFiniteNumber(payload.amountInr) && payload.amountInr > 0) score += 0.4;
      if (validDate(payload.occurredAt)) score += 0.2;
      if (shortText(payload.billerName) || shortText(payload.merchant)) score += 0.4;
      return score;
    }
    case 'balance_snapshot': {
      let score = 0;
      if (isFiniteNumber(payload.availableBalanceInr) && payload.availableBalanceInr >= 0) score += 0.5;
      if (validDate(payload.asOfAt)) score += 0.25;
      if (hasValidInstrument(payload)) score += 0.25;
      return score;
    }
    case 'pending_or_failed_attempt': {
      let score = 0;
      if (shortText(payload.attemptStatus)) score += 0.5;
      if (validDate(payload.occurredAt)) score += 0.5;
      return score;
    }
    case 'card_identity_hint': {
      let score = 0;
      if (shortText(payload.last4) || shortText(payload.accountLast4)) score += 0.5;
      if (validDate(payload.asOfAt)) score += 0.5;
      return score;
    }
    case 'security_or_service_alert': {
      let score = 0;
      if (shortText(payload.alertKind)) score += 0.5;
      if (validDate(payload.occurredAt)) score += 0.5;
      return score;
    }
    case 'promotion':
      return 1;
    default:
      return 0;
  }
}

function disambiguationScore(payload, factType = null, body = '') {
  let score = 0;
  const hasMovementParty = shortText(payload.merchant) || shortText(payload.transferParty);
  const normalizedBody = String(body).toLowerCase().replace(/[^a-z0-9]/g, '');
  const evidencedParty = [payload.merchant, payload.transferParty, payload.billerName, payload.serviceName]
    .filter(shortText)
    .some((party) => {
      const normalizedParty = party.toLowerCase().replace(/[^a-z0-9]/g, '');
      return normalizedParty.length >= 3 && normalizedBody.includes(normalizedParty);
    });
  if (factType === 'posted_movement' && hasMovementParty && evidencedParty) return 1;
  if (factType === 'bill_obligation' && shortText(payload.billerName)) {
    const biller = payload.billerName.toLowerCase().replace(/[^a-z0-9]/g, '');
    if (biller.length >= 3 && normalizedBody.includes(biller)) return 1;
  }
  if ((shortText(payload.merchant) || shortText(payload.billerName) || shortText(payload.serviceName)) && evidencedParty) {
    score += 0.5;
  }
  if (factType === 'bill_payment' &&
      (shortText(payload.merchant) || shortText(payload.billerName)) && evidencedParty) return 1;
  if (shortText(payload.last4) || shortText(payload.accountLast4)) score += 0.5;
  return Math.min(1, score);
}

/**
 * Scores one candidate fact against the redacted SMS body.
 * `isComplete` is the model's positive completeness assertion: absent or false
 * is never treated as complete.
 */
function computeFactScore(fact, body, receivedAt = null) {
  const payload = fact?.payload || {};
  const model = modelScore(payload);
  const evidence = evidenceScore(fact || {}, String(body || ''), receivedAt);
  const completeness = completenessScore(fact || {});
  const disambiguation = disambiguationScore(payload, fact?.factType, String(body || ''));
  const score = round4(
    WEIGHTS.model * model +
    WEIGHTS.evidence * evidence +
    WEIGHTS.completeness * completeness +
    WEIGHTS.disambiguation * disambiguation,
  );
  return {
    score,
    model: unitScore(model),
    evidence,
    completeness,
    disambiguation,
    isComplete: payload.isComplete === true,
    factType: fact?.factType || null,
  };
}

/**
 * Assesses a whole model result. Auto-resolution requires at least one
 * actionable fact, every actionable fact scoring >= 0.85, and every actionable
 * fact explicitly marked complete by the model. Informational facts are
 * reported but never gate the decision.
 */
function assessFacts(facts, body, receivedAt = null) {
  const list = Array.isArray(facts) ? facts : [];
  const perFact = list.map((fact) => computeFactScore(fact, body, receivedAt));
  const actionable = perFact.filter((entry) => ACTIONABLE_FACT_TYPES.has(entry.factType));
  const composite = actionable.length > 0
    ? round4(Math.max(...actionable.map((entry) => entry.score)))
    : 0;
  const reviewRequired = !(
    actionable.length === 1 &&
    actionable.every((entry) => entry.score >= AUTO_RESOLVE) &&
    actionable.every((entry) => entry.isComplete === true)
  );
  return {
    perFact,
    composite,
    reviewRequired,
    actionableCount: actionable.length,
  };
}

module.exports = {
  AUTO_RESOLVE,
  NEEDS_REVIEW,
  WEIGHTS,
  ACTIONABLE_FACT_TYPES,
  computeFactScore,
  assessFacts,
  // Exposed for focused tests and reuse by the route layer.
  amountAppears,
  dateAppears,
  MOVEMENT_VERBS,
};
