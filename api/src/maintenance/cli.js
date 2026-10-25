#!/usr/bin/env node
'use strict';

// Explicit operator command. Does not load .env, start HTTP, send a message,
// configure retention/grants, or enable a database control automatically.
const { resolveDatabaseTls } = require('../db_tls');
const { createMaintenanceRunner, checkMaintenanceIdentity, HEALTH_SQL, NOTIFICATIONS_SQL } = require('./runner');

async function main({ args = process.argv.slice(2), env = process.env, write = value => console.log(value), clientFactory } = {}) {
  if (args.includes('--help')) {
    write('Usage: node api/src/maintenance/cli.js [--run]\nDefault: bounded count/status-only health report. --run requires MAINTENANCE_ENABLED=true and a separately enabled database job. MAINTENANCE_DATABASE_URL must name a dedicated EXECUTE-only maintenance login. Auth retention uses auth/src/services/maintenanceCli.js with separate credentials and an explicit approved policy. No financial/account/history rows are erased and no messages are sent. Install a once-per-minute invocation only after restore/role/policy acceptance.');
    return;
  }
  if (args.length > 1 || args.some(x => x !== '--run')) throw new Error('Invalid maintenance command');
  if(args.includes('--run')&&env.MAINTENANCE_ENABLED!=='true'){
    write(JSON.stringify({status:'disabled',claimed:0,processed:0,failed:0,deferred:0}));return;
  }
  if (!env.MAINTENANCE_DATABASE_URL) throw new Error('Maintenance database is not configured');
  const resolved = resolveDatabaseTls(env.MAINTENANCE_DATABASE_URL, env);
  const options = { connectionString: resolved.connectionString, ssl: resolved.ssl, connectionTimeoutMillis: 5000,
    statement_timeout: 5000, query_timeout: 6000, application_name: 'pandapay-operational-maintenance' };
  const factory = () => clientFactory ? clientFactory(options) : new (require('pg').Client)(options);
  if (args.includes('--run')) {
    const run = createMaintenanceRunner({ clientFactory: factory, enabled: env.MAINTENANCE_ENABLED === 'true' });
    const result=await run();
    write(JSON.stringify(result));
    if(result.failed>0)throw new Error('Maintenance jobs require retry');
    return;
  }
  const client = factory();
  try {
    await client.connect();
    await checkMaintenanceIdentity(client);
    const health = await client.query(HEALTH_SQL);
    const notifications = await client.query(NOTIFICATIONS_SQL);
    if (!Array.isArray(health.rows) || health.rows.length > 4 || !Array.isArray(notifications.rows) || notifications.rows.length > 12) {
      throw new Error('Invalid maintenance health report');
    }
    write(JSON.stringify({ jobs: health.rows, notifications: notifications.rows, externalDeliveryConfigured: false }));
  } finally { await client.end(); }
}
if (require.main === module) main().catch(() => { console.error('Operational maintenance failed; database details and row contents are not logged'); process.exitCode = 1; });
module.exports = { main };
