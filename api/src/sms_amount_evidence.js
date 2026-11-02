// Mirrors app/lib/data/sms_amount_evidence.dart. Balance/limit values are
// independent monetary facts and cannot substitute for a payment amount.
const INR = /(?:₹|\b(?:rs\.?|inr)\s*)[:\s]*([\d,]+(?:\.\d{1,2})?)/gi;
const CURRENCY_CODES = Object.keys(require('./currency_minor_units.json')).filter((code) => code !== 'INR').join('|');
const FOREIGN = new RegExp(String.raw`\b(?:${CURRENCY_CODES})\s*[:.]?\s*(?=[\d.])|(?:US\$|\$|€|£)\s*(?=[\d.])|[\d.]\s+(?:${CURRENCY_CODES})\b`, 'i');
const NON_PAYMENT = /\b(?:(?:available|avail|avl|current|closing|remaining|ledger|total|cash)\.?\s*(?:credit\s*|cash\s*|account\s*)?(?:bal(?:ance)?|lmt|limit)|credit\s+limit|(?:bal(?:ance)?|limit|lmt)|outstanding|(?:minimum|total)\s+(?:amount\s+)?due)\b/gi;
const MOVEMENT = /\b(?:debited|deducted|spent|paid|charged|credited|received|refunded|withdrawn|transferred|settled|disbursed|deposited|billed|equivalent|converted|txn\s+amount|transaction\s+amount)\b/gi;
function paymentAmounts(body) {
  return [...String(body || '').matchAll(INR)].filter((match) => {
    const after = body.slice(match.index + match[0].length);
    const amountBeforeMovement = /^\s*(?:has\s+been\s+)?(?:spent|debited|paid|charged|credited|refunded|withdrawn|transferred)\b/i.test(after);
    const before = body.slice(0, match.index);
    const labels = [...before.matchAll(NON_PAYMENT)];
    const movements = [...before.matchAll(MOVEMENT)];
    if (labels.length && !amountBeforeMovement && (!movements.length || movements.at(-1).index <= labels.at(-1).index)) return false;
    return !/^\s*(?:(?:is|as)\s+)?(?:your\s+|the\s+)?(?:(?:available|remaining|credit|cash|closing|current)\s+)*(?:balance|bal|limit|lmt)\b/i.test(after);
  });
}
const CURRENCYLESS = /\b(?:debited|deducted|spent|paid|credited|received|refunded|withdrawn|transferred|sent)\s+(?:by|with|for|of)\s+([\d,]+(?:\.\d{1,2})?)\b/gi;
function permitsPaymentAmount(body, amount) {
  return [...paymentAmounts(body), ...(!FOREIGN.test(body) ? [...body.matchAll(CURRENCYLESS)] : [])].some((m) => Math.abs(Number(m[1].replace(/,/g, '')) - amount) < .005);
}
function hasInrAmount(body) { return [...String(body || '').matchAll(INR)].length > 0; }
function paymentReviewReason(body) {
  const text = String(body || '');
  // A limit-change or balance-only service alert has no movement verb. It
  // still must not escape the guard merely because an old configured rule
  // mistakes "spend limit" for "spent".
  if (![...text.matchAll(MOVEMENT)].length) {
    return hasInrAmount(text) && !paymentAmounts(text).length
      ? 'transaction_amount_not_evidenced'
      : null;
  }
  if (!FOREIGN.test(text) && [...text.matchAll(CURRENCYLESS)].length) return null;
  if (paymentAmounts(text).length) return null;
  if (FOREIGN.test(text)) return 'foreign_currency_needs_billed_inr';
  if ([...text.matchAll(INR)].length) return 'transaction_amount_not_evidenced';
  return null;
}
module.exports = { paymentAmounts, hasInrAmount, permitsPaymentAmount, paymentReviewReason };
