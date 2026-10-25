'use strict';

const { performance } = require('node:perf_hooks');
const JOBS = Object.freeze(['merchant_confidence', 'rate_divergence', 'inbound_body_retention']);
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CLAIM_SQL = 'SELECT * FROM maintenance.claim_job($1::text)';
const BATCH_SQL = 'SELECT * FROM maintenance.run_batch($1::text,$2::uuid)';
const YIELD_SQL = 'SELECT maintenance.yield_job($1::text,$2::uuid) AS accepted';
const FAIL_SQL = 'SELECT maintenance.fail_job($1::text,$2::uuid) AS accepted';
const HEALTH_SQL = 'SELECT * FROM maintenance.read_health()';
const NOTIFICATIONS_SQL = 'SELECT * FROM maintenance.read_notifications()';
const READINESS_SQL = `SELECT r.rolsuper,r.rolbypassrls,r.rolcreatedb,r.rolcreaterole,r.rolreplication,
 current_user=session_user AS direct_login,
 (SELECT count(*)::integer FROM pg_catalog.pg_auth_members m WHERE m.member=r.oid) AS memberships,
 pg_catalog.pg_has_role(current_user,'pandapay_maintenance','USAGE') AS capability,
 EXISTS(SELECT 1 FROM pg_catalog.pg_auth_members m WHERE m.member='pandapay_maintenance'::regrole) AS nested_capability,
 EXISTS(SELECT 1 FROM pg_catalog.pg_roles c WHERE c.rolname='pandapay_maintenance'
  AND (c.rolcanlogin OR c.rolsuper OR c.rolbypassrls OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication OR c.rolinherit)) AS unsafe_capability,
 pg_catalog.has_schema_privilege(current_user,'maintenance','CREATE') AS ddl,
 EXISTS(SELECT 1 FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relname IN ('profiles','user_cards','transactions','inbound_emails') AND
  (pg_catalog.has_any_column_privilege(current_user,c.oid,'SELECT,INSERT,UPDATE,REFERENCES') OR
   pg_catalog.has_table_privilege(current_user,c.oid,'DELETE,TRUNCATE,TRIGGER'))) AS customer_access,
 (SELECT count(*)::integer FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='maintenance' AND c.relname IN ('jobs','notifications') AND
  c.relrowsecurity AND c.relforcerowsecurity AND c.relowner<>r.oid) AS protected_tables
 FROM pg_catalog.pg_roles r WHERE r.rolname=current_user`;

async function checkMaintenanceIdentity(client) {
  const result = await client.query(READINESS_SQL);
  const row = result.rows?.[0];
  if (result.rows?.length !== 1 || !row || row.rolsuper || row.rolbypassrls || row.rolcreatedb || row.rolcreaterole || row.rolreplication ||
      row.direct_login !== true || row.memberships !== 1 || row.capability !== true || row.nested_capability || row.unsafe_capability ||
      row.ddl || row.customer_access || row.protected_tables !== 2) throw new Error('Maintenance database identity is not restricted');
}

/** A dedicated, non-pooled connection is always closed, including uncertain
 * query/rollback outcomes. Each fixed SQL batch commits checkpoint + effects
 * together. One batch/job/cycle prevents a large merchant rotation from
 * starving mail privacy or other work on a small host. There are no sends.
 */
function createMaintenanceRunner({ clientFactory, enabled = false, maxDurationMs = 15000,
  now = () => performance.now(), logger = console } = {}) {
  if (typeof enabled !== 'boolean' || !Number.isInteger(maxDurationMs) || maxDurationMs < 1000 || maxDurationMs > 60000) {
    throw new Error('Invalid maintenance limits');
  }
  let running = false;
  return async function runOnce() {
    if (!enabled) return { status: 'disabled', claimed: 0, processed: 0, failed: 0, deferred: 0 };
    if (typeof clientFactory !== 'function') throw new Error('Maintenance database is not configured');
    if (running) return { status: 'already_running', claimed: 0, processed: 0, failed: 0, deferred: 0 };
    running = true;
    let client;
    const summary = { status: 'completed', claimed: 0, processed: 0, failed: 0, deferred: 0 };
    try {
      client = clientFactory();
      await client.connect();
      await checkMaintenanceIdentity(client);
      const started = now();
      await client.query('SELECT maintenance.review_health()');
      for (const job of JOBS) {
        if (now() - started >= maxDurationMs) { summary.status = 'budget_exhausted'; break; }
        const claimed = await client.query(CLAIM_SQL, [job]);
        if (!Array.isArray(claimed.rows) || claimed.rows.length > 1) throw new Error('Invalid maintenance claim');
        const lease = claimed.rows[0];
        if (!lease) continue;
        if (!UUID.test(lease.lease_token) || !/^[1-9][0-9]{0,18}$/.test(String(lease.generation)) ||
            BigInt(lease.generation) > 9223372036854775807n) throw new Error('Invalid maintenance claim');
        summary.claimed++;
        try {
            const result = await client.query(BATCH_SQL, [job, lease.lease_token]);
            const row = result.rows?.[0];
            if (result.rows?.length !== 1 || !row || !Number.isInteger(row.processed) || row.processed < 0 || row.processed > 100 || typeof row.more !== 'boolean') {
              throw new Error('Invalid maintenance batch');
            }
            summary.processed += row.processed;
            if (row.more) {
              const released = await client.query(YIELD_SQL, [job, lease.lease_token]);
              if (released.rows?.[0]?.accepted !== true) throw new Error('Maintenance lease unavailable');
              summary.deferred++;
            }
        } catch (_) {
          summary.failed++;
          // A connection error may also make this fail; closing the dedicated
          // session leaves the durable lease to expire and be reported later.
          const failure = await client.query(FAIL_SQL, [job, lease.lease_token]);
          if (failure.rows?.[0]?.accepted !== true) throw new Error('Maintenance failure could not be recorded');
          logger.warn?.('Maintenance job requires retry');
        }
      }
      return summary;
    } finally {
      try { if (client) await client.end(); } finally { running = false; }
    }
  };
}

module.exports = { createMaintenanceRunner, checkMaintenanceIdentity, JOBS, CLAIM_SQL, BATCH_SQL, YIELD_SQL, FAIL_SQL,
  HEALTH_SQL, NOTIFICATIONS_SQL, READINESS_SQL };
