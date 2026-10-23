'use strict';

const { safeErrorCode } = require('../utils/safeErrorCode');

function requiresPostgresAbuseStorage(env = process.env) {
  const nodeEnv = String(env.NODE_ENV || '').trim().toLowerCase();
  return ['production', 'staging'].includes(nodeEnv) || env.AUTH_ABUSE_STORE === 'postgres';
}

async function checkAuthReadiness(query, { env = process.env } = {}) {
  if (typeof query !== 'function') throw new TypeError('A database query function is required');
  await query('SELECT 1');
  if (!requiresPostgresAbuseStorage(env)) return { ok: true, database: 'ready' };

  const result = await query(
    `SELECT has_schema_privilege(current_user, 'public', 'USAGE') AS schema_usage,
            has_table_privilege(current_user, 'public.auth_abuse_buckets', 'SELECT') AS can_select,
            has_table_privilege(current_user, 'public.auth_abuse_buckets', 'INSERT') AS can_insert,
            has_table_privilege(current_user, 'public.auth_abuse_buckets', 'UPDATE') AS can_update,
            has_table_privilege(current_user, 'public.auth_abuse_buckets', 'DELETE') AS can_delete`,
  );
  const access = result.rows?.[0];
  if (!access || access.schema_usage !== true || access.can_select !== true ||
      access.can_insert !== true || access.can_update !== true || access.can_delete !== true) {
    throw new Error('Auth abuse storage is unavailable');
  }

  // Probe the actual relation under the runtime identity without reading
  // bucket contents or mutating rate-limit state.
  await query('SELECT 1 FROM public.auth_abuse_buckets LIMIT 0');
  return { ok: true, database: 'ready' };
}

function createReadinessHandler({ query, env = process.env, logger = console } = {}) {
  return async (_req, res) => {
    try {
      const status = await checkAuthReadiness(query, { env });
      return res.json(status);
    } catch (error) {
      logger.error('Auth readiness dependency check failed', safeErrorCode(error));
      return res.status(503).json({ ok: false, database: 'unavailable' });
    }
  };
}

module.exports = {
  requiresPostgresAbuseStorage,
  checkAuthReadiness,
  createReadinessHandler,
};
