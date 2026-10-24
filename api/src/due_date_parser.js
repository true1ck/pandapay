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

// A printed Indian bank date names an India-calendar day. Pin it to midnight
// IST so the stored instant is identical whether the server clock runs in
// UTC (CI/prod) or IST (dev); `day` always comes from the IST calendar.
const IST_OFFSET_MS = 5.5 * 3600 * 1000;

const IST_DAY = new Intl.DateTimeFormat('en-CA', {
  timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit',
});

function istDayParts(value) {
  const parts = IST_DAY.formatToParts(value);
  const year = Number(parts.find((part) => part.type === 'year')?.value);
  const month = Number(parts.find((part) => part.type === 'month')?.value);
  const day = Number(parts.find((part) => part.type === 'day')?.value);
  return [year, month, day].every(Number.isInteger) ? { year, month, day } : null;
}

function validDate(year, month, day) {
  const normalizedYear = year < 100 ? year + 2000 : year;
  const value = new Date(Date.UTC(normalizedYear, month - 1, day) - IST_OFFSET_MS);
  const roundTrip = istDayParts(value);
  if (
    !roundTrip
    || roundTrip.year !== normalizedYear
    || roundTrip.month !== month
    || roundTrip.day !== day
  ) return null;
  return value;
}

function parseDateToken(token) {
  const text = String(token || '').trim();
  let match = text.match(/^(\d{4})[./-](\d{1,2})[./-](\d{1,2})$/);
  if (match) {
    const date = validDate(Number(match[1]), Number(match[2]), Number(match[3]));
    return date ? { date, day: istDayParts(date).day } : null;
  }

  match = text.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})$/);
  if (match) {
    const date = validDate(Number(match[3]), Number(match[2]), Number(match[1]));
    return date ? { date, day: istDayParts(date).day } : null;
  }

  match = text.match(/^(\d{1,2})(?:st|nd|rd|th)?[\s./-]+([A-Za-z]{3,9})[,\s./-]+(\d{2,4})$/i);
  if (match) {
    const month = MONTHS[match[2].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[1])) : null;
    return date ? { date, day: istDayParts(date).day } : null;
  }

  match = text.match(/^([A-Za-z]{3,9})[\s./-]+(\d{1,2})(?:st|nd|rd|th)?[,]?[\s./-]+(\d{2,4})$/i);
  if (match) {
    const month = MONTHS[match[1].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[2])) : null;
    return date ? { date, day: istDayParts(date).day } : null;
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
    // Some issuers put an earlier "Total Due" amount before the actual due
    // date (e.g. "Total Due: INR 30 ... Due date: 23-Sep-2026"). Match the
    // explicit label first so the earlier amount cannot shadow the date.
    new RegExp(`\\bdue\\s+date\\s*(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // Keep punctuation separate from the connector so issuer formats such as
    // "Due on: 02-11-26" and "Due by - 02/11/2026" are both accepted.
    new RegExp(`\\b(?:payment|amount|minimum|bill|total)?\\s*(?:is\\s+)?due\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // HDFC and other issuers sometimes place a relationship word between
    // "due date" and the date: "payment due date for your card is ..." or
    // "payment due date of your card is ...".  The older rule stopped at
    // "due date" and consequently missed the historical statement SMS that
    // is most useful for learning a recurring due day.
    new RegExp(`\\b(?:payment|bill|amount|minimum|total)\\s+due\\s+date\\s+(?:for|of)\\s+(?:your\\s+)?(?:credit\\s+|debit\\s+)?card(?:\\s+payment)?\\s*(?:is|on|by|:)\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\bdue\\s+date\\s+(?:for|of)\\s+(?:your\\s+)?(?:payment|bill|amount|card(?:\\s+payment)?)\\s*(?:is|on|by|:)\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // The card name/suffix may sit between the relationship word and the
    // copula: "due date for your HDFC Bank Card ending XX1234 is ...".
    // Keep the window bounded so a later unrelated date in a long message is
    // not promoted to a due date.
    new RegExp(`\\b(?:payment|bill|amount|minimum|total)\\s+due\\s+date\\b[\\s\\S]{0,120}?\\b(?:is|on|by)\\b\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // A few templates put the noun after the due phrase: "payment due on",
    // "bill payable by", or "minimum amount due date is". Keep this bounded
    // and explicit so a transaction's "paid on 02/10/2026" is not accepted.
    new RegExp(`\\b(?:payment|bill|amount|minimum\\s+amount|total\\s+amount)\\s+(?:is\\s+)?(?:due|payable)\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:due|payable)\\s+(?:for\\s+)?(?:payment|bill|amount)\\s*(?:date\\s*)?(?:is|on|by)?\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // Many issuers do not use the words "due date". They instruct the
    // customer to pay/keep/arrange the amount by a date instead. Restrict
    // this to payment-intent verbs so an ordinary transaction date cannot be
    // mistaken for a due date.
    new RegExp(`\\b(?:please\\s+)?(?:pay|keep|maintain|arrange|settle|clear|make\\s+(?:the\\s+)?payment)\\b[\\s\\S]{0,120}?\\b(?:on\\s+or\\s+before|on\\/before|latest\\s+by|by|before|on)\\s+(?:the\\s+)?(?:date\\s*)?(?:is\\s*)?(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:payment|amount|minimum|bill|total)\\b[\\s\\S]{0,100}?\\b(?:must|should|needs?\\s+to|is)(?:\\s+to)?\\s+(?:be\\s+)?(?:paid|made|cleared|settled)\\s+(?:on\\s+or\\s+before|by|before|on)\\s+(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\blast\\s+date\\s+(?:for\\s+)?(?:payment|paying|pay)\\s*(?:is|on|by|:)\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:payment|bill)\\s+(?:is\\s+)?(?:due|payable)\\s+(?:on|by)\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    // AutoPay / Auto-debit deduction alerts ("will be deducted from your A/C ... on 09/OCT/2026",
    // "deducted from ... on 09/JUL/2026", "auto-debited on 23-09-26").
    new RegExp(`\\b(?:will|shall|to)?\\s*(?:be\\s+)?(?:auto[- ]?)?(?:deducted|debited)\\b[\\s\\S]{0,70}?\\bon\\s+(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:auto[- ]?deducted|auto[- ]?debited)\\s+on\\s+(${DATE_TOKEN})`, 'i'),
  ];
  for (const pattern of patterns) {
    const match = text.match(pattern);
    if (!match) continue;
    const parsed = parseDateToken(match[1]);
    if (parsed) return { ...parsed, raw: match[1] };
  }
  return null;
}

/** Return true only for an alert about a credit-card statement/bill. */
function isCreditCardStatementAlert(body) {
  const text = String(body || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text) return false;

  const hasCardContext = /\bcredit\s+card\b/i.test(text)
    || /\b(?:card|cc)\b[\s\S]{0,45}\b(?:ending|last\s*4|no\.?|number|xx|x{2,}|\*{2,})\s*[:#.-]?\s*\d{4}\b/i.test(text);
  if (!hasCardContext) return false;

  const generated = /\b(?:e[- ]?statement|statement|bill)\b[\s\S]{0,70}\b(?:generated|ready|available|issued|created|raised|prepared)\b/i.test(text);
  // A printed billing period ("for the period 04-Sep-2026 to 03-Oct-2026")
  // is bill context on its own, even when the "ready" clause falls outside
  // the character window above.
  const periodPrinted = new RegExp(
    `\\b(?:period|cycle)\\b[\\s\\S]{0,25}?(${DATE_TOKEN})[\\s\\S]{0,15}?\\b(?:to|till|until)\\s*[:\\-]?\\s*(${DATE_TOKEN})`,
    'i',
  ).test(text);
  // A due reminder or outstanding-balance notice is not evidence of when
  // the statement was generated, even if it repeats the bill amount.
  return generated || periodPrinted;
}

function extractExplicitStatementDate(body) {
  const text = String(body || '')
    .replace(/[\u200B-\u200D\uFEFF]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
  if (!text || !isCreditCardStatementAlert(text)) return null;
  // Capture group 2 carries the cycle END date: issuing banks print the
  // statement period far more often than a generation date, and the cycle
  // closes on that printed date. That is the billing day.
  const patterns = [
    new RegExp(`\\b(?:period|cycle)\\b[\\s\\S]{0,25}?(${DATE_TOKEN})[\\s\\S]{0,15}?\\b(?:to|till|until)\\s*[:\\-]?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:statement|e[- ]?statement|bill)\\b[\\s\\S]{0,45}?\\b(?:generated|issued|created|raised|prepared|dated)\\b\\s*(?:on|is|:|-)?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:generated|issued|created|raised|prepared|dated)\\s*(?:date\\s+)?(?:on|is|:|-)?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\b(?:statement|e[- ]?statement|bill)\\s+date\\s*(?:is|on|:|-)?\\s*(${DATE_TOKEN})`, 'i'),
  ];
  // The period pattern closes with the cycle-end date in group 2; every
  // other pattern captures the printed date in group 1.
  const [periodPattern, ...printedPatterns] = patterns;
  for (const [pattern, group] of [
    [periodPattern, 2],
    ...printedPatterns.map((printed) => [printed, 1]),
  ]) {
    const match = text.match(pattern);
    if (!match) continue;
    // A due/payable clause inside the matched phrase means the captured date
    // is the PAYMENT date printed in the same bill SMS, not the billing day.
    if (/\b(?:due|payable|pay\s+by)\b/i.test(match[0])) continue;
    const parsed = parseDateToken(match[group]);
    if (parsed) return { ...parsed, raw: match[group], explicit: true };
  }
  return null;
}

function observedCalendarDay(observedAt) {
  if (!observedAt) return null;
  const value = observedAt instanceof Date ? observedAt : new Date(observedAt);
  return Number.isNaN(value.getTime()) ? null : istDayParts(value);
}

/** Extract the recurring statement day, using SMS receive date as fallback. */
function extractStatementDate(body, observedAt) {
  if (!isCreditCardStatementAlert(body)) return null;
  const explicit = extractExplicitStatementDate(body);
  if (explicit) return explicit;
  const observed = observedCalendarDay(observedAt);
  if (!observed) return null;
  return { ...observed, raw: null, explicit: false };
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

module.exports = {
  extractDueDate,
  extractLast4,
  isCreditCardStatementAlert,
  extractExplicitStatementDate,
  extractStatementDate,
};
