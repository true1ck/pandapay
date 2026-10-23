'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const Module = require('node:module');
const {
  ActiveOtpError,
  RateLimitExceededError,
  RateLimitStorageError,
} = require('../src/services/authAbuseStore');

function loadMiddleware(store) {
  const filename = require.resolve('../src/middleware/rateLimitMiddleware');
  const originalLoad = Module._load;
  Module._load = function(request, parent, isMain) {
    if (parent?.filename === filename && request === '../services/authAbuseStore') {
      return {
        RateLimitStorageError,
        RateLimitExceededError,
        ActiveOtpError,
        createRateLimitStore: () => store,
      };
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    delete require.cache[filename];
    return require(filename);
  } finally {
    Module._load = originalLoad;
  }
}

function response() {
  return {
    statusCode: null,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('storage failure blocks before OTP request continuation with a fixed 503 response', async () => {
  const secretIdentity = '+919876543210';
  const middleware = loadMiddleware({
    async exists() { throw new Error(`query leaked ${secretIdentity}`); },
    async increment() { throw new Error(`query leaked ${secretIdentity}`); },
    async get() { throw new Error(`query leaked ${secretIdentity}`); },
    async setWithTTL() { throw new Error(`query leaked ${secretIdentity}`); },
    async compareDelete() { throw new Error(`query leaked ${secretIdentity}`); },
  });
  let nextCalls = 0;
  const res = response();
  const oldError = console.error;
  const log = [];
  console.error = (...args) => log.push(args.join(' '));
  try {
    await middleware.checkActiveOtpForPhone(
      { body: { phone_number: secretIdentity } }, res, () => { nextCalls++; },
    );
  } finally {
    console.error = oldError;
  }
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, {
    success: false,
    message: 'Authentication is temporarily unavailable. Please try again shortly.',
  });
  assert.equal(nextCalls, 0);
  assert.equal(log.join(' ').includes(secretIdentity), false);

  const quotaRes = response();
  await middleware.rateLimitRequestOtpByPhone(
    { body: { phone_number: secretIdentity } }, quotaRes, () => { nextCalls++; },
  );
  assert.equal(quotaRes.statusCode, 503);
  assert.equal(nextCalls, 0);
});

test('successful retry continues and existing OTP limit response remains 429', async () => {
  let available = false;
  const middleware = loadMiddleware({
    async exists() {
      if (!available) throw new Error('synthetic unavailable');
      return false;
    },
    async increment() { return 4; },
    async get() { return 0; },
    async setWithTTL() { return true; },
    async compareDelete() { return false; },
  });
  const req = { body: { phone_number: '9876543210' } };
  const failed = response();
  await middleware.checkActiveOtpForPhone(req, failed, () => {});
  assert.equal(failed.statusCode, 503);

  available = true;
  let nextCalls = 0;
  const retried = response();
  await middleware.checkActiveOtpForPhone(req, retried, () => { nextCalls++; });
  assert.equal(nextCalls, 1);

  const limited = response();
  await middleware.rateLimitRequestOtpByPhone(req, limited, () => { nextCalls++; });
  assert.equal(limited.statusCode, 429);
  assert.equal(limited.body.message, 'Too many OTP requests. Please try again later.');
  assert.equal(nextCalls, 1);
});

test('phone/email normalization and recovery-purpose bucket names stay compatible', async () => {
  const checked = [];
  const middleware = loadMiddleware({
    async exists(key) { checked.push(key); return false; },
    async increment() { return 1; },
    async get() { return 0; },
    async setWithTTL() { return true; },
    async compareDelete() { return false; },
  });
  const res = response();
  await middleware.checkActiveOtpForPhone(
    { body: { phone_number: ' 98 76 543210 ', recovery_only: true } }, res, () => {},
  );
  await middleware.checkActiveOtpForEmail(
    { body: { email: ' TEST@EXAMPLE.INVALID ', recovery_only: true } }, res, () => {},
  );
  assert.deepEqual(checked, [
    'otp_active:phone:+919876543210:recovery',
    'otp_active:email:test@example.invalid:recovery',
  ]);
});

test('active OTP marker uses atomic claim and exposes a typed conflict', async () => {
  let calls = 0;
  const middleware = loadMiddleware({
    async claimMarker(key, value, ttl) {
      calls++;
      assert.equal(key, 'otp_active:email:test@example.invalid:signin');
      assert.equal(value, 'synthetic-request-id');
      assert.equal(ttl, 120);
      return false;
    },
  });
  assert.equal(middleware.ActiveOtpError, ActiveOtpError);
  await assert.rejects(
    middleware.markActiveOtp('TEST@example.invalid', 120, 'synthetic-request-id'),
    error => error.code === 'OTP_ACTIVE' && error.name === 'ActiveOtpError',
  );
  assert.equal(calls, 1);
});

test('replacement request budget increments account-scoped short and daily quotas', async () => {
  const calls = [];
  const middleware = loadMiddleware({
    async increment(key, ttl, saturation) {
      calls.push([key, ttl, saturation]);
      return 1;
    },
  });
  const result = await middleware.consumeReplacementBudget('user-1', 'phone', 'request');
  assert.deepEqual(result, { shortCount: 1, dayCount: 1 });
  assert.deepEqual(calls, [
    ['replacement:request:user:user-1:phone:hour', 600, middleware.config.OTP_REQ_PHONE_10MIN_LIMIT + 1],
    ['replacement:request:user:user-1:phone:day', 86400, middleware.config.OTP_REQ_PHONE_DAY_LIMIT + 1],
  ]);
});

test('replacement verify budget saturates and reports a typed quota refusal', async () => {
  let captured;
  const middleware = loadMiddleware({
    async increment(key, ttl, saturation) {
      captured = [key, ttl, saturation];
      return saturation;
    },
  });
  await assert.rejects(
    middleware.consumeReplacementBudget('user-1', 'email', 'verify'),
    error => error instanceof RateLimitExceededError && error.code === 'RATE_LIMIT_EXCEEDED',
  );
  assert.deepEqual(captured, [
    'replacement:verify:user:user-1:email:hour', 3600,
    middleware.config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT + 1,
  ]);
});

test('replacement budget rejects unbounded or malformed account/channel inputs', async () => {
  const middleware = loadMiddleware({ async increment() { throw new Error('must not write'); } });
  await assert.rejects(middleware.consumeReplacementBudget('x'.repeat(129), 'phone'), TypeError);
  await assert.rejects(middleware.consumeReplacementBudget('user-1', 'sms'), TypeError);
});
