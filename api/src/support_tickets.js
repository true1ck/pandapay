'use strict';

const SUPPORT_TICKET_KINDS = Object.freeze(['bug', 'wrong_card_data', 'card_request', 'general']);
const SUPPORT_TICKET_MAX_MESSAGE_LENGTH = 4_000;
const SUPPORT_TICKET_MAX_DIAGNOSTICS_BYTES = 4 * 1024;
const SUPPORT_TICKET_MAX_DIAGNOSTIC_FIELDS = 24;
const SUPPORT_TICKET_MAX_DIAGNOSTIC_STRING_LENGTH = 512;
const SUPPORT_TICKET_MAX_APP_VERSION_LENGTH = 64;
const SUPPORT_TICKET_RATE_WINDOW_MS = 60 * 60 * 1000;
const SUPPORT_TICKET_AUTHENTICATED_LIMIT = 5;
const SUPPORT_TICKET_ANONYMOUS_LIMIT = 30;
const SUPPORT_TICKET_MAX_RATE_LIMIT_ENTRIES = 50_000;
const { safeErrorCode } = require('./safeErrorCode');

function validateSupportTicketPayload(body) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return { ok: false, error: 'invalid_request' };
  }

  const { kind, message, diagnostics, appVersion } = body;
  if (!SUPPORT_TICKET_KINDS.includes(kind)) {
    return { ok: false, error: `kind must be one of ${SUPPORT_TICKET_KINDS.join(', ')}` };
  }
  if (typeof message !== 'string' || !message.trim()) {
    return { ok: false, error: 'message is required' };
  }
  const normalizedMessage = message.trim();
  if (normalizedMessage.includes('\u0000')) {
    return { ok: false, error: 'invalid_message' };
  }
  if (normalizedMessage.length > SUPPORT_TICKET_MAX_MESSAGE_LENGTH) {
    return { ok: false, error: 'message_too_long' };
  }

  let normalizedDiagnostics = null;
  if (diagnostics !== undefined && diagnostics !== null) {
    if (!diagnostics || typeof diagnostics !== 'object' || Array.isArray(diagnostics)) {
      return { ok: false, error: 'invalid_diagnostics' };
    }
    const entries = Object.entries(diagnostics);
    if (entries.length > SUPPORT_TICKET_MAX_DIAGNOSTIC_FIELDS) {
      return { ok: false, error: 'invalid_diagnostics' };
    }
    for (const [key, value] of entries) {
      if (!/^[A-Za-z][A-Za-z0-9_]{0,63}$/.test(key)) {
        return { ok: false, error: 'invalid_diagnostics' };
      }
      if (typeof value === 'string') {
        if (value.includes('\u0000') || value.length > SUPPORT_TICKET_MAX_DIAGNOSTIC_STRING_LENGTH) {
          return { ok: false, error: 'invalid_diagnostics' };
        }
      } else if (value !== null && typeof value !== 'boolean' &&
        !(typeof value === 'number' && Number.isFinite(value))) {
        return { ok: false, error: 'invalid_diagnostics' };
      }
    }
    normalizedDiagnostics = diagnostics;
    if (Buffer.byteLength(JSON.stringify(normalizedDiagnostics), 'utf8') > SUPPORT_TICKET_MAX_DIAGNOSTICS_BYTES) {
      return { ok: false, error: 'invalid_diagnostics' };
    }
  }

  let normalizedAppVersion = null;
  if (appVersion !== undefined && appVersion !== null) {
    if (typeof appVersion !== 'string' || appVersion.includes('\u0000') || appVersion.length > SUPPORT_TICKET_MAX_APP_VERSION_LENGTH) {
      return { ok: false, error: 'invalid_app_version' };
    }
    normalizedAppVersion = appVersion.trim() || null;
  }

  return {
    ok: true,
    value: { kind, message: normalizedMessage, diagnostics: normalizedDiagnostics, appVersion: normalizedAppVersion },
  };
}

/**
 * Bounded process-local backstop for this public support endpoint. It avoids
 * persistent IP storage; production still needs edge/shared admission control
 * when multiple API replicas are deployed.
 */
function createSupportTicketRateLimiter({
  now = () => Date.now(),
  windowMs = SUPPORT_TICKET_RATE_WINDOW_MS,
  authenticatedLimit = SUPPORT_TICKET_AUTHENTICATED_LIMIT,
  anonymousLimit = SUPPORT_TICKET_ANONYMOUS_LIMIT,
  maxEntries = SUPPORT_TICKET_MAX_RATE_LIMIT_ENTRIES,
} = {}) {
  for (const value of [windowMs, authenticatedLimit, anonymousLimit, maxEntries]) {
    if (!Number.isSafeInteger(value) || value < 1) throw new TypeError('support-ticket limiter configuration is invalid');
  }
  const attempts = new Map();
  let nextPruneAt = 0;

  function prune(current) {
    for (const [key, entry] of attempts) {
      if (entry.resetAt <= current) attempts.delete(key);
    }
    nextPruneAt = current + Math.min(windowMs, 60_000);
  }

  return {
    consume(identity, authenticated, current = now()) {
      if (typeof identity !== 'string' || !identity) {
        return { allowed: false, retryAfterSeconds: Math.ceil(windowMs / 1000) };
      }
      if (current >= nextPruneAt) prune(current);

      const key = `${authenticated ? 'user' : 'ip'}:${identity}`;
      const limit = authenticated ? authenticatedLimit : anonymousLimit;
      const existing = attempts.get(key);
      if (existing && existing.resetAt > current) {
        if (existing.count >= limit) {
          return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - current) / 1000)) };
        }
        existing.count += 1;
        return { allowed: true, retryAfterSeconds: 0 };
      }

      if (attempts.size >= maxEntries) prune(current);
      if (attempts.size >= maxEntries) {
        return { allowed: false, retryAfterSeconds: Math.ceil(windowMs / 1000) };
      }
      attempts.set(key, { count: 1, resetAt: current + windowMs });
      return { allowed: true, retryAfterSeconds: 0 };
    },
  };
}

function createSupportTicketHandler({ withUserClient, limiter = createSupportTicketRateLimiter() } = {}) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  if (!limiter || typeof limiter.consume !== 'function') throw new TypeError('limiter is required');

  return async (req, res) => {
    const parsed = validateSupportTicketPayload(req.body);
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });

    const authenticated = Boolean(req.userId);
    const identity = authenticated ? req.userId : (req.ip || req.socket?.remoteAddress || '');
    const rate = limiter.consume(identity, authenticated);
    if (!rate.allowed) {
      res.set?.('Retry-After', String(rate.retryAfterSeconds));
      return res.status(429).json({ error: 'support_ticket_rate_limited' });
    }

    const { kind, message, diagnostics, appVersion } = parsed.value;
    try {
      const result = await withUserClient(req.userId || null, (client) =>
        client.query(
          `INSERT INTO support_tickets (profile_id, kind, message, diagnostics, app_version)
           VALUES ($1, $2, $3, $4, $5)
           RETURNING id, kind, state, created_at`,
          [req.userId || null, kind, message, diagnostics === null ? null : JSON.stringify(diagnostics), appVersion],
        ),
      );
      return res.status(201).json({ ticket: result.rows[0] });
    } catch (err) {
      // Keep request data and PostgreSQL details out of routine logs.
      console.error('POST /support-tickets error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function registerSupportTicketRoute(app, { optionalAuth, withUserClient, limiter } = {}) {
  if (!app || typeof app.post !== 'function') throw new TypeError('app is required');
  if (typeof optionalAuth !== 'function') throw new TypeError('optionalAuth is required');
  app.post('/support-tickets', optionalAuth, createSupportTicketHandler({ withUserClient, limiter }));
  return app;
}

module.exports = {
  SUPPORT_TICKET_KINDS,
  SUPPORT_TICKET_MAX_MESSAGE_LENGTH,
  SUPPORT_TICKET_MAX_DIAGNOSTICS_BYTES,
  SUPPORT_TICKET_MAX_APP_VERSION_LENGTH,
  SUPPORT_TICKET_RATE_WINDOW_MS,
  SUPPORT_TICKET_AUTHENTICATED_LIMIT,
  SUPPORT_TICKET_ANONYMOUS_LIMIT,
  SUPPORT_TICKET_MAX_RATE_LIMIT_ENTRIES,
  validateSupportTicketPayload,
  createSupportTicketRateLimiter,
  createSupportTicketHandler,
  registerSupportTicketRoute,
};
