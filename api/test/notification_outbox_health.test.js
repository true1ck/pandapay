'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createNotificationOutboxHealth, validateHealth } = require('../src/notification_outbox_health');

const HEALTH = Object.freeze({
  enabled: null,
  queued: 2,
  retained: 3,
  max_queued: 10000,
  max_retained: 10000,
  oldest_pending_seconds: 17,
  expired_leased: 1,
  dead: 0,
  new_terminal_24h: 1,
  worker_rows: 1,
  heartbeat_age_seconds: 4,
  missing_worker: false,
  blocked_workers: 0,
  unavailable_workers: 0,
});

test('health reader issues only the count-only capability call and accepts enabled null', async () => {
  const calls = [];
  const reader = createNotificationOutboxHealth({ databasePool: { query: async (...args) => {
    calls.push(args); return { rows: [{ health: HEALTH }] };
  } } });
  const result = await reader.readHealth();
  assert.equal(result.available, true);
  assert.deepEqual(result.health, HEALTH);
  assert.deepEqual(calls, [['SELECT notification_delivery.health() AS health']]);
});

test('health reader validates a strict aggregate shape and rejects private or unknown fields', async () => {
  const reader = createNotificationOutboxHealth({ databasePool: { query: async () => ({ rows: [{ health: { ...HEALTH, profile_id: 'private' } }] }) } });
  assert.deepEqual(await reader.readHealth(), { available: false, errorCode: 'notification_health_unavailable' });
  assert.throws(() => validateHealth({ ...HEALTH, enabled: 'unknown' }), /invalid_notification_health/);
  assert.throws(() => validateHealth({ ...HEALTH, dead: -1 }), /invalid_notification_health/);
  assert.throws(() => validateHealth({ ...HEALTH, queued: 10001 }), /invalid_notification_health/);
});

test('health database failure is reported without SQL details', async () => {
  const reader = createNotificationOutboxHealth({ databasePool: { query: async () => {
    throw Object.assign(new Error('database host or query detail'), { code: 'XX000' });
  } } });
  assert.deepEqual(await reader.readHealth(), { available: false, errorCode: 'xx000' });
});

test('reader requires an injected query-capable pool and reads no ambient configuration', () => {
  assert.throws(() => createNotificationOutboxHealth(), /databasePool.query/);
  assert.throws(() => createNotificationOutboxHealth({ databasePool: {} }), /databasePool.query/);
});
