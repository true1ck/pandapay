'use strict';

// Coordinator-invoked disposable PostgreSQL integration fixture. It accepts
// only an explicitly supplied loopback lounge_usage_test database and a
// database with no user relations. It never consults DATABASE_URL.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { INSERT_OWNED_LOUNGE_USAGE_SQL } = require('../src/lounge_usage_route');

function fixtureConfig(raw) {
  if (!raw) throw new Error('LOUNGE_USAGE_TEST_URL is required');
  let url;
  try { url = new URL(raw); } catch { throw new Error('Fixture URL is invalid'); }
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) ||
      url.pathname !== '/lounge_usage_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires a loopback PostgreSQL URL for lounge_usage_test');
  }
  const port = url.port ? Number(url.port) : 5432;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Fixture port is invalid');
  return {
    host, port, user: decodeURIComponent(url.username), password: decodeURIComponent(url.password),
    database: 'lounge_usage_test', ssl: false, max: 4, connectionTimeoutMillis: 3000,
    application_name: 'lounge-usage-disposable-test',
  };
}

const config = fixtureConfig(process.env.LOUNGE_USAGE_TEST_URL);
const migrationDir = path.join(__dirname, '../../db/supabase/migrations');
const qIdent = (value) => `"${String(value).replaceAll('"', '""')}"`;

async function runAsRuntime(pool, role, profileId, query) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SET LOCAL ROLE ${qIdent(role)}`);
    await client.query("SELECT set_config('app.user_id', $1, true)", [profileId]);
    const result = await query(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

async function main() {
  const pool = new Pool(config);
  let role;
  let roleCreated = false;
  try {
    const server = await pool.query('SELECT host(inet_server_addr()) AS address, current_database() AS database');
    const address = String(server.rows[0]?.address || '').replace(/^\[|\]$/g, '').toLowerCase();
    if (!['127.0.0.1', '::1'].includes(address) || server.rows[0]?.database !== 'lounge_usage_test') {
      throw new Error('Fixture connection did not reach the required loopback test database');
    }
    const existing = await pool.query(`
      SELECT count(*)::bigint AS relations
        FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','extensions')
         AND c.relkind IN ('r','p','v','m','S','f')
         AND c.relname NOT LIKE 'pg_%' AND c.relname <> 'sql_features'`);
    if (Number(existing.rows[0].relations) !== 0) {
      throw new Error('Fixture refuses a non-empty disposable database');
    }

    // Apply the actual base migrations that define the target schema, benefit
    // relation, transaction-local uid(), and RLS policies.
    for (let version = 1; version <= 11; version += 1) {
      const filename = `${String(version).padStart(4, '0')}_${[
        'extensions_and_enums','reference_data','card_catalogue','user_domain','sync',
        'ingest','crowdsource','admin_console','platform_ops','functions_and_views','rls_policies',
      ][version - 1]}.sql`;
      await pool.query(fs.readFileSync(path.join(migrationDir, filename), 'utf8'));
    }

    role = `lounge_runtime_${process.pid}_${crypto.randomBytes(4).toString('hex')}`;
    await pool.query(`CREATE ROLE ${qIdent(role)} NOLOGIN`);
    roleCreated = true;
    await pool.query(`GRANT USAGE ON SCHEMA public, pandapay TO ${qIdent(role)}`);
    await pool.query(`GRANT SELECT ON profiles, user_cards, card_products, card_benefits, lounge_usage TO ${qIdent(role)}`);
    await pool.query(`GRANT INSERT ON lounge_usage TO ${qIdent(role)}`);
    // Matches the product runtime's existing owner-scoped wallet updates;
    // row locks require UPDATE privilege, still constrained by owner RLS.
    await pool.query(`GRANT UPDATE ON user_cards TO ${qIdent(role)}`);
    await pool.query(`GRANT EXECUTE ON FUNCTION pandapay.uid() TO ${qIdent(role)}`);

    const profileA = crypto.randomUUID();
    const profileB = crypto.randomUUID();
    const productA = crypto.randomUUID();
    const productB = crypto.randomUUID();
    const cardA = crypto.randomUUID();
    const cardB = crypto.randomUUID();
    const benefitA = crypto.randomUUID();
    const benefitB = crypto.randomUUID();
    await pool.query('INSERT INTO profiles (id) VALUES ($1),($2)', [profileA, profileB]);
    await pool.query('INSERT INTO issuers (id, slug, name) VALUES ($1,$2,$3),($4,$5,$6)',
      [crypto.randomUUID(),'lounge-test-a','Lounge Fixture A',crypto.randomUUID(),'lounge-test-b','Lounge Fixture B']);
    const issuers = await pool.query("SELECT id FROM issuers WHERE slug IN ('lounge-test-a','lounge-test-b') ORDER BY slug");
    await pool.query(`INSERT INTO card_products (id, issuer_id, name, slug, card_type, network)
      VALUES ($1,$2,'Lounge Fixture A','lounge-fixture-a','credit','visa'),
             ($3,$4,'Lounge Fixture B','lounge-fixture-b','credit','visa')`,
    [productA, issuers.rows[0].id, productB, issuers.rows[1].id]);
    await pool.query(`INSERT INTO card_benefits (id,card_product_id,kind,label)
      VALUES ($1,$2,'lounge_domestic','Fixture A'),($3,$4,'lounge_domestic','Fixture B')`,
    [benefitA,productA,benefitB,productB]);
    await pool.query(`INSERT INTO user_cards (id,profile_id,card_product_id)
      VALUES ($1,$2,$3),($4,$5,$6)`, [cardA,profileA,productA,cardB,profileB,productB]);

    const own = await runAsRuntime(pool, role, profileA, client => client.query(
      INSERT_OWNED_LOUNGE_USAGE_SQL, [profileA, cardA, benefitA, '2026-10-21', 'BLR']));
    assert.equal(own.rows.length, 1, 'runtime role can create an owned active card visit with its benefit');
    assert.equal(own.rows[0].user_card_id, cardA);
    assert.equal(own.rows[0].benefit_id, benefitA);

    for (const [label, cardId, benefitId] of [
      ['foreign card', cardB, benefitB],
      ['benefit belonging to another product', cardA, benefitB],
      ['unknown card', crypto.randomUUID(), benefitA],
    ]) {
      const denied = await runAsRuntime(pool, role, profileA, client => client.query(
        INSERT_OWNED_LOUNGE_USAGE_SQL, [profileA, cardId, benefitId, '2026-10-21', null]));
      assert.equal(denied.rows.length, 0, `${label} must be denied without a row`);
    }
    await pool.query('UPDATE user_cards SET is_archived=true, archived_at=now() WHERE id=$1', [cardA]);
    const archived = await runAsRuntime(pool, role, profileA, client => client.query(
      INSERT_OWNED_LOUNGE_USAGE_SQL, [profileA, cardA, benefitA, '2026-10-21', null]));
    assert.equal(archived.rows.length, 0, 'archived card must be denied');
    await pool.query('UPDATE user_cards SET is_archived=false, archived_at=NULL WHERE id=$1', [cardA]);

    const ownerRows = await runAsRuntime(pool, role, profileA, client => client.query(
      'SELECT id FROM user_cards ORDER BY id'));
    assert.deepEqual(ownerRows.rows.map(value => value.id), [cardA], 'migration RLS exposes only caller-owned cards');
    const ownerVisits = await runAsRuntime(pool, role, profileA, client => client.query('SELECT profile_id FROM lounge_usage'));
    assert.deepEqual(ownerVisits.rows.map(value => value.profile_id), [profileA], 'migration RLS exposes only caller-owned visits');
    const foreignRows = await runAsRuntime(pool, role, profileB, client => client.query('SELECT id FROM lounge_usage'));
    assert.equal(foreignRows.rowCount, 0, 'second profile cannot read first profile visit');

    await assert.rejects(runAsRuntime(pool, role, profileA, client => client.query(
      `INSERT INTO lounge_usage (profile_id,user_card_id,benefit_id,used_on)
       VALUES ($1,$2,$3,'2026-10-21')`, [profileB, cardB, benefitB])), error => error.code === '42501');

    // The CTE takes FOR UPDATE on the card through transaction end. A
    // concurrent archive must wait, so the recorded visit has a stable
    // active-card decision at its serialization point.
    const lockingClient = await pool.connect();
    const archiver = await pool.connect();
    try {
      await lockingClient.query('BEGIN');
      await lockingClient.query(`SET LOCAL ROLE ${qIdent(role)}`);
      await lockingClient.query("SELECT set_config('app.user_id',$1,true)", [profileA]);
      const lockedInsert = await lockingClient.query(
        INSERT_OWNED_LOUNGE_USAGE_SQL, [profileA, cardA, benefitA, '2026-10-22', null]);
      assert.equal(lockedInsert.rowCount, 1);
      await archiver.query('BEGIN');
      await archiver.query("SET LOCAL lock_timeout = '150ms'");
      await assert.rejects(archiver.query('UPDATE user_cards SET is_archived=true WHERE id=$1', [cardA]),
        error => error.code === '55P03');
      await archiver.query('ROLLBACK');
      await lockingClient.query('COMMIT');
    } finally {
      await archiver.query('ROLLBACK').catch(() => {});
      await lockingClient.query('ROLLBACK').catch(() => {});
      lockingClient.release();
      archiver.release();
    }

    console.log('PASS: migrated PostgreSQL schema and non-owner RLS role enforce lounge visit ownership, active-card state, benefit/card matching, and archive locking');
  } finally {
    if (roleCreated) await pool.query(`DROP ROLE IF EXISTS ${qIdent(role)}`).catch(() => {});
    await pool.end();
  }
}

main().catch(error => {
  console.error('Synthetic lounge usage PostgreSQL fixture failed', error.stack);
  process.exitCode = 1;
});

