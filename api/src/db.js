const { Pool } = require('pg');
const config = require('./config');

const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.dbSslEnabled ? { rejectUnauthorized: false } : false,
  max: config.dbPoolMax,
  idleTimeoutMillis: config.dbIdleTimeoutMs,
  connectionTimeoutMillis: config.dbConnectionTimeoutMs,
});

pool.on('error', (err) => {
  // Keep the process alive so the readiness probe can recover after a
  // transient idle-client failure. In-flight requests still receive their
  // own database error and the supervisor can restart only if readiness stays
  // unavailable.
  console.error('Unexpected PG pool error', err.message);
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
    }
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

module.exports = { pool, withUserClient };
