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

const DATE_TOKEN = String.raw`(?:\d{1,2}[./-]\d{1,2}[./-]\d{2,4}|\d{1,2}\s+[A-Za-z]{3,9}\s+\d{2,4}|[A-Za-z]{3,9}\s+\d{1,2},?\s+\d{2,4})`;

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
  let match = text.match(/^(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})$/);
  if (match) {
    const date = validDate(Number(match[3]), Number(match[2]), Number(match[1]));
    return date ? { date, day: date.getDate() } : null;
  }

  match = text.match(/^(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{2,4})$/);
  if (match) {
    const month = MONTHS[match[2].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[1])) : null;
    return date ? { date, day: date.getDate() } : null;
  }

  match = text.match(/^([A-Za-z]{3,9})\s+(\d{1,2}),?\s+(\d{2,4})$/);
  if (match) {
    const month = MONTHS[match[1].toLowerCase()];
    const date = month ? validDate(Number(match[3]), month, Number(match[2])) : null;
    return date ? { date, day: date.getDate() } : null;
  }

  return null;
}

function extractDueDate(body) {
  const text = String(body || '').replace(/\s+/g, ' ').trim();
  if (!text) return null;

  const patterns = [
    new RegExp(`\\b(?:payment|amount|minimum|bill|total)?\\s*(?:is\\s+)?due\\s*(?:date\\s*)?(?:is|on|by|:|-)?\\s*(${DATE_TOKEN})`, 'i'),
    new RegExp(`\\bdue\\s+date\\s*(?:is|on|by|:|-)?\\s*(${DATE_TOKEN})`, 'i'),
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
  const match = String(text || '').match(
    /\b(?:credit\s+card|card)\b[\s\S]{0,80}?(?:ending(?:\s+(?:in|with))?|last\s*4|x{1,4}|\*{1,4}|\.{2,})\s*([0-9]{4})\b/i,
  );
  return match ? match[1] : null;
}

module.exports = { extractDueDate, extractLast4 };
