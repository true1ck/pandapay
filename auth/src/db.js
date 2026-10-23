const { safeErrorCode } = require('./utils/safeErrorCode');
// src/db.js
// === SECURITY HARDENING: DATABASE ACCESS LOGGING ===
// === AWS SSM INTEGRATION ===
const { Pool } = require('pg');
const config = require('./config');
const { loggedQuery } = require('./middleware/dbAccessLogger');
const { getDbCredentials, buildDatabaseUrl } = require('./utils/awsSsm');
const { resolveDatabaseTls } = require('./utils/dbTls');

// Initialize database connection
let pool = null;
let dbInitPromise = null;
const isTestEnvironment = process.env.NODE_ENV === 'test';

/**
 * Initialize database connection
 * Tries AWS SSM Parameter Store first, falls back to DATABASE_URL
 */
async function initializeDb() {
  if (pool) {
    return pool; // Already initialized
  }

  if (dbInitPromise) {
    return dbInitPromise; // Initialization in progress
  }

  dbInitPromise = (async () => {
    let connectionString = config.databaseUrl;

    // Try to get credentials from AWS SSM Parameter Store
    // Only if USE_AWS_SSM is explicitly set to 'true'
    let credentials = null;
    if (process.env.USE_AWS_SSM === 'true' || process.env.USE_AWS_SSM === '1') {
      try {
        credentials = await getDbCredentials();
        if (credentials) {
          connectionString = buildDatabaseUrl(credentials);
        } else {
          console.warn('AWS SSM credentials unavailable; using configured database URL');
        }
      } catch (error) {
        console.error('Database credential lookup failed; using configured database URL', safeErrorCode(error));
        // Fall back to DATABASE_URL
      }
    } else {
    }

    // Apply the same verified TLS policy to SSM and ordinary DATABASE_URL
    // connections. Resolve before constructing a pool so bad production trust
    // settings fail closed during startup.
    const databaseTls = resolveDatabaseTls(connectionString);
    pool = new Pool({
      connectionString: databaseTls.connectionString,
      ssl: databaseTls.ssl,
      max: config.dbPoolMax,
      idleTimeoutMillis: config.dbIdleTimeoutMs,
      connectionTimeoutMillis: config.dbConnectionTimeoutMs,
    });

    pool.on('error', (err) => {
      // A failure on an idle pooled connection is recoverable: pg removes
      // that client and creates another on demand. Readiness and request
      // errors report an actual outage without terminating healthy workers.
      console.error('Unexpected PostgreSQL pool error', safeErrorCode(err));
    });

    // Test connection and log current user
    try {
      await pool.query('SELECT 1');
      console.info('Auth database connection established');
    } catch (err) {
      console.error('Auth database connection failed', safeErrorCode(err));
      throw err;
    }

    return pool;
  })();

  return dbInitPromise;
}

// Auto-initialize on module load
if (isTestEnvironment) {
  // Unit tests that only exercise token/configuration logic must not open a
  // real database connection or terminate the test process on connection
  // failure. Tests that need SQL should inject/mock the pool explicitly.
} else if (process.env.USE_AWS_SSM === 'true' || process.env.USE_AWS_SSM === '1') {
  initializeDb().catch((err) => {
    console.error('Auth database initialization failed', safeErrorCode(err));
    process.exit(1);
  });
} else {
  // For Supabase/direct DATABASE_URL connections
  const databaseTls = resolveDatabaseTls(config.databaseUrl);
  pool = new Pool({
    connectionString: databaseTls.connectionString,
    ssl: databaseTls.ssl,
    max: config.dbPoolMax,
    idleTimeoutMillis: config.dbIdleTimeoutMs,
    connectionTimeoutMillis: config.dbConnectionTimeoutMs,
  });

  pool.on('error', (err) => {
    // Match the SSM-backed pool behavior above. An idle client failure should
    // not take down the whole auth service; /ready reports database outages.
    console.error('Unexpected PostgreSQL pool error', safeErrorCode(err));
  });

  // Test connection on startup
  pool.query('SELECT 1')
    .then((result) => {
      console.info('Auth database connection established');
    })
    .catch((err) => {
      console.error('Auth database connection failed', safeErrorCode(err));
      process.exit(1);
    });
}

/**
 * Get database pool (ensures initialization if using SSM)
 * @returns {Promise<Pool>} Database pool
 */
async function getPool() {
  if (process.env.USE_AWS_SSM === 'true' || process.env.USE_AWS_SSM === '1') {
    if (!pool) {
      await initializeDb();
    }
  }
  return pool;
}

async function closeDb() {
  if (dbInitPromise) {
    await dbInitPromise.catch(() => {});
  }
  if (pool) {
    const currentPool = pool;
    pool = null;
    dbInitPromise = null;
    await currentPool.end();
  }
}

/**
 * Execute database query with optional logging and context
 * @param {string} text - SQL query
 * @param {Array} params - Query parameters
 * @param {Object} context - Request context for logging (optional)
 *   - userId: User ID from request
 *   - ipAddress: Client IP address
 *   - userAgent: User agent string
 * @returns {Promise} - Query result
 */
async function query(text, params = [], context = {}) {
  // Ensure pool is initialized
  const dbPool = await getPool();

  // Use logged query if logging is enabled, otherwise use direct query
  const DB_ACCESS_LOGGING_ENABLED = process.env.DB_ACCESS_LOGGING_ENABLED === 'true' || process.env.DB_ACCESS_LOGGING_ENABLED === '1';

  if (DB_ACCESS_LOGGING_ENABLED) {
    return loggedQuery(text, params, context, dbPool);
  }

  return dbPool.query(text, params);
}

/**
 * Helper to create context from Express request
 * @param {Object} req - Express request object
 * @returns {Object} - Context object for database logging
 */
function createContextFromRequest(req) {
  return {
    userId: req.user?.id || null,
    ipAddress: req.ip || req.connection?.remoteAddress || null,
    userAgent: req.headers['user-agent'] || null,
  };
}

module.exports = {
  query,
  get pool() {
    // For backward compatibility, return pool synchronously if available
    // Otherwise, return a promise that resolves to the pool
    if (pool) {
      return pool;
    }
    if (process.env.USE_AWS_SSM === 'true' || process.env.USE_AWS_SSM === '1') {
      return initializeDb();
    }
    return pool;
  },
  createContextFromRequest,
  initializeDb, // Export for explicit initialization if needed
  closeDb,
};
``
