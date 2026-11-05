'use strict';

// Small validators the SMS rule-bundle admin routes still use. They were part
// of the removed per-user learning pipeline; only these two survived.

const RESIDUAL_CAPS_RUN = /\b[A-Z]{2,30}(?:\s+[A-Z]{2,30})+\b/;

/** Redacts high-risk identifiers from sample text before it is shown to admins. */
function redactBody(body) {
  return String(body || '')
    .replace(/https?:\/\/\S+/gi, '[URL]')
    .replace(/\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/g, '[EMAIL]')
    .replace(/\b(?:\+?91|0)?[6-9]\d{9}\b/g, '[PHONE]')
    .replace(/(?<!\d)(?:\d[ -]?){11,18}\d(?!\d)/g, (val) => {
      const digits = val.replace(/\D/g, '');
      return `XXXX${digits.slice(-4)}`;
    });
}

function safeAdminPattern(pattern) {
  if (typeof pattern !== 'string' || !pattern.trim() || pattern.length > 250 || pattern.includes('@')) return null;
  if (redactBody(pattern) !== pattern) return null;
  const identifierCheckText = pattern.replace(/\{[A-Z_]+\}/g, ' ');
  const letters = identifierCheckText.replace(/[^A-Za-z]/g, '');
  if (letters) {
    const upperRatio = letters.replace(/[^A-Z]/g, '').length / letters.length;
    if (upperRatio < 0.8 && RESIDUAL_CAPS_RUN.test(identifierCheckText)) return null;
  }
  return pattern;
}

const CATEGORY_CONTEXT_TOKENS = new Set([
  'BROADBAND', 'CAB', 'DIESEL', 'DINING', 'EDUCATION', 'ELECTRICITY', 'EMI',
  'ENTERTAINMENT', 'FLIGHT', 'FUEL', 'GROCERIES', 'GROCERY', 'HOSPITAL',
  'HOTEL', 'INSURANCE', 'INVESTMENT', 'LOAN', 'MEDICAL', 'MOVIE', 'MUTUAL',
  'PHARMACY', 'PETROL', 'RENEWAL', 'RENEWED', 'RENT', 'RESTAURANT', 'RIDE',
  'SALARY', 'SCHOOL', 'SUBSCRIPTION', 'SUPERMARKET', 'TAX', 'TRAIN', 'TRAVEL',
  'TUITION', 'UTILITY', 'WALLET',
]);

function validCategoryContextKey(value) {
  if (typeof value !== 'string') return false;
  const tokens = value.split('|');
  return tokens.length >= 1 && tokens.length <= 8 &&
    tokens.every((token) => CATEGORY_CONTEXT_TOKENS.has(token)) &&
    [...new Set(tokens)].sort().join('|') === value;
}

module.exports = { redactBody, safeAdminPattern, validCategoryContextKey };
