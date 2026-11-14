'use strict';

/**
 * Shared mapping from PostgreSQL error codes to HTTP answers.
 *
 * Most route catch blocks answer 500 for every failure. The offline client
 * treats a 5xx as "retry later", so a permanent data error (a malformed id, a
 * missing reference, a failed CHECK) is retried for ever, while a genuinely
 * transient one (timeout, deadlock) looks no different. This module gives each
 * class one stable, non-leaking answer. Response bodies never contain the
 * database message, detail, constraint or submitted values.
 *
 * Adoption is deliberately incremental: a route opts in by calling
 * `respondDbError(res, err)` in its catch block and falling back to its
 * existing handling when that returns false.
 */

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// statement timeout, serialization failure, deadlock: the same request can
// succeed when repeated, so they are never a permanent rejection.
const TRANSIENT_DB_CODES = Object.freeze(['57014', '40001', '40P01']);

function isUuid(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function isTransientDbError(err) {
  return typeof err?.code === 'string' && TRANSIENT_DB_CODES.includes(err.code);
}

/**
 * Returns `{ status, body }` for a recognised database error, else null.
 * 22P02 is reported as `invalid_id` because in this API an unparseable text
 * value reaching SQL is, in practice, a malformed uuid path/body parameter.
 */
function classifyDbError(err) {
  // No pool connection within the connect timeout (the pg error carries no code): busy, retry shortly.
  if (err?.message === 'timeout exceeded when trying to connect') {
    return { status: 503, body: { error: 'server_busy', retryable: true } };
  }
  const code = err?.code;
  if (typeof code !== 'string') return null;
  if (code === '22P02') return { status: 400, body: { error: 'invalid_id' } };
  if (code === '23503') return { status: 409, body: { error: 'reference_conflict' } };
  if (code === '23514') return { status: 422, body: { error: 'data_rule_violation' } };
  if (code === '23505') return { status: 409, body: { error: 'duplicate' } };
  if (TRANSIENT_DB_CODES.includes(code)) {
    return { status: 503, body: { error: 'transient_db_error', retryable: true } };
  }
  return null;
}

/** Sends the mapped answer and returns true; returns false for unmapped errors. */
function respondDbError(res, err) {
  const mapped = classifyDbError(err);
  if (!mapped) return false;
  if (mapped.body.retryable && typeof res.set === 'function') res.set('Retry-After', mapped.body.error === 'server_busy' ? String(5 + Math.floor(Math.random() * 4)) : '1');
  res.status(mapped.status).json(mapped.body);
  return true;
}

/**
 * One-line route guard: `if (rejectInvalidUuid(res, req.params.id)) return;`
 * Answers 400 `invalid_id` and returns true when the value is not a UUID.
 */
function rejectInvalidUuid(res, value) {
  if (isUuid(value)) return false;
  res.status(400).json({ error: 'invalid_id' });
  return true;
}

/**
 * Parses an optional client edit clock (ISO string) into {ok, value}; value is
 * null when absent. A clock more than 5 minutes ahead of the server is clamped to
 * the server time (same rule as /sync/push), so a wrong phone clock cannot make
 * its edit win every later edit from other devices.
 */
function parseClientClock(v, nowMs = Date.now()) {
  if (v === undefined || v === null || v === '') return { ok: true, value: null };
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}T/.test(v) || Number.isNaN(Date.parse(v))) return { ok: false };
  const ms = Date.parse(v);
  return { ok: true, value: new Date(ms > nowMs + 5 * 60 * 1000 ? nowMs : ms).toISOString() };
}

module.exports = {
  parseClientClock,
  TRANSIENT_DB_CODES,
  isUuid,
  isTransientDbError,
  classifyDbError,
  respondDbError,
  rejectInvalidUuid,
};
