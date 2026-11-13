'use strict';

// LANE-D-1: the shipped (v1) app maps any entry_kind it does not know to
// `spend` (TxnEntryKind.fromJson orElse). v2 projects refunds as
// entry_kind = 'refund', so a v1 client would show a refund as spending.
//
// v1 apps send no X-App-Version, and the v2 app now sends `X-Sms-Pipeline: v2`
// only when its pipeline is on. Every JSON answer to a request WITHOUT that
// header therefore carries `transfer` (neutral: not spend, not income) in
// place of `refund`. Output only: stored rows, totals and reports are not
// touched, and v2 clients receive `refund` unchanged.

const KEYS = new Set(['entry_kind', 'entryKind']);

function isPlain(value) {
  if (value === null || typeof value !== 'object') return false;
  const proto = Object.getPrototypeOf(value);
  return proto === Object.prototype || proto === null;
}

/** Returns `value` itself when nothing needs to change, otherwise a copy. */
function downgradeRefund(value) {
  if (Array.isArray(value)) {
    let out = null;
    for (let i = 0; i < value.length; i += 1) {
      const next = downgradeRefund(value[i]);
      if (next !== value[i]) { if (!out) out = value.slice(); out[i] = next; }
    }
    return out || value;
  }
  if (!isPlain(value)) return value;
  let out = null;
  for (const key of Object.keys(value)) {
    const current = value[key];
    // 'investment_return' is as unknown to a v1 client as 'refund': it would
    // otherwise read as spending, so it too shows as a neutral transfer.
    const next = KEYS.has(key) && (current === 'refund' || current === 'investment_return')
      ? 'transfer'
      : downgradeRefund(current);
    if (next !== current) { if (!out) out = { ...value }; out[key] = next; }
  }
  return out || value;
}

function isV2Client(req) {
  const header = req.headers?.['x-sms-pipeline'];
  return String(Array.isArray(header) ? header[0] : header || '').trim().toLowerCase() === 'v2';
}

function legacyEntryKindFilter(req, res, next) {
  if (isV2Client(req)) return next();
  const json = res.json.bind(res);
  res.json = (body) => json(downgradeRefund(body));
  return next();
}

module.exports = { legacyEntryKindFilter, downgradeRefund, isV2Client };
