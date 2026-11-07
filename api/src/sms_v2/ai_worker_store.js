'use strict';

const { Pool } = require('pg');
const { resolveDatabaseTls } = require('../db_tls');

// Production database login for the AI drafts worker: the dedicated, least
// privilege `sms_ai_worker` role (db/setup_app_role.sql and
// db/supabase/migrations/20261116090000_sms_v2_ai_worker_role.sql). It replaces
// the private admin API login on hosts that do not run the admin console.
//
// The role is checked when the pool opens, in the same spirit as
// openRuleAdminStore: anything more powerful than the role the migrations
// created (superuser, BYPASSRLS, CREATEROLE, CREATEDB, replication, or one that
// inherits other roles' privileges) is refused. The public DATABASE_URL is
// never a fallback.
const WORKER_ROLE = 'sms_ai_worker';

async function openAiWorkerStore({ env = process.env, PoolClass = Pool } = {}) {
  if (!env.SMS_AI_WORKER_DATABASE_URL) throw new Error('SMS_AI_WORKER_DATABASE_URL is required');
  const tls = resolveDatabaseTls(env.SMS_AI_WORKER_DATABASE_URL, env);
  const pool = new PoolClass({ connectionString: tls.connectionString, ssl: tls.ssl, max: 1, application_name: 'pandapay-sms-v2-ai-worker' });
  try {
    const r = (await pool.query(
      `SELECT session_user AS name,
              r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolreplication OR r.rolinherit AS unsafe
         FROM pg_roles r WHERE r.rolname = session_user`,
    )).rows[0];
    if (r?.name !== WORKER_ROLE || r.unsafe !== false) throw new Error('Unsafe AI worker database identity');
    return { pool, transaction: (operation) => runTransaction(pool, operation) };
  } catch (error) {
    await pool.end();
    throw error;
  }
}

async function runTransaction(pool, operation) {
  if (typeof operation !== 'function') throw new TypeError('operation must be a function');
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query("SET LOCAL statement_timeout='5000ms'");
    await client.query("SET LOCAL lock_timeout='1000ms'");
    const result = await operation(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    try { await client.query('ROLLBACK'); } catch { /* connection cleanup only */ }
    throw error;
  } finally {
    client.release();
  }
}

module.exports = { openAiWorkerStore, WORKER_ROLE };
