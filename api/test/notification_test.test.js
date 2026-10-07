const test = require('node:test');
const assert = require('node:assert/strict');

const { createTestNotificationLimiter } = require('../src/notification_test');

test('self-test limiter allows one request and blocks an immediate repeat', () => {
  let now = 10_000;
  const limiter = createTestNotificationLimiter({ now: () => now, cooldownMs: 60_000 });

  assert.deepEqual(limiter.check('user-1'), { allowed: true, retryAfterSeconds: 0 });
  limiter.mark('user-1');
  assert.deepEqual(limiter.check('user-1'), { allowed: false, retryAfterSeconds: 60 });
  assert.deepEqual(limiter.check('user-2'), { allowed: true, retryAfterSeconds: 0 });

  now += 60_000;
  assert.deepEqual(limiter.check('user-1'), { allowed: true, retryAfterSeconds: 0 });
});

test('self-test limiter rounds the remaining cooldown up to a safe second', () => {
  let now = 0;
  const limiter = createTestNotificationLimiter({ now: () => now, cooldownMs: 5_000 });

  limiter.mark('user-1');
  now = 4_001;
  assert.deepEqual(limiter.check('user-1'), { allowed: false, retryAfterSeconds: 1 });
});
