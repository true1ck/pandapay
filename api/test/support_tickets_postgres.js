#!/usr/bin/env node
'use strict';

// Owns a temporary loopback cluster containing synthetic data only. This does
// not read .env, DATABASE_URL, saved backups, or provider configuration.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const net = require('node:net');
const { spawnSync } = require('node:child_process');
const { randomUUID } = require('node:crypto');
const { Client, Pool } = require('pg');
const { createSupportTicketHandler } = require('../src/support_tickets');
const { createDataErrorReportHandler } = require('../src/data_error_reports');

const ROOT = path.resolve(__dirname, '../..');
const migrations = path.join(ROOT, 'db/supabase/migrations');

function run(command, args, options) {
  const result = spawnSync(command, args, { encoding: 'utf8', timeout: 60_000, ...options });
  if (result.status !== 0) throw new Error(`${command} fixture failed: ${String(result.stderr || '').slice(-1200)}`);
  return result.stdout;
}

async function unusedPort() {
  return new Promise((resolve, reject) => {
    const socket = net.createServer();
    socket.once('error', reject);
    socket.listen(0, '127.0.0.1', () => {
      const port = socket.address().port;
      socket.close(() => resolve(port));
    });
  });
}

function response() {
  return {
    code: 200, headers: {}, body: null,
    status(value) { this.code = value; return this; },
    set(name, value) { this.headers[name] = value; return this; },
    json(body) { this.body = body; return this; },
  };
}

async function main() {
  const work = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-support-rls-'));
  const data = path.join(work, 'data');
  const env = { PATH: process.env.PATH || '', TMPDIR: work, LC_ALL: 'C', LANG: 'C' };
  let started = false, admin, runtime;
  try {
    const port = await unusedPort();
    run('initdb', ['-D', data, '-A', 'trust', '--no-locale', '--encoding=UTF8', '-U', 'fixture_owner'], { env });
    run('pg_ctl', ['-D', data, '-l', path.join(work, 'postgres.log'), '-o', `-p ${port} -h 127.0.0.1 -k ${work}`, 'start'], { env });
    started = true;
    const config = { host: '127.0.0.1', port, database: 'postgres', ssl: false, connectionTimeoutMillis: 3000 };
    admin = new Client({ ...config, user: 'fixture_owner' });
    await admin.connect();
    const baseline = fs.readdirSync(migrations).filter(file => /^00(?:0[1-9]|1[01])_/.test(file)).sort();
    assert.equal(baseline.length, 11);
    for (const file of baseline) await admin.query(fs.readFileSync(path.join(migrations, file), 'utf8'));
    await admin.query(fs.readFileSync(path.join(migrations, '0015_card_products_rls_fix.sql'), 'utf8'));
    await admin.query(fs.readFileSync(path.join(migrations, '0016_queue_tables_admin_rls.sql'), 'utf8'));
    // Apply the exact upstream ticket/report policy section. Its unrelated
    // dashboard view depends on later product tables outside this fixture.
    const upstream = fs.readFileSync(path.join(migrations, '20261024223000_support_tickets_dashboard_and_feedback.sql'), 'utf8');
    assert.equal(upstream.split('-- 3. Update v_data_quality_dashboard').length, 2);
    await admin.query(upstream.split('-- 3. Update v_data_quality_dashboard')[0]);

    await admin.query(`CREATE ROLE support_fixture_runtime LOGIN NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE NOREPLICATION;
      GRANT USAGE ON SCHEMA public,pandapay TO support_fixture_runtime;
      GRANT SELECT,INSERT,UPDATE ON public.support_tickets,public.data_error_reports TO support_fixture_runtime;
      GRANT SELECT ON public.card_products TO support_fixture_runtime;`);
    runtime = new Pool({ ...config, user: 'support_fixture_runtime', max: 4 });
    const role = (await runtime.query('SELECT current_user AS name, rolsuper, rolbypassrls FROM pg_roles WHERE rolname=current_user')).rows[0];
    assert.equal(role.name, 'support_fixture_runtime');
    assert.equal(role.rolsuper, false);
    assert.equal(role.rolbypassrls, false);
    const policies = (await admin.query("SELECT relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='support_tickets'::regclass")).rows[0];
    assert.equal(policies.relrowsecurity, true);
    assert.equal(policies.relforcerowsecurity, true);

    const owner = randomUUID(), other = randomUUID(), operator = randomUUID();
    await admin.query('INSERT INTO profiles(id) VALUES($1),($2)', [owner, other]);
    await admin.query("INSERT INTO admin_users(id,email) VALUES($1,'support-fixture@example.invalid')", [operator]);
    const historical = (await admin.query("INSERT INTO support_tickets(profile_id,kind,message) VALUES($1,'general','retained history') RETURNING *", [other])).rows[0];
    async function withUserClient(userId, callback) {
      const client = await runtime.connect();
      try {
        await client.query('BEGIN');
        await client.query("SELECT set_config('statement_timeout','3000ms',true)");
        if (userId) await client.query("SELECT set_config('app.user_id',$1,true)", [userId]);
        const result = await callback(client);
        await client.query('COMMIT');
        return result;
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      } finally { client.release(); }
    }
    await assert.rejects(withUserClient(null, client => client.query(
      "INSERT INTO support_tickets(profile_id,kind,message) VALUES(NULL,'general','old returning query') RETURNING id",
    )), error => error.code === '42501', 'anonymous INSERT RETURNING must remain unreadable');

    const handler = createSupportTicketHandler({ withUserClient });
    const guest = response();
    await handler({ userId: null, ip: '203.0.113.8', body: { kind: 'general', message: 'OTP help', diagnostics: { platform: 'android' } } }, guest);
    assert.equal(guest.code, 201, 'anonymous API submission must succeed under the real runtime role');
    assert.match(guest.body.ticket.id, /^[0-9a-f-]{36}$/);
    assert.equal(guest.body.ticket.state, 'pending');
    assert.equal((await withUserClient(null, client => client.query('SELECT * FROM support_tickets'))).rowCount, 0);
    const storedGuest = (await admin.query('SELECT * FROM support_tickets WHERE id=$1', [guest.body.ticket.id])).rows[0];
    assert.equal(storedGuest.profile_id, null);
    assert.equal(storedGuest.message, 'OTP help');
    assert.equal(storedGuest.created_at.toISOString(), new Date(guest.body.ticket.created_at).toISOString());

    const member = response();
    await handler({ userId: owner, ip: '203.0.113.9', body: { kind: 'bug', message: 'Signed-in issue' } }, member);
    assert.equal(member.code, 201);
    const visible = await withUserClient(owner, client => client.query('SELECT id FROM support_tickets'));
    assert.deepEqual(visible.rows.map(row => row.id), [member.body.ticket.id]);
    assert.equal((await withUserClient(null, client => client.query('SELECT id FROM support_tickets'))).rowCount, 0,
      'the reused connection must not retain the preceding owner identity');
    await assert.rejects(withUserClient(owner, client => client.query(
      "INSERT INTO support_tickets(profile_id,kind,message) VALUES($1,'bug','wrong owner')", [other],
    )), error => error.code === '42501');
    const after = (await admin.query('SELECT * FROM support_tickets WHERE id=$1', [historical.id])).rows[0];
    assert.deepEqual(after, historical, 'existing ticket history is preserved');
    const operatorRows = await withUserClient(operator, client => client.query('SELECT id FROM support_tickets'));
    assert.deepEqual(operatorRows.rows.map(row => row.id).sort(),
      [historical.id, guest.body.ticket.id, member.body.ticket.id].sort(), 'the existing operator policy can triage all tickets');

    const issuer = randomUUID(), published = randomUUID(), draft = randomUUID();
    await admin.query("INSERT INTO issuers(id,slug,name) VALUES($1,'feedback-fixture','Feedback fixture')", [issuer]);
    await admin.query(`INSERT INTO card_products(id,issuer_id,slug,name,network,status,verified_at)
      VALUES($1,$3,'published-feedback','Published feedback','visa','published',now()),
            ($2,$3,'draft-feedback','Draft feedback','visa','draft',null)`, [published, draft, issuer]);
    const historicalReport = (await admin.query(`INSERT INTO data_error_reports(profile_id,card_product_id,field_path,claimed_value)
      VALUES($1,$2,'annual_fee','retained private evidence') RETURNING *`, [other, published])).rows[0];
    await assert.rejects(withUserClient(null, client => client.query(
      "INSERT INTO data_error_reports(profile_id,card_product_id,field_path) VALUES(NULL,$1,'annual_fee') RETURNING id", [published],
    )), error => error.code === '42501', 'the old report insert must reproduce the same anonymous read-policy failure');
    const reportHandler = createDataErrorReportHandler({ withUserClient });
    const anonymousReport = response();
    await reportHandler({ ip: '203.0.113.18', body: { cardProductId: published.toUpperCase(), fieldPath: ' annual_fee ',
      shownValue: '1000', claimedValue: '500', profileId: other } }, anonymousReport);
    assert.equal(anonymousReport.code, 201);
    assert.equal(anonymousReport.body.errorReport.field_path, 'annual_fee');
    assert.equal(anonymousReport.body.errorReport.card_product_id, published);
    const storedReport = (await admin.query('SELECT * FROM data_error_reports WHERE id=$1', [anonymousReport.body.errorReport.id])).rows[0];
    assert.equal(storedReport.profile_id, null, 'client-supplied profile ID cannot attribute the report');
    assert.equal(storedReport.claimed_value, '500');
    assert.equal(storedReport.created_at.toISOString(), new Date(anonymousReport.body.errorReport.created_at).toISOString());
    assert.equal((await withUserClient(null, client => client.query('SELECT id FROM data_error_reports'))).rowCount, 0);
    for (const userId of [null, owner]) {
      for (const cardProductId of [draft, randomUUID()]) {
        const hidden = response();
        await reportHandler({ userId, ip: '203.0.113.19', body: { cardProductId, fieldPath: 'annual_fee' } }, hidden);
        assert.equal(hidden.code, 404, 'draft and nonexistent cards have the same response');
      }
    }
    const memberReport = response();
    await reportHandler({ userId: owner, ip: '203.0.113.20', body: { cardProductId: published,
      fieldPath: 'annual_fee', claimedValue: '0', profileId: other } }, memberReport);
    assert.equal(memberReport.code, 201);
    const ownerReports = await withUserClient(owner, client => client.query('SELECT id,profile_id FROM data_error_reports'));
    assert.deepEqual(ownerReports.rows, [{ id: memberReport.body.errorReport.id, profile_id: owner }]);
    assert.equal((await withUserClient(null, client => client.query('SELECT id FROM data_error_reports'))).rowCount, 0);
    await assert.rejects(withUserClient(owner, client => client.query(
      "INSERT INTO data_error_reports(profile_id,card_product_id,field_path) VALUES($1,$2,'annual_fee')", [other, published],
    )), error => error.code === '42501');
    const operatorReports = await withUserClient(operator, client => client.query('SELECT id FROM data_error_reports'));
    assert.deepEqual(operatorReports.rows.map(row => row.id).sort(),
      [historicalReport.id, anonymousReport.body.errorReport.id, memberReport.body.errorReport.id].sort());
    assert.deepEqual((await admin.query('SELECT * FROM data_error_reports WHERE id=$1', [historicalReport.id])).rows[0], historicalReport);
    assert.equal((await admin.query('SELECT count(*)::int AS count FROM data_error_reports')).rows[0].count, 3,
      'refused and hidden-card requests must leave no report row');
    const version = (await admin.query('SHOW server_version')).rows[0].server_version;
    process.stdout.write(JSON.stringify({ result: 'passed', postgres_version: version,
      scenarios: ['legacy_returning_refused', 'anonymous_submission', 'anonymous_read_denied', 'member_submission',
        'owner_read_only', 'pooled_identity_reset', 'foreign_insert_denied', 'history_preserved', 'operator_triage'],
      catalogue_report_scenarios: ['legacy_report_returning_refused', 'anonymous_report_and_receipt', 'anonymous_report_read_denied',
        'draft_and_missing_cards_hidden', 'member_report_owner_isolation', 'report_pooled_identity_reset',
        'foreign_report_insert_denied', 'operator_report_triage', 'report_history_and_counts_preserved'] }) + '\n');
  } finally {
    if (runtime) await runtime.end().catch(() => {});
    if (admin) await admin.end().catch(() => {});
    if (started) run('pg_ctl', ['-D', data, '-m', 'immediate', 'stop'], { env });
    fs.rmSync(work, { recursive: true, force: true });
  }
}

if (require.main === module) main().catch(error => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
