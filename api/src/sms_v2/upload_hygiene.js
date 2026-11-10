'use strict';

// What POST /sms/v2/facts:batch tolerates in a batch, and what it refuses
// cleanly, before storage runs.
//
// Two ordinary things used to stop a phone's whole upload queue. A sender
// header with a character the brand pattern does not allow (`SBI-UPI`,
// `HDFC_BK`, `Paytm Bank`) made the contract refuse the batch it was in, and a
// timestamp that passes the contract but not the database (year 0000) made
// the insert fail with a 500. Either way every record behind that batch
// waited, and the phone retried the same batch for good.

const BRAND_SHAPE = /^[A-Z0-9]+$/;

/**
 * The brand in the only shape the server stores: capital letters and digits,
 * at most 32. A header that is only a long number is a person's phone number
 * and is never kept as digits. Same rule as `uploadSenderBrand` on the phone.
 */
function cleanSenderBrand(value) {
  const upper = String(value).toUpperCase();
  const cleaned = upper.replace(/[^A-Z0-9]/g, '');
  if (!cleaned) return 'UNKNOWN';
  if (cleaned.length >= 10 && !/[A-Z]/.test(upper)) return 'NUMBER';
  return cleaned.slice(0, 32);
}

/** Cleans `senderBrand` on every source group of [body] in place. Returns how many it changed. */
function cleanSenderBrands(body) {
  let changed = 0;
  if (!body || !Array.isArray(body.items)) return changed;
  for (const item of body.items) {
    if (!item || typeof item.senderBrand !== 'string' || BRAND_SHAPE.test(item.senderBrand)) continue;
    item.senderBrand = cleanSenderBrand(item.senderBrand);
    changed += 1;
  }
  return changed;
}

// The database's own limits are far wider (year 1 to 294276, with no year 0).
// No bank message is dated outside these.
const YEAR_FROM = 1970;
const YEAR_TO = 2199;
const TIME = /^(\d{4})-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/;

/**
 * JSON paths of the timestamps in [body] whose year no real message carries.
 * Called after the contract has accepted the body, so every such string is
 * already a well-formed UTC time. At most [limit] paths.
 */
function implausibleTimes(body, limit = 20) {
  const found = [];
  const stack = [['', body]];
  while (stack.length && found.length < limit) {
    const [path, value] = stack.pop();
    if (typeof value === 'string') {
      const m = TIME.exec(value);
      if (m) {
        const year = Number(m[1]);
        if (year < YEAR_FROM || year > YEAR_TO) found.push(path);
      }
    } else if (Array.isArray(value)) {
      for (let i = value.length - 1; i >= 0; i -= 1) stack.push([`${path}/${i}`, value[i]]);
    } else if (value && typeof value === 'object') {
      for (const key of Object.keys(value)) stack.push([`${path}/${key}`, value[key]]);
    }
  }
  return found;
}

module.exports = { cleanSenderBrand, cleanSenderBrands, implausibleTimes, YEAR_FROM, YEAR_TO };
