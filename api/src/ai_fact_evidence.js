/** Conservative checks before model output can affect a financial projection.
 * A valid JSON shape is not evidence that an amount or event occurred.
 */
const MONEY_FIELDS = [
  'amountInr', 'amountDueInr', 'minimumDueInr', 'outstandingInr',
  'limitInr', 'proposedAmountInr', 'availableBalanceInr',
];

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
    if (fact.factType === 'posted_movement' && !hasCompletionEvidence(body)) {
      errors.push(`facts[${index}]: posted movement lacks unambiguous completion`);
    }
    if (fact.factType === 'bill_payment') {
      if (!hasCompletionEvidence(body)) {
        errors.push(`facts[${index}]: bill payment lacks unambiguous completion`);
      }
      if (!amountInCompletedTransaction(body, value.amountInr)) {
        errors.push(`facts[${index}].amountInr: amount is not tied to completed payment`);
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
  MOVEMENT_VERBS,
  COMPLETED_TRANSACTION,
  coreTransactionClause,
  hasCompletionEvidence,
};
