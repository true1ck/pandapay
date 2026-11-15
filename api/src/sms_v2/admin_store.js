'use strict';

const { Pool } = require('pg');
const { resolveDatabaseTls } = require('../db_tls');
const { createAdminDbHelpers } = require('../admin/server');
const { createPgStore } = require('./rules_store');

// Maintenance imports and jobs use the same authenticated database authority as
// private admin HTTP requests. The public DATABASE_URL is never a fallback.
async function openRuleAdminStore({ env = process.env, PoolClass = Pool } = {}) {
  if (!env.ADMIN_API_DATABASE_URL) throw new Error('ADMIN_API_DATABASE_URL is required');
  const tls = resolveDatabaseTls(env.ADMIN_API_DATABASE_URL, env);
  const pool = new PoolClass({ connectionString: tls.connectionString, ssl: tls.ssl, max: 1, application_name: 'pandapay-sms-v2-rule-maintenance' });
  // An idle connection the database drops (a pooler restart, a network blip) is reported on the pool as an
  // 'error' event; with no listener Node treats it as uncaught and ends the process. The pool opens a fresh
  // connection on the next query, so log the code only (never the message) and carry on.
  if (typeof pool.on === 'function') {
    pool.on('error', (error) => console.error('SMS v2 database pool error', (error && (error.code || error.name)) || 'Error'));
  }
  try {
    const r = (await pool.query("SELECT session_user AS name, r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolinherit AS unsafe FROM pg_roles r WHERE r.rolname=session_user")).rows[0];
    if (r?.name !== 'admin_api_runtime' || r.unsafe !== false) throw new Error('Unsafe private API database identity');
    const { withAdminClient } = createAdminDbHelpers(pool);
    return {
      pool,
      store: createPgStore({ withUserClient: (actorId, operation) => withAdminClient(actorId, 'learning.publish', operation) }),
    };
  } catch (error) {
    await pool.end();
    throw error;
  }
}

module.exports = { openRuleAdminStore };
