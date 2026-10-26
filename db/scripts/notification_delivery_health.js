#!/usr/bin/env node
'use strict';
// Read-only operator probe. Deliberately no dotenv or app-server import.
const { createRequire } = require('node:module');
const apiRequire = createRequire(require.resolve('../../api/package.json'));
const { resolveDatabaseTls } = require('../../api/src/db_tls');
const { createNotificationOutboxHealth } = require('../../api/src/notification_outbox_health');

async function probe({ env = process.env, PoolClass, write = value => process.stdout.write(value + '\n') } = {}) {
  if (!PoolClass) PoolClass = apiRequire('pg').Pool;
  if (!env.NOTIFICATION_MONITOR_DATABASE_URL) throw new Error('NOTIFICATION_MONITOR_DATABASE_URL required');
  const tls = resolveDatabaseTls(env.NOTIFICATION_MONITOR_DATABASE_URL, env);
  const pool = new PoolClass({ connectionString: tls.connectionString, ssl: tls.ssl, max: 1,
    connectionTimeoutMillis: 1500, statement_timeout: 2000, query_timeout: 2500,
    application_name: 'pandapay-notification-health' });
  pool.on?.('error', () => {});
  try {
    const result = await pool.query(`SELECT
      NOT r.rolsuper AND NOT r.rolcreatedb AND NOT r.rolcreaterole AND NOT r.rolreplication AND NOT r.rolbypassrls AS bounded,
      has_function_privilege(current_user,'notification_delivery.health()','EXECUTE') AS can_read,
      EXISTS(SELECT 1 FROM unnest(ARRAY['notification_delivery.outbox','notification_delivery.revisions',
        'notification_delivery.worker_status','notification_delivery.profile_queue_counts','notification_delivery.global_queue_count']) t
        WHERE has_any_column_privilege(current_user,t,'SELECT,INSERT,UPDATE') OR
          has_table_privilege(current_user,t,'DELETE,TRUNCATE,TRIGGER')) AS direct_private,
      has_schema_privilege(current_user,'notification_delivery','CREATE') AS can_create,
      EXISTS(SELECT 1 FROM pg_roles c WHERE c.rolname='notification_monitor' AND
        (c.rolcanlogin OR c.rolsuper OR c.rolcreatedb OR c.rolcreaterole OR c.rolreplication OR c.rolbypassrls)) AS unsafe_capability,
      EXISTS(SELECT 1 FROM pg_auth_members m WHERE
        (m.member=current_user::regrole AND m.roleid<>'notification_monitor'::regrole) OR m.member='notification_monitor'::regrole) AS unsafe_membership
      FROM pg_roles r WHERE r.rolname=current_user`);
    const row = result.rows?.[0];
    if (!row || row.bounded !== true || row.can_read !== true || row.direct_private !== false
        || row.can_create !== false || row.unsafe_capability !== false || row.unsafe_membership !== false) throw new Error('Unsafe monitor role');
    const health = await createNotificationOutboxHealth({ databasePool: pool }).readHealth();
    write(JSON.stringify(health));
    return health.available ? 0 : 2;
  } finally { await pool.end(); }
}
if (require.main === module) {
  if (process.argv.length !== 2) { process.stderr.write('Usage: notification_delivery_health.js\n'); process.exitCode = 2; }
  else probe().then(code => { process.exitCode = code; }).catch(() => {
    process.stderr.write('Notification health unavailable; check the scoped monitor configuration.\n'); process.exitCode = 2;
  });
}
module.exports = { probe };
