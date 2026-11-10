'use strict';

// POST /sms/v2/facts:batch (WP-08).
//
// The phone uploads facts, instruments, events and ledger entries. The server
// validates against the frozen contracts and stores; it never reads SMS text.
//
// Body: JSON, optionally gzip (Content-Encoding: gzip). At most 1 MiB as sent
// and 8 MiB after inflation, at most 500 items. `?backfill=true` marks a bulk
// historical upload: transactions are recorded but card reward state is not
// touched (the contract body has no backfill field, so it is a query flag).

const zlib = require('node:zlib');
const contracts = require('./contracts');
const storage = require('./storage');
const hygiene = require('./upload_hygiene');
const { safeErrorCode } = require('../safeErrorCode');

const MAX_BODY_BYTES = 1024 * 1024;
const MAX_INFLATED_BYTES = 8 * 1024 * 1024;
const MAX_ITEMS = 500;
const LISTS = ['items', 'instruments', 'events', 'ledger'];
const ROUTE = '/sms/v2/facts\\:batch'; // Express 5: the colon must be escaped

const denied = (v) => v === false || (v && typeof v === 'object' && v.ok === false);

function fail(res, status, error, detail, extra) {
  // Only the fixed error word is logged: it says why a phone was refused and holds no value or account.
  if (status >= 400 && status < 500 && status !== 429) console.warn('sms_v2 facts:batch refused', status, error);
  return res.status(status).json({ error, ...(detail ? { detail } : {}), ...(extra || {}) });
}

// A rejected item is answered per item with a 200, so nothing else records WHY phones are refused. Count the codes
// (never ids, accounts or values) so the reason shows up in the server log.
function logRejections(results) {
  const counts = {};
  for (const result of results || []) {
    if (result.status === 'accepted' || result.status === 'duplicate') continue;
    const code = result.errors?.[0]?.code || result.status || 'unknown';
    const key = `${result.kind}:${code}`;
    counts[key] = (counts[key] || 0) + 1;
  }
  if (Object.keys(counts).length) console.warn('sms_v2 facts:batch rejected', JSON.stringify(counts));
}

function readBody(req) {
  const enc = String(req.headers['content-encoding'] || 'identity').toLowerCase();
  if (enc !== 'identity' && enc !== 'gzip') return { error: 'unsupported_encoding', status: 415 };
  if (!Buffer.isBuffer(req.body) || req.body.length === 0) return { error: 'invalid_json', status: 400 };
  let raw = req.body;
  if (enc === 'gzip') {
    try {
      raw = zlib.gunzipSync(raw, { maxOutputLength: MAX_INFLATED_BYTES });
    } catch (err) {
      const tooBig = err && (err.code === 'ERR_BUFFER_TOO_LARGE' || /larger than/i.test(String(err.message)));
      return tooBig ? { error: 'payload_too_large', status: 413 } : { error: 'invalid_json', status: 400 };
    }
  }
  if (raw.length > MAX_INFLATED_BYTES) return { error: 'payload_too_large', status: 413 };
  try {
    const parsed = JSON.parse(raw.toString('utf8'));
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return { error: 'invalid_json', status: 400 };
    return { body: parsed };
  } catch (_) {
    return { error: 'invalid_json', status: 400 };
  }
}

function createFactsHandler({ withUserClient, hooks, deps, categoryOnly = false }) {
  return async function factsHandler(req, res) {
    try {
      if (denied(await hooks.security.verifyAttestation(req))) return fail(res, 403, 'attestation_required');
    } catch (err) {
      console.error('sms_v2 attestation hook failed', safeErrorCode(err));
      return fail(res, 503, 'security_unavailable');
    }
    // A request that fails before contract validation has already cost an
    // inflate and a parse, so it spends one admission unit like any other.
    const chargeRejected = async () => {
      try {
        return denied(await hooks.security.checkRate(req, 'facts:batch', 1)) ? 'limited' : null;
      } catch (err) {
        console.error('sms_v2 rate hook failed', safeErrorCode(err));
        return 'unavailable';
      }
    };
    const refuse = async (status, error, detail) => {
      const outcome = await chargeRejected();
      if (outcome === 'limited') return fail(res, 429, 'rate_limited');
      if (outcome === 'unavailable') return fail(res, 503, 'security_unavailable');
      return fail(res, status, error, detail);
    };
    const parsed = readBody(req);
    if (parsed.error) return refuse(parsed.status, parsed.error);
    const { body } = parsed;
    // Every list is capped, and the daily budget is charged for the largest
    // one, so a body of events or ledger rows cannot skip the item limit.
    const sizes = LISTS.map((key) => (Array.isArray(body[key]) ? body[key].length : 0));
    if (Math.max(...sizes) > MAX_ITEMS) {
      return refuse(413, 'request.facts_batch.items_too_many', `A batch holds at most ${MAX_ITEMS} items, instruments, events and ledger entries each.`);
    }
    try {
      const units = Math.max(1, ...sizes);
      if (denied(await hooks.security.checkRate(req, 'facts:batch', units))) return fail(res, 429, 'rate_limited');
    } catch (err) {
      console.error('sms_v2 rate hook failed', safeErrorCode(err));
      return fail(res, 503, 'security_unavailable');
    }
    // A sender header with a character the brand pattern refuses must not cost the phone its whole batch.
    hygiene.cleanSenderBrands(body);
    const check = contracts.validateRequest('facts_batch', body);
    if (!check.ok) {
      return fail(res, 400, check.errors[0].code, `${check.errors.length} validation error(s)`, { errors: check.errors.slice(0, 50) });
    }
    // The contract accepts a year the database cannot store (0000); left alone it fails the insert with a 500.
    const oddTimes = hygiene.implausibleTimes(body);
    if (oddTimes.length) {
      return fail(res, 400, 'common.timestamp_invalid', `${oddTimes.length} timestamp(s) outside ${hygiene.YEAR_FROM}-${hygiene.YEAR_TO}`, {
        errors: oddTimes.map((path) => ({ code: 'common.timestamp_invalid', path })),
      });
    }
    if (categoryOnly && (body.items.length || body.instruments.length || body.events.length)) {
      return fail(res, 400, 'invalid_request', 'A category refresh contains ledger entries only.');
    }
    const backfill = categoryOnly || String(req.query.backfill || '').toLowerCase() === 'true';
    try {
      const out = await withUserClient(req.userId, (client) => storage.ingestBatch(client, req.userId, body, { backfill, categoryOnly, deps, hooks }));
      logRejections(out.results);
      return res.status(200).json({ results: out.results, serverTime: new Date().toISOString() });
    } catch (err) {
      console.error('sms_v2 facts:batch failed', safeErrorCode(err));
      return fail(res, 500, 'internal_error');
    }
  };
}

// Reads the body as sent (no inflation), at most MAX_BODY_BYTES. body-parser
// cannot do this: it refuses any content-encoding when inflate is off.
function readRawBody(req, res, next) {
  const chunks = [];
  let size = 0;
  let tooLarge = false;
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_BODY_BYTES) {
      tooLarge = true;
      if (size > 4 * MAX_BODY_BYTES) req.destroy(); // stop draining a hostile sender
      return;
    }
    chunks.push(chunk);
  });
  req.on('end', () => {
    if (tooLarge) return fail(res, 413, 'payload_too_large');
    req.body = Buffer.concat(chunks);
    return next();
  });
  req.on('error', () => { if (!res.headersSent) fail(res, 400, 'invalid_json'); });
  return undefined;
}

function registerFactsRoute(app, { requireSmsV2, requireMember, withUserClient, hooks, deps }) {
  app.post(ROUTE, requireSmsV2, requireMember, readRawBody, createFactsHandler({ withUserClient, hooks, deps }));
  app.post('/sms/v2/categories\\:batch', requireSmsV2, requireMember, readRawBody,
    createFactsHandler({ withUserClient, hooks, deps, categoryOnly: true }));
}

module.exports = { registerFactsRoute, createFactsHandler, readBody, MAX_BODY_BYTES, MAX_INFLATED_BYTES, MAX_ITEMS, ROUTE, logRejections };
