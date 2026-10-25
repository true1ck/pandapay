'use strict';

const { safeErrorCode } = require('./safeErrorCode');
const { createFeedbackRateLimiter } = require('./feedback_rate_limit');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATA_ERROR_REPORT_LIMITS = Object.freeze({
  fieldPath: 256, shownValue: 4000, claimedValue: 4000, sourceUrl: 2048, attachmentPath: 1024,
});
const VISIBLE_CARD_SQL = 'SELECT id FROM card_products WHERE id = $1';
const REPORT_METADATA_SQL = 'SELECT gen_random_uuid() AS id, now() AS created_at';
const INSERT_DATA_ERROR_REPORT_SQL = `INSERT INTO data_error_reports
  (id, profile_id, card_product_id, field_path, shown_value, claimed_value, source_url, attachment_path, state, created_at)
  VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'pending', now())`;

function validateDataErrorReport(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'invalid_request' };
  const { cardProductId, fieldPath } = body;
  if (typeof cardProductId !== 'string' || !cardProductId) return { error: 'cardProductId is required' };
  if (!UUID_RE.test(cardProductId)) return { error: 'invalid_card_product_id' };
  if (typeof fieldPath !== 'string' || !fieldPath.trim()) return { error: 'fieldPath is required' };
  const value = { cardProductId };
  for (const [field, maxLength] of Object.entries(DATA_ERROR_REPORT_LIMITS)) {
    const raw = body[field];
    if (raw === null || raw === undefined) {
      value[field] = null;
      continue;
    }
    if (typeof raw !== 'string' || raw.length > maxLength || raw.includes('\u0000')) {
      return { error: `invalid_${field}` };
    }
    // Preserve values and path/URL strings as supplied. Field identifiers
    // retain their existing trim behavior; none of these strings are fetched.
    value[field] = field === 'fieldPath' ? raw.trim() :
      ['sourceUrl', 'attachmentPath'].includes(field) ? raw || null : raw;
  }
  return { value };
}

function createDataErrorReportHandler({ withUserClient, limiter = createFeedbackRateLimiter(), logger = console } = {}) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  if (!limiter || typeof limiter.consume !== 'function') throw new TypeError('limiter is required');
  return async (req, res) => {
    const parsed = validateDataErrorReport(req.body);
    if (parsed.error) return res.status(400).json({ error: parsed.error });
    const authenticated = Boolean(req.userId);
    const identity = authenticated ? req.userId : (req.ip || req.socket?.remoteAddress || '');
    const rate = limiter.consume(identity, authenticated);
    if (!rate.allowed) {
      res.set?.('Retry-After', String(rate.retryAfterSeconds));
      return res.status(429).json({ error: 'data_error_report_rate_limited' });
    }

    const { cardProductId, fieldPath, shownValue, claimedValue, sourceUrl, attachmentPath } = parsed.value;
    try {
      const report = await withUserClient(req.userId || null, async client => {
        const card = await client.query(VISIBLE_CARD_SQL, [cardProductId]);
        if (!card.rows.length) return null;
        // Anonymous rows deliberately have no SELECT policy. Produce the
        // receipt from transaction metadata, without reading stored reports.
        const metadata = (await client.query(REPORT_METADATA_SQL)).rows[0];
        await client.query(INSERT_DATA_ERROR_REPORT_SQL, [metadata.id, req.userId || null, cardProductId,
          fieldPath, shownValue, claimedValue, sourceUrl, attachmentPath]);
        return { id: metadata.id, card_product_id: card.rows[0].id, field_path: fieldPath,
          state: 'pending', created_at: metadata.created_at };
      });
      if (!report) return res.status(404).json({ error: 'card_product not found' });
      return res.status(201).json({ errorReport: report });
    } catch (error) {
      logger.error('POST /data-error-reports error', safeErrorCode(error));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function registerDataErrorReportRoute(app, { optionalAuth, withUserClient, limiter, logger } = {}) {
  if (!app || typeof app.post !== 'function') throw new TypeError('app is required');
  if (typeof optionalAuth !== 'function') throw new TypeError('optionalAuth is required');
  app.post('/data-error-reports', optionalAuth, createDataErrorReportHandler({ withUserClient, limiter, logger }));
  return app;
}

module.exports = { DATA_ERROR_REPORT_LIMITS, VISIBLE_CARD_SQL, REPORT_METADATA_SQL,
  INSERT_DATA_ERROR_REPORT_SQL, validateDataErrorReport, createDataErrorReportHandler, registerDataErrorReportRoute };
