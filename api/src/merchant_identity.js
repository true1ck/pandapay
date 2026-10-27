/**
 * Merchant-name identity helpers shared by the SMS parser, AI fact evidence
 * and composite scoring.
 *
 * A merchant name is display evidence, not an identifier. This module keeps
 * three concerns together so every caller agrees on them:
 *
 *   1. cleanMerchantName() repairs harmless capture noise (quotes, receipt
 *      boilerplate, URL/link tails) and returns null when nothing trustworthy
 *      remains.
 *   2. isWeakMerchantName() rejects hash-like IDs, reference numbers and
 *      sentence fragments while preserving short, numeric and Unicode brands.
 *   3. merchantEvidence() grounds a name in the source message, including the
 *      parser's derived transfer/refund labels.
 *
 * Derived labels emitted by sms_parser (for example "Transfer to <person>",
 * "Refund", "Reward or cashback") are supported canonical aliases. They must
 * never be rewritten by a historical repair or treated as hash noise.
 */

'use strict';

const CANONICAL_MERCHANT_ALIASES = Object.freeze([
  'Amazon Pay Later',
  'Bank or service fee',
  'Bank transfer',
  'Card statement adjustment',
  'Cash deposit',
  'Cash withdrawal',
  'Credit card bill payment',
  'Gift received',
  'Investment contribution',
  'Investment proceeds',
  'Loan disbursement',
  'Loan or EMI repayment',
  'Money received',
  'Reimbursement',
  'Refund',
  'Reversal',
  'Reward or cashback',
  'Salary',
  'Transfer between own accounts',
  'Wallet load',
]);

const ALIAS_BY_LOWER = new Map(
  CANONICAL_MERCHANT_ALIASES.map((alias) => [alias.toLowerCase(), alias]),
);

// Everything from the first marker onwards is receipt/notice boilerplate, not
// part of the merchant. Anchored and case-insensitive so it also cleans names
// captured by a broad pattern.
const BOILERPLATE_CUTS = [
  /\bhttps?:\/\/\S+/i,
  /\bwww\.\S+/i,
  /\b(?:for\s+other\s+services|other\s+services)\b/i,
  /\b(?:if\s+not\s+u|if\s+not\s+you|not\s+you)\b/i,
  /\b(?:view|download)\s+(?:the\s+)?(?:payment\s+)?(?:receipt|bill|invoice)\b/i,
  /\b(?:has|have|had|was|were|is|are)\s+(?:been\s+)?(?:successfully\s+)?(?:recorded|completed|processed|confirmed)\b/i,
  /\b(?:call|sms\s+block|to\s+block|block\s+card|report\s+spam)\b/i,
];

const SIGNATURE_TAIL = /\s*[-–—]\s*(?:my\s*bill\s*book|mybillbook(?:\.in)?)\s*$/i;
const WEAK_EXACT = new Set([
  'call',
  'completed',
  'downloaded',
  'other services',
  'payment',
  'payment receipt',
  'receipt',
  'recorded',
  'reference',
  'refno',
  'successful',
  'successfully',
  'the payment receipt',
  'view receipt',
  'your payment',
]);
const MERCHANT_FRAGMENT_KEYWORDS =
  /\b(?:payment|receipt|recorded|completed|processed|successfully|your|has|been|view|download|call|services|account|bank|other)\b/gi;

function normalizeWhitespace(value) {
  return String(value || '').replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
}

function stripWrapping(text) {
  return text
    .replace(/^[\s"'“”‘’()[\]{}]+/u, '')
    .replace(/[\s"'“”‘’()[\]{}]+$/u, '')
    .replace(/^_+/, '')
    .replace(/[\s.,;:!?*-]+$/u, '')
    .trim();
}

function cutBoilerplate(text) {
  let value = text;
  for (const pattern of BOILERPLATE_CUTS) {
    const match = pattern.exec(value);
    if (!match) continue;
    value = match.index === 0 ? '' : value.slice(0, match.index);
    value = value.trim();
  }
  return value.replace(SIGNATURE_TAIL, '').trim();
}

function baseWeaknessReason(text) {
  if (!text) return 'empty';
  if (text.length > 120) return 'too_long';
  const lower = text.toLowerCase();
  if (ALIAS_BY_LOWER.has(lower)) return null;
  if (WEAK_EXACT.has(lower)) return 'boilerplate';

  const letters = text.match(/\p{L}/gu) || [];
  const digits = text.match(/\p{N}/gu) || [];
  if (!letters.length) {
    // A one-to-three digit brand ("7") is legitimate; a longer number is an
    // account/reference/phone fragment.
    return digits.length >= 4 ? 'numeric_id' : null;
  }
  if (/\b(?:https?:\/\/|www\.)/i.test(text)) return 'url';
  if (BOILERPLATE_CUTS.some((pattern) => pattern.test(text))) return 'boilerplate';

  if (/^(?:ref(?:erence)?|refno|txn|utr|rrn|order\s*id|id)\b[\s:#-]*[\p{L}\p{N}-]*$/iu.test(text)) {
    return 'reference_id';
  }
  // X5121, REF123456, TXN998877 — mask prefixes followed by long digits.
  if (/^[A-Z]{1,4}[-#]?\d{4,}$/u.test(text)) return 'reference_id';
  if (/^\+?\p{N}[\p{N}\s-]{5,}$/u.test(text)) return 'numeric_id';

  const compact = text.replace(/[\s_-]+/g, '');
  if (/^[a-f0-9]{16,}$/i.test(compact)) return 'hash_id';
  if (/^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)[A-Za-z0-9_-]{12,}$/.test(text)) return 'hash_id';

  const words = text.split(/\s+/).filter(Boolean);
  if (words.length === 1 && compact.length >= 8 &&
      /\p{N}/u.test(compact) && /\p{L}/u.test(compact)) {
    const vowels = (compact.match(/[aeiou]/gi) || []).length;
    const digitRatio = digits.length / compact.length;
    // ljbffep4r / NEFT123456 / HDFC0001234 are single-token captures with
    // almost no vowel structure or a high digit share. 7-Eleven and 99acres
    // stay under the length/ratio thresholds and remain valid brands.
    if (vowels <= 1 || digitRatio >= 0.4) return 'hash_id';
  }

  if (words.length >= 5) {
    const keywordHits = (text.match(MERCHANT_FRAGMENT_KEYWORDS) || []).length;
    if (keywordHits >= 3) return 'sentence_fragment';
  }
  return null;
}

/**
 * Returns the display-safe merchant name, or null when the captured value is
 * an ID, boilerplate fragment or otherwise too weak to store.
 */
function cleanMerchantName(value) {
  if (typeof value !== 'string') return null;
  let text = normalizeWhitespace(value);
  if (!text) return null;
  text = stripWrapping(text);
  text = cutBoilerplate(text);
  text = stripWrapping(text);
  if (!text) return null;

  const alias = ALIAS_BY_LOWER.get(text.toLowerCase());
  if (alias) return alias;

  const transfer = /^transfer\s+to\s+(.+)$/i.exec(text);
  if (transfer) {
    const party = cleanMerchantName(transfer[1]);
    if (!party || baseWeaknessReason(party) || /^transfer\s+to\b/i.test(party)) return null;
    return `Transfer to ${party}`;
  }

  if (baseWeaknessReason(text)) return null;
  return text;
}

/** True when the value cannot safely be displayed or stored as a merchant. */
function isWeakMerchantName(value) {
  return cleanMerchantName(value) === null;
}

function normalizeForMatch(value) {
  return String(value || '')
    .normalize('NFKC')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]/gu, '');
}

function appearsInMessage(value, body) {
  const normalized = normalizeForMatch(value);
  if (normalized.length < 2) return false;
  const normalizedBody = normalizeForMatch(body);
  if (!normalizedBody) return false;
  if (normalized.length >= 4) return normalizedBody.includes(normalized);

  // Short brands such as "Vi" must match as a whole token, otherwise "view"
  // would count as evidence for "Vi".
  const escaped = String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(
    `(?:^|[^\\p{L}\\p{N}])${escaped}(?:$|[^\\p{L}\\p{N}])`,
    'iu',
  ).test(String(body || ''));
}

function hasAny(body, pattern) {
  return pattern.test(String(body || ''));
}

/**
 * The transaction context each parser-emitted label actually implies. A label
 * is grounded only by its own family's wording: "Bank transfer" must not be
 * bought by the word "bank" in an ordinary card/UPI debit, "Refund" must not
 * be bought by "cashback", and "Credit card bill payment" needs a bill — not
 * just a card purchase. Explicit literal spelling of an alias is not evidence
 * either; it always goes through these semantics.
 */
const ALIAS_EVIDENCE = new Map([
  ['Amazon Pay Later', /\b(?:pay\s+later|axio)\b/i],
  ['Bank or service fee', /\b(?:fees?|charges?)\b/i],
  ['Bank transfer',
    /\b(?:credited|received|deposited)\b[^.!?\n]{0,100}\bfrom\b[^.!?\n]{0,60}\b(?:bank|a\/?c\.?|account)\b|\bfrom\b[^.!?\n]{0,100}\b(?:bank|a\/?c\.?|account)\b[^.!?\n]{0,60}\b(?:credited|received|deposited)\b/i],
  ['Card statement adjustment',
    /\b(?:card|statement)\b[^.!?\n]{0,60}\b(?:credited|adjusted|adjustment)\b|\bcredit(?:ed)?\s+to\s+(?:your\s+)?(?:\w+\s+){0,3}(?:credit\s+)?card\b/i],
  ['Cash deposit',
    /\bcash\b[^.!?\n]{0,40}\bdeposit(?:ed)?\b|\bdeposit(?:ed)?\b[^.!?\n]{0,40}\bcash\b/i],
  ['Cash withdrawal',
    /\b(?:cash|atm)\b[^.!?\n]{0,40}\bwithdraw(?:al|n)?\b|\bwithdraw(?:al|n)?\b[^.!?\n]{0,40}\b(?:cash|atm)\b/i],
  ['Credit card bill payment',
    /\b(?:credit\s+card|card)\b[^.!?\n]{0,80}\bbill\b|\bbill\s+payment\b[^.!?\n]{0,60}\b(?:credit\s+)?card\b|\bcard\s+bill(?:\s+payment)?\b/i],
  ['Gift received',
    /\bgift\b[^.!?\n]{0,40}\b(?:received|credited)\b|\b(?:received|credited)\b[^.!?\n]{0,40}\bgift\b/i],
  ['Investment contribution',
    /\b(?:sip|systematic\s+investment|mutual\s+fund|invested\s+in)\b/i],
  ['Investment proceeds',
    /\b(?:proceeds|redemption|redeem(?:ed)?|payout)\b[^.!?\n]{0,60}\b(?:invest|fund|mutual|broker|securities)\b|\b(?:invest|fund|mutual|broker|securities)\b[^.!?\n]{0,60}\b(?:proceeds|redemption|redeem(?:ed)?|payout)\b/i],
  ['Loan disbursement',
    /\b(?:loan|credit\s+line)\b[^.!?\n]{0,60}\bdisburs(?:ed|ement)\b|\bdisburs(?:ed|ement)\b[^.!?\n]{0,40}\bloan\b/i],
  ['Loan or EMI repayment',
    /\b(?:emi|loan)\b[^.!?\n]{0,60}\b(?:repay(?:ment)?|repaid|paid|debited|deducted)\b|\b(?:repay(?:ment)?|repaid)\b[^.!?\n]{0,40}\b(?:emi|loan)\b/i],
  ['Money received', /\b(?:credited|received|deposited)\b/i],
  ['Reimbursement', /\b(?:reimburse(?:ment|d)?|expense\s+claim)\b/i],
  ['Refund', /\b(?:refund(?:ed)?|chargeback)\b/i],
  ['Reversal', /\brevers(?:al|ed)\b/i],
  ['Reward or cashback',
    /\b(?:cashback|reward(?:s)?|points?|miles?)\b[^.!?\n]{0,40}\b(?:credited|received|earned|added|won)\b|\b(?:credited|received|earned|added|won)\b[^.!?\n]{0,40}\b(?:cashback|reward(?:s)?|points?|miles?)\b/i],
  ['Salary', /\b(?:salary|wages?|payroll|pension)\b/i],
  ['Transfer between own accounts',
    /\b(?:self[ -]?transfer|own\s+(?:bank\s+)?account|between\s+(?:my|your)\s+(?:bank\s+)?accounts)\b|\bfrom\s+your\b[\s\S]{0,100}\bto\s+your\b/i],
  ['Wallet load',
    /\bwallet\b[^.!?\n]{0,40}\b(?:load(?:ed)?|top[ -]?up|credited|added)\b|\b(?:load(?:ed)?|top[ -]?up)\b[^.!?\n]{0,40}\bwallet\b/i],
]);

/**
 * Grounds a merchant/party name in the message. Canonical derived labels are
 * accepted only when their own transaction context is present; "Transfer to
 * <person>" also requires the person's name in the SMS.
 *
 * Returns { ok, cleaned, grounded, derived, reason }.
 */
function merchantEvidence(value, body) {
  const cleaned = cleanMerchantName(value);
  if (!cleaned) {
    return { ok: false, cleaned: null, grounded: false, derived: false, reason: 'weak_merchant' };
  }
  const transfer = /^transfer\s+to\s+(.+)$/i.exec(cleaned);
  if (transfer) {
    const party = cleanMerchantName(transfer[1]);
    const grounded = Boolean(party && appearsInMessage(party, body));
    return {
      ok: grounded,
      cleaned,
      grounded,
      derived: true,
      reason: grounded ? null : 'transfer_party_absent',
    };
  }

  const alias = ALIAS_BY_LOWER.get(cleaned.toLowerCase());
  if (alias) {
    const cue = ALIAS_EVIDENCE.get(alias);
    const grounded = cue ? hasAny(body, cue) : appearsInMessage(alias, body);
    return { ok: grounded, cleaned, grounded, derived: true, reason: grounded ? null : 'label_absent' };
  }

  const grounded = appearsInMessage(cleaned, body);
  return {
    ok: grounded,
    cleaned,
    grounded,
    derived: false,
    reason: grounded ? null : 'merchant_absent',
  };
}

module.exports = {
  CANONICAL_MERCHANT_ALIASES,
  cleanMerchantName,
  isWeakMerchantName,
  merchantEvidence,
  appearsInMessage,
};
