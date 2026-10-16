/**
 * Extract a recurring credit-card payment due date from a bank alert.
 *
 * This parser is intentionally narrower than the spend parser. It only
 * accepts a date that is attached to an explicit "due date/payment due"
 * phrase, so transaction dates and statement dates cannot silently become a
 * payment date.
 */

const MONTHS = {
  jan: 1, january: 1,
  feb: 2, february: 2,
  mar: 3, march: 3,
  apr: 4, april: 4,
  may: 5,
  jun: 6, june: 6,
  jul: 7, july: 7,
  aug: 8, august: 8,
  sep: 9, sept: 9, september: 9,
  oct: 10, october: 10,
  nov: 11, november: 11,
  dec: 12, december: 12,
};

// Issuers use all of these in otherwise equivalent alerts: 16/10/26,
// 16-Oct-26, 16 October 2026, Oct 16, 2026, and ISO 2026-10-16. Keep the
// token strict enough that an ordinary transaction date cannot be mistaken
// for a payment date.
const DATE_TOKEN = String.raw`(?:\d{4}[./-]\d{1,2}[./-]\d{1,2}|\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{1,2}(?:st|nd|rd|th)?[\s./-]+[A-Za-z]{3,9}[,\s./-]+\d{2,4}|[A-Za-z]{3,9}[\s./-]+\d{1,2}(?:st|nd|rd|th)?[,]?[\s./-]+\d{2,4})`;

function validDate(year, month, day) {
  const normalizedYear = year < 100 ? year + 2000 : year;
  const value = new Date(normalizedYear, month - 1, day);
  if (
    value.getFullYear() !== normalizedYear
    || value.getMonth() !== month - 1
    || value.getDate() !== day
  ) return null;
  return value;
}

function parseDateToken(token) {
  const text = String(token || '').trim();
  let match = text.match(/^(\d{4})[./-](\d{1,2})[./-](\d{1,2})$/);
  if (match) {
    const date = validDate(Number(match[1]), Number(match[2]), Number(match[3]));
    return date ? { date, day: date.getDate() } : null;
  }

  match = text.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})$/);
  if (match) {
    const date = validDate(Number(match[3]), Number(match[2]), Number(match[1]));
    return date ? { date, day: date.getDate() } : null;
  }

  match = text.match(/^(\d{1,2})(?:st|nd|rd|th)?[\s./-]+([A-Za-z]{3,9})[,\s./-]+(\d{2,4})$/i);
  if (match) {
    const month = MONTHS[match[2].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[1])) : null;
    return date ? { date, day: date.getDate() } : null;
  }

  match = text.match(/^([A-Za-z]{3,9})[\s./-]+(\d{1,2})(?:st|nd|rd|th)?[,]?[\s./-]+(\d{2,4})$/i);
  if (match) {
    const month = MONTHS[match[1].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[2])) : null;
    return date ? { date, day: date.getDate() } : null;
  }

  return null;
}

function extractDueDate(body) {
  // Bank gateways occasionally insert a zero-width character when an SMS is
  // copied from the messaging app. Remove it before applying the strict
  // phrase/date rules below.
  const text = String(body || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text) return null;

  const patterns = [
    // Keep punctuation separate from the connector so issuer formats such as
    // "Due on: 02-11-26" and "Due by - 02/11/2026" are both accepted.
    new RegExp(`\\b(?:payment|amount|minimum|bill|total)?\\s*(?:is\\s+)?due\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // A few templates put the noun after the due phrase: "payment due on",
    // "bill payable by", or "minimum amount due date is". Keep this bounded
    // and explicit so a transaction's "paid on 02/10/2026" is not accepted.
    new RegExp(`\\b(?:payment|bill|amount|minimum\\s+amount|total\\s+amount)\\s+(?:is\\s+)?(?:due|payable)\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:due|payable)\\s+(?:for\\s+)?(?:payment|bill|amount)\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // Many issuers do not use the words "due date". They instruct the
    // customer to pay/keep/arrange the amount by a date instead. Restrict
    // this to payment-intent verbs so an ordinary transaction date cannot be
    // mistaken for a due date.
    new RegExp(`\\b(?:please\\s+)?(?:pay|keep|maintain|arrange|settle|clear|make\\s+(?:the\\s+)?payment)\\b[\\s\\S]{0,120}?\\b(?:on\\s+or\\s+before|on\\/before|latest\\s+by|by|before)\\s+(?:the\\s+)?(?:date\\s*)?(?:is\\s*)?(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:payment|amount|minimum|bill|total)\\b[\\s\\S]{0,100}?\\b(?:must|should|needs?\\s+to|is)(?:\\s+to)?\\s+(?:be\\s+)?(?:paid|made|cleared|settled)\\s+(?:on\\s+or\\s+before|by|before|on)\\s+(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\blast\\s+date\\s+(?:for\\s+)?(?:payment|paying|pay)\\s*(?:is|on|by|:)\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:payment|bill)\\s+(?:is\\s+)?(?:due|payable)\\s+(?:on|by)\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match) continue;
    const parsed = parseDateToken(match[1]);
    if (parsed) return { ...parsed, raw: match[1] };
  }
  return null;
}

function extractLast4(text) {
  const value = String(text || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  const match = value.match(
    /\b(?:credit\s+|debit\s+)?card\b[\s\S]{0,55}?(?:ending(?:\s+(?:in|with))?|last\s*4|(?:no|number|num)\.?\s*[:#-]?|x{1,4}|\*{1,4}|\.{2,})[\s:x*.-]*([0-9](?:[\s-]?[0-9]){3})\b/i,
  );
  if (!match) return null;
  const last4 = match[1].replace(/[\s-]/g, '');
  return /^[0-9]{4}$/.test(last4) ? last4 : null;
}

module.exports = { extractDueDate, extractLast4 };
