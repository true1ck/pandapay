'use strict';

// Read-only catalog query compatibility fixture. It accepts only a loopback
// database named schema_fingerprint_test and performs no DDL or writes.
const assert = require('node:assert/strict');
const path = require('node:path');
const { ACL_INVENTORY_SQL } = require('../scripts/schema_fingerprint');
const { runSchemaFingerprintPostgresFixture } = require('./schema_fingerprint_postgres_fixture');

function connectionConfig(raw) {
  if (!raw) throw new Error('SCHEMA_FINGERPRINT_TEST_URL is required');
  let url;
  try { url = new URL(raw); } catch { throw new Error('Schema fingerprint fixture URL is invalid'); }
  const hostname = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(hostname) ||
      url.pathname !== '/schema_fingerprint_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires a loopback PostgreSQL URL for schema_fingerprint_test');
  }
  let pg;
  try {
    const authRoot = process.env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
    pg = require(require.resolve('pg', { paths: [authRoot] }));
  } catch {
    throw new Error('PostgreSQL client dependency is unavailable for the fingerprint fixture');
  }
  return {
    Pool: pg.Pool,
    config: {
      host: hostname,
      port: url.port ? Number(url.port) : 5432,
      user: decodeURIComponent(url.username),
      password: decodeURIComponent(url.password),
      database: 'schema_fingerprint_test',
      ssl: false,
      max: 1,
      connectionTimeoutMillis: 3000,
      application_name: 'schema-fingerprint-read-only-fixture',
    },
  };
}

async function main() {
  const { Pool, config } = connectionConfig(process.env.SCHEMA_FINGERPRINT_TEST_URL);
  const pool = new Pool(config);
  try {
    const server = await pool.query('SELECT host(inet_server_addr()) AS address, current_database() AS database');
    const address = String(server.rows[0]?.address || '').replace(/^\[|\]$/g, '').toLowerCase();
    assert.ok(['127.0.0.1', '::1'].includes(address), 'connection resolved to loopback');
    assert.equal(server.rows[0]?.database, 'schema_fingerprint_test');

    const result = await pool.query(ACL_INVENTORY_SQL);
    const inventory = result.rows[0]?.inventory;
    assert.ok(inventory && typeof inventory === 'object');
    for (const category of [
      'languages', 'foreign_data_wrappers', 'foreign_servers', 'tablespaces',
      'large_objects', 'parameter_acl', 'default_acl', 'extension_members',
    ]) {
      assert.ok(Array.isArray(inventory[category]), `${category} catalog result exists`);
    }

    const emptyPublic = await pool.query(
      `SELECT count(*)::bigint AS relations FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='public' AND c.relkind IN ('r','p','v','m','S','f')
          AND c.relname NOT LIKE 'pg_%' AND c.relname <> 'sql_features'`,
    );
    const largeObjectCount = await pool.query('SELECT count(*)::bigint AS count FROM pg_largeobject_metadata');
    if (Number(emptyPublic.rows[0].relations) !== 0 || Number(largeObjectCount.rows[0].count) !== 0) {
      throw new Error('ACL drift fixture refuses a non-empty disposable database');
    }

    const role = `schema_acl_test_${process.pid}_${require('node:crypto').randomBytes(4).toString('hex')}`;
    const quotedRole = `"${role.replace(/"/g, '""')}"`;
    await pool.query('BEGIN');
    try {
      await pool.query(`CREATE ROLE ${quotedRole} NOLOGIN`);
      await pool.query(`GRANT USAGE ON LANGUAGE sql TO ${quotedRole}`);
      const loid = (await pool.query('SELECT lo_create(0)::text AS oid')).rows[0].oid;
      await pool.query(`GRANT SELECT ON LARGE OBJECT ${loid} TO ${quotedRole}`);
      const changed = (await pool.query(ACL_INVENTORY_SQL)).rows[0]?.inventory;
      assert.notDeepEqual(changed.languages, inventory.languages, 'language ACL grant changes inventory');
      assert.notDeepEqual(changed.large_objects, inventory.large_objects, 'large-object identity and ACL change inventory');
    } finally {
      await pool.query('ROLLBACK');
    }

    const fixtureClient = await pool.connect();
    try {
      await runSchemaFingerprintPostgresFixture(fixtureClient);
    } finally {
      fixtureClient.release();
    }
    console.log('PASS: catalog ACL and CHECK fingerprint fixtures detect semantic drift');
  } finally {
    await pool.end();
  }
}

main().catch(() => {
  console.error('Read-only schema fingerprint PostgreSQL fixture failed');
  process.exitCode = 1;
});
