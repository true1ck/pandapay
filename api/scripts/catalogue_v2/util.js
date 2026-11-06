'use strict';

// Small, dependency-free helpers shared by the loader v2 modules.

// CardPipeline uses the literal "N/A" for "does not apply" and null for "not
// verified". Both mean "nothing usable here".
function isNA(v) {
  return v === null || v === undefined || v === 'N/A' || v === 'n/a';
}

function asNumber(v) {
  if (isNA(v) || v === '' || typeof v === 'boolean') return null;
  const n = typeof v === 'number' ? v : Number(String(v).replace(/,/g, '').trim());
  return Number.isFinite(n) ? n : null;
}

function firstDefined(...vals) {
  for (const v of vals) if (!isNA(v)) return v;
  return null;
}

function uniq(values) {
  return [...new Set(values)];
}

// Plan C5 normalize(): lowercase, every non-alphanumeric run -> one space, trim.
function normalizeText(s) {
  return String(s ?? '')
    .toLowerCase()
    .replace(/₹/g, ' ')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

// True when `needle` appears in `hay` on word boundaries (both normalised).
function containsWords(hay, needle) {
  const h = ` ${normalizeText(hay)} `;
  const n = normalizeText(needle);
  return n !== '' && h.includes(` ${n} `);
}

const MAX_MCC_RANGE = 1000;

// Converts a source MCC list (numbers, numeric strings, "3000-3350" ranges,
// sometimes 3-digit agricultural codes) into 4-digit strings. Anything that
// can't be read is returned in `invalid` so the caller can refuse to treat a
// half-read list as complete.
function normalizeMccList(raw) {
  const out = [];
  const invalid = [];
  // D20d: a code of one or two digits (or more than four) can't be a real
  // MCC; it is reported and dropped rather than padded into a fake one.
  // Three-digit codes are real (0742 veterinary, 0763 agriculture).
  const malformed = [];
  const items = Array.isArray(raw) ? raw : isNA(raw) ? [] : [raw];
  for (const item of items) {
    if (item === null || item === undefined || item === '') continue;
    if (typeof item === 'number' && Number.isInteger(item)) {
      if (item >= 100 && item <= 9999) out.push(String(item).padStart(4, '0'));
      else malformed.push(item);
      continue;
    }
    const text = String(item).trim();
    if (/^\d{1,2}$|^\d{5,}$/.test(text)) {
      malformed.push(item);
      continue;
    }
    // A comma-separated string of codes.
    if (/^\d{3,4}(\s*,\s*\d{3,4})+$/.test(text)) {
      for (const part of text.split(',')) out.push(part.trim().padStart(4, '0'));
      continue;
    }
    const single = text.match(/^(?:mcc\s*)?(\d{3,4})$/i);
    if (single) {
      out.push(single[1].padStart(4, '0'));
      continue;
    }
    const range = text.match(/^(\d{3,4})\s*(?:-|–|to)\s*(\d{3,4})$/i);
    if (range) {
      const lo = Number(range[1]);
      const hi = Number(range[2]);
      if (hi >= lo && hi - lo < MAX_MCC_RANGE) {
        for (let m = lo; m <= hi; m++) out.push(String(m).padStart(4, '0'));
        continue;
      }
    }
    invalid.push(item);
  }
  return { mccs: uniq(out).sort(), invalid, malformed };
}

function deepClone(value) {
  return value === undefined ? undefined : JSON.parse(JSON.stringify(value));
}

module.exports = {
  asNumber,
  containsWords,
  deepClone,
  firstDefined,
  isNA,
  normalizeMccList,
  normalizeText,
  uniq,
};
