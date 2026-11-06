'use strict';

const { createHash } = require('node:crypto');
const zlib = require('node:zlib');
const { promisify } = require('node:util');
const { safeErrorCode } = require('./safeErrorCode');
const { createFeedbackRateLimiter } = require('./feedback_rate_limit');

const gzip = promisify(zlib.gzip);

// GET /catalogue serves the v1 feed by default (exact shape installed apps
// parse; plan H1) and the v2 feed when ?schema=2 (plan C2).
//
// Hardening (plan D33d): per-IP rate limit, a strong ETag answered with 304
// before any heavy view query runs, Cache-Control, and gzip. None of this
// changes the decoded v1 JSON body.

const V1_SQL = 'SELECT * FROM v_card_catalogue_export ORDER BY name';
const V2_CARDS_SQL = 'SELECT * FROM v_card_catalogue_export_v2 ORDER BY name';
const V2_MERCHANTS_SQL =
  'SELECT slug, name, parent_slug, category_slug, aliases, vpa_prefixes, mcc ' +
  'FROM merchant_brands WHERE is_active ORDER BY slug';
const V2_PLATFORMS_SQL =
  'SELECT slug, name, kind, issuer_slug, aliases ' +
  'FROM payment_platforms WHERE is_active ORDER BY slug';

// One cheap query over base tables (no jsonb aggregation). Child-row changes
// bump card_products.data_version via triggers; directory rows are covered by
// max(updated_at) plus counts (payment_platforms has no updated_at).
const FINGERPRINT_SQL =
  'SELECT ' +
  '(SELECT coalesce(max(c.data_version), 0)::text FROM card_products c ' +
  "   JOIN issuers i ON i.id = c.issuer_id WHERE c.status = 'published' AND c.is_active) AS max_data_version, " +
  '(SELECT count(*)::text FROM card_products c JOIN issuers i ON i.id = c.issuer_id ' +
  "   WHERE c.status = 'published' AND c.is_active) AS card_count, " +
  "(SELECT coalesce(max(updated_at)::text, '') FROM merchant_brands) AS merchants_updated_at, " +
  '(SELECT count(*)::text FROM merchant_brands) AS merchants_total, ' +
  '(SELECT count(*)::text FROM merchant_brands WHERE is_active) AS merchants_active, ' +
  '(SELECT count(*)::text FROM payment_platforms) AS platforms_total, ' +
  '(SELECT count(*)::text FROM payment_platforms WHERE is_active) AS platforms_active';

const CACHE_CONTROL = 'public, max-age=300';
const RATE_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_PER_WINDOW = 60;

function wantsV2(req) {
  const schema = req && req.query ? req.query.schema : undefined;
  return schema === '2';
}

function acceptsGzip(req) {
  const header = req && req.headers ? req.headers['accept-encoding'] : undefined;
  if (typeof header !== 'string') return false;
  return header.split(',').some((part) => {
    const [token, ...params] = part.trim().toLowerCase().split(';');
    if (token !== 'gzip' && token !== '*') return false;
    const q = params.map((p) => p.trim()).find((p) => p.startsWith('q='));
    return !q || Number(q.slice(2)) > 0;
  });
}

function etagFor(fingerprint, v2, gzipped) {
  const hash = createHash('sha256')
    .update(JSON.stringify([v2 ? 2 : 1, fingerprint]))
    .digest('hex')
    .slice(0, 32);
  return `"${hash}${gzipped ? '-gz' : ''}"`;
}

function ifNoneMatchHits(req, etag) {
  const header = req && req.headers ? req.headers['if-none-match'] : undefined;
  if (typeof header !== 'string') return false;
  return header.split(',').some((candidate) => {
    const value = candidate.trim();
    return value === '*' || value === etag;
  });
}

function createCatalogueHandler({ withUserClient, logger = console, limiter } = {}) {
  const rateLimiter = limiter || createFeedbackRateLimiter({
    windowMs: RATE_WINDOW_MS,
    authenticatedLimit: RATE_LIMIT_PER_WINDOW,
    anonymousLimit: RATE_LIMIT_PER_WINDOW,
  });

  return async function catalogueHandler(req, res) {
    try {
      const identity = req.ip || (req.socket && req.socket.remoteAddress) || 'unknown';
      const admission = rateLimiter.consume(identity, false);
      if (!admission.allowed) {
        res.set('Retry-After', String(admission.retryAfterSeconds));
        return res.status(429).json({ error: 'rate_limited' });
      }

      const user = req.user || null;
      const v2 = wantsV2(req);
      const useGzip = acceptsGzip(req);

      const fingerprint = await withUserClient(user, async (client) => {
        const result = await client.query(FINGERPRINT_SQL);
        return result.rows[0] || {};
      });
      const etag = etagFor(fingerprint, v2, useGzip);
      const cacheHeaders = () => {
        res.set('ETag', etag);
        res.set('Cache-Control', CACHE_CONTROL);
        res.set('Vary', 'Accept-Encoding');
      };
      if (ifNoneMatchHits(req, etag)) {
        cacheHeaders();
        return res.status(304).end();
      }

      let body;
      if (v2) {
        body = await withUserClient(user, async (client) => {
          const cards = await client.query(V2_CARDS_SQL);
          const merchants = await client.query(V2_MERCHANTS_SQL);
          const platforms = await client.query(V2_PLATFORMS_SQL);
          return { schema: 2, cards: cards.rows, merchants: merchants.rows, platforms: platforms.rows };
        });
      } else {
        const result = await withUserClient(user, (client) => client.query(V1_SQL));
        body = { cards: result.rows };
      }

      cacheHeaders();
      if (!useGzip) return res.json(body);
      const compressed = await gzip(Buffer.from(JSON.stringify(body), 'utf8'));
      res.set('Content-Type', 'application/json; charset=utf-8');
      res.set('Content-Encoding', 'gzip');
      return res.status(200).send(compressed);
    } catch (err) {
      logger.error('GET /catalogue error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = {
  createCatalogueHandler, V1_SQL, V2_CARDS_SQL, V2_MERCHANTS_SQL, V2_PLATFORMS_SQL, FINGERPRINT_SQL,
};
