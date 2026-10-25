'use strict';

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
    consume(identity, authenticated, current = now()) {
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

module.exports = { createFeedbackRateLimiter, FEEDBACK_RATE_WINDOW_MS,
  FEEDBACK_PROFILE_LIMIT, FEEDBACK_ANONYMOUS_LIMIT, FEEDBACK_MAX_IDENTITIES };
