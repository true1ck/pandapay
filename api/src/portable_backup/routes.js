'use strict';

const { EXPORT_PATH, MEDIA_TYPE } = require('./contract');
const { DEFAULT_BATCH_SIZE, DEFAULT_STATEMENT_TIMEOUT_MS, databaseErrorCode, exportSnapshot } = require('./export');

const DEFAULT_RATE_WINDOW_MS = 60_000;
const DEFAULT_RATE_LIMIT = 3;

function registerPortableBackupRoutes(app, {
  requireAuth,
  pool,
  batchSize = DEFAULT_BATCH_SIZE,
  statementTimeoutMs = DEFAULT_STATEMENT_TIMEOUT_MS,
  rateLimit = DEFAULT_RATE_LIMIT,
  rateWindowMs = DEFAULT_RATE_WINDOW_MS,
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
  now = () => Date.now(),
  attempts = new Map(),
} = {}) {
  if (!pool || typeof pool.connect !== 'function') throw new TypeError('pool is required');
  return async (req, res) => {
    const profileId = req.userId;
    if (!profileId) return res.status(401).json({ error: 'session_invalid' });
    const current = now();
    const previous = attempts.get(profileId) || [];
    const active = previous.filter((timestamp) => timestamp > current - rateWindowMs);
    if (active.length >= rateLimit) return res.status(429).json({ error: 'export_rate_limited' });
    active.push(current);
    attempts.set(profileId, active);

    res.setHeader?.('Content-Type', `${MEDIA_TYPE}; charset=utf-8`);
    res.setHeader?.('Cache-Control', 'no-store');

    let client;
    let committed = false;
    try {
      client = await pool.connect();
      await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
      await client.query("SELECT set_config('statement_timeout', $1, true)", [`${statementTimeoutMs}ms`]);
      await client.query("SELECT set_config('app.user_id', $1, true)", [profileId]);
      await exportSnapshot({ client, res, profileId, batchSize });
      // The snapshot is read-only. Rollback closes the transaction without
      // creating a commit record and makes cancellation cleanup explicit.
      await client.query('ROLLBACK');
      committed = true;
    } catch (error) {
      const code = databaseErrorCode(error);
      if (!res.headersSent) return res.status(code === 'export_cancelled' ? 499 : 503).json({ error: code });
      if (!res.destroyed) res.destroy();
    } finally {
      if (client) {
        if (!committed) await client.query('ROLLBACK').catch(() => {});
        client.release();
      }
    }
    return undefined;
  };
}

module.exports = { createPortableBackupExportHandler, registerPortableBackupRoutes };
