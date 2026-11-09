'use strict';

// Operator-only, read-only. Never loads .env. Needs AUTH_SUPPORT_DATABASE_URL, a role that
// can read users, user_devices and auth_audit. Prints masked emails, account ids and
// counts; never a phone number, token or code.
//
//   node auth/scripts/account_clusters.js devices [--min 3] [--limit 50]
//   node auth/scripts/account_clusters.js ips     [--days 7] [--min 5] [--limit 50]
//   node auth/scripts/account_clusters.js flags   [--days 7] [--limit 50]
//
// devices  phones (install ids) that more than --min live accounts have signed in on.
// ips      addresses that created more than --min new accounts in the last --days. Many
//          people share one address on a mobile network, so treat a big cluster as a
//          lead to look at, never as proof.
// flags    sign-ups the device limit recorded (or refused) in the last --days.
//
// Phones are not listed: one number can only be held by one live account, so there is no
// phone cluster to show. A person using many numbers shows up here, by device or address.

const { maskEmail } = require('../src/utils/recoveryContacts');
const { SHARED_PLACEHOLDERS, ACTION } = require('../src/services/deviceAccountLimit');

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i];
    if (!/^--[a-z]+$/.test(key || '') || rest[i + 1] === undefined || rest[i + 1].startsWith('--')) throw new Error(`Bad option near "${key || ''}"`);
    options[key.slice(2)] = rest[i + 1];
  }
  return { command, options };
}

function whole(options, name, fallback, min, max) {
  if (options[name] === undefined) return fallback;
  const value = Number(options[name]);
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`--${name} must be a whole number from ${min} to ${max}`);
  return value;
}

const iso = value => (value ? new Date(value).toISOString() : null);
const member = row => ({ user_id: row.user_id, account: row.email ? maskEmail(row.email) : null, created_at: iso(row.created_at) });

async function run({ pool, argv, write = value => console.log(value) }) {
  const { command, options } = parseArgs(argv);
  const print = value => write(JSON.stringify(value, null, 2));
  const limit = whole(options, 'limit', 50, 1, 200);

  if (command === 'devices') {
    const min = whole(options, 'min', 3, 2, 1000);
    const { rows } = await pool.query(
      `WITH shared AS (
         SELECT d.device_identifier, COUNT(DISTINCT d.user_id)::int AS accounts
           FROM user_devices d JOIN users u ON u.id = d.user_id
          WHERE u.deleted = FALSE AND d.device_identifier IS NOT NULL AND d.device_identifier <> ALL($1::text[])
          GROUP BY d.device_identifier HAVING COUNT(DISTINCT d.user_id) > $2
          ORDER BY accounts DESC, d.device_identifier LIMIT $3)
       SELECT s.device_identifier, s.accounts, u.id AS user_id, u.email, u.created_at
         FROM shared s
         JOIN user_devices d ON d.device_identifier = s.device_identifier
         JOIN users u ON u.id = d.user_id AND u.deleted = FALSE
        ORDER BY s.accounts DESC, s.device_identifier, u.created_at`,
      [[...SHARED_PLACEHOLDERS], min, limit]);
    const byDevice = new Map();
    for (const row of rows) {
      if (!byDevice.has(row.device_identifier)) byDevice.set(row.device_identifier, { device: row.device_identifier, accounts: row.accounts, members: [] });
      const cluster = byDevice.get(row.device_identifier);
      if (!cluster.members.some(m => m.user_id === row.user_id)) cluster.members.push(member(row));
    }
    return print({ min_exclusive: min, clusters: [...byDevice.values()] });
  }

  if (command === 'ips') {
    const days = whole(options, 'days', 7, 1, 90);
    const min = whole(options, 'min', 5, 2, 1000);
    const { rows } = await pool.query(
      `WITH made AS (
         SELECT a.ip_address, a.user_id
           FROM auth_audit a
          WHERE a.action IN ('otp_verify_email', 'otp_verify') AND a.status = 'success'
            AND a.created_at > NOW() - ($1::int * INTERVAL '1 day')
            AND a.meta->>'is_new_account' = 'true' AND a.ip_address IS NOT NULL AND a.user_id IS NOT NULL),
       shared AS (
         SELECT ip_address, COUNT(DISTINCT user_id)::int AS accounts FROM made
          GROUP BY ip_address HAVING COUNT(DISTINCT user_id) > $2 ORDER BY accounts DESC, ip_address LIMIT $3)
       SELECT s.ip_address, s.accounts, u.id AS user_id, u.email, u.created_at
         FROM shared s JOIN made m ON m.ip_address = s.ip_address JOIN users u ON u.id = m.user_id AND u.deleted = FALSE
        ORDER BY s.accounts DESC, s.ip_address, u.created_at`,
      [days, min, limit]);
    const byIp = new Map();
    for (const row of rows) {
      if (!byIp.has(row.ip_address)) byIp.set(row.ip_address, { ip: row.ip_address, accounts: row.accounts, members: [] });
      const cluster = byIp.get(row.ip_address);
      if (!cluster.members.some(m => m.user_id === row.user_id)) cluster.members.push(member(row));
    }
    return print({
      days, min_exclusive: min, clusters: [...byIp.values()],
      note: 'Mobile networks put many people behind one address. A cluster is a lead, not proof.',
    });
  }

  if (command === 'flags') {
    const days = whole(options, 'days', 7, 1, 90);
    const { rows } = await pool.query(
      `SELECT a.created_at, a.status, a.device_id, a.ip_address, a.user_id, u.email, a.meta
         FROM auth_audit a LEFT JOIN users u ON u.id = a.user_id
        WHERE a.action = $1 AND a.created_at > NOW() - ($2::int * INTERVAL '1 day')
        ORDER BY a.created_at DESC LIMIT $3`,
      [ACTION, days, limit]);
    return print({
      days,
      events: rows.map(r => ({
        at: iso(r.created_at), status: r.status, device: r.device_id, ip: r.ip_address,
        user_id: r.user_id, account: r.email ? maskEmail(r.email) : null,
        accounts_on_device: r.meta?.accounts ?? null, limit: r.meta?.limit ?? null, enforced: r.meta?.enforced ?? null,
      })),
    });
  }

  throw new Error('Usage: account_clusters.js devices | ips | flags (see the header of this file)');
}

async function main({ argv = process.argv.slice(2), env = process.env, write } = {}) {
  if (!env.AUTH_SUPPORT_DATABASE_URL) throw new Error('AUTH_SUPPORT_DATABASE_URL is required');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const resolved = resolveDatabaseTls(env.AUTH_SUPPORT_DATABASE_URL, env);
  const { Pool } = require('pg');
  const pool = new Pool({
    connectionString: resolved.connectionString, ssl: resolved.ssl, max: 1,
    connectionTimeoutMillis: 5000, statement_timeout: 15000, application_name: 'pandapay-auth-account-clusters',
  });
  try { await run({ pool, argv, write }); } finally { await pool.end(); }
}

if (require.main === module) {
  main().catch(error => { console.error(error && /^(Usage|Bad option|--|AUTH_SUPPORT)/.test(error.message) ? error.message : 'Account cluster command failed'); process.exitCode = 1; });
}
module.exports = { run, main, parseArgs };
