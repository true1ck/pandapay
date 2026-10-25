'use strict';

const { performance } = require('node:perf_hooks');
const { validateRetentionPolicy } = require('./retentionPolicy');

const RETENTION_LOCK = Object.freeze([1646756207, 1048493242]);
// All identifiers are fixed in source. Policies only supply bounded integers.
const TABLES = Object.freeze({
  db_access_log: Object.freeze({ table: 'public.db_access_log', key: 'id', expiry: 'created_at' }),
  expired_abuse_state: Object.freeze({ table: 'public.auth_abuse_buckets', key: 'bucket_key', expiry: 'expires_at' }),
});

function statement(scope, apply) {
  const { table, key, expiry } = TABLES[scope];
  const eligible = `${expiry} < pg_catalog.clock_timestamp() - ($1::integer * INTERVAL '1 day')`;
  if (!apply) return `SELECT count(*)::integer AS count FROM (
    SELECT 1 FROM ONLY ${table} WHERE ${eligible}
    ORDER BY ${expiry}, ${key} LIMIT $2
  ) AS bounded_candidates`;
  return `WITH candidates AS (
    SELECT ${key} FROM ONLY ${table} WHERE ${eligible}
    ORDER BY ${expiry}, ${key} LIMIT $2 FOR UPDATE SKIP LOCKED
  ), removed AS (
    DELETE FROM ONLY ${table} AS target USING candidates
    WHERE target.${key} = candidates.${key}
      AND target.${eligible}
    RETURNING 1
  ) SELECT count(*)::integer AS count FROM removed`;
}

async function runRetention(client, policy, { apply = false, now = () => performance.now() } = {}) {
  validateRetentionPolicy(policy);
  if (typeof apply !== 'boolean' || typeof now !== 'function') throw new Error('Invalid retention run options');
  const result = {
    mode: apply ? 'apply' : 'dry_run', status: 'completed',
    scopes: policy.scopes.map(({ scope, days }) => ({ scope, retention_days: days, candidates: 0, deleted: 0, examined: false, more_possible: null })),
    batches: 0,
  };
  if (!policy.scopes.length) {
    if (apply) throw new Error('An explicit retention policy is required before applying');
    result.status = 'no_policy';
    return result;
  }
  if (!client || typeof client.query !== 'function') throw new Error('A dedicated retention database client is required');
  const started = now();
  let locked = false;
  let inTransaction = false;
  try {
    const lock = await client.query('SELECT pg_catalog.pg_try_advisory_lock($1, $2) AS locked', RETENTION_LOCK);
    locked = lock.rows?.[0]?.locked === true;
    if (!locked) { result.status = 'busy'; return result; }
    for (let index = 0; index < policy.scopes.length; index++) {
      const rule = policy.scopes[index];
      const summary = result.scopes[index];
      for (;;) {
        const remaining = Math.floor(policy.maxDurationMs - (now() - started));
        if (remaining < 1 || result.batches >= policy.maxBatches) {
          result.status = 'budget_exhausted';
          summary.more_possible = true;
          return result;
        }
        await client.query(apply ? 'BEGIN' : 'BEGIN READ ONLY');
        inTransaction = true;
        await client.query(`SET LOCAL statement_timeout = '${Math.min(5000, remaining)}ms'`);
        await client.query(`SET LOCAL lock_timeout = '${Math.min(1000, remaining)}ms'`);
        await client.query("SET LOCAL idle_in_transaction_session_timeout = '5000ms'");
        await client.query("SET LOCAL search_path = 'pg_catalog'");
        const rows = await client.query(statement(rule.scope, apply), [rule.days, policy.batchSize + (apply ? 0 : 1)]);
        const count = rows.rows?.[0]?.count;
        if (!Number.isInteger(count) || count < 0 || count > policy.batchSize + (apply ? 0 : 1)) throw new Error('Invalid retention result');
        await client.query('COMMIT');
        inTransaction = false;
        result.batches++;
        summary.examined = true;
        if (!apply) {
          summary.candidates = Math.min(policy.batchSize, count);
          summary.more_possible = count > policy.batchSize;
          break;
        }
        summary.deleted += count;
        // A short SKIP LOCKED batch cannot certify the absence of eligible
        // rows locked by another transaction. A later run may find more.
        summary.more_possible = count === policy.batchSize ? true : null;
        if (count < policy.batchSize) break;
      }
    }
    return result;
  } catch (error) {
    if (inTransaction) await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    // This is a dedicated, non-pooled maintenance connection. The CLI always
    // closes it; a failed unlock must never become an unnoticed pooled lock.
    if (locked) {
      const unlocked = await client.query('SELECT pg_catalog.pg_advisory_unlock($1, $2) AS unlocked', RETENTION_LOCK);
      if (unlocked.rows?.[0]?.unlocked !== true) throw new Error('Retention session lock could not be released');
    }
  }
}

module.exports = { runRetention, RETENTION_LOCK };
