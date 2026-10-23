'use strict';

const ABUSE_MIGRATION_FILE = '0004_auth_abuse_buckets.sql';

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

async function verifyRuntimeRoleAccess(client, role) {
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
}

async function configureAuthRuntimeRole(client, { files, runtimeRole } = {}) {
  if (!includesAbuseMigration(files)) return { configured: false };
  if (runtimeRole === undefined || runtimeRole === '') return { configured: false };
  if (typeof runtimeRole !== 'string') throw new Error('AUTH_RUNTIME_ROLE must be a PostgreSQL role name');

  const quotedRole = quotePgIdentifier(runtimeRole);
  const roleResult = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [runtimeRole]);
  if (!roleResult.rows?.length) throw new Error('AUTH_RUNTIME_ROLE does not name an existing PostgreSQL role');

  const tableResult = await client.query(
    "SELECT to_regclass('public.auth_abuse_buckets') IS NOT NULL AS table_exists",
  );
  if (tableResult.rows?.[0]?.table_exists !== true) {
    throw new Error('Auth abuse-bucket table is missing after its migration');
  }

  const schemaResult = await client.query(
    "SELECT has_schema_privilege($1, 'public', 'USAGE') AS schema_usage",
    [runtimeRole],
  );
  if (schemaResult.rows?.[0]?.schema_usage !== true) {
    throw new Error('AUTH_RUNTIME_ROLE lacks USAGE on the public schema');
  }

  // Grant only the bucket table's required DML privileges. Keep unrelated
  // identity, contact history, and schema-wide permissions untouched.
  await client.query(
    `GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.auth_abuse_buckets TO ${quotedRole}`,
  );
  await verifyRuntimeRoleAccess(client, runtimeRole);
  return { configured: true };
}

module.exports = {
  ABUSE_MIGRATION_FILE,
  quotePgIdentifier,
  includesAbuseMigration,
  verifyRuntimeRoleAccess,
  configureAuthRuntimeRole,
};
