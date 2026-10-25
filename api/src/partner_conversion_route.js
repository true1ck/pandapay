'use strict';

const crypto = require('node:crypto');

const STATUSES = Object.freeze(['pending', 'approved', 'rejected', 'reversed']);
const MAX_BODY_BYTES = 16 * 1024;
const MAX_TOKEN_BYTES = 256;
const MAX_REFERENCE_BYTES = 512;
const MAX_COMMISSION = 9_999_999_999.99;
const INGEST_CONVERSION_SQL = `
  SELECT partner_webhook.ingest_conversion($1::text, $2::text, $3::numeric, $4::text) AS matched`;

function boundedText(value, maxBytes) {
  return typeof value === 'string' && value.length > 0 &&
    Buffer.byteLength(value, 'utf8') <= maxBytes && !/[\u0000-\u001f\u007f]/.test(value);
}

function validateConversion(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { error: 'invalid_request' };
  }
  try {
    if (Buffer.byteLength(JSON.stringify(body), 'utf8') > MAX_BODY_BYTES) {
      return { error: 'invalid_request' };
    }
  } catch (_) {
    return { error: 'invalid_request' };
  }
  if (!boundedText(body.clickToken, MAX_TOKEN_BYTES)) {
    return { error: 'clickToken is required' };
  }
  const status = body.status === undefined || body.status === null || body.status === ''
    ? 'pending' : body.status;
  if (!STATUSES.includes(status)) {
    return { error: `status must be one of ${STATUSES.join(', ')}` };
  }
  const commissionInr = body.commissionInr === undefined || body.commissionInr === null
    ? null : body.commissionInr;
  if (commissionInr !== null && (typeof commissionInr !== 'number' ||
      !Number.isFinite(commissionInr) || Math.abs(commissionInr) > MAX_COMMISSION)) {
    return { error: 'invalid_request' };
  }
  // Missing and empty references mean one conversion per click. A partner
  // reporting multiple conversions for a click must supply distinct refs.
  const externalRef = body.externalRef === undefined || body.externalRef === null || body.externalRef === ''
    ? null : body.externalRef;
  if (externalRef !== null && !boundedText(externalRef, MAX_REFERENCE_BYTES)) {
    return { error: 'invalid_request' };
  }
  return { clickToken: body.clickToken, status, commissionInr, externalRef };
}

function validSignature(provided, secret) {
  if (typeof provided !== 'string' || typeof secret !== 'string') return false;
  const expected = Buffer.from(secret, 'utf8');
  const actual = Buffer.from(provided, 'utf8');
  return expected.length === actual.length && crypto.timingSafeEqual(expected, actual);
}

/**
 * The supplied pool MUST use the separate partner webhook login. It has only
 * EXECUTE on a private, bounded capability; the user API pool is never used.
 * Pool configuration and shutdown belong to the server composition root.
 */
function createPartnerConversionPostHandler({ pool = null, secret = null, logger = console } = {}) {
  return async function postPartnerConversion(req, res) {
    if (typeof secret !== 'string' || !secret) {
      return res.status(503).json({ error: 'webhook_not_configured' });
    }
    if (!validSignature(req.get('x-partner-signature') || '', secret)) {
      return res.status(401).json({ error: 'invalid_signature' });
    }
    const input = validateConversion(req.body);
    if (input.error) return res.status(400).json({ error: input.error });
    if (!pool || typeof pool.query !== 'function') {
      return res.status(503).json({ error: 'webhook_not_configured' });
    }
    try {
      const result = await pool.query(INGEST_CONVERSION_SQL,
        [input.clickToken, input.status, input.commissionInr, input.externalRef]);
      if (typeof result.rows[0]?.matched !== 'boolean') throw new Error('invalid_capability_result');
      return res.status(202).json({ ok: true, matched: result.rows[0].matched });
    } catch (_) {
      if (logger && typeof logger.error === 'function') logger.error('POST /partner-conversions/webhook failed');
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = {
  INGEST_CONVERSION_SQL, MAX_BODY_BYTES, MAX_TOKEN_BYTES, MAX_REFERENCE_BYTES,
  MAX_COMMISSION, createPartnerConversionPostHandler, validateConversion, validSignature,
};
