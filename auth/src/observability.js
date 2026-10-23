/**
 * Structured request logging with correlation ids — auth/'s side of the same
 * gap api/src/observability.js closed. Before this, auth/ had no request
 * logger and no terminal error-handling middleware at all: a rejected async
 * route handler had nothing standing between it and an unhandled rejection,
 * and every signal was whatever an individual route's own try/catch happened
 * to `console.log`/`console.error`, uncorrelated across a request.
 *
 * Deliberately the same shape as api/'s version, not a new design — same
 * reasoning applies twice over here: this service handles phone numbers,
 * OTPs, and refresh tokens, so the logger cannot be handed a request body or
 * an unredacted query string, and no vendor SDK is wired in pending a DPDP
 * review of what a hosted log platform would actually receive.
 */

const crypto = require('crypto');

// Query values include contacts, locations and arbitrary provider tokens.
// Drop the query entirely; a denylist cannot cover future or encoded keys.
function safeUrl(originalUrl) {
  return String(originalUrl).split('?')[0];
}

function requestPath(req) {
  return typeof req.route?.path === 'string'
    ? safeUrl(`${req.baseUrl || ''}${req.route.path}`)
    : '[unmatched]';
}

function correlationId(req) {
  const supplied = req.get('x-request-id');
  return typeof supplied === 'string' && /^[A-Za-z0-9._-]{1,128}$/.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

function log(level, fields) {
  const line = JSON.stringify({ level, ts: new Date().toISOString(), ...fields });
  if (level === 'error') {
    process.stderr.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
}

function requestLogger(req, res, next) {
  const requestId = correlationId(req);
  req.requestId = requestId;
  res.setHeader('x-request-id', requestId);

  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    log(res.statusCode >= 500 ? 'error' : 'info', {
      msg: 'request',
      requestId,
      method: req.method,
      path: requestPath(req),
      status: res.statusCode,
      durationMs: Math.round(durationMs * 10) / 10,
      // req.userId is set by authMiddleware on the routes that require it;
      // undefined elsewhere, which is the honest signal for "unauthenticated
      // request" rather than a fabricated value.
      userId: req.userId || null,
    });
  });

  next();
}

/**
 * Terminal error handler. Must be registered last, after every route and
 * after the existing CORS-error handler in index.js — Express only routes to
 * a 4-arg middleware when something upstream calls `next(err)` or an async
 * handler rejects.
 */
function errorHandler(err, req, res, _next) {
  log('error', {
    msg: 'unhandled',
    requestId: req.requestId || null,
    method: req.method,
    path: requestPath(req),
    error: 'request_failed',
  });
  if (res.headersSent) return;
  res.status(500).json({ error: 'internal_error', requestId: req.requestId });
}

module.exports = { requestLogger, errorHandler, log, safeUrl, correlationId };
