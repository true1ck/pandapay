'use strict';

const SUPPORT_TICKET_KINDS = Object.freeze(['bug', 'wrong_card_data', 'card_request', 'general']);
const SUPPORT_TICKET_MAX_MESSAGE_LENGTH = 4_000;
const SUPPORT_TICKET_MAX_DIAGNOSTICS_BYTES = 4 * 1024;
const SUPPORT_TICKET_MAX_DIAGNOSTIC_FIELDS = 24;
const SUPPORT_TICKET_MAX_DIAGNOSTIC_STRING_LENGTH = 512;
const SUPPORT_TICKET_MAX_APP_VERSION_LENGTH = 64;
const {
  createFeedbackRateLimiter: createSupportTicketRateLimiter,
  FEEDBACK_RATE_WINDOW_MS: SUPPORT_TICKET_RATE_WINDOW_MS,
  FEEDBACK_PROFILE_LIMIT: SUPPORT_TICKET_AUTHENTICATED_LIMIT,
  FEEDBACK_ANONYMOUS_LIMIT: SUPPORT_TICKET_ANONYMOUS_LIMIT,
  FEEDBACK_MAX_IDENTITIES: SUPPORT_TICKET_MAX_RATE_LIMIT_ENTRIES,
} = require('./feedback_rate_limit');
const { safeErrorCode } = require('./safeErrorCode');
const SUPPORT_TICKET_METADATA_SQL = 'SELECT gen_random_uuid() AS id, now() AS created_at';
const INSERT_SUPPORT_TICKET_SQL = `INSERT INTO support_tickets
  (id, profile_id, kind, message, diagnostics, app_version, state, created_at)
  VALUES ($1, $2, $3, $4, $5, $6, 'pending', now())`;

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

function createSupportTicketHandler({ withUserClient, limiter = createSupportTicketRateLimiter() } = {}) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  if (!limiter || typeof limiter.consume !== 'function') throw new TypeError('limiter is required');

  return async (req, res) => {
    const parsed = validateSupportTicketPayload(req.body);
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });

    const authenticated = Boolean(req.userId);
    const identity = authenticated ? req.userId : (req.ip || req.socket?.remoteAddress || '');
    let rate;
    try { rate = await limiter.consume(identity, authenticated, 'support_tickets'); }
    catch (err) {
      console.error('POST /support-tickets admission unavailable', safeErrorCode(err));
      res.set?.('Retry-After', '5');
      return res.status(503).json({ error: 'feedback_admission_unavailable' });
    }
    if (rate.unavailable) {
      res.set?.('Retry-After', '5');
      return res.status(503).json({ error: 'feedback_admission_unavailable' });
    }
    if (!rate.allowed) {
      res.set?.('Retry-After', String(rate.retryAfterSeconds));
      return res.status(429).json({ error: 'support_ticket_rate_limited' });
    }

    const { kind, message, diagnostics, appVersion } = parsed.value;
    try {
      const ticket = await withUserClient(req.userId || null, async (client) => {
        // Generate the same UUID/database transaction time as the table
        // defaults, then insert without RETURNING. Anonymous tickets are
        // intentionally unreadable under RLS, including INSERT RETURNING.
        const metadata = (await client.query(SUPPORT_TICKET_METADATA_SQL)).rows[0];
        await client.query(INSERT_SUPPORT_TICKET_SQL, [metadata.id, req.userId || null, kind,
          message, diagnostics === null ? null : JSON.stringify(diagnostics), appVersion]);
        return { id: metadata.id, kind, state: 'pending', created_at: metadata.created_at };
      });
      return res.status(201).json({ ticket });
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
  SUPPORT_TICKET_METADATA_SQL,
  INSERT_SUPPORT_TICKET_SQL,
  validateSupportTicketPayload,
  createSupportTicketRateLimiter,
  createSupportTicketHandler,
  registerSupportTicketRoute,
};
