'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  configureAuthRuntimeRole,
  includesAbuseMigration,
  quotePgIdentifier,
} = require('../scripts/runtimePermissions');

const abuseMigration = { file: '0004_auth_abuse_buckets.sql', version: '0004_auth_abuse_buckets' };

function fakeClient({ roleExists = true, schemaUsage = true, privileges = true } = {}) {
  const queries = [];
  return {
    queries,
    async query(sql, params) {
      queries.push({ sql, params });
      if (sql.includes('FROM pg_roles')) return { rows: roleExists ? [{ '?column?': 1 }] : [] };
      if (sql.includes('to_regclass')) return { rows: [{ table_exists: true }] };
      if (sql.includes('has_table_privilege')) {
        return { rows: [{
          schema_usage: schemaUsage,
          can_select: privileges,
          can_insert: privileges,
          can_update: privileges,
          can_delete: privileges,
        }] };
      }
      if (sql.includes("has_schema_privilege($1, 'public', 'USAGE')")) {
        return { rows: [{ schema_usage: schemaUsage }] };
      }
      return { rows: [], rowCount: 0 };
    },
  };
}

test('PostgreSQL role identifiers are safely quoted and bounded', () => {
  assert.equal(quotePgIdentifier('auth runtime'), '"auth runtime"');
  assert.equal(quotePgIdentifier('a"b'), '"a""b"');
  assert.throws(() => quotePgIdentifier(''), /1 to 63 UTF-8 bytes/);
  assert.throws(() => quotePgIdentifier('x'.repeat(64)), /63 UTF-8 bytes/);
  assert.throws(() => quotePgIdentifier('bad\0role'), /without ASCII controls/);
  assert.throws(() => quotePgIdentifier('public'), /PostgreSQL role identifier/);
  assert.throws(() => quotePgIdentifier('PuBlIc'), /PostgreSQL role identifier/);
  assert.throws(() => quotePgIdentifier('bad\nrole'), /PostgreSQL role identifier/);
  assert.throws(() => quotePgIdentifier('bad\trole'), /PostgreSQL role identifier/);
  assert.throws(() => quotePgIdentifier('bad\x7frole'), /PostgreSQL role identifier/);
});

test('runtime role grants are not applied when the actual abuse migration is absent', async () => {
  const client = fakeClient();
  assert.equal(includesAbuseMigration([{ file: '0003_other.sql', version: '0003_other' }]), false);
  assert.deepEqual(await configureAuthRuntimeRole(client, {
    files: [{ file: '0003_other.sql', version: '0003_other' }], runtimeRole: 'api_auth',
  }), { configured: false });
  assert.deepEqual(await configureAuthRuntimeRole(client, {
    files: [abuseMigration], runtimeRole: '',
  }), { configured: false });
  assert.equal(client.queries.length, 0);
  await assert.rejects(
    configureAuthRuntimeRole(client, { files: [abuseMigration], runtimeRole: 42 }),
    /must be a PostgreSQL role name/,
  );
});

test('explicit runtime role must already exist and schema usage is not broadened', async () => {
  const missingRole = fakeClient({ roleExists: false });
  await assert.rejects(
    configureAuthRuntimeRole(missingRole, { files: [abuseMigration], runtimeRole: 'missing_role' }),
    /does not name an existing/,
  );
  assert.equal(missingRole.queries.some(call => call.sql.startsWith('GRANT')), false);

  const noSchema = fakeClient({ schemaUsage: false });
  await assert.rejects(
    configureAuthRuntimeRole(noSchema, { files: [abuseMigration], runtimeRole: 'runtime' }),
    /lacks USAGE/,
  );
  assert.equal(noSchema.queries.some(call => call.sql.startsWith('GRANT')), false);
});

test('explicit role receives only quoted table DML privileges and all are verified', async () => {
  const client = fakeClient();
  const result = await configureAuthRuntimeRole(client, {
    files: [abuseMigration], runtimeRole: 'odd"role',
  });
  assert.deepEqual(result, { configured: true });
  const grant = client.queries.find(call => call.sql.startsWith('GRANT'))?.sql;
  assert.equal(grant,
    'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.auth_abuse_buckets TO "odd""role"');
  assert.equal(grant.includes('ON ALL TABLES'), false);
  assert.equal(grant.includes('GRANT USAGE'), false);
  assert.equal(client.queries.some(call => call.sql.includes("has_table_privilege($1, 'public.auth_abuse_buckets', 'SELECT')") &&
    call.sql.includes("has_table_privilege($1, 'public.auth_abuse_buckets', 'INSERT')") &&
    call.sql.includes("has_table_privilege($1, 'public.auth_abuse_buckets', 'UPDATE')") &&
    call.sql.includes("has_table_privilege($1, 'public.auth_abuse_buckets', 'DELETE')")), true);
});

test('a partial runtime grant fails migration completion', async () => {
  const client = fakeClient({ privileges: false });
  await assert.rejects(
    configureAuthRuntimeRole(client, { files: [abuseMigration], runtimeRole: 'runtime' }),
    /lacks required schema or auth abuse-bucket privileges/,
  );
});
