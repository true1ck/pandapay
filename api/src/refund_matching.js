'use strict';

/**
 * Pairs credit-card refunds with the spends they reverse, so a refunded
 * purchase stops earning (or has its reward reduced in proportion).
 *
 * Banks do not say which purchase a refund belongs to, so the pairing is a
 * conservative guess that may leave a refund unmatched but never invents one:
 *
 *   - same card (the caller passes one card's rows);
 *   - the spend is not later than the refund (one day of slack for time zones
 *     and same-minute reversals);
 *   - the spend is at most MAX_AGE_DAYS older than the refund;
 *   - the spend still has at least the refund's amount left unrefunded;
 *   - the merchant matches (equal, or one name is the other cut short — banks
 *     truncate), OR the amount is exactly the spend's amount.
 *
 * Among the candidates the best is: exact amount AND merchant match, then
 * merchant match, then exact amount; the most recent wins ties.
 *
 * Pure: no I/O, no clock.
 */

const MAX_AGE_DAYS = 180;
const SLACK_MS = 24 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;
const EPS = 0.005;

function merchantKey(value) {
  return String(value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '')
    .trim();
}

const GENERIC = new Set(['', 'unknown', 'creditcardpayment', 'moneyreceived']);

/** A merchant text that actually names a shop (not blank, "UNKNOWN" or a generic label). */
function isNamed(value) {
  return !GENERIC.has(merchantKey(value));
}

/** Equal, or one is a (5+ character) prefix of the other — a truncated bank name. */
function sameMerchant(a, b) {
  const x = merchantKey(a);
  const y = merchantKey(b);
  if (GENERIC.has(x) || GENERIC.has(y)) return false;
  if (x === y) return true;
  const [short, long] = x.length <= y.length ? [x, y] : [y, x];
  return short.length >= 5 && long.startsWith(short);
}

function cents(value) {
  return Math.round(Number(value) * 100);
}

/**
 * @param {Array} spends   active card spends: { id, amount_inr, occurred_at, merchant_name }
 * @param {Array} refunds  active card refunds: same shape
 * @returns {Map<string, number>} spend id -> total rupees refunded against it
 */
function matchRefunds(spends, refunds) {
  const out = new Map();
  const remaining = new Map();
  const pool = (spends || [])
    .filter((s) => Number(s.amount_inr) > 0)
    .map((s) => ({ ...s, time: new Date(s.occurred_at).getTime(), left: cents(s.amount_inr) }))
    .filter((s) => Number.isFinite(s.time))
    .sort((a, b) => a.time - b.time || (String(a.id) < String(b.id) ? -1 : 1));
  for (const s of pool) remaining.set(String(s.id), s.left);

  const ordered = (refunds || [])
    .filter((r) => Number(r.amount_inr) > 0)
    .map((r) => ({ ...r, time: new Date(r.occurred_at).getTime(), amt: cents(r.amount_inr) }))
    .filter((r) => Number.isFinite(r.time))
    .sort((a, b) => a.time - b.time || (String(a.id) < String(b.id) ? -1 : 1));

  for (const refund of ordered) {
    let best = null;
    let bestScore = -1;
    for (const spend of pool) {
      if (spend.time > refund.time + SLACK_MS) continue;
      if (refund.time - spend.time > MAX_AGE_DAYS * DAY_MS) continue;
      const left = remaining.get(String(spend.id));
      if (left + 0.5 < refund.amt) continue;
      const merchant = sameMerchant(spend.merchant_name, refund.merchant_name);
      const exact = cents(spend.amount_inr) === refund.amt;
      if (!merchant && !exact) continue;
      // Round amounts repeat (Rs500, Rs1,000): an equal amount alone only pairs
      // when one side names no merchant. Two different named shops never pair.
      if (!merchant && isNamed(spend.merchant_name) && isNamed(refund.merchant_name)) continue;
      const score = (merchant ? 2 : 0) + (exact ? 1 : 0);
      if (score > bestScore || (score === bestScore && spend.time > best.time)) {
        best = spend;
        bestScore = score;
      }
    }
    if (!best) continue;
    remaining.set(String(best.id), remaining.get(String(best.id)) - refund.amt);
    out.set(String(best.id), Math.round(((out.get(String(best.id)) || 0) * 100 + refund.amt)) / 100);
  }
  return out;
}

/** The spend's amount after refunds, never below zero; the rows are not mutated. */
function netOfRefunds(spend, refundedInr) {
  const refunded = Number(refundedInr) || 0;
  if (refunded <= EPS) return spend;
  const net = Math.max(0, Math.round((Number(spend.amount_inr) - refunded) * 100) / 100);
  return { ...spend, amount_inr: net, refunded_inr: refunded };
}

module.exports = { matchRefunds, netOfRefunds, sameMerchant, merchantKey, MAX_AGE_DAYS };
