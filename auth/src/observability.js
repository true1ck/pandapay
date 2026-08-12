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

/** Query-string keys whose VALUES must never be logged, even in a URL. */
const SENSITIVE_QUERY_KEYS = new Set([
  'token',
  'access_token',
  'refresh_token',
  'otp',
  'code',
  'secret',
  'password',
  'signature',
  'subid',
]);

function safeUrl(originalUrl) {
  const [path, query] = String(originalUrl).split('?');
  if (!query) return path;
  const parts = query.split('&').map((pair) => {
    const [key, ...rest] = pair.split('=');
    if (rest.length === 0) return key;
    return SENSITIVE_QUERY_KEYS.has(key.toLowerCase()) ? `${key}=[redacted]` : pair;
  });
  return `${path}?${parts.join('&')}`;
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
  const requestId = req.get('x-request-id') || crypto.randomUUID();
  req.requestId = requestId;
  res.setHeader('x-request-id', requestId);

  const startedAt = process.hrtime.bigint();

  res.on('finish', () => {
    const durationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
    log(res.statusCode >= 500 ? 'error' : 'info', {
      msg: 'request',
      requestId,
      method: req.method,
      path: safeUrl(req.originalUrl),
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
    path: safeUrl(req.originalUrl),
    error: err && err.message,
    stack: err && err.stack,
  });
  if (res.headersSent) return;
  res.status(500).json({ error: 'internal_error', requestId: req.requestId });
}

module.exports = { requestLogger, errorHandler, log, safeUrl };
