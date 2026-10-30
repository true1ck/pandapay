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
  isReceiptOnlyMessage,
  hasReceiptCompletion,
} = require('./ai_fact_evidence');
const { cleanMerchantName, merchantEvidence } = require('./merchant_identity');
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

/** Shape is not identity: a hash, URL or boilerplate fragment is not a payee. */
function merchantText(value) {
  return typeof value === 'string' && cleanMerchantName(value) !== null;
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
    // Compact Indian bank date token: 17Oct26.
    `${day}${monthName}${shortYear}`,
    `${day}${monthName}${year}`,
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
      if (merchantText(payload.merchant) || merchantText(payload.transferParty)) score += 0.25;
      if (hasValidCategory(payload)) score += 0.25;
      return score;
    }
    case 'bill_obligation': {
      let score = 0;
      if (isFiniteNumber(payload.amountDueInr) && payload.amountDueInr > 0) score += 0.35;
      if (validDate(payload.dueDate)) score += 0.35;
      if (merchantText(payload.billerName)) score += 0.30;
      return score;
    }
    case 'mandate_lifecycle': {
      let score = 0;
      if (isFiniteNumber(payload.limitInr) && payload.limitInr > 0) score += 0.40;
      if (merchantText(payload.serviceName) || merchantText(payload.merchant)) score += 0.30;
      if (shortText(payload.mandateStatus)) score += 0.30;
      return score;
    }
    case 'bill_payment': {
      let score = 0;
      if (isFiniteNumber(payload.amountInr) && payload.amountInr > 0) score += 0.4;
      if (validDate(payload.occurredAt)) score += 0.2;
      if (merchantText(payload.billerName) || merchantText(payload.merchant)) score += 0.4;
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
  const hasMovementParty = merchantText(payload.merchant) || merchantText(payload.transferParty);
  // Ground through merchant identity, not a raw substring: an opaque ID can
  // appear in the body and still not identify the payee.
  const evidencedParty = [payload.merchant, payload.transferParty, payload.billerName, payload.serviceName]
    .filter(shortText)
    .some((party) => merchantEvidence(party, body).ok);
  if (factType === 'posted_movement' && hasMovementParty && evidencedParty) return 1;
  if (factType === 'bill_obligation' && merchantText(payload.billerName) &&
      merchantEvidence(payload.billerName, body).ok) return 1;
  if ((merchantText(payload.merchant) || merchantText(payload.billerName) || merchantText(payload.serviceName)) && evidencedParty) {
    score += 0.5;
  }
  if (factType === 'bill_payment' &&
      (merchantText(payload.merchant) || merchantText(payload.billerName)) && evidencedParty) return 1;
  if (shortText(payload.last4) || shortText(payload.accountLast4)) score += 0.5;
  return Math.min(1, score);
}

/**
 * Hard gates that a composite score must never outvote:
 *
 *   - a posted spend/transfer needs completion language, not a promise or a
 *     decline, even if amount/date/suffix happen to score well;
 *   - its merchant/party must exist, survive identity cleanup and be grounded
 *     in the SMS (a synthetic name cannot buy disambiguation points);
 *   - a merchant e-bill receipt confirms the shop recorded a payment but is
 *     not an independent ledger entry, so it cannot auto-post.
 */
function autoResolveGate(fact, body) {
  const payload = fact?.payload || {};
  const factType = fact?.factType || null;
  const receiptOnly = isReceiptOnlyMessage(body);
  const receiptCompletion = hasReceiptCompletion(body);
  const needsLedgerGate = factType === 'posted_movement' || factType === 'bill_payment';
  const party = factType === 'bill_payment'
    ? (payload.billerName || payload.merchant)
    : (payload.merchant || payload.transferParty);
  // Parity with the device mirror: non-ledger facts have no merchant or
  // completion requirement, but every actionable fact is still blocked by a
  // receipt-only message.
  const merchantEvidenced = !needsLedgerGate ||
    Boolean(party && merchantEvidence(party, body).ok);
  const completionEvidence = !needsLedgerGate || hasCompletionEvidence(body);
  const ok = merchantEvidenced && completionEvidence && !receiptOnly;
  return { merchantEvidenced, completionEvidence, receiptOnly, receiptCompletion, ok };
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
  const gate = autoResolveGate(fact, String(body || ''));
  return {
    score,
    model: unitScore(model),
    evidence,
    completeness,
    disambiguation,
    isComplete: payload.isComplete === true,
    factType: fact?.factType || null,
    merchantEvidenced: gate.merchantEvidenced,
    completionEvidence: gate.completionEvidence,
    receiptOnly: gate.receiptOnly,
    receiptCompletion: gate.receiptCompletion,
    autoResolveEligible: gate.ok,
  };
}

/**
 * Assesses a whole model result. Auto-resolution requires at least one
 * actionable fact, every actionable fact scoring >= 0.85, every actionable
 * fact explicitly marked complete by the model, and every posted/bill fact
 * passing the merchant/completion/receipt gate. Informational facts are
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
    actionable.every((entry) => entry.isComplete === true) &&
    actionable.every((entry) => entry.autoResolveEligible !== false)
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
  autoResolveGate,
  // Exposed for focused tests and reuse by the route layer.
  amountAppears,
  dateAppears,
  MOVEMENT_VERBS,
};
