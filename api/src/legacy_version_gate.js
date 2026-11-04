'use strict';

// WP-17 item 4: upgrade notice for the legacy SMS routes.
//
// After a configured cutoff date, the routes the old SMS pipeline used answer
// `426 Upgrade Required` to app builds older than the first v2 build. Before the
// cutoff, or when no cutoff is configured (the default), the middleware does
// nothing, so today's production app is unaffected.
//
// Phone traffic only: the AI worker's lease/heartbeat/result/retry/fail calls
// share the /ai/jobs prefix but carry no app version and stay open.

const LEGACY_PATHS = Object.freeze([
  /^\/transactions\/from-sms\/batch$/,
  /^\/sms\/facts(?:\/.*)?$/,
  /^\/ai\/jobs(?:\/.*)?$/,
  /^\/sms\/rules\/active$/,
]);
const WORKER_PATHS = Object.freeze([
  /^\/ai\/jobs\/lease$/,
  /^\/ai\/jobs\/[^/]+\/(?:heartbeat|result|retry|fail)$/,
]);

/** "1.2.3", "1.2.3+45" or "1.2.3-beta" -> [1,2,3,45]; null when it is not a version. */
function parseAppVersion(value) {
  if (typeof value !== 'string') return null;
  const match = /^\s*v?(\d{1,6})(?:\.(\d{1,6}))?(?:\.(\d{1,6}))?(?:[-][0-9A-Za-z.-]*)?(?:\+(\d{1,9}))?\s*$/.exec(value);
  if (!match) return null;
  return [match[1], match[2], match[3], match[4]].map((part) => Number(part || 0));
}

function compareVersions(a, b) {
  for (let i = 0; i < 4; i += 1) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return 0;
}

/** LEGACY_SMS_CUTOFF_DATE: unset/empty disables the gate. YYYY-MM-DD means 00:00 UTC that day. */
function parseCutoff(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  const text = String(value).trim();
  if (!/^\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z)?$/.test(text)) {
    throw new Error('LEGACY_SMS_CUTOFF_DATE must be YYYY-MM-DD or an ISO UTC timestamp ending in Z');
  }
  const date = new Date(text.length === 10 ? `${text}T00:00:00Z` : text);
  if (Number.isNaN(date.getTime())) throw new Error('LEGACY_SMS_CUTOFF_DATE is not a real date');
  return date;
}

function parseFirstVersion(value) {
  if (value === undefined || value === null || String(value).trim() === '') return null;
  if (!parseAppVersion(String(value))) throw new Error('SMS_V2_FIRST_APP_VERSION must look like 1.2.3 or 1.2.3+45');
  return String(value).trim();
}

/**
 * @param {object} o
 * @param {Date|null} o.cutoffAt              null disables the gate
 * @param {string|null} o.firstV2Version      first app version that speaks v2
 * @param {boolean} [o.blockMissingVersion]   an absent or unreadable header counts as an old app (default true:
 *                                            builds before v2 do not send X-App-Version at all)
 * @param {() => number} [o.now]
 */
function createLegacyVersionGate({ cutoffAt = null, firstV2Version = null, blockMissingVersion = true, now = Date.now } = {}) {
  if (!cutoffAt) return (_req, _res, next) => next();
  if (!firstV2Version || !parseAppVersion(firstV2Version)) {
    throw new Error('legacy gate: SMS_V2_FIRST_APP_VERSION is required when LEGACY_SMS_CUTOFF_DATE is set');
  }
  const minimum = parseAppVersion(firstV2Version);
  const cutoffMs = cutoffAt.getTime();
  return function legacyVersionGate(req, res, next) {
    if (now() < cutoffMs) return next();
    if (req.method === 'OPTIONS') return next();
    const path = String(req.path || '/').toLowerCase().replace(/\/{2,}/g, '/').replace(/(.)\/$/, '$1');
    if (!LEGACY_PATHS.some((re) => re.test(path)) || WORKER_PATHS.some((re) => re.test(path))) return next();
    const header = req.headers?.['x-app-version'];
    const parsed = parseAppVersion(Array.isArray(header) ? header[0] : header);
    if (parsed ? compareVersions(parsed, minimum) >= 0 : !blockMissingVersion) return next();
    res.set('Cache-Control', 'no-store');
    return res.status(426).json({
      error: 'upgrade_required',
      message: 'This version of PandaPay can no longer import SMS. Please update the app.',
      minimumVersion: firstV2Version,
    });
  };
}

module.exports = { createLegacyVersionGate, parseAppVersion, compareVersions, parseCutoff, parseFirstVersion, LEGACY_PATHS };
