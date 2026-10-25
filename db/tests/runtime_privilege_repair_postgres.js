'use strict';
// Explicit disposable PostgreSQL fixture. Refuses any existing application DB.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { Client } = require('../../api/node_modules/pg');
const { auditRuntimePrivileges } = require('../scripts/audit_runtime_privileges');
const { TARGET_SQL, catalogDigest, hash, createRepairPlan, reviewTemplate, runRepair } = require('../scripts/runtime_privilege_repair');

async function main() {
  const raw = process.env.RUNTIME_PRIVILEGE_REPAIR_TEST_URL;
  if (!raw) throw new Error('RUNTIME_PRIVILEGE_REPAIR_TEST_URL is required');
  const url = new URL(raw);
  if (!['postgres:', 'postgresql:'].includes(url.protocol) || !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname) ||
      url.pathname !== '/runtime_privilege_repair_test' || url.search || url.hash) throw new Error('Fresh loopback runtime_privilege_repair_test required');
  const admin = new Client({ connectionString: raw, ssl: false, connectionTimeoutMillis: 3000 });
  let app, service;
  await admin.connect();
  try {
    const existing = await admin.query(`SELECT count(*)::integer AS count FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname <> 'information_schema' AND n.nspname !~ '^pg_' AND c.relkind IN ('r','p','v','m','S','f')`);
    assert.equal(existing.rows[0].count, 0, 'fixture refuses non-empty database');
    const suffix = crypto.randomBytes(5).toString('hex'), schema = `repair_fixture_${suffix}`, runtime = `repair_runtime_${suffix}`,
      cap = `repair_cap_${suffix}`, login = `repair_login_${suffix}`, owner = `repair_owner_${suffix}`;
    const target = (await admin.query(TARGET_SQL)).rows[0], operator = target.operator;
    const q = value => '"' + value.replaceAll('"', '""') + '"';
    await admin.query(`CREATE ROLE ${runtime} LOGIN PASSWORD 'synthetic-no-secret' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
      CREATE ROLE ${login} LOGIN PASSWORD 'synthetic-no-secret' NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
      CREATE ROLE ${cap} NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
      CREATE ROLE ${owner} NOLOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
      GRANT ${cap} TO ${login} WITH INHERIT TRUE,SET TRUE;
      GRANT ${owner} TO ${q(operator)} WITH INHERIT TRUE,SET TRUE;
      REVOKE ALL ON SCHEMA public FROM PUBLIC;
      CREATE SCHEMA ${schema}; REVOKE ALL ON SCHEMA ${schema} FROM PUBLIC;
      GRANT USAGE ON SCHEMA ${schema} TO ${runtime},${cap},${owner};
      GRANT CREATE ON SCHEMA ${schema} TO ${runtime};
      ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
      CREATE TABLE ${schema}.records(id uuid PRIMARY KEY,user_id uuid NOT NULL,note text NOT NULL);
      ALTER TABLE ${schema}.records ENABLE ROW LEVEL SECURITY;
      ALTER TABLE ${schema}.records FORCE ROW LEVEL SECURITY;
      CREATE POLICY owned_rows ON ${schema}.records TO ${runtime}
        USING(user_id=NULLIF(current_setting('app.user_id',true),'')::uuid)
        WITH CHECK(user_id=NULLIF(current_setting('app.user_id',true),'')::uuid);
      GRANT SELECT ON ${schema}.records TO ${runtime} WITH GRANT OPTION;
      GRANT INSERT,UPDATE,DELETE,TRUNCATE ON ${schema}.records TO ${runtime};
      CREATE TABLE ${schema}.schema_migrations(version text PRIMARY KEY);
      ALTER TABLE ${schema}.schema_migrations ENABLE ROW LEVEL SECURITY;
      ALTER TABLE ${schema}.schema_migrations FORCE ROW LEVEL SECURITY;
      GRANT SELECT ON ${schema}.schema_migrations TO ${runtime};
      CREATE FUNCTION ${schema}.safe() RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path='' AS $$SELECT true$$;
      GRANT CREATE ON SCHEMA ${schema} TO ${owner};
      ALTER FUNCTION ${schema}.safe() OWNER TO ${owner};
      REVOKE CREATE ON SCHEMA ${schema} FROM ${owner};
      REVOKE ALL ON FUNCTION ${schema}.safe() FROM PUBLIC;
      GRANT EXECUTE ON FUNCTION ${schema}.safe() TO ${cap};
      CREATE FUNCTION ${schema}.unneeded() RETURNS boolean LANGUAGE sql AS $$SELECT true$$;
      REVOKE ALL ON FUNCTION ${schema}.unneeded() FROM PUBLIC;GRANT EXECUTE ON FUNCTION ${schema}.unneeded() TO ${cap};
      ALTER DEFAULT PRIVILEGES IN SCHEMA ${schema} GRANT SELECT ON TABLES TO ${runtime};
      REVOKE ${owner} FROM ${q(operator)};`);
    const policy = { format: 'pandapay-runtime-privilege-policy-v1', scope: 'fixture', managedSchemas: [schema],
      roles: [{ name: runtime, kind: 'runtime', required: true }, { name: login, kind: 'runtime', required: true },
        { name: cap, kind: 'capability', required: true }, { name: owner, kind: 'owner', required: true }],
      ledgers: [`${schema}.schema_migrations`], memberships: [{ member: login, role: cap }],
      restrictedRoles: [{ role: cap, relations: [], routines: [`${schema}.safe()`] }, { role: login, relations: [], routines: [`${schema}.safe()`] }],
      requiredRoutineAccess: [{ role: login, identity: `${schema}.safe()` }, { role: cap, identity: `${schema}.safe()` }], acceptedFindings: [] };
    const before = await auditRuntimePrivileges(admin, { policy });
    assert.equal(before.strict_pass, false);
    const source = { candidate_sha256: 'a'.repeat(64) };
    const op = (kind, privilege, extra) => ({ kind, privilege, grantor: operator, grantee: runtime, grant_option_only: false,
      reason: 'Explicit synthetic clone review; ordinary CRUD and required RPC remain covered.', ...extra });
    const review = { ...reviewTemplate({ audit: before, policy, source, target }), reviewed_by: 'Synthetic operator', review_reference: 'Independent LOGIN RLS CRUD and safe capability regression',
      operations: [op('relation', 'TRUNCATE', { schema, name: 'records' }), op('relation', 'SELECT', { schema, name: 'records', grant_option_only: true }),
        op('relation', 'SELECT', { schema, name: 'schema_migrations' }), op('schema', 'CREATE', { schema }),
        op('default', 'SELECT', { schema, default_owner: operator, default_kind: 'r' }),
        op('routine', 'EXECUTE', { identity: `${schema}.unneeded()`, grantee: cap })],
      expected_effective_losses: [JSON.stringify(['relation', runtime, schema, 'records', 'TRUNCATE']),
        JSON.stringify(['relation', runtime, schema, 'schema_migrations', 'SELECT']), JSON.stringify(['schema', runtime, schema, 'CREATE']),
        JSON.stringify(['routine', cap, `${schema}.unneeded()`, 'EXECUTE']), JSON.stringify(['routine', login, `${schema}.unneeded()`, 'EXECUTE'])] };
    const plan = createRepairPlan({ audit: before, policy, review, source, target });
    const loginUrl = role => { const changed = new URL(raw); changed.username = role; changed.password = 'synthetic-no-secret'; return changed.toString(); };
    app = new Client({ connectionString: loginUrl(runtime), ssl: false }); await app.connect();
    service = new Client({ connectionString: loginUrl(login), ssl: false }); await service.connect();
    const subject = '11111111-1111-4111-8111-111111111111', other = '22222222-2222-4222-8222-222222222222';
    const originalId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
    await admin.query(`INSERT INTO ${schema}.records(id,user_id,note) VALUES($1,$2,'preserved synthetic record'),($3,$4,'other owner')`,
      [originalId, subject, 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', other]);
    const digestSql = `SELECT count(*)::integer AS count,md5(string_agg(id::text||':'||user_id::text||':'||note,'|' ORDER BY id)) AS digest FROM ${schema}.records`;
    const dataBefore = (await admin.query(digestSql)).rows[0];
    const runtimeState = (await app.query(`SELECT current_user AS role,rolsuper,rolbypassrls FROM pg_roles WHERE rolname=current_user`)).rows[0];
    assert.equal(runtimeState.role, runtime); assert.equal(runtimeState.rolsuper, false); assert.equal(runtimeState.rolbypassrls, false);
    const receipt = await runRepair(admin, { plan, source, sourceProvider: () => source, policyProvider: () => policy, quiesced: true });
    assert.equal(receipt.rolled_back, true); assert.equal(receipt.strict_pass, true, JSON.stringify(receipt.remaining_findings));
    assert.equal(catalogDigest((await auditRuntimePrivileges(admin, { policy })).inventory), catalogDigest(before.inventory), 'rehearsal changes all roll back');
    assert.equal((await app.query(`SELECT has_table_privilege(current_user,'${schema}.records','TRUNCATE') AS allowed`)).rows[0].allowed, true);
    const stale = structuredClone(receipt); stale.plan_sha256 = 'b'.repeat(64);
    await assert.rejects(runRepair(admin, { plan, receipt: stale, source, sourceProvider: () => source, policyProvider: () => policy, mode: 'apply', quiesced: true }), /receipt/);
    const applied = await runRepair(admin, { plan, receipt, source, sourceProvider: () => source, policyProvider: () => policy, mode: 'apply', quiesced: true });
    assert.equal(applied.committed, true); assert.equal(applied.strict_pass, true);
    await app.query('BEGIN');
    await app.query(`SELECT set_config('app.user_id',$1,true)`, [subject]);
    const rows = await app.query(`SELECT id,note FROM ${schema}.records ORDER BY id`);
    assert.equal(rows.rows.length, 1); assert.equal(rows.rows[0].id, originalId);
    const tempId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
    await app.query(`INSERT INTO ${schema}.records(id,user_id,note) VALUES($1,$2,'new synthetic record')`, [tempId, subject]);
    assert.equal((await app.query(`UPDATE ${schema}.records SET note='updated synthetic record' WHERE id=$1 RETURNING id`, [tempId])).rowCount, 1);
    assert.equal((await app.query(`DELETE FROM ${schema}.records WHERE id=$1 RETURNING id`, [tempId])).rowCount, 1);
    await app.query('COMMIT');
    assert.equal((await service.query(`SELECT ${schema}.safe() AS allowed`)).rows[0].allowed, true, 'separate restricted service LOGIN retains required RPC');
    await assert.rejects(service.query(`SELECT ${schema}.unneeded()`), error => error.code === '42501');
    await assert.rejects(app.query(`TRUNCATE ${schema}.records`), error => error.code === '42501');
    await assert.rejects(app.query(`SELECT * FROM ${schema}.schema_migrations`), error => error.code === '42501');
    await assert.rejects(app.query(`CREATE TABLE ${schema}.forbidden(id integer)`), error => error.code === '42501');
    // PostgreSQL may warn instead of error when no grant option remains.
    await app.query(`GRANT SELECT ON ${schema}.records TO ${login}`);
    assert.equal((await service.query(`SELECT has_table_privilege(current_user,'${schema}.records','SELECT') AS allowed`)).rows[0].allowed, false);
    assert.deepEqual((await admin.query(digestSql)).rows[0], dataBefore, 'all original financial-like records preserved byte-for-byte');
    const final = await auditRuntimePrivileges(app, { policy });
    assert.equal(final.strict_pass, true, 'same strict audit passes via independent non-owner login');
    // A plan cannot silently run again after grants changed.
    await assert.rejects(runRepair(admin, { plan, receipt, source, sourceProvider: () => source, policyProvider: () => policy, mode: 'apply', quiesced: true }), /Catalog drift/);
    console.log('PASS: exact-grant repair rehearsal rolled back; reviewed apply removed only TRUNCATE, grant option, ledger, schema CREATE, default table grant and unneeded inherited RPC; independent non-owner LOGIN retains tenant RLS CRUD and separate service safe RPC; data digests preserved; strict audit passes; tampered receipt and replay refused');
  } finally { if (app) await app.end(); if (service) await service.end(); await admin.end(); }
}
main().catch(error => { console.error('Synthetic privilege repair fixture failed:', error.stack); process.exitCode = 1; });
