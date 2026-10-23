'use strict';

// Coordinator-invoked fixture for disposable loopback PostgreSQL databases.
// It never creates, drops, or resets a database and refuses non-local URLs.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Pool } = require('pg');

function localDatabaseUrl(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is required for the isolated PostgreSQL fixture`);
  const url = new URL(value);
  if (!['127.0.0.1', 'localhost', '::1'].includes(url.hostname) || url.pathname !== `/${name.endsWith('CONFLICT_TEST_DATABASE_URL') ? 'auth_contact_conflict_test' : 'auth_contact_unique_test'}`) {
    throw new Error(`${name} must name the expected disposable loopback database`);
  }
  return value;
}

function migrationEnv() {
  return {
    ...process.env,
    NODE_ENV: 'test',
    ENCRYPTION_ENABLED: 'true',
    ENCRYPTION_KEY: Buffer.alloc(32, 0x43).toString('base64'),
    PHONE_LOOKUP_HMAC_KEY: 'synthetic-contact-uniqueness-hmac-key-0001',
    AUTH_MIGRATION_STATEMENT_TIMEOUT_MS: '10000',
  };
}

function assertNoSensitiveOutput(value) {
  const rendered = JSON.stringify(value);
  assert.doesNotMatch(rendered, /\+91\d{10}|@example\.invalid|@example\.test/i);
  assert.doesNotMatch(rendered, /[0-9a-f]{64}/i);
}

async function withPool(url, callback) {
  const pool = new Pool({ connectionString: url, max: 2, connectionTimeoutMillis: 5000 });
  try {
    return await callback(pool);
  } finally {
    await pool.end();
  }
}

async function assertFresh(pool) {
  const { rows } = await pool.query(`
    SELECT COUNT(*)::int AS count
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
  `);
  assert.equal(rows[0].count, 0, 'fixture database must be freshly created by the coordinator');
}

async function installPreBackfillOnly(pool, runner, migrationRoot, fixtureEnv) {
  const migrationsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'auth-contact-pre-'));
  try {
    for (const file of ['0001_phone_lookup_hashes.sql', '0002_otp_purpose_binding.sql']) {
      fs.copyFileSync(path.join(migrationRoot, file), path.join(migrationsDir, file));
    }
    await runner.runMigrations(pool, {
      migrationsDir,
      env: fixtureEnv,
      onProgress: () => {},
    });
  } finally {
    fs.rmSync(migrationsDir, { recursive: true, force: true });
  }
}

async function main() {
  const uniqueUrl = localDatabaseUrl('AUTH_CONTACT_UNIQUENESS_TEST_DATABASE_URL');
  const conflictUrl = localDatabaseUrl('AUTH_CONTACT_UNIQUENESS_CONFLICT_TEST_DATABASE_URL');
  Object.assign(process.env, migrationEnv());
  const runner = require('../scripts/migrate');
  const { encryptPhoneNumber } = require('../src/utils/fieldEncryption');
  const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
  const migrationRoot = path.resolve(__dirname, '../db/migrations');
  const fixtureEnv = migrationEnv();

  await withPool(uniqueUrl, async pool => {
    await assertFresh(pool);
    await runner.runMigrations(pool, { env: fixtureEnv, onProgress: () => {} });

    const historyTable = await pool.query(
      `SELECT to_regclass('public.contact_resolution_history')::text AS relation`,
    );
    assert.equal(historyTable.rows[0].relation, 'contact_resolution_history');
    const historyColumns = await pool.query(
      `SELECT column_name, data_type, udt_name, character_maximum_length
         FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'contact_resolution_history'`,
    );
    const historyTypes = new Map(historyColumns.rows.map(row => [row.column_name, row]));
    assert.equal(historyTypes.get('original_row_age')?.udt_name, 'bytea');
    assert.equal(historyTypes.get('archive_sha256')?.character_maximum_length, 64);
    assert.equal(historyTypes.get('resolution_id')?.udt_name, 'uuid');
    assert.equal(historyTypes.get('user_id')?.udt_name, 'uuid');
    assert.equal(historyTypes.get('retained_phone_account_id')?.udt_name, 'uuid');
    const historyConstraints = await pool.query(
      `SELECT conname, contype, pg_get_constraintdef(oid) AS definition
         FROM pg_constraint
        WHERE conrelid = 'public.contact_resolution_history'::regclass`,
    );
    assert.equal(historyConstraints.rows.some(row => row.conname === 'uq_contact_resolution_history_resolution_user'), true);
    const historyForeignKeys = await pool.query(
      `SELECT COUNT(*)::int AS count FROM pg_constraint
        WHERE conrelid = 'public.contact_resolution_history'::regclass AND contype = 'f'
          AND confdeltype = 'r'`,
    );
    assert.equal(historyForeignKeys.rows[0].count, 2);
    const publicGrants = await pool.query(
      `SELECT COUNT(*)::int AS count FROM information_schema.table_privileges
        WHERE table_schema = 'public' AND table_name = 'contact_resolution_history' AND grantee = 'PUBLIC'`,
    );
    assert.equal(publicGrants.rows[0].count, 0);

    const phone = '+919876540001';
    const phoneCiphertext = encryptPhoneNumber(phone);
    const phoneHash = phoneLookupHash(phone);
    await pool.query(
      `INSERT INTO users (email, phone_number, phone_lookup_hash, deleted)
       VALUES ($1, $2, $3, TRUE)`,
      ['reusable@example.test', phoneCiphertext, phoneHash],
    );
    await pool.query(
      `INSERT INTO users (email, phone_number, phone_lookup_hash, deleted)
       VALUES ($1, $2, $3, FALSE)`,
      ['reusable@example.test', phoneCiphertext, phoneHash],
    );

    const emailRace = await Promise.allSettled([
      pool.query(`INSERT INTO users (email) VALUES ('email-race@example.test')`),
      pool.query(`INSERT INTO users (email) VALUES ('email-race@example.test')`),
    ]);
    const phoneRaceValue = '+919876540002';
    const phoneRace = await Promise.allSettled([
      pool.query(`INSERT INTO users (phone_number, phone_lookup_hash) VALUES ($1, $2)`, [
        encryptPhoneNumber(phoneRaceValue), phoneLookupHash(phoneRaceValue),
      ]),
      pool.query(`INSERT INTO users (phone_number, phone_lookup_hash) VALUES ($1, $2)`, [
        encryptPhoneNumber(phoneRaceValue), phoneLookupHash(phoneRaceValue),
      ]),
    ]);
    for (const race of [emailRace, phoneRace]) {
      assert.equal(race.filter(result => result.status === 'fulfilled').length, 1);
      const failure = race.find(result => result.status === 'rejected').reason;
      assert.equal(failure.code, '23505');
    }
    const indexRows = await pool.query(
      `SELECT indexname FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexname IN ('uq_users_active_email_lower', 'uq_users_active_phone_lookup_hash')`,
    );
    assert.equal(indexRows.rows.length, 2);
  });

  await withPool(conflictUrl, async pool => {
    await assertFresh(pool);
    await installPreBackfillOnly(pool, runner, migrationRoot, fixtureEnv);
    const phone = '+919876540003';
    const encrypted = encryptPhoneNumber(phone);
    await pool.query(
      `INSERT INTO users (email, phone_number, phone_lookup_hash, deleted)
       VALUES ('conflict-a@example.test', $1, NULL, FALSE),
              ('conflict-b@example.test', $1, NULL, FALSE)`,
      [encrypted],
    );

    let failure;
    try {
      await runner.runMigrations(pool, { env: fixtureEnv, onProgress: () => {} });
    } catch (error) {
      failure = error;
    }
    assert.ok(failure, 'duplicate active phone hashes must block migration');
    assert.match(failure.message, /phone_hash_duplicate_groups=1/);
    assert.doesNotMatch(failure.message, /conflict-[ab]|@example|\+91|[0-9a-f]{64}/i);
    const rows = await pool.query(
      `SELECT COUNT(*)::int AS total, COUNT(phone_lookup_hash)::int AS hashed,
              COUNT(DISTINCT phone_lookup_hash)::int AS distinct_hashes
         FROM users WHERE deleted = FALSE`,
    );
    assert.deepEqual(rows.rows[0], { total: 2, hashed: 2, distinct_hashes: 1 });
    const ledger = await pool.query(
      `SELECT COUNT(*)::int AS count FROM auth_schema_migrations WHERE version = '9001_active_contact_uniqueness'`,
    );
    assert.equal(ledger.rows[0].count, 0);
    const index = await pool.query(
      `SELECT COUNT(*)::int AS count FROM pg_indexes WHERE schemaname = 'public'
        AND indexname IN ('uq_users_active_email_lower', 'uq_users_active_phone_lookup_hash')`,
    );
    assert.equal(index.rows[0].count, 0);
    assertNoSensitiveOutput({ failure: { code: failure.code }, rows: rows.rows[0] });
  });

  process.stdout.write('Active-contact uniqueness PostgreSQL fixture passed.\n');
}

main().catch(error => {
  // Keep diagnostics free of database messages, URLs, contacts and hashes.
  process.stderr.write(`Active-contact uniqueness PostgreSQL fixture failed (${String(error?.code || error?.name || 'error')}).\n`);
  process.exitCode = 1;
});
