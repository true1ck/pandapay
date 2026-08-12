const { Pool } = require('pg');
const config = require('./config');

const pool = new Pool({
  connectionString: config.databaseUrl,
  ssl: config.dbSslEnabled ? { rejectUnauthorized: false } : false,
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
