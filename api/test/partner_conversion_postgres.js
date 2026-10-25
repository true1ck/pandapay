'use strict';

// Standalone opt-in fixture. Never reads DATABASE_URL, .env, live provider
// settings, or customer data. The coordinator supplies a fresh local cluster.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { INGEST_CONVERSION_SQL } = require('../src/partner_conversion_route');

function fixtureConfig(raw) {
  if (!raw) throw new Error('PARTNER_CONVERSION_TEST_URL is required');
  let url;
  try { url = new URL(raw); } catch { throw new Error('Fixture URL is invalid'); }
  const host = url.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['127.0.0.1', 'localhost', '::1'].includes(host) ||
      url.pathname !== '/partner_conversion_test' ||
      !['postgres:', 'postgresql:'].includes(url.protocol) ||
      !url.username || !url.password || url.search || url.hash) {
    throw new Error('Fixture requires loopback PostgreSQL URL for partner_conversion_test');
  }
  const port = url.port ? Number(url.port) : 5432;
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Fixture port is invalid');
  return { host, port, user: decodeURIComponent(url.username), password: decodeURIComponent(url.password),
    database: 'partner_conversion_test', ssl: false, max: 6, connectionTimeoutMillis: 3000,
    application_name: 'partner-conversion-disposable-test' };
}

const migrationDir = path.join(__dirname, '../../db/supabase/migrations');
const qIdent = value => `"${String(value).replaceAll('"', '""')}"`;

function expectedServerAddress(address, dockerAddress) {
  if (['127.0.0.1', '::1'].includes(address)) return true;
  // A fresh Docker container reached through a loopback port reports its
  // private bridge IP. The coordinator must inspect that owned container and
  // explicitly attest the exact IP. This never permits a remote fixture URL.
  if (typeof dockerAddress !== 'string' || address !== dockerAddress) return false;
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some(part => !Number.isInteger(part) || part < 0 || part > 255)) return false;
  return parts[0] === 10 || (parts[0] === 172 && parts[1] >= 16 && parts[1] <= 31) ||
    (parts[0] === 192 && parts[1] === 168);
}

async function asRole(pool, role, callback) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SET LOCAL ROLE ${qIdent(role)}`);
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally { client.release(); }
}

async function main() {
  const config = fixtureConfig(process.env.PARTNER_CONVERSION_TEST_URL);
  const pool = new Pool(config);
  let runtimePool;
  try {
    const reached = await pool.query('SELECT host(inet_server_addr()) AS address, current_database() AS database, current_user AS fixture_admin');
    const address = String(reached.rows[0]?.address || '').replace(/^\[|\]$/g, '').toLowerCase();
    if (!expectedServerAddress(address, process.env.PARTNER_CONVERSION_TEST_SERVER_ADDRESS) ||
        reached.rows[0]?.database !== 'partner_conversion_test') {
      throw new Error('Fixture connection did not reach the required loopback test database');
    }
    const existing = await pool.query(`SELECT count(*)::int AS relations
      FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname NOT IN ('pg_catalog','information_schema','pg_toast','extensions')
        AND c.relkind IN ('r','p','v','m','S','f')
        AND c.relname NOT LIKE 'pg_%' AND c.relname <> 'sql_features'`);
    if (existing.rows[0].relations !== 0) throw new Error('Fixture refuses a non-empty disposable database');

    const baseline = ['0001_extensions_and_enums.sql', '0002_reference_data.sql',
      '0003_card_catalogue.sql', '0004_user_domain.sql', '0005_sync.sql', '0006_ingest.sql',
      '0007_crowdsource.sql', '0008_admin_console.sql', '0009_platform_ops.sql',
      '0010_functions_and_views.sql', '0011_rls_policies.sql',
      '0023_catalogue_base_reward_rate.sql', '0030_partner_attribution.sql'];
    for (const file of baseline) await pool.query(fs.readFileSync(path.join(migrationDir, file), 'utf8'));

    const suffix = `${process.pid}_${crypto.randomBytes(4).toString('hex')}`;
    const runtime = `partner_runtime_${suffix}`;
    const runtimePassword = crypto.randomBytes(32).toString('hex');
    const appRole = `partner_app_${suffix}`;
    const outsider = `partner_outsider_${suffix}`;
    for (const role of [runtime, appRole, outsider]) {
      await pool.query(`CREATE ROLE ${qIdent(role)} ${role === runtime ? `LOGIN PASSWORD '${runtimePassword}'` : 'NOLOGIN'}
        NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS`);
      // Managed CREATEROLE fixture admins need explicit SET for synthetic
      // roles, whereas the native superuser fixture can SET them directly.
      const fixtureAdmin = qIdent(reached.rows[0].fixture_admin);
      await pool.query(`GRANT ${qIdent(role)} TO ${fixtureAdmin} WITH SET TRUE GRANTED BY ${fixtureAdmin}`);
    }
    await pool.query(`GRANT USAGE ON SCHEMA public, pandapay TO ${qIdent(appRole)}`);
    await pool.query(`GRANT SELECT,INSERT,UPDATE,DELETE ON public.partner_clicks,public.partner_conversions TO ${qIdent(appRole)}`);

    const capabilityFiles = fs.readdirSync(migrationDir).filter(file => /_partner_conversion_capability\.sql$/.test(file));
    assert.equal(capabilityFiles.length, 1, 'exactly one additive partner capability migration exists');
    const migration = fs.readFileSync(path.join(migrationDir, capabilityFiles[0]), 'utf8');
    await pool.query(migration);
    // Replay source SQL to prove repeat safety; production runner applies its
    // checksum ledger and intentionally does not execute a migration twice.
    await pool.query(migration);
    await pool.query(`GRANT pandapay_partner_webhook TO ${qIdent(runtime)}`);
    runtimePool = new Pool({ ...config, user: runtime, password: runtimePassword });
    const runtimeIdentity = await runtimePool.query('SELECT current_user,session_user');
    assert.equal(runtimeIdentity.rows[0].current_user, runtime);
    assert.equal(runtimeIdentity.rows[0].session_user, runtime);

    const ids = Array.from({ length: 4 }, () => crypto.randomUUID());
    const [profile, issuer, product, program] = ids;
    await pool.query('INSERT INTO profiles(id) VALUES($1)', [profile]);
    await pool.query("INSERT INTO issuers(id,slug,name) VALUES($1,'partner-fixture','Partner Fixture')", [issuer]);
    await pool.query(`INSERT INTO card_products(id,issuer_id,slug,name,card_type,network)
      VALUES($1,$2,'partner-fixture','Partner Fixture','credit','visa')`, [product, issuer]);
    await pool.query(`INSERT INTO partner_programs(id,issuer_id,partner_name)
      VALUES($1,$2,'Fixture Network')`, [program, issuer]);
    for (const token of ['fixture-click','null-click','legacy-click','empty-legacy-click']) {
      await pool.query(`INSERT INTO partner_clicks(profile_id,card_product_id,partner_program_id,click_token)
        VALUES($1,$2,$3,$4)`, [profile, product, program, token]);
    }
    // Simulate the old nullable unique constraint allowing two historical rows.
    const oldA = '10000000-0000-4000-8000-000000000001';
    const oldB = '10000000-0000-4000-8000-000000000002';
    await pool.query(`INSERT INTO partner_conversions(id,click_token,status,raw_payload,reported_at)
      VALUES($1,'legacy-click','pending','{"old":"canonical"}','2026-10-01'),
            ($2,'legacy-click','pending','{"old":"later"}','2026-10-02')`, [oldA, oldB]);
    await pool.query(`INSERT INTO partner_conversions(click_token,external_ref,status)
      VALUES('empty-legacy-click','','pending')`);

    const call = (token, status = 'pending', commission = null, ref = null) =>
      runtimePool.query(INGEST_CONVERSION_SQL, [token, status, commission, ref]);
    assert.equal((await call('unknown')).rows[0].matched, false);
    assert.equal((await call('fixture-click', 'pending', 123.45, 'ref-1')).rows[0].matched, true);
    await call('fixture-click', 'approved', 125.67, 'ref-1');
    await call('fixture-click', 'reversed', -125.67, 'ref-1');
    await call('fixture-click', 'approved', 1, 'ref-2');
    const updates = await pool.query(`SELECT status,commission_inr,external_ref,raw_payload
      FROM partner_conversions WHERE click_token='fixture-click' ORDER BY external_ref`);
    assert.equal(updates.rowCount, 2, 'distinct refs coexist; same ref retries do not duplicate');
    assert.equal(updates.rows[0].status, 'reversed');
    assert.equal(updates.rows[0].commission_inr, '-125.67');
    assert.deepEqual(Object.keys(updates.rows[0].raw_payload).sort(), ['clickToken','commissionInr','externalRef','status']);

    // Concurrent first inserts and empty/missing ref retries converge.
    await Promise.all(Array.from({ length: 12 }, (_, index) => call('null-click', 'approved', index, index % 2 ? '' : null)));
    const noRef = await pool.query("SELECT count(*)::int AS n FROM partner_conversions WHERE click_token='null-click'");
    assert.equal(noRef.rows[0].n, 1, 'concurrent no-ref retries create one row');
    await call('legacy-click', 'approved', 9);
    await call('legacy-click', 'approved', 10);
    const preserved = await pool.query(`SELECT id,status,raw_payload FROM partner_conversions
      WHERE click_token='legacy-click' ORDER BY id`);
    assert.equal(preserved.rowCount, 2, 'pre-existing duplicate records are preserved');
    assert.equal(preserved.rows.find(row => row.id === oldA).status, 'approved');
    assert.deepEqual(preserved.rows.find(row => row.id === oldB).raw_payload, { old: 'later' });
    await call('empty-legacy-click', 'approved', 11);
    const emptyLegacy = await pool.query(`SELECT status FROM partner_conversions
      WHERE click_token='empty-legacy-click'`);
    assert.equal(emptyLegacy.rowCount, 1, 'legacy empty-ref record is reused when a retry omits its reference');
    assert.equal(emptyLegacy.rows[0].status, 'approved');

    for (const role of [appRole, outsider]) {
      await assert.rejects(asRole(pool, role, client => client.query(INGEST_CONVERSION_SQL,
        ['fixture-click','approved',1,'forbidden'])), error => error.code === '42501');
    }
    // App's normal grants and lack of app.user_id still deny cross-user reads
    // and unauthorised writes; the new function grants do not widen them.
    const hidden = await asRole(pool, appRole, client => client.query('SELECT id FROM partner_clicks'));
    assert.equal(hidden.rowCount, 0);
    await assert.rejects(asRole(pool, appRole, client => client.query(`INSERT INTO partner_conversions
      (click_token,status) VALUES('fixture-click','approved')`)), error => error.code === '42501');
    for (const table of ['partner_clicks','partner_conversions']) {
      await assert.rejects(runtimePool.query(`SELECT * FROM public.${table}`),
        error => error.code === '42501');
    }
    await assert.rejects(runtimePool.query('SET ROLE partner_webhook_owner'),
      error => error.code === '42501');

    for (const args of [['fixture-click','invalid',1,'bad'],['x'.repeat(257),'approved',1,'bad'],
      ['fixture-click','approved','NaN','bad'],['fixture-click','approved','Infinity','bad'],
      ['fixture-click','approved',1,'x'.repeat(513)]]) {
      await assert.rejects(asRole(pool, runtime, client => client.query(INGEST_CONVERSION_SQL, args)),
        error => error.code === '22023');
    }
    const properties = await pool.query(`SELECT p.prosecdef,p.proconfig,r.rolname,
      r.rolcanlogin,r.rolsuper,r.rolbypassrls
      FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner
      WHERE n.nspname='partner_webhook' AND p.proname='ingest_conversion'`);
    assert.equal(properties.rows[0].prosecdef, true);
    assert.equal(properties.rows[0].rolname, 'partner_webhook_owner');
    assert.equal(properties.rows[0].rolcanlogin, false);
    assert.equal(properties.rows[0].rolsuper, false);
    assert.equal(properties.rows[0].rolbypassrls, false);
    assert.ok(properties.rows[0].proconfig.includes('search_path=""'));
    const noPublic = await pool.query(`SELECT pg_catalog.has_function_privilege($1,
      'partner_webhook.ingest_conversion(text,text,numeric,text)','execute') AS allowed`, [outsider]);
    assert.equal(noPublic.rows[0].allowed, false);

    // Unqualified table names would resolve to attacker temp tables first.
    // Qualified relations and the empty function path keep this harmless.
    await asRole(pool, runtime, async client => {
      await client.query('CREATE TEMP TABLE partner_clicks(click_token text,partner_program_id uuid)');
      await client.query("INSERT INTO pg_temp.partner_clicks VALUES('spoofed',NULL)");
      await client.query("SET LOCAL search_path=pg_temp,public");
      assert.equal((await client.query(INGEST_CONVERSION_SQL, ['spoofed','approved',1,'ref'])).rows[0].matched, false);
      assert.equal((await client.query(INGEST_CONVERSION_SQL, ['fixture-click','approved',2,'ref-3'])).rows[0].matched, true);
    });
    console.log('PASS: additive partner migration/replay, non-owner service role, app/PUBLIC denials, SQL validation, search-path isolation, status upserts, concurrent no-ref retries and preserved historical rows');
  } finally {
    if (runtimePool) await runtimePool.end();
    await pool.end();
  }
}

module.exports = { fixtureConfig, expectedServerAddress };
if (require.main === module) main().catch(error => {
  console.error('Synthetic partner conversion PostgreSQL fixture failed', error.stack);
  process.exitCode = 1;
});
