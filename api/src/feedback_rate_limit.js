'use strict';

const { createHmac } = require('node:crypto');

const FEEDBACK_RATE_WINDOW_MS = 60 * 60 * 1000;
const FEEDBACK_PROFILE_LIMIT = 5;
const FEEDBACK_ANONYMOUS_LIMIT = 30;
const FEEDBACK_MAX_IDENTITIES = 50_000;

/** Bounded process-local guard; replica-wide budgets still need a shared store. */
function createFeedbackRateLimiter({
  now = () => Date.now(),
  windowMs = FEEDBACK_RATE_WINDOW_MS,
  authenticatedLimit = FEEDBACK_PROFILE_LIMIT,
  anonymousLimit = FEEDBACK_ANONYMOUS_LIMIT,
  maxEntries = FEEDBACK_MAX_IDENTITIES,
} = {}) {
  for (const value of [windowMs, authenticatedLimit, anonymousLimit, maxEntries]) {
    if (!Number.isSafeInteger(value) || value < 1) throw new TypeError('feedback limiter configuration is invalid');
  }
  const attempts = new Map();
  let nextPruneAt = 0;

  return {
    consume(identity, authenticated, bucketOrCurrent = now()) {
      const current = typeof bucketOrCurrent === 'number' ? bucketOrCurrent : now();
      if (typeof identity !== 'string' || !identity) {
        return { allowed: false, retryAfterSeconds: Math.ceil(windowMs / 1000) };
      }
      // Prune at most once per interval, including when the map is full, so
      // bursts of unknown identities cannot force a full scan per request.
      if (current >= nextPruneAt) {
        for (const [key, entry] of attempts) {
          if (entry.resetAt <= current) attempts.delete(key);
        }
        nextPruneAt = current + Math.min(windowMs, 60_000);
      }

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
      if (!existing && attempts.size >= maxEntries) {
        return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil((nextPruneAt - current) / 1000)) };
      }
      attempts.set(key, { count: 1, resetAt: current + windowMs });
      return { allowed: true, retryAfterSeconds: 0 };
    },
  };
}

/** Shared store adapter. The pool must be a dedicated, bounded service pool
 * whose DB role can execute only feedback_admission.consume(). */
function createPostgresFeedbackRateLimiter({ pool, digestSecret, queryTimeoutMs = 1500 } = {}) {
  if (!pool || typeof pool.connect !== 'function') throw new TypeError('pool is required');
  if (typeof digestSecret !== 'string' || Buffer.byteLength(digestSecret) < 32) {
    throw new TypeError('digestSecret must contain at least 32 bytes');
  }
  if (!Number.isSafeInteger(queryTimeoutMs) || queryTimeoutMs < 100 || queryTimeoutMs > 5000) {
    throw new TypeError('queryTimeoutMs is invalid');
  }
  let inFlight = false;
  return {
    async consume(identity, authenticated, bucket) {
      if (typeof identity !== 'string' || !identity || identity.length > 256 || Buffer.byteLength(identity, 'utf8') > 256 ||
          typeof authenticated !== 'boolean' || !['support_tickets', 'data_error_reports'].includes(bucket)) {
        return { allowed: false, retryAfterSeconds: 3600, unavailable: true };
      }
      const digest = createHmac('sha256', digestSecret)
        .update(`feedback-v1\0${bucket}\0${authenticated ? 'profile' : 'ip'}\0${identity}`, 'utf8').digest('hex');
      // Refuse locally while the single shared-store connection is busy. This
      // avoids an unbounded pg Pool waiter queue during database stalls.
      if (inFlight) throw new Error('feedback_admission_busy');
      inFlight = true;
      let client;
      let result;
      try {
        client = await pool.connect();
        result = await client.query({
          text: 'SELECT * FROM feedback_admission.consume($1, $2, $3)',
          values: [bucket, digest, authenticated],
          query_timeout: queryTimeoutMs,
        });
      } catch (error) {
        if (client) client.release(error);
        client = null;
        throw error;
      } finally {
        if (client) client.release();
        inFlight = false;
      }
      const row = result.rows?.[0];
      if (!row || typeof row.allowed !== 'boolean' || !Number.isSafeInteger(row.retry_after_seconds) ||
          row.retry_after_seconds < 0 || row.retry_after_seconds > 3600 ||
          (row.allowed && row.retry_after_seconds !== 0) || (!row.allowed && row.retry_after_seconds < 1)) {
        throw new Error('feedback_admission_invalid_result');
      }
      return { allowed: row.allowed, retryAfterSeconds: row.retry_after_seconds };
    },
  };
}

module.exports = { createFeedbackRateLimiter, FEEDBACK_RATE_WINDOW_MS,
  createPostgresFeedbackRateLimiter,
  FEEDBACK_PROFILE_LIMIT, FEEDBACK_ANONYMOUS_LIMIT, FEEDBACK_MAX_IDENTITIES };
