'use strict';

const ABUSE_MIGRATION_FILE = '0004_auth_abuse_buckets.sql';
const DB_ACCESS_MIGRATION_FILE = '0005_db_access_log.sql';
const DASHBOARD_MIGRATION_FILE = '0007_security_dashboard_capability.sql';
const GOOGLE_MIGRATION_FILE = '0006_google_oauth_identity.sql';

function isDbAccessLoggingEnabled(env = process.env) {
  return env.DB_ACCESS_LOGGING_ENABLED === 'true' || env.DB_ACCESS_LOGGING_ENABLED === '1';
}

function quotePgIdentifier(value) {
  if (typeof value !== 'string' || value.length === 0 || Buffer.byteLength(value, 'utf8') > 63 ||
      /[\x00-\x1f\x7f]/.test(value) || value.toLowerCase() === 'public') {
    throw new Error('AUTH_RUNTIME_ROLE must be a non-PUBLIC PostgreSQL role identifier from 1 to 63 UTF-8 bytes without ASCII controls');
  }
  return `"${value.replace(/"/g, '""')}"`;
}

function includesAbuseMigration(files) {
  return Array.isArray(files) && files.some(file =>
    file?.file === ABUSE_MIGRATION_FILE && file?.version === '0004_auth_abuse_buckets');
}

function includesDbAccessMigration(files) {
  return Array.isArray(files) && files.some(file =>
    file?.file === DB_ACCESS_MIGRATION_FILE && file?.version === '0005_db_access_log');
}

async function verifyRuntimeRoleAccess(client, role, { dbAccessLoggingEnabled = false } = {}) {
  const roleResult = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [role]);
  if (!roleResult.rows?.length) throw new Error('AUTH_RUNTIME_ROLE does not name an existing PostgreSQL role');

  const tableResult = await client.query(
    "SELECT to_regclass('public.auth_abuse_buckets') IS NOT NULL AS table_exists",
  );
  if (tableResult.rows?.[0]?.table_exists !== true) {
    throw new Error('Auth abuse-bucket table is missing after its migration');
  }

  const privileges = await client.query(
    `SELECT has_schema_privilege($1, 'public', 'USAGE') AS schema_usage,
            has_table_privilege($1, 'public.auth_abuse_buckets', 'SELECT') AS can_select,
            has_table_privilege($1, 'public.auth_abuse_buckets', 'INSERT') AS can_insert,
            has_table_privilege($1, 'public.auth_abuse_buckets', 'UPDATE') AS can_update,
            has_table_privilege($1, 'public.auth_abuse_buckets', 'DELETE') AS can_delete`,
    [role],
  );
  const access = privileges.rows?.[0];
  if (!access || access.schema_usage !== true || access.can_select !== true ||
      access.can_insert !== true || access.can_update !== true || access.can_delete !== true) {
    throw new Error('AUTH_RUNTIME_ROLE lacks required schema or auth abuse-bucket privileges');
  }

  if (dbAccessLoggingEnabled) {
    const logExists = await client.query(
      "SELECT to_regclass('public.db_access_log') IS NOT NULL AS table_exists",
    );
    if (logExists.rows?.[0]?.table_exists !== true) {
      throw new Error('Auth database access log table is missing after its migration');
    }
    await verifyDatabaseAccessLogRoleAccess(client, role);
  }
}

async function configureAuthRuntimeRole(client, {
  files,
  runtimeRole,
  dbAccessLoggingEnabled = isDbAccessLoggingEnabled(),
  securityDashboardEnabled = false,
} = {}) {
  const hasAbuseMigration = includesAbuseMigration(files);
  const hasDbAccessMigration = dbAccessLoggingEnabled && includesDbAccessMigration(files);
  const hasDashboardMigration = securityDashboardEnabled && Array.isArray(files) && files.some(file => file?.file === DASHBOARD_MIGRATION_FILE);
  const hasGoogleMigration = Array.isArray(files) && files.some(file => file?.file === GOOGLE_MIGRATION_FILE);
  if (!hasAbuseMigration && !hasDbAccessMigration && !hasDashboardMigration && !hasGoogleMigration) return { configured: false };
  if (runtimeRole === undefined || runtimeRole === '') return { configured: false };
  if (typeof runtimeRole !== 'string') throw new Error('AUTH_RUNTIME_ROLE must be a PostgreSQL role name');

  const quotedRole = quotePgIdentifier(runtimeRole);
  const roleResult = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [runtimeRole]);
  if (!roleResult.rows?.length) throw new Error('AUTH_RUNTIME_ROLE does not name an existing PostgreSQL role');

  const schemaResult = await client.query(
    "SELECT has_schema_privilege($1, 'public', 'USAGE') AS schema_usage",
    [runtimeRole],
  );
  if (schemaResult.rows?.[0]?.schema_usage !== true) {
    throw new Error('AUTH_RUNTIME_ROLE lacks USAGE on the public schema');
  }

  if (hasAbuseMigration) {
    const tableResult = await client.query(
      "SELECT to_regclass('public.auth_abuse_buckets') IS NOT NULL AS table_exists",
    );
    if (tableResult.rows?.[0]?.table_exists !== true) {
      throw new Error('Auth abuse-bucket table is missing after its migration');
    }

    // Grant only the bucket table's required DML privileges. Keep unrelated
    // identity, contact history, and schema-wide permissions untouched.
    await client.query(
      `GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.auth_abuse_buckets TO ${quotedRole}`,
    );
  }

  if (hasDbAccessMigration) {
    const tableResult = await client.query(
      "SELECT to_regclass('public.db_access_log') IS NOT NULL AS table_exists",
    );
    if (tableResult.rows?.[0]?.table_exists !== true) {
      throw new Error('Auth database access log table is missing after its migration');
    }
    // The optional audit writer only inserts rows; it receives no read,
    // update, delete, sequence, or DDL privileges on the audit table.
    await client.query(`GRANT INSERT ON TABLE public.db_access_log TO ${quotedRole}`);
  }
  if (hasDashboardMigration) {
    await client.query(`GRANT USAGE ON SCHEMA auth_private TO ${quotedRole}`);
    await client.query(`GRANT SELECT ON TABLE auth_private.security_admins TO ${quotedRole}`);
    const access = await client.query(
      `SELECT has_table_privilege($1, 'auth_private.security_admins', 'SELECT') AS can_select,
              has_table_privilege($1, 'auth_private.security_admins', 'INSERT') AS can_insert,
              has_table_privilege($1, 'auth_private.security_admins', 'UPDATE') AS can_update,
              has_table_privilege($1, 'auth_private.security_admins', 'DELETE') AS can_delete`, [runtimeRole]);
    const permission = access.rows?.[0];
    if (!permission || permission.can_select !== true || permission.can_insert !== false || permission.can_update !== false || permission.can_delete !== false) {
      throw new Error('AUTH_RUNTIME_ROLE must have read-only security-dashboard capability access');
    }
  }
  if (hasGoogleMigration) {
    await client.query(`GRANT SELECT, INSERT ON TABLE public.oauth_accounts TO ${quotedRole}`);
    const access = await client.query(
      `SELECT has_table_privilege($1, 'public.oauth_accounts', 'SELECT') AS can_select,
              has_table_privilege($1, 'public.oauth_accounts', 'INSERT') AS can_insert`, [runtimeRole]);
    if (access.rows?.[0]?.can_select !== true || access.rows?.[0]?.can_insert !== true) {
      throw new Error('AUTH_RUNTIME_ROLE lacks Google identity lookup/link access');
    }
  }

  if (hasAbuseMigration) await verifyRuntimeRoleAccess(client, runtimeRole, { dbAccessLoggingEnabled: hasDbAccessMigration });
  else if (hasDbAccessMigration) {
    await verifyDatabaseAccessLogRoleAccess(client, runtimeRole);
  }
  return { configured: true };
}

async function verifyDatabaseAccessLogRoleAccess(client, role) {
  const tableResult = await client.query(
    "SELECT to_regclass('public.db_access_log') IS NOT NULL AS table_exists",
  );
  if (tableResult.rows?.[0]?.table_exists !== true) {
    throw new Error('Auth database access log table is missing after its migration');
  }
  const privileges = await client.query(
    `SELECT has_schema_privilege($1, 'public', 'USAGE') AS schema_usage,
            has_table_privilege($1, 'public.db_access_log', 'SELECT') AS can_select,
            has_table_privilege($1, 'public.db_access_log', 'INSERT') AS can_insert,
            has_table_privilege($1, 'public.db_access_log', 'UPDATE') AS can_update,
            has_table_privilege($1, 'public.db_access_log', 'DELETE') AS can_delete`,
    [role],
  );
  const access = privileges.rows?.[0];
  if (!access || access.schema_usage !== true || access.can_insert !== true || access.can_select !== false ||
      access.can_update !== false || access.can_delete !== false) {
    throw new Error('AUTH_RUNTIME_ROLE lacks INSERT-only access to the auth database access log');
  }
}

module.exports = {
  ABUSE_MIGRATION_FILE,
  DB_ACCESS_MIGRATION_FILE,
  quotePgIdentifier,
  includesAbuseMigration,
  includesDbAccessMigration,
  isDbAccessLoggingEnabled,
  verifyRuntimeRoleAccess,
  verifyDatabaseAccessLogRoleAccess,
  configureAuthRuntimeRole,
};
