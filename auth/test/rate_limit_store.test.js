'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  RateLimitCapacityError,
  createMemoryRateLimitStore,
  createRateLimitStore,
  toBucketKey,
} = require('../src/services/authAbuseStore');

test('bucket HMAC is stable, domain separated, and never emits the source key', () => {
  const secret = Buffer.alloc(32, 7);
  const value = 'otp_req:email:private@example.invalid:signin:10min';
  const digest = toBucketKey(value, secret);
  assert.equal(digest.length, 32);
  assert.deepEqual(toBucketKey(value, secret), digest);
  assert.notDeepEqual(toBucketKey(value, Buffer.alloc(32, 8)), digest);
  assert.equal(digest.toString('utf8').includes('private@example.invalid'), false);
});

test('memory store keeps concurrent increments, fixed expiry, and saturates', async () => {
  let now = 1000;
  const store = createMemoryRateLimitStore({ now: () => now });
  const values = await Promise.all(Array.from({ length: 25 }, () => store.increment('synthetic-counter', 10, 9)));
  assert.equal(Math.max(...values), 9);
  assert.equal(await store.get('synthetic-counter'), 9);
  now += 9999;
  assert.equal(await store.get('synthetic-counter'), 9);
  now += 2;
  assert.equal(await store.get('synthetic-counter'), 0);
  assert.equal(await store.increment('synthetic-counter', 10), 1);
});

test('memory marker compare-delete cannot clear a newer marker and expires', async () => {
  let now = 0;
  const store = createMemoryRateLimitStore({ now: () => now });
  await store.setWithTTL('active-marker', 'request-a', 2);
  await store.setWithTTL('active-marker', 'request-b', 3);
  assert.equal(await store.compareDelete('active-marker', 'request-a'), false);
  assert.equal(await store.exists('active-marker'), true);
  assert.equal(await store.compareDelete('active-marker', 'request-b'), true);
  assert.equal(await store.exists('active-marker'), false);
  await store.setWithTTL('active-marker', 'request-c', 2);
  now = 2001;
  assert.equal(await store.exists('active-marker'), false);
});

test('memory marker claims are atomic under concurrent OTP creation', async () => {
  const store = createMemoryRateLimitStore();
  const claims = await Promise.all(Array.from({ length: 50 }, (_, index) =>
    store.claimMarker('active:concurrent-synthetic', `request-${index}`, 60)));
  assert.equal(claims.filter(Boolean).length, 1);
  assert.equal(await store.exists('active:concurrent-synthetic'), true);

  const winner = claims.findIndex(Boolean);
  assert.equal(await store.compareDelete('active:concurrent-synthetic', `request-${winner}`), true);
  assert.equal(await store.claimMarker('active:concurrent-synthetic', 'replacement', 60), true);
});

test('hosted environments always choose PostgreSQL and reject memory configuration', () => {
  const poolProvider = async () => ({ query: async () => ({ rows: [], rowCount: 0 }) });
  const store = createRateLimitStore({
    env: { NODE_ENV: 'staging', PHONE_LOOKUP_HMAC_KEY: 'synthetic-hmac-key-0123456789abcdef' },
    poolProvider,
  });
  assert.equal(store.mode, 'postgres');
  assert.throws(() => createRateLimitStore({
    env: { NODE_ENV: 'production', AUTH_ABUSE_STORE: 'memory', PHONE_LOOKUP_HMAC_KEY: 'synthetic-hmac-key-0123456789abcdef' },
    poolProvider,
  }), /Hosted auth abuse storage must use PostgreSQL/);
});

test('memory storage remains available to explicit local test fixtures', () => {
  assert.equal(createRateLimitStore({ env: { NODE_ENV: 'test', AUTH_ABUSE_STORE: 'memory' } }).mode, 'memory');
  assert.equal(new RateLimitCapacityError().code, 'capacity_exhausted');
});
