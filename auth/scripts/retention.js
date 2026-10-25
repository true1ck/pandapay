'use strict';

// Operator-only and opt-in. Never loads .env, starts a scheduler, or changes
// runtime-role grants. A dry run reports bounded counts, never row contents.
const { readRetentionPolicy } = require('../src/services/retentionPolicy');
const { runRetention } = require('../src/services/retentionRunner');

async function main({ args = process.argv.slice(2), env = process.env, write = value => console.log(value), clientFactory } = {}) {
  if (args.length > 1 || (args.length === 1 && !['--apply', '--help'].includes(args[0]))) throw new Error('Invalid retention command');
  if (args[0] === '--help') {
    write('Usage: node auth/scripts/retention.js [--apply]\nDefault: count-only dry run. Set AUTH_DB_ACCESS_LOG_RETENTION_DAYS (30–3650) and/or AUTH_ABUSE_STATE_RETENTION_DAYS (1–365). AUTH_RETENTION_DATABASE_URL is required when a policy is configured. No policy preserves every row. auth_audit and OTP/contact/account/financial history are never purged. Limits: AUTH_RETENTION_BATCH_SIZE (1–1000, default 100), AUTH_RETENTION_MAX_BATCHES (1–100, default 10), AUTH_RETENTION_MAX_DURATION_MS (100–60000, default 10000).');
    return;
  }
  const policy = readRetentionPolicy(env);
  const apply = args[0] === '--apply';
  if (!policy.scopes.length) {
    write(JSON.stringify(await runRetention(null, policy, { apply })));
    return;
  }
  if (!env.AUTH_RETENTION_DATABASE_URL) throw new Error('AUTH_RETENTION_DATABASE_URL is required');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const resolved = resolveDatabaseTls(env.AUTH_RETENTION_DATABASE_URL, env);
  const options = {
    connectionString: resolved.connectionString, ssl: resolved.ssl,
    connectionTimeoutMillis: 5000, statement_timeout: 5000, query_timeout: 6000,
    application_name: 'pandapay-auth-retention',
  };
  const client = clientFactory ? clientFactory(options) : new (require('pg').Client)(options);
  try {
    await client.connect();
    write(JSON.stringify(await runRetention(client, policy, { apply })));
  } finally { await client.end(); }
}

if (require.main === module) main().catch(() => { console.error('Auth retention failed; no row contents or database details are logged'); process.exitCode = 1; });
module.exports = { main };
