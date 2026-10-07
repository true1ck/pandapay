const TEST_NOTIFICATION_COOLDOWN_MS = 60 * 1000;

/**
 * A small process-local guard for the authenticated self-test endpoint.
 *
 * The endpoint is intentionally self-only, but it is still easy to tap twice
 * while diagnosing a device. This guard avoids turning that into a burst of
 * provider requests. It is not a security boundary; authentication and the
 * provider's own rate limits remain the real controls.
 */
function createTestNotificationLimiter({ now = () => Date.now(), cooldownMs = TEST_NOTIFICATION_COOLDOWN_MS } = {}) {
  const lastSentAt = new Map();

  return {
    check(userId) {
      const previous = lastSentAt.get(userId);
      if (previous == null) return { allowed: true, retryAfterSeconds: 0 };

      const remainingMs = cooldownMs - (now() - previous);
      if (remainingMs <= 0) return { allowed: true, retryAfterSeconds: 0 };

      return {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil(remainingMs / 1000)),
      };
    },

    mark(userId) {
      lastSentAt.set(userId, now());
    },
  };
}

module.exports = { TEST_NOTIFICATION_COOLDOWN_MS, createTestNotificationLimiter };
