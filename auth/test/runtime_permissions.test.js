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

test('optional access log gets INSERT only after its migration and when enabled', async () => {
  const logMigration = { file: '0005_db_access_log.sql', version: '0005_db_access_log' };
  const client = fakeClient();
  const originalQuery = client.query.bind(client);
  client.query = async (sql, params) => {
    if (sql.includes('has_table_privilege') && sql.includes('public.db_access_log')) {
      client.queries.push({ sql, params });
      return { rows: [{ schema_usage: true, can_select: false, can_insert: true, can_update: false, can_delete: false }] };
    }
    return originalQuery(sql, params);
  };
  await configureAuthRuntimeRole(client, { files: [abuseMigration, logMigration], runtimeRole: 'runtime', dbAccessLoggingEnabled: true });
  assert.deepEqual(client.queries.filter(call => call.sql.startsWith('GRANT')).map(call => call.sql), [
    'GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.auth_abuse_buckets TO "runtime"',
    'GRANT INSERT ON TABLE public.db_access_log TO "runtime"',
  ]);
  for (const options of [
    { files: [abuseMigration], dbAccessLoggingEnabled: true },
    { files: [abuseMigration, logMigration], dbAccessLoggingEnabled: false },
  ]) {
    const disabled = fakeClient();
    await configureAuthRuntimeRole(disabled, { runtimeRole: 'runtime', ...options });
    assert.equal(disabled.queries.some(call => call.sql.includes('db_access_log')), false);
  }
});

test('optional security dashboard receives read-only capability lookup without role promotion', async () => {
  const client=fakeClient();const query=client.query.bind(client);
  client.query=async(sql,params)=>{
    if(sql.includes('has_table_privilege')&&sql.includes('auth_private.security_admins')){
      client.queries.push({sql,params});return {rows:[{can_select:true,can_insert:false,can_update:false,can_delete:false}]};
    }
    return query(sql,params);
  };
  await configureAuthRuntimeRole(client,{files:[{file:'0007_security_dashboard_capability.sql'}],runtimeRole:'auth_runtime',securityDashboardEnabled:true});
  assert.deepEqual(client.queries.filter(x=>x.sql.startsWith('GRANT')).map(x=>x.sql),[
    'GRANT USAGE ON SCHEMA auth_private TO "auth_runtime"',
    'GRANT SELECT ON TABLE auth_private.security_admins TO "auth_runtime"',
  ]);
  assert.equal(client.queries.some(x=>x.sql.includes('INSERT INTO auth_private')),false);
});

test('canonical provider links grant only lookup and insertion to explicit auth runtime', async () => {
  const client=fakeClient();
  await configureAuthRuntimeRole(client,{files:[{file:'0006_google_oauth_identity.sql'}],runtimeRole:'auth_runtime'});
  assert.deepEqual(client.queries.filter(x=>x.sql.startsWith('GRANT')).map(x=>x.sql),[
    'GRANT SELECT, INSERT ON TABLE public.oauth_accounts TO "auth_runtime"',
  ]);
});
