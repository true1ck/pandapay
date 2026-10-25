'use strict';

const { readRetentionPolicy } = require('./retentionPolicy');
const { runRetention } = require('./retentionRunner');

/** Explicit apply-only adapter for the bounded operational coordinator. The
 * product ledger contains only counts/status; all auth DML uses a different
 * dedicated connection with the existing approved fixed-scope policy.
 */
function createMaintenanceRetention({ env = process.env, apply = false, clientFactory } = {}) {
  if (apply !== true || env.AUTH_RETENTION_MAINTENANCE_ENABLED !== 'true') return undefined;
  const original = readRetentionPolicy(env);
  if (!original.scopes.length) throw new Error('An explicit auth retention policy is required');
  if (!env.AUTH_RETENTION_DATABASE_URL) throw new Error('Auth retention maintenance database is not configured');
  const policy = { ...original, batchSize: Math.min(original.batchSize, 100), maxBatches: Math.min(original.maxBatches, 10),
    maxDurationMs: Math.min(original.maxDurationMs, 5000) };
  const { resolveDatabaseTls } = require('../utils/dbTls');
  const resolved = resolveDatabaseTls(env.AUTH_RETENTION_DATABASE_URL, env);
  const options = { connectionString: resolved.connectionString, ssl: resolved.ssl, connectionTimeoutMillis: 5000,
    statement_timeout: 5000, query_timeout: 6000, application_name: 'pandapay-auth-scheduled-retention' };
  return async function runAuthRetention() {
    const client = clientFactory ? clientFactory(options) : new (require('pg').Client)(options);
    try {
      await client.connect();
      const identity = await client.query(`SELECT r.rolsuper,r.rolbypassrls,r.rolcreatedb,r.rolcreaterole,r.rolreplication,
       current_user=session_user AS direct_login,
       EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema') AND n.nspname NOT LIKE 'pg_toast%'
        AND c.relkind IN ('r','p','v','m','f')
        AND NOT(n.nspname='public' AND c.relname IN ('db_access_log','auth_abuse_buckets'))
        AND (pg_catalog.has_any_column_privilege(current_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES') OR
          pg_catalog.has_table_privilege(current_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) AS identity_access
       FROM pg_catalog.pg_roles r WHERE r.rolname=current_user`);
      const row = identity.rows?.[0];
      if (identity.rows?.length !== 1 || !row || row.rolsuper || row.rolbypassrls || row.rolcreatedb || row.rolcreaterole ||
          row.rolreplication || row.direct_login !== true || row.identity_access) throw new Error('Auth retention database identity is not restricted');
      const result = await runRetention(client, policy, { apply: true });
      return { status: result.status, deleted: result.scopes.reduce((total, scope) => total + scope.deleted, 0), more: result.status === 'budget_exhausted' };
    } finally { await client.end(); }
  };
}
module.exports = { createMaintenanceRetention };
