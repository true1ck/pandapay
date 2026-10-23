'use strict';

const crypto = require('node:crypto');
const { safeErrorCode } = require('../utils/safeErrorCode');

const MAX_COUNTER = 1000000;
const CLEANUP_BATCH = 200;
const CAPACITY_LOCK = [1346458690, 4]; // fixed application namespace, never user input
const STORAGE_STATEMENT_TIMEOUT_MS = 1500;

class RateLimitStorageError extends Error {
  constructor(code = 'storage_unavailable') {
    super(code);
    this.name = 'RateLimitStorageError';
    this.code = code;
  }
}

class RateLimitCapacityError extends RateLimitStorageError {
  constructor() {
    super('capacity_exhausted');
    this.name = 'RateLimitCapacityError';
  }
}

class RateLimitExceededError extends Error {
  constructor() {
    super('Rate limit exceeded');
    this.name = 'RateLimitExceededError';
    this.code = 'RATE_LIMIT_EXCEEDED';
  }
}

class ActiveOtpError extends Error {
  constructor() {
    super('An OTP is already active');
    this.name = 'ActiveOtpError';
    this.code = 'OTP_ACTIVE';
  }
}

function parseCapacity(value) {
  const parsed = Number(value || 100000);
  if (!Number.isInteger(parsed) || parsed < 1000 || parsed > 1000000) {
    throw new Error('AUTH_ABUSE_BUCKET_CAPACITY must be an integer from 1000 to 1000000');
  }
  return parsed;
}

function validateTtlSeconds(ttlSeconds) {
  if (!Number.isFinite(ttlSeconds) || ttlSeconds < 0.05 || ttlSeconds > 86400 * 30) {
    throw new TypeError('Rate limit TTL must be between 0.05 seconds and 30 days');
  }
  return ttlSeconds;
}

function validateSaturation(saturation) {
  if (!Number.isInteger(saturation) || saturation < 1 || saturation > MAX_COUNTER) {
    throw new TypeError('Rate limit counter saturation is out of range');
  }
  return saturation;
}

function toBucketKey(rawKey, hmacKey) {
  if (typeof rawKey !== 'string' || !rawKey || !Buffer.isBuffer(hmacKey) || hmacKey.length < 32) {
    throw new TypeError('Invalid auth abuse bucket key configuration');
  }
  return crypto.createHmac('sha256', hmacKey)
    .update('pandapay-auth-abuse-bucket-v1\0', 'utf8')
    .update(rawKey, 'utf8')
    .digest();
}

function safeStorageFailure(error) {
  if (error instanceof RateLimitStorageError) return error;
  // Preserve only a bounded error classification for operational telemetry.
  // SQL text, parameters, keys, and provider messages are never propagated.
  const code = safeErrorCode(error);
  return new RateLimitStorageError(code === 'unknown' ? 'storage_unavailable' : code);
}

function createMemoryRateLimitStore({ now = Date.now } = {}) {
  const buckets = new Map();

  function live(rawKey) {
    const entry = buckets.get(rawKey);
    if (!entry) return null;
    if (entry.expiresAt <= now()) {
      buckets.delete(rawKey);
      return null;
    }
    return entry;
  }

  return {
    mode: 'memory',
    async increment(rawKey, ttlSeconds, saturation = MAX_COUNTER) {
      validateTtlSeconds(ttlSeconds);
      validateSaturation(saturation);
      const entry = live(rawKey);
      if (entry) {
        if (entry.kind !== 'counter') throw new RateLimitStorageError('bucket_kind_mismatch');
        entry.count = Math.min(saturation, entry.count + 1);
        return entry.count;
      }
      const count = Math.min(saturation, 1);
      buckets.set(rawKey, { kind: 'counter', count, expiresAt: now() + ttlSeconds * 1000 });
      return count;
    },
    async get(rawKey) {
      const entry = live(rawKey);
      if (!entry) return 0;
      if (entry.kind !== 'counter') throw new RateLimitStorageError('bucket_kind_mismatch');
      return entry.count;
    },
    async exists(rawKey) {
      return Boolean(live(rawKey));
    },
    async setWithTTL(rawKey, value, ttlSeconds) {
      validateTtlSeconds(ttlSeconds);
      if (String(value).length > 128) throw new TypeError('Rate limit marker value is too long');
      buckets.set(rawKey, {
        kind: 'marker', value: String(value), expiresAt: now() + ttlSeconds * 1000,
      });
      return true;
    },
    async claimMarker(rawKey, value, ttlSeconds) {
      validateTtlSeconds(ttlSeconds);
      const markerValue = String(value);
      if (markerValue.length > 128) throw new TypeError('Rate limit marker value is too long');
      // No await before lookup and set: competing calls in this process observe
      // the first claim before either async function yields to its caller.
      const entry = live(rawKey);
      if (entry) {
        if (entry.kind !== 'marker') throw new RateLimitStorageError('bucket_kind_mismatch');
        return false;
      }
      buckets.set(rawKey, {
        kind: 'marker', value: markerValue, expiresAt: now() + ttlSeconds * 1000,
      });
      return true;
    },
    async compareDelete(rawKey, expectedValue) {
      if (String(expectedValue).length > 128) throw new TypeError('Rate limit marker value is too long');
      const entry = live(rawKey);
      if (entry?.kind === 'marker' && entry.value === String(expectedValue)) {
        buckets.delete(rawKey);
        return true;
      }
      return false;
    },
    _sizeForTests() { return buckets.size; },
  };
}

function createPostgresRateLimitStore({
  poolProvider,
  hmacKey = process.env.PHONE_LOOKUP_HMAC_KEY,
  capacity = parseCapacity(process.env.AUTH_ABUSE_BUCKET_CAPACITY),
  cleanupBatch = CLEANUP_BATCH,
} = {}) {
  const keyBytes = Buffer.isBuffer(hmacKey) ? hmacKey : Buffer.from(hmacKey || '', 'utf8');
  if (keyBytes.length < 32) {
    throw new Error('PHONE_LOOKUP_HMAC_KEY must contain at least 32 bytes for hosted rate limiting');
  }
  if (typeof poolProvider !== 'function') throw new TypeError('poolProvider is required');
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 1000000) throw new TypeError('Rate limit bucket capacity is out of range');
  if (!Number.isInteger(cleanupBatch) || cleanupBatch < 1 || cleanupBatch > 500) throw new TypeError('Rate limit cleanup batch is out of range');

  async function transaction(work) {
    let client;
    let inTransaction = false;
    let releaseError;
    try {
      const pool = await poolProvider();
      if (!pool || typeof pool.connect !== 'function') throw new RateLimitStorageError();
      client = await pool.connect();
      await client.query('BEGIN');
      inTransaction = true;
      await client.query(`SET LOCAL statement_timeout = '${STORAGE_STATEMENT_TIMEOUT_MS}ms'`);
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '3000ms'");
      const result = await work(client);
      await client.query('COMMIT');
      inTransaction = false;
      return result;
    } catch (error) {
      if (inTransaction && client) {
        try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; }
      }
      throw safeStorageFailure(error);
    } finally {
      if (client) client.release(releaseError);
    }
  }

  async function lockOrCreate(client, digest, kind) {
    let selected = await client.query(
      'SELECT bucket_kind, counter_value, marker_value, expires_at > clock_timestamp() AS is_live FROM auth_abuse_buckets WHERE bucket_key = $1 FOR UPDATE',
      [digest],
    );
    if (selected.rows.length) {
      const row = selected.rows[0];
      if (row.bucket_kind !== kind) throw new RateLimitStorageError('bucket_kind_mismatch');
      return row;
    }

    // Serialize only new-key creation. This bounds the table under adversarial
    // unique identifiers while existing buckets remain independently writable.
    await client.query('SELECT pg_advisory_xact_lock($1, $2)', CAPACITY_LOCK);
    await client.query(
      `DELETE FROM auth_abuse_buckets AS buckets USING (
         SELECT bucket_key FROM auth_abuse_buckets
          WHERE expires_at <= clock_timestamp()
          ORDER BY expires_at LIMIT $1 FOR UPDATE SKIP LOCKED
       ) AS expired
       WHERE buckets.bucket_key = expired.bucket_key
         AND buckets.expires_at <= clock_timestamp()`,
      [cleanupBatch],
    );
    selected = await client.query(
      'SELECT bucket_kind, counter_value, marker_value, expires_at > clock_timestamp() AS is_live FROM auth_abuse_buckets WHERE bucket_key = $1 FOR UPDATE',
      [digest],
    );
    if (selected.rows.length) {
      const row = selected.rows[0];
      if (row.bucket_kind !== kind) throw new RateLimitStorageError('bucket_kind_mismatch');
      return row;
    }

    const countResult = await client.query('SELECT count(*)::bigint AS bucket_count FROM auth_abuse_buckets');
    if (Number(countResult.rows[0]?.bucket_count || 0) >= capacity) throw new RateLimitCapacityError();
    await client.query(
      `INSERT INTO auth_abuse_buckets
         (bucket_key, bucket_kind, counter_value, marker_value, expires_at)
       VALUES ($1, $2, 0, $3, clock_timestamp())`,
      [digest, kind, kind === 'marker' ? '' : null],
    );
    return { bucket_kind: kind, counter_value: '0', marker_value: kind === 'marker' ? '' : null, is_live: false };
  }

  return {
    mode: 'postgres',
    async increment(rawKey, ttlSeconds, saturation = MAX_COUNTER) {
      validateTtlSeconds(ttlSeconds);
      validateSaturation(saturation);
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        const row = await lockOrCreate(client, digest, 'counter');
        const result = await client.query(
          `UPDATE auth_abuse_buckets
              SET counter_value = CASE WHEN expires_at <= clock_timestamp() THEN LEAST(1, $2::bigint)
                                       ELSE LEAST(counter_value + 1, $2::bigint) END,
                  marker_value = NULL,
                  expires_at = CASE WHEN expires_at <= clock_timestamp()
                                    THEN clock_timestamp() + ($3::double precision * interval '1 second')
                                    ELSE expires_at END,
                  updated_at = clock_timestamp()
            WHERE bucket_key = $1 RETURNING counter_value`,
          [digest, saturation, ttlSeconds],
        );
        return Number(result.rows[0].counter_value);
      });
    },
    async get(rawKey) {
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        const result = await client.query(
          `SELECT counter_value FROM auth_abuse_buckets
            WHERE bucket_key = $1 AND bucket_kind = 'counter' AND expires_at > clock_timestamp()`,
          [digest],
        );
        return result.rows.length ? Number(result.rows[0].counter_value) : 0;
      });
    },
    async exists(rawKey) {
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        const result = await client.query(
          `SELECT 1 FROM auth_abuse_buckets
            WHERE bucket_key = $1 AND bucket_kind = 'marker' AND expires_at > clock_timestamp()`,
          [digest],
        );
        return result.rowCount > 0;
      });
    },
    async setWithTTL(rawKey, value, ttlSeconds) {
      validateTtlSeconds(ttlSeconds);
      const markerValue = String(value);
      if (markerValue.length > 128) throw new TypeError('Rate limit marker value is too long');
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        await lockOrCreate(client, digest, 'marker');
        await client.query(
          `UPDATE auth_abuse_buckets
              SET marker_value = $2, counter_value = 0,
                  expires_at = clock_timestamp() + ($3::double precision * interval '1 second'),
                  updated_at = clock_timestamp()
            WHERE bucket_key = $1`,
          [digest, markerValue, ttlSeconds],
        );
        return true;
      });
    },
    async claimMarker(rawKey, value, ttlSeconds) {
      validateTtlSeconds(ttlSeconds);
      const markerValue = String(value);
      if (markerValue.length > 128) throw new TypeError('Rate limit marker value is too long');
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        const row = await lockOrCreate(client, digest, 'marker');
        if (row.is_live === true || row.is_live === 't') return false;
        await client.query(
          `UPDATE auth_abuse_buckets
              SET marker_value = $2, counter_value = 0,
                  expires_at = clock_timestamp() + ($3::double precision * interval '1 second'),
                  updated_at = clock_timestamp()
            WHERE bucket_key = $1`,
          [digest, markerValue, ttlSeconds],
        );
        return true;
      });
    },
    async compareDelete(rawKey, expectedValue) {
      const markerValue = String(expectedValue);
      if (markerValue.length > 128) throw new TypeError('Rate limit marker value is too long');
      const digest = toBucketKey(rawKey, keyBytes);
      return transaction(async client => {
        const result = await client.query(
          `DELETE FROM auth_abuse_buckets
            WHERE bucket_key = $1 AND bucket_kind = 'marker' AND marker_value = $2`,
          [digest, markerValue],
        );
        return result.rowCount > 0;
      });
    },
  };
}

function createRateLimitStore({ env = process.env, poolProvider } = {}) {
  const environment = String(env.NODE_ENV || '').trim().toLowerCase();
  const hosted = ['production', 'staging'].includes(environment);
  const local = ['development', 'test'].includes(environment);
  const requested = env.AUTH_ABUSE_STORE;
  if (hosted) {
    if (requested && requested !== 'postgres') throw new Error('Hosted auth abuse storage must use PostgreSQL');
    const provider = poolProvider || (() => require('../db').getPool());
    return createPostgresRateLimitStore({ poolProvider: provider, hmacKey: env.PHONE_LOOKUP_HMAC_KEY, capacity: parseCapacity(env.AUTH_ABUSE_BUCKET_CAPACITY) });
  }
  if (requested === 'postgres') {
    const provider = poolProvider || (() => require('../db').getPool());
    return createPostgresRateLimitStore({ poolProvider: provider, hmacKey: env.PHONE_LOOKUP_HMAC_KEY, capacity: parseCapacity(env.AUTH_ABUSE_BUCKET_CAPACITY) });
  }
  if (requested && requested !== 'memory') throw new Error('AUTH_ABUSE_STORE must be postgres or memory');
  if (!local) throw new Error('NODE_ENV must be production, staging, development, or test for auth abuse storage');
  return createMemoryRateLimitStore();
}

module.exports = {
  RateLimitStorageError,
  RateLimitCapacityError,
  RateLimitExceededError,
  ActiveOtpError,
  MAX_COUNTER,
  toBucketKey,
  createMemoryRateLimitStore,
  createPostgresRateLimitStore,
  createRateLimitStore,
};
