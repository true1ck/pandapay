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

const INSERT_SUPPORT_TICKET_IDEMPOTENT_SQL = `${INSERT_SUPPORT_TICKET_SQL}
  ON CONFLICT (id) DO NOTHING`;
const { isUuid } = require('./http_db_errors');

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

  // Charges the limiter; returns null when admitted, else a {status, body, retryAfter} refusal.
  async function admit(req) {
    const authenticated = Boolean(req.userId);
    const identity = authenticated ? req.userId : (req.ip || req.socket?.remoteAddress || '');
    let rate;
    try { rate = await limiter.consume(identity, authenticated, 'support_tickets'); }
    catch (err) {
      console.error('POST /support-tickets admission unavailable', safeErrorCode(err));
      return { status: 503, body: { error: 'feedback_admission_unavailable' }, retryAfter: '5' };
    }
    if (rate.unavailable) return { status: 503, body: { error: 'feedback_admission_unavailable' }, retryAfter: '5' };
    if (!rate.allowed) return { status: 429, body: { error: 'support_ticket_rate_limited' }, retryAfter: String(rate.retryAfterSeconds) };
    return null;
  }
  const refuse = (res, r) => {
    if (r.retryAfter) res.set?.('Retry-After', r.retryAfter);
    return res.status(r.status).json(r.body);
  };

  return async (req, res) => {
    // optionalAuth leaves userId null for a bad token; a present-but-invalid
    // credential must not silently become an anonymous ticket.
    if (req.headers?.authorization && !req.userId) {
      return res.status(401).json({ error: 'Missing or invalid access token' });
    }
    const parsed = validateSupportTicketPayload(req.body);
    if (!parsed.ok) return res.status(400).json({ error: parsed.error });
    const clientId = req.body.id;
    if (clientId !== undefined && clientId !== null && !isUuid(clientId)) {
      return res.status(400).json({ error: 'invalid_id' });
    }

    // Without a client id: unchanged (charge first, then insert).
    if (!clientId) {
      const refusal = await admit(req);
      if (refusal) return refuse(res, refusal);
    }

    const { kind, message, diagnostics, appVersion } = parsed.value;
    try {
      const ticket = await withUserClient(req.userId || null, async (client) => {
        // Generate the same UUID/database transaction time as the table
        // defaults, then insert without RETURNING. Anonymous tickets are
        // intentionally unreadable under RLS, including INSERT RETURNING.
        const metadata = (await client.query(SUPPORT_TICKET_METADATA_SQL)).rows[0];
        const id = clientId || metadata.id;
        const inserted = await client.query(clientId ? INSERT_SUPPORT_TICKET_IDEMPOTENT_SQL : INSERT_SUPPORT_TICKET_SQL,
          [id, req.userId || null, kind, message, diagnostics === null ? null : JSON.stringify(diagnostics), appVersion]);
        if (clientId) {
          if (inserted.rowCount === 0) {
            // Replay: same 201 shape, no limiter charge. Authenticated callers can
            // read the stored row back; anonymous ones cannot (RLS).
            if (req.userId) {
              const stored = (await client.query('SELECT id, kind, state, created_at FROM support_tickets WHERE id = $1', [id])).rows[0];
              if (stored) return { id: stored.id, kind: stored.kind, state: stored.state, created_at: stored.created_at };
            }
            return { id, kind, state: 'pending', created_at: metadata.created_at };
          }
          // New row: charge now; a refusal rolls the insert back.
          const refusal = await admit(req);
          if (refusal) throw Object.assign(new Error('support_ticket_refused'), { refusal });
        }
        return { id, kind, state: 'pending', created_at: metadata.created_at };
      });
      return res.status(201).json({ ticket });
    } catch (err) {
      if (err?.refusal) return refuse(res, err.refusal);
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
