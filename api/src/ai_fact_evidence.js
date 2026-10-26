/** Conservative checks before model output can affect a financial projection.
 * A valid JSON shape is not evidence that an amount or event occurred.
 */
const MONEY_FIELDS = [
  'amountInr', 'amountDueInr', 'minimumDueInr', 'outstandingInr',
  'limitInr', 'proposedAmountInr', 'availableBalanceInr',
];
const { extractDueDate } = require('./due_date_parser');

/**
 * Verbs that prove money actually moved. Expanded beyond the original card /
 * UPI set to cover loan disbursements, mutual-fund SIPs, deposits, payouts and
 * settlements — the Indian message families the universal engine must accept.
 */
const MOVEMENT_VERBS = /\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled|disbursed|invested|deposited|sent)\b/i;
// Payment processors often say "payment ... was completed successfully"
// instead of using "paid" or "debited". Treat that explicit confirmation as
// movement evidence while requiring a transaction noun before "completed".
const COMPLETED_TRANSACTION = /\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,100}\bcompleted(?:\s+successfully)?\b/i;

/**
 * Marketing / operational footers appended to genuine bank alerts. Everything
 * from the first marker onwards is not part of the transaction clause, so a
 * footer word like "eligible" or "scheduled maintenance" must not invalidate a
 * real movement.
 */
const FOOTER_MARKERS = /\b(?:you are eligible|avail loan|get flat|apply for|offer valid|terms and conditions|t&c|scheduled maintenance|maintenance window)\b/i;

/** Failure / tentative language that only disqualifies the core clause. */
const FAILURE_OR_TENTATIVE = /\b(?:failed|declined|unsuccessful|reversed|cancelled|will be|to be|is scheduled|scheduled for)\b/i;

function moneyInMessage(body) {
  const values = [];
  const pattern = /(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)/gi;
  for (const match of body.matchAll(pattern)) {
    const amount = Number(match[1].replace(/,/g, ''));
    if (Number.isFinite(amount)) values.push(amount);
  }
  return values;
}

function extractAmountInCompletedTransaction(body) {
  const values = [];
  const pattern = /\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,120}\bcompleted(?:\s+successfully)?\b/gi;
  for (const match of String(body || '').matchAll(pattern)) values.push(...moneyInMessage(match[0]));
  const unique = [...new Set(values.map((amount) => Math.round(amount * 100) / 100))];
  return unique.length === 1 ? unique[0] : null;
}

function explicitPayee(body) {
  const match = String(body || '').match(/\b(?:payment|transfer|paid)\b[\s\S]{0,90}?\b(?:to|towards)\s+([A-Za-z][A-Za-z0-9&.' -]{1,38}?)(?=\s+(?:was|is|has|completed|successfully|on|via|through)\b|[,;.!?]|$)/i);
  const payee = match?.[1]?.trim().replace(/\s+/g, ' ');
  if (!payee || /^(?:ref(?:erence)?|id|txn|transaction|account|a\/c)$/i.test(payee)) return null;
  return payee;
}

function evidencedUtilityBiller(body) {
  const text = String(body || '');
  const match = text.match(/\b(electricity|power|water|gas|internet|broadband|mobile|telephone|phone)\s+bill\b/i);
  return match ? `${match[1][0].toUpperCase()}${match[1].slice(1).toLowerCase()}` : null;
}

function hasPrintedCalendarDate(body) {
  return /\b(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{1,2}[ -](?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*(?:[ -]\d{2,4})?|20\d{2}-\d{2}-\d{2})\b/i.test(String(body || ''));
}

/**
 * Fill only missing model fields whose values are unambiguous in the SMS or
 * its phone receipt metadata. This repairs schema omissions without replacing
 * a conflicting model value or inferring a financial fact that Gemini omitted.
 */
function normalizeModelFacts(facts, message) {
  const body = String(message?.body || '');
  return (Array.isArray(facts) ? facts : []).map((fact) => {
    const payload = { ...(fact?.payload || {}) };
    const normalized = { ...fact, payload };
    if (fact?.factType === 'posted_movement' && payload.amountInr == null) {
      payload.amountInr = extractAmountInPostedTransaction(body) ?? undefined;
    }
    if (['posted_movement', 'bill_payment'].includes(fact?.factType) &&
        !hasPrintedCalendarDate(body) && message?.occurredAt) {
      // When the SMS contains no event date, the original device receipt time
      // is the only grounded time; do not retain an unrelated model date.
      payload.occurredAt = message.occurredAt;
    }
    if (fact?.factType === 'posted_movement') {
      const namedParty = payload.merchant || payload.transferParty;
      const normalizedParty = String(namedParty || '').toLowerCase().replace(/[^a-z0-9]/g, '');
      const normalizedBody = body.toLowerCase().replace(/[^a-z0-9]/g, '');
      const hasRequiredEvidence = typeof payload.amountInr === 'number' &&
        amountInPostedTransaction(body, payload.amountInr) &&
        Boolean(payload.occurredAt && movementTimestampSupported(body, payload.occurredAt, message)) &&
        Boolean(normalizedParty.length >= 3 && normalizedBody.includes(normalizedParty)) &&
        Boolean(payload.entryKind && payload.instrument && payload.category);
      if (hasRequiredEvidence && payload.isComplete !== false) {
        payload.isComplete = true;
        if (typeof payload.confidence !== 'number') payload.confidence = 0.9;
      }
    }
    if (fact?.factType === 'bill_obligation') {
      if (!payload.dueDate) {
        const due = extractDueDate(body);
        if (due?.date instanceof Date && !Number.isNaN(due.date.getTime())) {
          payload.dueDate = due.date.toISOString();
        }
      }
      if (!payload.billerName) payload.billerName = evidencedUtilityBiller(body) || undefined;
      if (!payload.category && payload.billerName) payload.category = 'bills';
      const amountField = {
        due_total: 'amountDueInr', due_minimum: 'minimumDueInr', outstanding: 'outstandingInr',
      }[payload.amountRole];
      const hasRequiredEvidence = Boolean(
        amountField && typeof payload[amountField] === 'number' && payload.dueDate && payload.billerName,
      ) && dateAppearsInMessage(body, payload.dueDate) &&
        amountInBillObligation(body, payload.amountRole, payload[amountField]);
      if (hasRequiredEvidence && payload.isComplete !== false) {
        payload.isComplete = true;
        if (typeof payload.confidence !== 'number') payload.confidence = 0.9;
      }
    }
    if (fact?.factType === 'bill_payment') {
      if (payload.amountRole == null) payload.amountRole = 'posted';
      if (payload.entryKind == null) payload.entryKind = 'transfer';
      if (payload.amountInr == null) payload.amountInr = extractAmountInCompletedTransaction(body) ?? undefined;
      if (payload.billerName == null) payload.billerName = explicitPayee(body) || undefined;
      if (!hasPrintedCalendarDate(body) && message?.occurredAt) {
        payload.occurredAt = message.occurredAt;
      }
      const hasRequiredEvidence = typeof payload.amountInr === 'number' &&
        amountInCompletedTransaction(body, payload.amountInr) &&
        Boolean(payload.occurredAt && movementTimestampSupported(body, payload.occurredAt, message)) &&
        Boolean(payload.billerName && String(body).toLowerCase().includes(payload.billerName.toLowerCase()));
      if (hasRequiredEvidence && payload.isComplete !== false) {
        payload.isComplete = true;
        if (typeof payload.confidence !== 'number') payload.confidence = 0.9;
      }
    }
    for (const [key, value] of Object.entries(payload)) {
      if (value === undefined) delete payload[key];
    }
    return normalized;
  });
}

/** Amount must occur in the same explicit completed payment clause. This
 * prevents a nearby available-balance figure from being filed as the payment. */
function amountInCompletedTransaction(body, amount) {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return false;
  const text = String(body || '');
  const pattern = /\b(?:payment|transaction|transfer|purchase)\b[\s\S]{0,120}\bcompleted(?:\s+successfully)?\b/gi;
  for (const match of text.matchAll(pattern)) {
    if (moneyInMessage(match[0]).some((printed) => Math.abs(printed - amount) < 0.005)) return true;
  }
  return false;
}

function amountInBillObligation(body, amountRole, amount) {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return false;
  const labels = {
    due_total: /\b(?:total\s+(?:amount\s+)?due|amount\s+due|bill(?:\s+amount)?|total\s+amount)\b/i,
    due_minimum: /\b(?:minimum\s+due|min\.?\s+due|minimum\s+(?:amount|payment))\b/i,
    outstanding: /\boutstanding(?:\s+amount|\s+balance)?\b/i,
    ceiling: /\b(?:credit\s+)?limit\b/i,
    proposed: /\b(?:proposed|offer(?:ed)?)\b/i,
  }[amountRole];
  if (!labels) return false;
  const text = String(body || '');
  const money = /(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)/gi;
  const matches = [...text.matchAll(money)];
  for (const [index, match] of matches.entries()) {
    if (Math.abs(Number(match[1].replace(/,/g, '')) - amount) >= 0.005) continue;
    const start = match.index || 0;
    const previous = matches[index - 1];
    const contextStart = previous ? previous.index + previous[0].length : Math.max(0, start - 80);
    const context = text.slice(contextStart, start + match[0].length);
    if (labels.test(context)) return true;
  }
  return false;
}

function dateAppearsInMessage(body, value) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return false;
  const variants = [];
  for (const candidate of [date, new Date(date.getTime() + 330 * 60 * 1000)]) {
    const day = String(candidate.getUTCDate()).padStart(2, '0');
    const monthNumber = String(candidate.getUTCMonth() + 1).padStart(2, '0');
    const year = String(candidate.getUTCFullYear());
    const shortYear = year.slice(-2);
    const month = candidate.toLocaleString('en-US', { month: 'short', timeZone: 'UTC' });
    variants.push(
      `${year}-${monthNumber}-${day}`, `${day}-${monthNumber}-${year}`, `${day}/${monthNumber}/${year}`,
      `${day}-${monthNumber}-${shortYear}`, `${day}/${monthNumber}/${shortYear}`,
      `${day} ${month} ${year}`, `${day}-${month}-${year}`, `${day} ${month} ${shortYear}`,
      `${day}-${month}-${shortYear}`, `${day} ${month}`, `${day}-${month}`,
    );
  }
  const lower = String(body || '').toLowerCase();
  return variants.some((variant) => lower.includes(variant.toLowerCase()));
}

function movementTimestampSupported(body, timestamp, payload) {
  if (dateAppearsInMessage(body, timestamp)) return true;
  // If the SMS prints a calendar date and it does not match the model's
  // timestamp, do not replace that conflicting evidence with receipt time.
  if (/\b(?:\d{1,2}[/-]\d{1,2}[/-]\d{2,4}|\d{1,2}[ -](?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*(?:[ -]\d{2,4})?|20\d{2}-\d{2}-\d{2})\b/i.test(body)) return false;
  // The phone receipt timestamp is an allowed deterministic fallback only
  // when the SMS itself does not print an event date.
  const receipt = payload?.occurredAt || payload?.receivedAt;
  const eventMs = new Date(timestamp).getTime();
  const receiptMs = new Date(receipt).getTime();
  return Number.isFinite(eventMs) && Number.isFinite(receiptMs) && Math.abs(eventMs - receiptMs) <= 5 * 60 * 1000;
}

/** The posted amount must be attached to the movement clause, not a nearby
 * balance-after figure from the same bank SMS. */
function amountInPostedTransaction(body, amount) {
  if (typeof amount !== 'number' || !Number.isFinite(amount) || amount <= 0) return false;
  const core = coreTransactionClause(body);
  // Do not split on every period: `Rs.` and decimal paise both contain dots.
  // Periods remain inside a clause; explicit separators still isolate the
  // common movement / balance clauses.
  const clauses = core.split(/[!?;\n]+/).map((value) => value.trim()).filter(Boolean);
  const balanceLabel = /\b(?:available|avail\.?|current|closing|remaining|ledger)\s*(?:account\s*)?(?:bal(?:ance)?|balance\s+after)\b|\b(?:bal(?:ance)?|balance\s+after)\s*(?:is|after|now|:|=)?/i;
  for (const clause of clauses) {
    if (!MOVEMENT_VERBS.test(clause) && !COMPLETED_TRANSACTION.test(clause)) continue;
    const matches = [...clause.matchAll(/(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)/gi)];
    for (const match of matches) {
      if (Math.abs(Number(match[1].replace(/,/g, '')) - amount) >= 0.005) continue;
      const start = match.index || 0;
      const before = clause.slice(Math.max(0, start - 60), start);
      const after = clause.slice(start + match[0].length, start + match[0].length + 40);
      const balanceLabels = [...before.matchAll(new RegExp(balanceLabel, 'gi'))];
      const movementMatches = [...before.matchAll(/\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled|disbursed|invested|deposited|sent)\b/gi)];
      const lastBalance = balanceLabels.at(-1)?.index ?? -1;
      const lastMovement = movementMatches.at(-1)?.index ?? -1;
      if (lastBalance >= 0 && lastMovement <= lastBalance) continue;
      if (/\b(?:is|as)\s+(?:your\s+|the\s+)?(?:available\s+|current\s+|closing\s+|remaining\s+)?balance\b/i.test(after)) continue;
      return true;
    }
  }
  return false;
}

function extractAmountInPostedTransaction(body) {
  const unique = [...new Set(moneyInMessage(body)
    .filter((amount) => amountInPostedTransaction(body, amount))
    .map((amount) => Math.round(amount * 100) / 100))];
  return unique.length === 1 ? unique[0] : null;
}

/**
 * Returns the transaction-bearing part of a message, before any promotional or
 * maintenance footer that frequently trails Indian bank SMS.
 */
function coreTransactionClause(body) {
  const text = String(body || '');
  const match = FOOTER_MARKERS.exec(text);
  return (match ? text.slice(0, match.index) : text).trim();
}

/**
 * True when the core clause contains a completion verb and no failure or
 * tentative wording. Shared by evidence verification and composite scoring.
 */
function hasCompletionEvidence(body) {
  const core = coreTransactionClause(body);
  if (!core) return false;
  if (!MOVEMENT_VERBS.test(core) && !COMPLETED_TRANSACTION.test(core)) return false;
  if (FAILURE_OR_TENTATIVE.test(core)) return false;
  return true;
}

function verifyModelFacts(facts, payload) {
  const body = String(payload?.body || '');
  const lower = body.toLowerCase();
  const printedAmounts = moneyInMessage(body);
  const errors = [];
  for (const [index, fact] of facts.entries()) {
    const value = fact.payload || {};
    for (const field of MONEY_FIELDS) {
      if (typeof value[field] === 'number' &&
          !printedAmounts.some((amount) => Math.abs(amount - value[field]) < 0.005)) {
        errors.push(`facts[${index}].${field}: amount absent from SMS`);
      }
    }
    for (const field of ['last4', 'accountLast4']) {
      if (value[field] && !body.includes(value[field])) {
        errors.push(`facts[${index}].${field}: suffix absent from SMS`);
      }
    }
    if (value.reference && !lower.includes(String(value.reference).toLowerCase())) {
      errors.push(`facts[${index}].reference: reference absent from SMS`);
    }
    if (fact.factType === 'posted_movement') {
      if (!hasCompletionEvidence(body)) {
        errors.push(`facts[${index}]: posted movement lacks unambiguous completion`);
      }
      if (!amountInPostedTransaction(body, value.amountInr)) {
        errors.push(`facts[${index}].amountInr: amount is not tied to completed movement`);
      }
      if (!movementTimestampSupported(body, value.occurredAt, payload)) {
        errors.push(`facts[${index}].occurredAt: timestamp is not supported by SMS or receipt metadata`);
      }
    }
    if (fact.factType === 'bill_payment') {
      if (!hasCompletionEvidence(body)) {
        errors.push(`facts[${index}]: bill payment lacks unambiguous completion`);
      }
      if (!amountInCompletedTransaction(body, value.amountInr)) {
        errors.push(`facts[${index}].amountInr: amount is not tied to completed payment`);
      }
      if (!movementTimestampSupported(body, value.occurredAt, payload)) {
        errors.push(`facts[${index}].occurredAt: timestamp is not supported by SMS or receipt metadata`);
      }
    }
    if (fact.factType === 'bill_obligation') {
      const amountField = {
        due_total: 'amountDueInr', due_minimum: 'minimumDueInr', outstanding: 'outstandingInr',
        ceiling: 'limitInr', proposed: 'proposedAmountInr',
      }[value.amountRole];
      if (amountField && typeof value[amountField] === 'number' &&
          !amountInBillObligation(body, value.amountRole, value[amountField])) {
        errors.push(`facts[${index}].${amountField}: amount is not tied to the ${value.amountRole} bill clause`);
      }
    }
    if (fact.factType === 'balance_snapshot' && !/\b(balance|available|bal|avail)\b/i.test(body)) {
      errors.push(`facts[${index}]: no balance evidence`);
    }
    if (fact.factType === 'balance_snapshot' && value.instrument === 'upi_bank' &&
        !/\b(bank|savings|current|a\/c|account|upi)\b/i.test(body)) {
      errors.push(`facts[${index}]: no bank-account evidence`);
    }
    if (fact.factType === 'balance_snapshot' && value.instrument === 'upi_bank' &&
        !/^\d{4}$/.test(String(value.accountLast4 || ''))) {
      errors.push(`facts[${index}]: bank balance requires an evidenced account suffix`);
    }
    if (fact.factType === 'bill_obligation' && !/\b(bill|due|statement|outstanding|minimum)\b/i.test(body)) {
      errors.push(`facts[${index}]: no bill evidence`);
    }
    if (fact.factType === 'mandate_lifecycle' && !/\b(mandate|autopay|auto.pay)\b/i.test(body)) {
      errors.push(`facts[${index}]: no mandate evidence`);
    }
  }
  return { valid: errors.length === 0, errors };
}

module.exports = {
  verifyModelFacts,
  moneyInMessage,
  amountInCompletedTransaction,
  amountInBillObligation,
  amountInPostedTransaction,
  dateAppearsInMessage,
  movementTimestampSupported,
  extractAmountInCompletedTransaction,
  extractAmountInPostedTransaction,
  normalizeModelFacts,
  MOVEMENT_VERBS,
  COMPLETED_TRANSACTION,
  coreTransactionClause,
  hasCompletionEvidence,
};
