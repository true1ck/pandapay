// src/db.js
// === SECURITY HARDENING: DATABASE ACCESS LOGGING ===
// === AWS SSM INTEGRATION ===
const { Pool } = require('pg');
const config = require('./config');
const { loggedQuery } = require('./middleware/dbAccessLogger');
const { getDbCredentials, buildDatabaseUrl } = require('./utils/awsSsm');

// Initialize database connection
let pool = null;
let dbInitPromise = null;

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
          console.log('✅ Using database credentials from AWS SSM Parameter Store');
          console.log(`   📊 Database: ${credentials.dbname || credentials.database || 'unknown'}`);
          console.log(`   🌐 Hostname: ${credentials.host || 'unknown'}`);
          console.log(`   👤 User: ${credentials.user || 'unknown'}`);
        } else {
          console.log('⚠️  AWS SSM not available, using DATABASE_URL from environment');
        }
      } catch (error) {
        console.error('❌ Error fetching credentials from SSM, using DATABASE_URL:', error.message);
        // Fall back to DATABASE_URL
      }
    } else {
      console.log('ℹ️  Using DATABASE_URL from environment (USE_AWS_SSM not enabled)');
    }

    pool = new Pool({
      connectionString,
      ssl: { rejectUnauthorized: false }
    });

    pool.on('error', (err) => {
      console.error('Unexpected PG client error', err);
      process.exit(-1);
    });

    // Test connection and log current user
    try {
      await pool.query('SELECT 1');
      console.log('✅ Database connection established');

      // Try to get connection details (may fail if user lacks permissions)
      try {
        const userResult = await pool.query('SELECT current_user, current_database(), inet_server_addr() as server_ip');
        const dbInfo = userResult.rows[0];
        console.log(`   👤 Connected as: ${dbInfo.current_user}`);
        console.log(`   📊 Database: ${dbInfo.current_database}`);
        // Show hostname from SSM (what we connected to) and server IP (actual server)
        if (credentials && credentials.host) {
          console.log(`   🌐 Hostname (from SSM): ${credentials.host}`);
        }
        if (dbInfo.server_ip) {
          console.log(`   🖥️  Server IP: ${dbInfo.server_ip}`);
        }
      } catch (infoErr) {
        // If we can't get user info, at least show what we know from credentials
        if (credentials) {
          console.log(`   👤 User: ${credentials.user || 'unknown'}`);
          console.log(`   📊 Database: ${credentials.dbname || credentials.database || 'unknown'}`);
          console.log(`   🌐 Hostname (from SSM): ${credentials.host || 'unknown'}`);
        }
      }
    } catch (err) {
      console.error('❌ Database connection failed:', err.message);
      throw err;
    }

    return pool;
  })();

  return dbInitPromise;
}

// Auto-initialize on module load
if (process.env.USE_AWS_SSM === 'true' || process.env.USE_AWS_SSM === '1') {
  initializeDb().catch((err) => {
    console.error('Failed to initialize database:', err);
    process.exit(1);
  });
} else {
  // For Supabase/direct DATABASE_URL connections
  console.log('ℹ️  Using DATABASE_URL from environment');

  pool = new Pool({
    connectionString: config.databaseUrl,
    ssl: { rejectUnauthorized: false }
  });

  pool.on('error', (err) => {
    console.error('Unexpected PG client error', err);
    process.exit(-1);
  });

  // Test connection on startup
  pool.query('SELECT current_user, current_database(), inet_server_addr() as host, inet_server_port() as port')
    .then((result) => {
      const { current_user, current_database, host, port } = result.rows[0];
      console.log('✅ Database connection established');
      console.log(`   👤 Connected as: ${current_user}`);
      console.log(`   📊 Database: ${current_database}`);
      if (host) console.log(`   🌐 Host: ${host}:${port}`);
    })
    .catch((err) => {
      console.error('❌ Database connection failed:', err.message);
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
    return loggedQuery(text, params, context);
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
};
``