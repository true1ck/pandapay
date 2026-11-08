'use strict';
/**
 * Display data for a verified phone number: country code and a mask.
 * The country comes from parsing the number itself (never from account data).
 * Never throws: on any problem it falls back to a last-4-only mask.
 */
const { parsePhoneNumberFromString } = require('libphonenumber-js/min');

const DOT = '•';

function maskNational(national) {
  const digits = String(national);
  if (digits.length < 8) return DOT.repeat(3) + digits.slice(-3);
  const shape = digits.slice(0, 2) + DOT.repeat(digits.length - 6) + digits.slice(-4);
  const groups = [];
  for (let i = 0; i < shape.length; i += 5) groups.push(shape.slice(i, i + 5));
  return groups.join(' ');
}

/** {countryCode:'+91', mask:'+91 72••• •4821', last4} for an E.164 string. */
function describePhone(e164) {
  const last4 = String(e164).replace(/\D/g, '').slice(-4);
  try {
    const parsed = parsePhoneNumberFromString(String(e164));
    if (parsed && parsed.countryCallingCode && parsed.nationalNumber) {
      const countryCode = `+${parsed.countryCallingCode}`;
      return { countryCode, mask: `${countryCode} ${maskNational(parsed.nationalNumber)}`, last4 };
    }
  } catch (_) { /* display data must never break a request */ }
  return { countryCode: '', mask: `${DOT.repeat(4)} ${last4}`, last4 };
}

module.exports = { describePhone, maskNational };
