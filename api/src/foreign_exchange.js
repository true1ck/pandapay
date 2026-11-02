'use strict';

// Rates are public reference data. No account identifiers or SMS text leave
// the service. Decimal text and integer arithmetic avoid binary-money drift.
// ISO 4217 accounting units; Intl display rounding can differ (PKR/HUF/IQD).
const MINOR_UNITS = require('./currency_minor_units.json');
const CURRENCIES = new Set(Object.keys(MINOR_UNITS));
const MAX_INR_MINOR = 999999999999n;
function decimalParts(value, maxScale = 14) {
  if (!['string', 'number'].includes(typeof value)) return null;
  const text = String(value).trim();
  const match = /^(\d{1,16})(?:\.(\d{1,14}))?$/.exec(text);
  if (!match || (match[2] || '').length > maxScale) return null;
  const scale = (match[2] || '').length;
  return { coefficient: BigInt(match[1] + (match[2] || '')), scale, text };
}
function canonicalDecimal(value, maxScale = 14) {
  const parsed = decimalParts(value, maxScale);
  if (!parsed) return null;
  const [whole, fraction = ''] = parsed.text.split('.');
  return `${BigInt(whole)}${fraction.replace(/0+$/, '') ? `.${fraction.replace(/0+$/, '')}` : ''}`;
}
function currencyPrecision(currency) {
  if (!CURRENCIES.has(currency)) return null;
  return MINOR_UNITS[currency];
}
function originalAmount(value, currency) {
  const precision = currency ? currencyPrecision(currency) : 4;
  if (precision === null) return null;
  const normalized = canonicalDecimal(value, 4);
  const parsed = decimalParts(normalized, precision);
  if (!parsed || parsed.coefficient <= 0n || parsed.coefficient > 9999999999999999n) return null;
  return canonicalDecimal(normalized, precision);
}
function inrAmount(value) {
  const parsed = decimalParts(value, 2);
  if (!parsed || parsed.coefficient <= 0n) return null;
  const paise = parsed.coefficient * (10n ** BigInt(2 - parsed.scale));
  return paise <= MAX_INR_MINOR ? minorToInr(paise) : null;
}
function minorToInr(value) {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  return `${negative ? '-' : ''}${abs / 100n}.${String(abs % 100n).padStart(2, '0')}`;
}
function inrMinor(value) {
  const p = decimalParts(value, 2);
  return p ? p.coefficient * (10n ** BigInt(2 - p.scale)) : null;
}
function convertToInr(amount, rate) {
  const a = decimalParts(amount, 4), r = decimalParts(rate, 14);
  if (!a || !r || a.coefficient <= 0n || r.coefficient <= 0n) return null;
  const numerator = a.coefficient * r.coefficient * 100n;
  const denominator = 10n ** BigInt(a.scale + r.scale);
  const paise = (numerator + denominator / 2n) / denominator;
  return paise > 0n && paise <= MAX_INR_MINOR ? minorToInr(paise) : null;
}
function calendarDay(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === value;
}
function accountingDay(value) {
  const date = new Date(value);
  return Number.isFinite(date.getTime())
    ? new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Kolkata', year: 'numeric', month: '2-digit', day: '2-digit' }).format(date)
    : null;
}
function validateRate(payload, currency, requestedDay) {
  if (!payload || Array.isArray(payload) || String(payload.base).toUpperCase() !== currency
      || String(payload.quote).toUpperCase() !== 'INR' || !calendarDay(payload.date)
      || payload.date > requestedDay || Date.parse(requestedDay) - Date.parse(payload.date) > 31 * 86400000) return null;
  const rate = canonicalDecimal(payload.rate);
  const parsed = decimalParts(rate);
  if (!parsed || parsed.coefficient <= 0n || Number(rate) < 1e-12 || Number(rate) > 1e12) return null;
  return { rate, rate_date: payload.date, rate_source: 'Frankfurter reference rate' };
}
async function readBoundedJson(response) {
  if (!response.ok) return null;
  if (Number(response.headers?.get('content-length') || 0) > 16384) return null;
  if (!response.body?.getReader) {
    const text = await response.text();
    return Buffer.byteLength(text) <= 16384 ? JSON.parse(text) : null;
  }
  const reader = response.body.getReader();
  let bytes = 0;
  const chunks = [];
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > 16384) { await reader.cancel(); return null; }
      chunks.push(Buffer.from(value));
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } finally { reader.releaseLock(); }
}
function createForeignExchangeService({ withUserClient, fetchImpl = globalThis.fetch, now = () => new Date(), timeoutMs = 3500, maxConcurrent = 2 } = {}) {
  const inFlight = new Map(), retryAfter = new Map();
  async function getRate(userId, currency, day) {
    if (!CURRENCIES.has(currency) || currency === 'INR' || !calendarDay(day) || day > accountingDay(now())) return null;
    const key = `${currency}:${day}`;
    if (inFlight.has(key)) return inFlight.get(key);
    if ((retryAfter.get(key) || 0) > now().getTime()) return null;
    const cached = await withUserClient(userId, async (client) => {
      const result = await client.query('SELECT rate::text, rate_date::text, rate_source FROM foreign_exchange_rates WHERE currency = $1 AND requested_date = $2', [currency, day]);
      return result.rows[0] || null;
    });
    if (cached) return validateRate({ base: currency, quote: 'INR', date: String(cached.rate_date).slice(0, 10), rate: cached.rate }, currency, day);
    if (inFlight.has(key)) return inFlight.get(key);
    if (inFlight.size >= maxConcurrent || typeof fetchImpl !== 'function') return null;
    const work = (async () => {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);
      try {
        const response = await fetchImpl(`https://api.frankfurter.dev/v2/rate/${currency.toLowerCase()}/inr?date=${day}`, {
          signal: controller.signal, redirect: 'error', headers: { Accept: 'application/json' },
        });
        const rate = validateRate(await readBoundedJson(response), currency, day);
        if (!rate) throw new Error('invalid_reference_rate');
        return await withUserClient(userId, async (client) => {
          const result = await client.query(
            `INSERT INTO foreign_exchange_rates(currency, requested_date, rate_date, rate, rate_source)
             VALUES ($1,$2,$3,$4,$5) ON CONFLICT(currency,requested_date) DO UPDATE SET currency=EXCLUDED.currency
             RETURNING rate::text,rate_date::text,rate_source`,
            [currency, day, rate.rate_date, rate.rate, rate.rate_source],
          );
          return result.rows[0] || rate;
        });
      } catch (_) {
        if (retryAfter.size >= 1000) retryAfter.delete(retryAfter.keys().next().value);
        retryAfter.set(key, now().getTime() + 30000);
        return null;
      } finally { clearTimeout(timer); }
    })();
    inFlight.set(key, work);
    try { return await work; } finally { inFlight.delete(key); }
  }
  return { getRate };
}

module.exports = { CURRENCIES, canonicalDecimal, decimalParts, currencyPrecision, originalAmount, inrAmount, minorToInr, inrMinor, convertToInr, calendarDay, accountingDay, validateRate, createForeignExchangeService };
