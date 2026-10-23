'use strict';

const { EXPORT_PATH, MEDIA_TYPE } = require('./contract');
const {
  DEFAULT_BATCH_SIZE,
  DEFAULT_STATEMENT_TIMEOUT_MS,
  DEFAULT_MAX_EXPORT_DURATION_MS,
  DEFAULT_BACKPRESSURE_TIMEOUT_MS,
  DEFAULT_MAX_OUTPUT_BYTES,
  DEFAULT_MAX_RECORDS,
  databaseErrorCode,
  exportSnapshot,
} = require('./export');

const DEFAULT_RATE_WINDOW_MS = 60_000;
const DEFAULT_RATE_LIMIT = 3;
const DEFAULT_MAX_RATE_LIMIT_ENTRIES = 10_000;
// One export per Node process/registered handler; this is not a distributed lock.
const DEFAULT_MAX_CONCURRENT_EXPORTS = 1;

function registerPortableBackupRoutes(app, {
  requireAuth,
  pool,
  batchSize = DEFAULT_BATCH_SIZE,
  statementTimeoutMs = DEFAULT_STATEMENT_TIMEOUT_MS,
  rateLimit = DEFAULT_RATE_LIMIT,
  rateWindowMs = DEFAULT_RATE_WINDOW_MS,
  maxRateLimitEntries = DEFAULT_MAX_RATE_LIMIT_ENTRIES,
  maxDurationMs = DEFAULT_MAX_EXPORT_DURATION_MS,
  backpressureTimeoutMs = DEFAULT_BACKPRESSURE_TIMEOUT_MS,
  maxOutputBytes = DEFAULT_MAX_OUTPUT_BYTES,
  maxRecords = DEFAULT_MAX_RECORDS,
  maxConcurrentExports = DEFAULT_MAX_CONCURRENT_EXPORTS,
  now = () => Date.now(),
} = {}) {
  if (!app || typeof app.get !== 'function') throw new TypeError('app is required');
  if (typeof requireAuth !== 'function') throw new TypeError('requireAuth is required');
  if (!pool || typeof pool.connect !== 'function') throw new TypeError('pool is required');
  const attempts = new Map();

  const handler = createPortableBackupExportHandler({
    pool,
    batchSize,
    statementTimeoutMs,
    rateLimit,
    rateWindowMs,
    maxRateLimitEntries,
    maxDurationMs,
    backpressureTimeoutMs,
    maxOutputBytes,
    maxRecords,
    maxConcurrentExports,
    now,
    attempts,
  });
  app.get(EXPORT_PATH, requireAuth, handler);
  return app;
}

/**
 * Creates the authenticated export callback without requiring an Express app.
 * This keeps transport wiring in index.js while allowing API tests to drive
 * the complete transaction and stream lifecycle with a response double.
 */
function createPortableBackupExportHandler({
  pool,
  batchSize = DEFAULT_BATCH_SIZE,
  statementTimeoutMs = DEFAULT_STATEMENT_TIMEOUT_MS,
  rateLimit = DEFAULT_RATE_LIMIT,
  rateWindowMs = DEFAULT_RATE_WINDOW_MS,
  maxRateLimitEntries = DEFAULT_MAX_RATE_LIMIT_ENTRIES,
  maxDurationMs = DEFAULT_MAX_EXPORT_DURATION_MS,
  backpressureTimeoutMs = DEFAULT_BACKPRESSURE_TIMEOUT_MS,
  maxOutputBytes = DEFAULT_MAX_OUTPUT_BYTES,
  maxRecords = DEFAULT_MAX_RECORDS,
  maxConcurrentExports = DEFAULT_MAX_CONCURRENT_EXPORTS,
  now = () => Date.now(),
  attempts = new Map(),
} = {}) {
  if (!pool || typeof pool.connect !== 'function') throw new TypeError('pool is required');
  for (const value of [rateLimit, rateWindowMs, maxRateLimitEntries, statementTimeoutMs,
    maxDurationMs, backpressureTimeoutMs, maxOutputBytes, maxRecords, maxConcurrentExports]) {
    if (!Number.isSafeInteger(value) || value < 1) throw new TypeError('portable backup route configuration is invalid');
  }
  let activeExports = 0;
  return async (req, res) => {
    const profileId = req.userId;
    if (!profileId) return res.status(401).json({ error: 'session_invalid' });
    if (activeExports >= maxConcurrentExports) {
      return res.status(503).json({ error: 'export_busy' });
    }
    const current = now();
    for (const [id, timestamps] of attempts) {
      const unexpired = timestamps.filter((timestamp) => timestamp > current - rateWindowMs);
      if (unexpired.length) attempts.set(id, unexpired);
      else attempts.delete(id);
    }
    const previous = attempts.get(profileId) || [];
    const active = previous.filter((timestamp) => timestamp > current - rateWindowMs);
    if (active.length >= rateLimit) return res.status(429).json({ error: 'export_rate_limited' });
    if (!attempts.has(profileId) && attempts.size >= maxRateLimitEntries) {
      return res.status(429).json({ error: 'export_rate_limited' });
    }
    active.push(current);
    attempts.set(profileId, active);
    activeExports += 1;

    let client;
    let committed = false;
    try {
      res.setHeader?.('Content-Type', `${MEDIA_TYPE}; charset=utf-8`);
      res.setHeader?.('Cache-Control', 'no-store');
      client = await pool.connect();
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SELECT set_config('statement_timeout', $1, true)", [`${statementTimeoutMs}ms`]);
      await client.query("SELECT set_config('app.user_id', $1, true)", [profileId]);
      await exportSnapshot({ client, res, profileId, batchSize, maxDurationMs,
        backpressureTimeoutMs, maxOutputBytes, maxRecords, now });
      // The snapshot is read-only. Rollback closes the transaction without
      // creating a commit record and makes cancellation cleanup explicit.
      await client.query('ROLLBACK');
      committed = true;
    } catch (error) {
      const code = databaseErrorCode(error);
      if (!res.headersSent) {
        res.setHeader?.('Content-Type', 'application/json; charset=utf-8');
        return res.status(code === 'export_cancelled' ? 499 : 503).json({ error: code });
      }
      if (!res.destroyed) res.destroy();
    } finally {
      try {
        if (client) {
          if (!committed) await client.query('ROLLBACK').catch(() => {});
          client.release();
        }
      } finally {
        activeExports -= 1;
      }
    }
    return undefined;
  };
}

module.exports = { createPortableBackupExportHandler, registerPortableBackupRoutes };
