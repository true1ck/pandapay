const { Pool } = require('pg');
const config = require('./config');
const { resolveDatabaseTls } = require('./db_tls');
const { safeErrorCode } = require('./safeErrorCode');
const { createPartnerWebhookPool, createImapWorkerPool,createAccountLifecyclePool,createSharedFeedbackPool,createNotificationOutboxPool } = require('./service_pools');
const partnerWebhookPool = createPartnerWebhookPool(config.partnerWebhookDatabaseUrl);
const imapWorkerPool = createImapWorkerPool(config.imapPollDatabaseUrl);
const accountLifecyclePool=createAccountLifecyclePool(config.accountLifecycleEnabled?config.accountLifecycleDatabaseUrl:null);
const sharedFeedbackPool=createSharedFeedbackPool(config.sharedFeedbackAdmissionEnabled?config.sharedFeedbackDatabaseUrl:null);
const notificationOutboxPool=createNotificationOutboxPool(config.notificationOutboxEnabled?config.notificationOutboxDatabaseUrl:null);
if(config.accountLifecycleEnabled&&!accountLifecyclePool)throw new Error('Dedicated account lifecycle database required');
const {ASSERT_ACCESS_SQL}=require('./account_lifecycle_routes');
const lifecycleJournalRuntime=require('./account_lifecycle_journal_runtime').createJournalRuntime({pool:accountLifecyclePool});

// Resolve and validate TLS before the pool can be created. This also removes
// pg connection-string TLS parameters only after translating supported CA
// settings, so sslmode cannot replace the verified ssl object below.
const databaseTls = resolveDatabaseTls(config.databaseUrl);

const pool = new Pool({
  connectionString: databaseTls.connectionString,
  ssl: databaseTls.ssl,
  max: config.dbPoolMax,
  idleTimeoutMillis: config.dbIdleTimeoutMs,
  connectionTimeoutMillis: config.dbConnectionTimeoutMs,
});

pool.on('error', (err) => {
  // Keep the process alive so the readiness probe can recover after a
  // transient idle-client failure. In-flight requests still receive their
  // own database error and the supervisor can restart only if readiness stays
  // unavailable.
  console.error('Unexpected PG pool error', safeErrorCode(err));
});

/**
 * Runs `fn(client)` inside a transaction with `app.user_id` set as a
 * transaction-local session variable — this is the RLS session context
 * that db/supabase/migrations/0011_rls_policies.sql's pandapay.uid() reads.
 * SET LOCAL only survives inside the transaction, so a client that leaks
 * back to the pool never carries someone else's identity into the next
 * request that borrows it.
 *
 * `userId` may be null (unauthenticated request) — pandapay.uid() then
 * returns null and every owner-scoped RLS policy denies by construction.
 */
async function withUserClient(userId, fn) {
  const client = await pool.connect();
  let discardConnection;
  try {
    await client.query('BEGIN');
    // Keep every request bounded at the database too. Without a statement
    // deadline a stalled report query can keep the HTTP request, transaction,
    // and pool connection alive indefinitely, which is exactly the failure
    // mode that presents as an endless skeleton on mobile.
    await client.query(
      "SELECT set_config('statement_timeout', $1, true)",
      [`${config.dbStatementTimeoutMs}ms`],
    );
    if (userId) {
      await client.query("SELECT set_config('app.user_id', $1, true)", [userId]);
      if(config.accountLifecycleEnabled){await client.query(ASSERT_ACCESS_SQL,[userId]);await lifecycleJournalRuntime.readiness();}
    }
    if (process.env.SMS_LEARNING_HMAC_KEY?.length >= 32) {
      await client.query("SELECT set_config('app.sms_learning_hmac_key', $1, true)", [process.env.SMS_LEARNING_HMAC_KEY]);
    }
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    try { await client.query('ROLLBACK'); } catch(error) { discardConnection=error; }
    throw err;
  } finally {
    client.release(discardConnection);
  }
}

module.exports = { lifecycleJournalRuntime, pool, withUserClient, partnerWebhookPool, imapWorkerPool,accountLifecyclePool,sharedFeedbackPool,notificationOutboxPool };
