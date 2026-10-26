'use strict';

const FIELDS = Object.freeze({
  enabled: 'nullableBoolean',
  queued: 'integer',
  retained: 'integer',
  max_queued: 'integer',
  max_retained: 'integer',
  oldest_pending_seconds: 'nullableInteger',
  expired_leased: 'integer',
  dead: 'integer',
  new_terminal_24h: 'integer',
  worker_rows: 'integer',
  heartbeat_age_seconds: 'nullableInteger',
  missing_worker: 'boolean',
  blocked_workers: 'integer',
  unavailable_workers: 'integer',
});

function safeErrorCode(error) {
  const value = typeof error?.code === 'string' ? error.code.toLowerCase() : '';
  return /^[a-z][a-z0-9_]{0,63}$/.test(value) ? value : 'notification_health_unavailable';
}

function validateHealth(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new TypeError('invalid_notification_health');
  const keys = Object.keys(value).sort();
  const expected = Object.keys(FIELDS).sort();
  if (keys.length !== expected.length || keys.some((key, index) => key !== expected[index])) {
    throw new TypeError('invalid_notification_health');
  }
  for (const [key, type] of Object.entries(FIELDS)) {
    const field = value[key];
    const valid = type === 'integer' ? Number.isSafeInteger(field) && field >= 0
      : type === 'nullableInteger' ? field === null || (Number.isSafeInteger(field) && field >= 0)
        : type === 'boolean' ? typeof field === 'boolean'
          : type === 'nullableBoolean' ? field === null || typeof field === 'boolean'
            : false;
    if (!valid) throw new TypeError('invalid_notification_health');
  }
  if (value.max_queued !== 10000 || value.max_retained !== 10000
      || value.queued > value.max_queued || value.retained > value.max_retained
      || value.worker_rows > 128 || value.blocked_workers > value.worker_rows || value.unavailable_workers > value.worker_rows) {
    throw new TypeError('invalid_notification_health');
  }
  return Object.freeze({ ...value });
}

function createNotificationOutboxHealth({ databasePool } = {}) {
  if (!databasePool || typeof databasePool.query !== 'function') {
    throw new TypeError('databasePool.query is required');
  }
  async function readHealth() {
    try {
      const result = await databasePool.query('SELECT notification_delivery.health() AS health');
      return { available: true, health: validateHealth(result.rows?.[0]?.health) };
    } catch (error) {
      return { available: false, errorCode: safeErrorCode(error) };
    }
  }
  return { readHealth };
}

module.exports = { createNotificationOutboxHealth, safeErrorCode, validateHealth };
