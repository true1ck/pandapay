'use strict';

// Called only by the privileged migration job after capability migrations.
// Blank opt-in secrets do not create, rotate or enable service accounts.
const CAPABILITIES = [
  { password: 'PARTNER_WEBHOOK_DB_PASSWORD', login: 'partner_webhook_runtime', role: 'pandapay_partner_webhook' },
  { password: 'BACKUP_STATUS_WRITER_DB_PASSWORD', login: 'backup_status_runtime', role: 'backup_status_writer' },
  { password: 'IMAP_WORKER_DB_PASSWORD', login: 'imap_worker_runtime', role: 'pandapay_imap_worker' },
  { password: 'MAINTENANCE_DB_PASSWORD', login: 'maintenance_runtime', role: 'pandapay_maintenance' },
  { password: 'AUTH_MAINTENANCE_DB_PASSWORD', login: 'auth_maintenance_runtime', role: 'pandapay_auth_retention_coordinator' },
  { password: 'MAINTENANCE_READER_DB_PASSWORD', login: 'maintenance_reader_runtime', role: 'pandapay_maintenance_reader' },
  { password: 'ACCOUNT_LIFECYCLE_DB_PASSWORD', login: 'account_lifecycle_runtime', role: 'pandapay_account_lifecycle' },
];
const quoted = value => `"${value.replaceAll('"','""')}"`;

async function configureServiceCapabilities(client, env = process.env) {
  const configured = [];
  for (const entry of CAPABILITIES) {
    const password = env[entry.password];
    if (!password) continue;
    if (typeof password !== 'string' || Buffer.byteLength(password) < 32 || password.includes('\0')) {
      throw new Error(`${entry.password} must contain at least 32 bytes without NUL`);
    }
    const capability = await client.query('SELECT rolcanlogin,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname=$1', [entry.role]);
    const cap = capability.rows?.[0];
    if (!cap || cap.rolcanlogin || cap.rolsuper || cap.rolbypassrls || cap.rolcreatedb || cap.rolcreaterole || cap.rolreplication) throw new Error('Service capability migration is missing or unsafe');
    const capMemberships=await client.query(`SELECT parent.rolname FROM pg_auth_members m
      JOIN pg_roles child ON child.oid=m.member JOIN pg_roles parent ON parent.oid=m.roleid
      WHERE child.rolname=$1`,[entry.role]);
    if(capMemberships.rows.length)throw new Error('Service capability has unreviewed memberships');
    const found = await client.query('SELECT rolcanlogin,rolinherit,rolsuper,rolbypassrls,rolcreatedb,rolcreaterole,rolreplication FROM pg_roles WHERE rolname=$1', [entry.login]);
    if (!found.rows?.length) {
      // PostgreSQL role DDL does not accept bind parameters. Ask PostgreSQL
      // to quote the password; never put it into command-line arguments/logs.
      const literal = (await client.query('SELECT quote_literal($1::text) AS value', [password])).rows[0]?.value;
      if (typeof literal !== 'string') throw new Error('Service credential quoting failed');
      await client.query(`CREATE ROLE ${quoted(entry.login)} LOGIN PASSWORD ${literal} NOSUPERUSER NOCREATEDB NOCREATEROLE INHERIT NOREPLICATION NOBYPASSRLS`);
    } else {
      const role = found.rows[0];
      if (!role.rolcanlogin || role.rolinherit === false || role.rolsuper || role.rolbypassrls || role.rolcreatedb || role.rolcreaterole || role.rolreplication) {
        throw new Error('Existing service login has unsafe role attributes');
      }
      // Do not rotate an existing credential while re-running migrations.
    }
    const memberships = await client.query(`SELECT parent.rolname FROM pg_auth_members m
      JOIN pg_roles child ON child.oid=m.member JOIN pg_roles parent ON parent.oid=m.roleid
      WHERE child.rolname=$1`, [entry.login]);
    if (memberships.rows.some(row => row.rolname !== entry.role)) throw new Error('Service login has unreviewed role memberships');
    await client.query(`GRANT ${quoted(entry.role)} TO ${quoted(entry.login)}`);
    const database = (await client.query('SELECT current_database() AS name')).rows[0]?.name;
    if (!database) throw new Error('Service database is unavailable');
    await client.query(`GRANT CONNECT ON DATABASE ${quoted(database)} TO ${quoted(entry.login)}`);
    configured.push(entry.login);
  }
  return configured;
}
module.exports = { configureServiceCapabilities, CAPABILITIES };
