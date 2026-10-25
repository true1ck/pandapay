/** Conservative checks before model output can affect a financial projection.
 * A valid JSON shape is not evidence that an amount or event occurred.
 */
const MONEY_FIELDS = [
  'amountInr', 'amountDueInr', 'minimumDueInr', 'outstandingInr',
  'limitInr', 'proposedAmountInr', 'availableBalanceInr',
];

function moneyInMessage(body) {
  const values = [];
  const pattern = /(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)/gi;
  for (const match of body.matchAll(pattern)) {
    const amount = Number(match[1].replace(/,/g, ''));
    if (Number.isFinite(amount)) values.push(amount);
  }
  return values;
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
    if (fact.factType === 'posted_movement' &&
        (!/\b(debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|transfer|processed|payout|settled)\b/i.test(body) ||
         /\b(failed|declined|unsuccessful|will be|to be|scheduled|offer|eligible)\b/i.test(body))) {
      errors.push(`facts[${index}]: posted movement lacks unambiguous completion`);
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

module.exports = { verifyModelFacts, moneyInMessage };
