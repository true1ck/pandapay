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
      return { ...originalLoad.call(this, request, parent, isMain), randomInt: (minimum) => minimum===100000?620000+(codeIndex++):codes[codeIndex++] || 1000 + codeIndex };
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

    await client.query(fs.readFileSync(path.join(sourceMigrationDir,'0011_versioned_otp_challenges.sql'),'utf8'));
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
    const v2Email='version2-purpose@example.invalid',device='stable-device-v2';
    const six=await otp.createOtpV2(v2Email,'email','signin',device);
    assert.match(six.code,/^\d{6}$/);
    assert.equal((await otp.verifyOtp(v2Email,six.code,'email','signin')).ok,false,'legacy cannot consume version2');
    for(const [code,type,purpose,dev,id] of [[six.code,'email','recovery',device,six.requestId],[six.code,'email','signin','foreign-device',six.requestId],[six.code,'email','signin',device,require('crypto').randomUUID()],['1234','email','signin',device,six.requestId]]){
      assert.equal((await otp.verifyOtpV2(v2Email,code,type,purpose,dev,id)).ok,false,'challenge/device/purpose/version bound');
    }
    const winners=await Promise.all([1,2].map(()=>otp.verifyOtpV2(v2Email,six.code,'email','signin',device,six.requestId)));
    assert.equal(winners.filter(r=>r.ok).length,1,'v2 has one atomic consume');
    const old=await otp.createOtp('v1-isolation@example.invalid','email','signin');
    assert.equal((await otp.verifyOtpV2('v1-isolation@example.invalid',old.code.padStart(6,'0'),'email','signin',device,old.requestId)).ok,false);
    assert.equal((await otp.verifyOtp('v1-isolation@example.invalid',old.code,'email','signin')).ok,true);
    const undelivered=await otp.createOtpV2('v2-undelivered@example.invalid','email','recovery',device);
    await otp.discardUndeliveredOtpV2('v2-undelivered@example.invalid','email',undelivered.requestId,'recovery',device);
    assert.equal((await otp.verifyOtpV2('v2-undelivered@example.invalid',undelivered.code,'email','recovery',device,undelivered.requestId)).ok,false);
    const capped=await otp.createOtpV2('v2-attempts@example.invalid','email','signin',device);
    for(let i=0;i<5;i++)assert.equal((await otp.verifyOtpV2('v2-attempts@example.invalid','000000','email','signin',device,capped.requestId)).ok,false);
    assert.equal((await otp.verifyOtpV2('v2-attempts@example.invalid',capped.code,'email','signin',device,capped.requestId)).ok,false,'v2 attempts capped at5');
    const replacementEmail='v2-replacement@example.invalid';
    const replacement=await otp.createOtpV2(replacementEmail,'email','replacement',device);
    assert.match(replacement.code,/^\d{6}$/);
    for(const purpose of ['signin','recovery'])assert.equal((await otp.verifyOtpV2(replacementEmail,replacement.code,'email',purpose,device,replacement.requestId)).ok,false);
    assert.equal((await otp.verifyOtp(replacementEmail,replacement.code,'email','replacement')).ok,false,'replacement cannot downgrade');
    assert.equal((await otp.verifyOtpV2(replacementEmail,replacement.code,'email','replacement','wrong-device',replacement.requestId)).ok,false);
    const replacementWinners=await Promise.all([1,2].map(()=>otp.verifyOtpV2(replacementEmail,replacement.code,'email','replacement',device,replacement.requestId)));
    assert.equal(replacementWinners.filter(r=>r.ok).length,1,'v2 replacement consumes exactly once');
    // Capacity rejection must happen before a challenge/attempt mutation, and
    // the exact already-issued code must remain usable when capacity returns.
    const { getOtpWorkAdmission, OtpCapacityError } = require('../src/services/otpWorkAdmission');
    const admission = getOtpWorkAdmission(), capacityEmail = 'capacity-fixture@example.invalid';
    const capacityCode = await otp.createOtpV2(capacityEmail, 'email', 'signin', device);
    const beforeCapacity = (await client.query('SELECT id,attempt_count,consumed_at,deleted FROM otp_requests ORDER BY id')).rows;
    let releaseCapacity;
    const held = new Promise(resolve => { releaseCapacity = resolve; });
    const occupied = Array.from({ length: admission.snapshot().work.maximum }, () => admission.run('work', () => held));
    try {
      await assert.rejects(otp.verifyOtpV2(capacityEmail, capacityCode.code, 'email', 'signin', device, capacityCode.requestId), OtpCapacityError);
      await assert.rejects(otp.createOtp('rejected-capacity@example.invalid', 'email', 'recovery'), OtpCapacityError);
      assert.deepEqual((await client.query('SELECT id,attempt_count,consumed_at,deleted FROM otp_requests ORDER BY id')).rows, beforeCapacity);
    } finally { releaseCapacity(); await Promise.all(occupied); }
    assert.equal((await otp.verifyOtpV2(capacityEmail, capacityCode.code, 'email', 'signin', device, capacityCode.requestId)).ok, true);
    console.log('PASS: OTP saturation preserves every existing challenge/attempt and allows the same code after capacity returns');
    console.log('PASS: v2 replacement six-digit/device/purpose/protocol binding and atomic one-winner consume');
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
