#!/usr/bin/env node
'use strict';

// Runs only after exact source-to-copy restore verification. The generated
// recovery databases are discarded afterwards; source URLs are never used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const { createRequire } = require('node:module');
const resolution = require('./resolve_test_contacts');

function identifier(value) { return '"' + value.replace(/"/g, '""') + '"'; }
function digestRows(rows) {
  const hash = crypto.createHash('sha256');
  for (const row of rows) hash.update(row.canonical).update('\n');
  return { rows: rows.length, sha256: hash.digest('hex') };
}

async function tableInventory(client, table, columns, secondaries) {
  const json = table === 'users'
    ? 'CASE WHEN t.id=ANY($2::uuid[]) THEN to_jsonb(t)-$1::text[] ELSE to_jsonb(t) END'
    : 'to_jsonb(t)';
  const parameters = table === 'users'
    ? [['phone_number', 'phone_lookup_hash', 'is_phone_verified', 'updated_at'], secondaries] : [];
  const result = await client.query(`SELECT canonical FROM (
    SELECT (${json})::text AS canonical FROM (
      SELECT ${columns.map(identifier).join(',')} FROM public.${identifier(table)}
    ) t) r ORDER BY canonical COLLATE "C"`, parameters);
  return digestRows(result.rows);
}

async function main() {
  const target = process.env.RESTORE_AUTH_TARGET_URL;
  if (!target || new URL(target).hostname !== '127.0.0.1' ||
      !/^\/pprestore_[a-f0-9]{20}_a$/.test(new URL(target).pathname) ||
      process.env.RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION !== 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER') {
    throw new Error('An explicitly isolated generated recovery database is required');
  }
  if (process.env.PRODUCT_REVIEWED_BASELINE_FILE) {
    await require('./rehearse_product_upgrade').main();
  }
  const planFile = process.env.CONTACT_PROPOSAL_FILE;
  const identity = process.env.CONTACT_IDENTITY_FILE;
  const recipients = process.env.CONTACT_RECIPIENTS_FILE;
  if (!planFile || !identity || !recipients) throw new Error('Private approved proposal inputs are required');
  const planBytes = fs.readFileSync(planFile);
  const planHash = resolution.sha256(planBytes);
  const proposal = JSON.parse(resolution.ageDecrypt(identity, planBytes).toString('utf8'));
  const checked = resolution.validateProposal(proposal);
  const secondaries = checked.groups.flatMap(group => group.rows.filter(row => row.id !== group.keeperId).map(row => row.id));
  const authDir = process.env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
  const authRequire = createRequire(path.join(authDir, 'package.json'));
  const { Client } = authRequire('pg');
  const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
  const { runAudit } = require(path.join(authDir, 'scripts/auditContactUniqueness'));
  const client = new Client({ ...resolveDatabaseTls(target), connectionTimeoutMillis: 10000 });
  await client.connect();
  try {
    await client.query("SET statement_timeout='15000ms'");
    const catalog = await client.query(`SELECT c.relname,a.attname FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace JOIN pg_attribute a ON a.attrelid=c.oid
      WHERE n.nspname='public' AND c.relkind IN ('r','p') AND a.attnum>0 AND NOT a.attisdropped
        AND c.relname NOT IN ('auth_schema_migrations','contact_resolution_history')
      ORDER BY c.relname,a.attnum`);
    const tables = new Map();
    for (const row of catalog.rows) {
      if (!tables.has(row.relname)) tables.set(row.relname, []);
      tables.get(row.relname).push(row.attname);
    }
    const before = new Map();
    for (const [table, columns] of tables) before.set(table, await tableInventory(client, table, columns, secondaries));
    const userIds = (await client.query('SELECT id::text FROM public.users ORDER BY id')).rows;
    const upgradeEnv = { ...process.env, AUTH_MIGRATION_DATABASE_URL: target, AUTH_DATABASE_URL: target,
      AUTH_MIGRATION_ADOPT_LEGACY_CHECKSUMS: 'true', CONTACT_RESOLUTION_APPROVAL: resolution.APPROVAL,
      CONTACT_RESOLUTION_WRITERS_FENCED: resolution.WRITERS_FENCED };
    const args = ['--plan', planFile, '--identity', identity, '--recipients', recipients,
      '--apply', '--approved-proposal-sha256', planHash];
    // The migration module reads process.env; pin it to the disposable target
    // for both initial application and the idempotent replay verification.
    const originalEnv = {};
    for (const [name, value] of Object.entries(upgradeEnv)) {
      originalEnv[name] = process.env[name];
      process.env[name] = value;
    }
    try {
      await resolution.main(args, process.env);
      await resolution.main(args, process.env);
    } finally {
      for (const [name, value] of Object.entries(originalEnv)) {
        if (value === undefined) delete process.env[name]; else process.env[name] = value;
      }
    }
    assert.deepEqual((await client.query('SELECT id::text FROM public.users ORDER BY id')).rows, userIds);
    for (const [table, columns] of tables) {
      assert.deepEqual(await tableInventory(client, table, columns, secondaries), before.get(table));
    }
    const cleared = await client.query(`SELECT COUNT(*)::int AS count FROM public.users
      WHERE id=ANY($1::uuid[]) AND phone_number IS NULL AND phone_lookup_hash IS NULL
        AND is_phone_verified=FALSE AND is_email_verified=TRUE AND deleted=FALSE`, [secondaries]);
    assert.equal(cleared.rows[0].count, secondaries.length);
    const history = await client.query(`SELECT original_row_age,archive_sha256 FROM public.contact_resolution_history
      WHERE resolution_id=$1::uuid`, [resolution.resolutionId(planHash)]);
    assert.equal(history.rows.length, secondaries.length);
    for (const row of history.rows) assert.equal(resolution.sha256(row.original_row_age), row.archive_sha256.trim());
    const poolFacade = { connect: async () => ({ query: (...args) => client.query(...args), release() {} }) };
    const audit = await runAudit(poolFacade);
    assert.equal(audit.gates.active_uniqueness_clear, true);
    assert.equal(audit.gates.phone_hashes_complete, true);
    assert.equal(audit.lifecycle.total, userIds.length);
    await require('./verify_recovery').main();
    console.log(`CONTACT_UPGRADE_STATUS=passed accounts_preserved=${userIds.length} phone_claims_archived=${secondaries.length} preserved_auth_tables=${tables.size} replay=passed`);
  } finally { await client.end(); }
}

if (require.main === module) main().catch(error => {
  const code = /^[a-z_]{1,64}$/.test(error?.rehearsalCode || '') ? error.rehearsalCode
    : /^[0-9A-Z]{5}$/.test(error?.code || '') ? error.code : 'check_failed';
  const stage = ['preflight', 'apply', 'replay'].includes(error?.rehearsalStage) ? error.rehearsalStage : 'verification';
  console.error(`Contact upgrade rehearsal failed (${code}) stage=${stage}`);
  if (error?.rehearsalDiagnostic) console.error(`Migration diagnostic metadata ${JSON.stringify(error.rehearsalDiagnostic)}`);
  process.exitCode = 1;
});
module.exports = { digestRows, identifier };
