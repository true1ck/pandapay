'use strict';

const { Pool } = require('pg');
const { createAdminApiApp } = require('./app');
const { routeManifest } = require('./route_manifest');
const { registerAdminRoutes } = require('./routes');
const { resolveDatabaseTls } = require('../db_tls');

const INTROSPECTION_PATH = '/internal/admin/session/introspect';

function requiredString(env, name) {
  const value = env[name];
  if (typeof value !== 'string' || value.length === 0) throw new Error(`${name} is required`);
  return value;
}

function parseConfig(env = process.env) {
  if (env.ADMIN_API_ENABLED !== 'true') throw new Error('ADMIN_API_ENABLED must be true for the private API entrypoint');
  const databaseUrl = requiredString(env, 'ADMIN_API_DATABASE_URL');
  const serviceSecret = requiredString(env, 'ADMIN_INTROSPECTION_SERVICE_SECRET');
  if (Buffer.byteLength(serviceSecret, 'utf8') < 32) throw new Error('ADMIN_INTROSPECTION_SERVICE_SECRET must be at least 32 bytes');
  const rawEndpoint = requiredString(env, 'ADMIN_INTROSPECTION_BASE_URL');
  const endpoint = new URL(rawEndpoint);
  if (endpoint.username || endpoint.password || endpoint.search || endpoint.hash || endpoint.pathname !== '/') {
    throw new Error('ADMIN_INTROSPECTION_BASE_URL must be a fixed service origin');
  }
  const localHttp = endpoint.protocol === 'http:' && (['127.0.0.1', '[::1]', 'localhost'].includes(endpoint.hostname) ||
    (env.ADMIN_CONTAINER_NETWORK === 'true' && endpoint.hostname === 'admin-gateway'));
  if (endpoint.protocol !== 'https:' && !localHttp) throw new Error('Admin introspection requires HTTPS except on loopback');
  const port = Number(env.ADMIN_API_PORT || 4001);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('ADMIN_API_PORT is invalid');
  const host = env.ADMIN_API_HOST || '127.0.0.1';
  if (!['127.0.0.1','::1'].includes(host) && !(env.ADMIN_CONTAINER_NETWORK === 'true' && host === '0.0.0.0')) throw new Error('Private admin API bind is invalid');
  return Object.freeze({ databaseUrl, serviceSecret, introspectionUrl: new URL(INTROSPECTION_PATH, endpoint).toString(), host, port });
}

function createIntrospectionClient({ url, serviceSecret, fetchImpl = fetch }) {
  return async function introspectAdminSession(token) {
    const response = await fetchImpl(url, {
      method: 'POST',
      redirect: 'error',
      signal: AbortSignal.timeout(2500),
      headers: {
        'content-type': 'application/json',
        'x-admin-service-secret': serviceSecret,
      },
      body: JSON.stringify({ token }),
    });
    if (response.status === 401 || response.status === 403) return { active: false };
    if (!response.ok) throw new Error('admin_introspection_unavailable');
    const chunks = [];
    let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 4096) {
        throw new Error('admin_introspection_response_too_large');
      }
      chunks.push(chunk);
    }
    const raw = Buffer.concat(chunks).toString('utf8');
    let result;
    try { result = JSON.parse(raw); } catch { throw new Error('invalid_admin_introspection_response'); }
    return result;
  };
}

function createAdminDbHelpers(pool) {
  async function loadPermissions({userId: actorId}) {
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE pandapay_admin_api');
      await client.query("SET LOCAL statement_timeout='5000ms'");
      await client.query("SET LOCAL lock_timeout='1000ms'");
      await client.query("SELECT set_config('pandapay.admin_actor', $1, true)", [actorId]);
      const member = await client.query(
        'SELECT id, email::text AS email, role, is_active FROM public.admin_users WHERE id = $1',
        [actorId]
      );
      const row = member.rows[0];
      if (!row || row.is_active !== true || row.id !== actorId) {
        await client.query('ROLLBACK');
        return { active: false, userId: actorId, role: null, email: null, permissions: [] };
      }
      const result = await client.query(
        'SELECT permission FROM public.admin_role_permissions WHERE role = $1 ORDER BY permission',
        [row.role]
      );
      await client.query('COMMIT');
      return {
        active: true,
        userId: row.id,
        role: row.role,
        email: row.email,
        permissions: result.rows.map(item => item.permission),
      };
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch { /* connection cleanup only */ }
      throw error;
    } finally {
      client.release();
    }
  }

  async function withAdminClient(actorId, permission, operation) {
    if (typeof operation !== 'function') throw new TypeError('admin operation must be a function');
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      await client.query('SET LOCAL ROLE pandapay_admin_api');
      await client.query("SET LOCAL statement_timeout='5000ms'");
      await client.query("SET LOCAL lock_timeout='1000ms'");
      await client.query("SELECT set_config('pandapay.admin_actor', $1, true)", [actorId]);
      await client.query("SELECT set_config('pandapay.admin_permission', $1, true)", [permission]);
      await client.query("SELECT set_config('app.user_id', $1, true)", [actorId]);
      const access = await client.query('SELECT pandapay.admin_has_permission($1) AS allowed', [permission]);
      if (access.rows[0]?.allowed !== true) {
        const error = new Error('admin_permission_denied');
        error.code = 'ADMIN_PERMISSION_DENIED';
        throw error;
      }
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

  return Object.freeze({ loadPermissions, withAdminClient });
}

function createAdminRuntime({ env = process.env, PoolClass = Pool, fetchImpl = fetch, registerRoutes: register = registerAdminRoutes } = {}) {
  const config = parseConfig(env);
  const tls = resolveDatabaseTls(config.databaseUrl);
  const pool = new PoolClass({ connectionString: tls.connectionString, ssl: tls.ssl, max: 2, idleTimeoutMillis: 10_000, connectionTimeoutMillis: 3_000, query_timeout: 5_000, application_name: 'pandapay-admin-api' });
  const db = createAdminDbHelpers(pool);
  const app = createAdminApiApp({
    readiness: async () => {
      const r=(await pool.query("SELECT session_user AS name, r.rolsuper OR r.rolbypassrls OR r.rolcreaterole OR r.rolcreatedb OR r.rolinherit AS unsafe FROM pg_roles r WHERE r.rolname=session_user")).rows[0];
      if(r?.name!=='admin_api_runtime'||r.unsafe!==false) throw new Error('Unsafe private API database identity');
    },
    introspectAdminSession: createIntrospectionClient({ url: config.introspectionUrl, serviceSecret: config.serviceSecret, fetchImpl }),
    loadPermissions: db.loadPermissions,
    withAdminClient: db.withAdminClient,
    registerRoutes: register,
    routeManifest,
  });
  return Object.freeze({ app, pool, config });
}

async function startAdminApi(options = {}) {
  const runtime = createAdminRuntime(options);
  const server = await new Promise((resolve, reject) => {
    const listening = runtime.app.listen(runtime.config.port, runtime.config.host, () => resolve(listening));
    listening.once('error', reject);
  });
  return Object.freeze({
    ...runtime,
    server,
    async close() {
      await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
      await runtime.pool.end();
    },
  });
}

if (require.main === module) {
  startAdminApi().then(runtime => {
    console.log(`private pandapay admin API listening on ${runtime.config.host}:${runtime.config.port}`);
    const stop = () => runtime.close().then(() => process.exit(0), () => process.exit(1));
    process.once('SIGTERM', stop);
    process.once('SIGINT', stop);
  }).catch(() => {
    console.error('private pandapay admin API startup failed');
    process.exitCode = 1;
  });
}

module.exports = { INTROSPECTION_PATH, parseConfig, createIntrospectionClient, createAdminDbHelpers, createAdminRuntime, startAdminApi };
