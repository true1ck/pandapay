'use strict';

// Real PostgreSQL compatibility fixture. The parent recovery rehearsal creates
// a fresh loopback-only database named otp_purpose_test and passes its URL.
// This script refuses any other target to avoid accidentally touching a DB.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const bcrypt = require('bcrypt');
const { Client, Pool } = require('pg');

const connectionString = process.env.OTP_PURPOSE_TEST_DATABASE_URL;
if (!connectionString) throw new Error('OTP_PURPOSE_TEST_DATABASE_URL is required for the synthetic OTP PostgreSQL fixture');
const target = new URL(connectionString);
if (!['127.0.0.1', 'localhost', '::1'].includes(target.hostname) || target.pathname !== '/otp_purpose_test') {
  throw new Error('OTP purpose PostgreSQL fixture requires a loopback database named otp_purpose_test');
}

process.env.NODE_ENV = 'test';
process.env.AUTH_DATABASE_URL = connectionString;
process.env.DATABASE_URL = connectionString;
process.env.ENCRYPTION_ENABLED = 'true';
process.env.ENCRYPTION_KEY ||= Buffer.alloc(32, 9).toString('base64');
process.env.PHONE_LOOKUP_HMAC_KEY ||= 'synthetic-otp-purpose-hmac-key-32bytes';
process.env.JWT_ACCESS_SECRET ||= 'synthetic-otp-purpose-access-secret';
process.env.JWT_REFRESH_SECRET ||= 'synthetic-otp-purpose-refresh-secret';

function serviceWithSyntheticRateLimiter(client) {
  const filename = require.resolve('../src/services/otpService');
  const Module = require('node:module');
  const originalLoad = Module._load;
  const codes = [4821, 5732, 8643, 2914, 7359, 6182, 9473, 3164];
  let codeIndex = 0;
  Module._load = function(request, parent, isMain) {
    if (parent?.filename === filename && request === '../db') return { query: (...args) => client.query(...args) };
    if (parent?.filename === filename && request === '../config') return { isProduction: false };
    if (parent?.filename === filename && request === 'node:crypto') {
      return { ...originalLoad.call(this, request, parent, isMain), randomInt: () => codes[codeIndex++] || 1000 + codeIndex };
    }
    if (parent?.filename === filename && request === '../middleware/rateLimitMiddleware') {
      return { markActiveOtp: async () => {}, clearActiveOtp: async () => {} };
    }
    return originalLoad.call(this, request, parent, isMain);
  };
  try {
    delete require.cache[filename];
    return require(filename);
  } finally {
    Module._load = originalLoad;
  }
}

async function main() {
  const { runMigrations } = require('../scripts/migrate');
  const migrationDir = fs.mkdtempSync(path.join(os.tmpdir(), 'otp-purpose-migrations-'));
  const sourceMigrationDir = path.join(__dirname, '../db/migrations');
  const pool = new Pool({ connectionString, max: 1 });
  const client = new Client({ connectionString });
  try {
    const preflight = await pool.query(
      `SELECT EXISTS (
         SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
            AND n.nspname NOT LIKE 'pg_toast%'
            AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
       ) AS has_relations`,
    );
    if (preflight.rows[0]?.has_relations) throw new Error('OTP purpose fixture refuses a non-empty database');
    // First install the deployed pre-purpose migration set, then write a
    // historical NULL-purpose challenge before adding the new migration.
    fs.copyFileSync(path.join(sourceMigrationDir, '0001_phone_lookup_hashes.sql'), path.join(migrationDir, '0001_phone_lookup_hashes.sql'));
    await runMigrations(pool, { migrationsDir: migrationDir, env: process.env, onProgress: () => {} });
    await client.connect();
    const legacyIdentifier = 'legacy-purpose-fixture@example.invalid';
    const legacyCode = '4817';
    await client.query(
      `INSERT INTO otp_requests(email, type, otp_hash, expires_at)
       VALUES ($1, 'email', $2, NOW() + INTERVAL '2 minutes')`,
      [legacyIdentifier, await bcrypt.hash(legacyCode, 4)],
    );

    fs.copyFileSync(path.join(sourceMigrationDir, '0002_otp_purpose_binding.sql'), path.join(migrationDir, '0002_otp_purpose_binding.sql'));
    await runMigrations(pool, { migrationsDir: migrationDir, env: process.env, onProgress: () => {} });
    const legacy = await client.query('SELECT purpose FROM otp_requests WHERE email = $1', [legacyIdentifier]);
    assert.equal(legacy.rows[0]?.purpose, null, 'migration preserves unknown historical purpose');

    const otp = serviceWithSyntheticRateLimiter(client);
    assert.equal((await otp.verifyOtp(legacyIdentifier, legacyCode, 'email', 'recovery')).ok, false,
      'historical NULL challenge must not authorize recovery');
    assert.equal((await otp.verifyOtp(legacyIdentifier, legacyCode, 'email', 'signin')).ok, true,
      'historical NULL challenge remains compatible with sign-in');

    const identifier = 'purpose-isolation-fixture@example.invalid';
    const signin = await otp.createOtp(identifier, 'email', 'signin');
    const recovery = await otp.createOtp(identifier, 'email', 'recovery');
    const recoveryResend = await otp.createOtp(identifier, 'email', 'recovery');
    const challengeRows = await client.query(
      'SELECT id, purpose, deleted FROM otp_requests WHERE email = $1 ORDER BY created_at, id', [identifier],
    );
    assert.deepEqual(challengeRows.rows.map(row => [row.id, row.purpose, row.deleted]), [
      [signin.requestId, 'signin', false],
      [recovery.requestId, 'recovery', true],
      [recoveryResend.requestId, 'recovery', false],
    ], 'resending one purpose leaves other purpose challenges alone');
    assert.equal((await otp.verifyOtp(identifier, recoveryResend.code, 'email', 'signin')).ok, false,
      'recovery code cannot be used for sign-in');
    assert.equal((await otp.verifyOtp(identifier, signin.code, 'email', 'signin')).ok, true);

    const cleanupIdentifier = 'purpose-cleanup-fixture@example.invalid';
    const cleanupSignin = await otp.createOtp(cleanupIdentifier, 'email', 'signin');
    const cleanupRecovery = await otp.createOtp(cleanupIdentifier, 'email', 'recovery');
    await otp.discardUndeliveredOtp(cleanupIdentifier, 'email', cleanupRecovery.requestId, 'signin');
    let cleanupRows = await client.query('SELECT id, deleted FROM otp_requests WHERE email = $1 ORDER BY created_at, id', [cleanupIdentifier]);
    assert.deepEqual(cleanupRows.rows.map(row => [row.id, row.deleted]), [
      [cleanupSignin.requestId, false], [cleanupRecovery.requestId, false],
    ], 'cleanup with the wrong purpose changes no row');
    await otp.discardUndeliveredOtp(cleanupIdentifier, 'email', cleanupRecovery.requestId, 'recovery');
    cleanupRows = await client.query('SELECT id, deleted FROM otp_requests WHERE email = $1 ORDER BY created_at, id', [cleanupIdentifier]);
    assert.deepEqual(cleanupRows.rows.map(row => [row.id, row.deleted]), [
      [cleanupSignin.requestId, false], [cleanupRecovery.requestId, true],
    ], 'delivery cleanup only discards the matching purpose challenge');

    const concurrentIdentifier = 'single-use-fixture@example.invalid';
    const concurrent = await otp.createOtp(concurrentIdentifier, 'email', 'replacement');
    const results = await Promise.all([
      otp.verifyOtp(concurrentIdentifier, concurrent.code, 'email', 'replacement'),
      otp.verifyOtp(concurrentIdentifier, concurrent.code, 'email', 'replacement'),
    ]);
    assert.equal(results.filter(result => result.ok).length, 1, 'exactly one concurrent consume succeeds');
    console.log('PASS: real PostgreSQL OTP purpose migration, NULL legacy signin-only, purpose isolation, resend and delivery cleanup scope, atomic concurrent consume');
  } finally {
    await client.end().catch(() => {});
    await pool.end();
    fs.rmSync(migrationDir, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error('Synthetic OTP PostgreSQL fixture failed:', error.message);
  process.exitCode = 1;
});
