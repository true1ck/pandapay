'use strict';

// A "claimed" phone is a number the person typed in. It is NOT verified: no
// code was sent to it. Its only job is to lock that number to one live account.
// Everything that decides which number a typed value means lives here, so the
// route, the rate limits and the database all see the same canonical form.

// Add a country here (with a real national-number rule) before listing it in
// PHONE_ALLOWED_COUNTRIES. India only for now.
const COUNTRIES = Object.freeze({
  IN: Object.freeze({ callingCode: '91', national: /^[6-9]\d{9}$/ }),
});

const DEFAULT_COUNTRIES = Object.freeze(['IN']);

function parseAllowedCountries(value) {
  if (value === undefined || value === null || String(value).trim() === '') return [...DEFAULT_COUNTRIES];
  const codes = String(value).split(',').map(part => part.trim().toUpperCase()).filter(Boolean);
  if (codes.length === 0) return [...DEFAULT_COUNTRIES];
  for (const code of codes) {
    if (!Object.hasOwn(COUNTRIES, code)) throw new Error(`PHONE_ALLOWED_COUNTRIES names an unsupported country: ${code}`);
  }
  return [...new Set(codes)];
}

function allSameDigit(value) {
  return /^(\d)\1+$/.test(value);
}

/**
 * Turn what a person typed into one canonical number, or say why not.
 * Accepts: 9876543210, 09876543210, 919876543210, +91 98765 43210,
 * +91-98765-43210, 0091 9876543210. A bare number means the first allowed country.
 * Returns { ok: true, phone: '+919876543210' } or { ok: false, reason }.
 */
function parseClaimedPhone(input, { countries = DEFAULT_COUNTRIES } = {}) {
  if (typeof input !== 'string') return { ok: false, reason: 'invalid' };
  const raw = input.trim();
  if (raw.length < 7 || raw.length > 32 || !/^\+?[\d\s().-]+$/.test(raw)) return { ok: false, reason: 'invalid' };
  const hasPlus = raw.startsWith('+');
  let digits = raw.replace(/\D/g, '');
  if (!hasPlus && digits.startsWith('00')) {
    digits = digits.slice(2);
    return matchInternational(digits, countries);
  }
  if (hasPlus) return matchInternational(digits, countries);

  // No plus sign. Try each allowed country: bare national number, a leading
  // trunk 0, or the calling code written without the plus.
  const candidates = [];
  for (const code of countries) {
    const country = COUNTRIES[code];
    candidates.push({ country, national: digits });
    if (digits.startsWith('0')) candidates.push({ country, national: digits.slice(1) });
    if (digits.startsWith(country.callingCode)) candidates.push({ country, national: digits.slice(country.callingCode.length) });
  }
  for (const { country, national } of candidates) {
    if (country.national.test(national) && !allSameDigit(national)) {
      return { ok: true, phone: `+${country.callingCode}${national}` };
    }
  }
  return { ok: false, reason: 'invalid' };
}

function matchInternational(digits, countries) {
  if (digits.length < 8 || digits.length > 15) return { ok: false, reason: 'invalid' };
  for (const code of countries) {
    const country = COUNTRIES[code];
    if (!digits.startsWith(country.callingCode)) continue;
    const national = digits.slice(country.callingCode.length);
    if (country.national.test(national) && !allSameDigit(national)) {
      return { ok: true, phone: `+${country.callingCode}${national}` };
    }
    return { ok: false, reason: 'invalid' };
  }
  return { ok: false, reason: 'unsupported_country' };
}

function canonicalizeClaimedPhone(input, options) {
  const parsed = parseClaimedPhone(input, options);
  return parsed.ok ? parsed.phone : null;
}

module.exports = { COUNTRIES, parseAllowedCountries, parseClaimedPhone, canonicalizeClaimedPhone };
