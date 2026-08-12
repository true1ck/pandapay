/**
 * Plan Phase 0.4 — structured request logging with correlation ids.
 *
 * Before this, every server-side signal was a bare `console.error('GET /x
 * error', err)`. Three things were impossible as a result: correlating the
 * lines belonging to one request, telling a slow endpoint from a fast one, and
 * finding anything at all once the output is more than one terminal's worth.
 * A production incident would have been invisible until a user complained.
 *
 * Deliberately no vendor SDK and no dependency. Adding one would mean a new
 * package, an account, a DSN in the build, and — for Sentry specifically —
 * default-on PII capture that would need reviewing against DPDP before it
 * could ship. JSON lines on stdout are what every hosted log platform ingests
 * natively, so this is portable to whichever one gets chosen, and costs
 * nothing until then.
 *
 * REDACTION IS THE POINT, not a nicety. This service handles cards, OTPs and
 * tokens; a log line is a copy of data that outlives the request and gets
 * shipped somewhere else. So the logger cannot be handed a request body at
 * all — it records shape (method, path, status, duration) and never content.
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

/**
 * Strips the query string down to its keys, replacing every value with
 * `[redacted]` for anything sensitive.
 *
 * Path parameters are left alone: they're ids, and an id is what makes a log
 * line useful for support. Query VALUES are a different matter — this is where
 * OTP codes and click tokens actually appear.
 */
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
  // One JSON object per line — the format every log platform parses without
  // configuration, and the one that survives being piped through anything.
  const line = JSON.stringify({ level, ts: new Date().toISOString(), ...fields });
  if (level === 'error') {
    process.stderr.write(`${line}\n`);
  } else {
    process.stdout.write(`${line}\n`);
  }
}

/**
 * Assigns a request id and logs one line per completed request.
 *
 * The id comes from an inbound `x-request-id` when a proxy supplied one, so a
 * trace survives across services rather than restarting at each hop, and is
 * echoed back on the response — which is what lets a user's screenshot of an
 * error be matched to the exact server-side line.
 */
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
      // The authenticated user id, never the token. Support needs "which
      // account", and this is the whole of what's needed to answer it.
      userId: req.userId || null,
    });
  });

  next();
}

/**
 * Terminal error handler.
 *
 * Express 5 forwards a rejected async handler here, which the per-route
 * try/catch blocks in index.js would otherwise be the only thing standing
 * between and a hung request. Logs the stack server-side and returns the
 * request id to the caller — never the stack, which routinely contains query
 * fragments and parameter values.
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
