'use strict';

// Disposable loopback-only PostgreSQL fixture. This accepts only a fresh
// database named auth_abuse_test and drops the test table before returning.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const { RateLimitCapacityError, createPostgresRateLimitStore, toBucketKey } = require('../src/services/authAbuseStore');

const connectionString = process.env.AUTH_ABUSE_TEST_DATABASE_URL;
if (!connectionString) throw new Error('AUTH_ABUSE_TEST_DATABASE_URL is required for the disposable PostgreSQL fixture');
const target = new URL(connectionString);
if (!['127.0.0.1', 'localhost', '::1'].includes(target.hostname) || target.pathname !== '/auth_abuse_test') {
  throw new Error('Auth abuse PostgreSQL fixture requires a loopback database named auth_abuse_test');
}

async function main() {
  const pool = new Pool({ connectionString, max: 8, connectionTimeoutMillis: 3000 });
  let created = false;
  try {
    const existing = await pool.query(
      `SELECT count(*)::bigint AS relations FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'public' AND c.relkind IN ('r','p','v','m','S','f')
         AND c.relname NOT LIKE 'pg_%' AND c.relname <> 'sql_features'`,
    );
    if (Number(existing.rows[0].relations) !== 0) {
      throw new Error('Auth abuse fixture refuses a non-empty disposable database');
    }

    const migration = fs.readFileSync(path.join(__dirname, '../db/migrations/0004_auth_abuse_buckets.sql'), 'utf8');
    await pool.query(migration);
    created = true;
    const store = createPostgresRateLimitStore({
      poolProvider: async () => pool,
      hmacKey: Buffer.alloc(32, 11),
      capacity: 100,
      cleanupBatch: 20,
    });

    const rawKey = 'otp_req:email:synthetic@example.invalid:signin:10min';
    const counts = await Promise.all(Array.from({ length: 40 }, () => store.increment(rawKey, 60)));
    assert.equal(Math.min(...counts), 1);
    assert.equal(Math.max(...counts), 40);
    assert.equal(await store.get(rawKey), 40);
    const stored = await pool.query('SELECT bucket_key FROM auth_abuse_buckets');
    assert.equal(stored.rows.length, 1);
    assert.deepEqual(stored.rows[0].bucket_key, toBucketKey(rawKey, Buffer.alloc(32, 11)));

    const competingClaims = await Promise.all(Array.from({ length: 40 }, (_, index) =>
      store.claimMarker('otp_active:phone:+910000000001:signin', `request-${index}`, 60)));
    assert.equal(competingClaims.filter(Boolean).length, 1, 'one concurrent OTP creation owns the marker');
    const claimedMarker = await pool.query(
      `SELECT marker_value FROM auth_abuse_buckets
        WHERE bucket_key = $1 AND bucket_kind = 'marker'`,
      [toBucketKey('otp_active:phone:+910000000001:signin', Buffer.alloc(32, 11))],
    );
    const winningRequestId = claimedMarker.rows[0].marker_value;
    assert.equal(await store.compareDelete('otp_active:phone:+910000000001:signin', 'not-the-winner'), false);
    assert.equal(await store.exists('otp_active:phone:+910000000001:signin'), true);
    assert.equal(await store.compareDelete('otp_active:phone:+910000000001:signin', winningRequestId), true);
    assert.equal(await store.claimMarker('otp_active:phone:+910000000001:signin', 'after-release', 60), true);

    await store.setWithTTL('active:synthetic', 'request-a', 60);
    await store.setWithTTL('active:synthetic', 'request-b', 60);
    assert.equal(await store.compareDelete('active:synthetic', 'request-a'), false);
    assert.equal(await store.exists('active:synthetic'), true);
    assert.equal(await store.compareDelete('active:synthetic', 'request-b'), true);

    await store.increment('short-lived:one', 0.2);
    await store.increment('short-lived:two', 0.2);
    await new Promise(resolve => setTimeout(resolve, 350));
    assert.equal(await store.increment('after-expiry', 60), 1, 'bounded cleanup frees expired capacity');

    await store.increment('refresh-cleanup-race', 0.2);
    await new Promise(resolve => setTimeout(resolve, 250));
    await Promise.all([
      store.increment('refresh-cleanup-race', 2),
      store.increment('cleanup-trigger', 60),
    ]);
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(await store.get('refresh-cleanup-race'), 1, 'cleanup cannot delete a row whose TTL was concurrently refreshed');

    await pool.query('TRUNCATE auth_abuse_buckets');
    const boundedStore = createPostgresRateLimitStore({
      poolProvider: async () => pool,
      hmacKey: Buffer.alloc(32, 11),
      capacity: 2,
      cleanupBatch: 20,
    });
    await boundedStore.increment('capacity-one', 60);
    await boundedStore.increment('capacity-two', 60);
    await assert.rejects(boundedStore.increment('at-capacity', 60), RateLimitCapacityError);
    console.log('PASS: PostgreSQL concurrency, atomic marker claim, HMAC-only key storage, TTL, compare-delete, refresh/cleanup race and capacity refusal');
  } finally {
    if (created) await pool.query('DROP TABLE IF EXISTS auth_abuse_buckets CASCADE').catch(() => {});
    await pool.end();
  }
}

main().catch(() => {
  console.error('Synthetic auth abuse PostgreSQL fixture failed');
  process.exitCode = 1;
});
