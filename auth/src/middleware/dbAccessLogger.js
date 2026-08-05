// src/middleware/dbAccessLogger.js
// === SECURITY HARDENING: DATABASE ACCESS LOGGING ===
// Logs all database access for security auditing and compliance

/**
 * Database Access Logging
 * 
 * Logs all database queries for security auditing:
 * - Query type (SELECT, INSERT, UPDATE, DELETE)
 * - Table names accessed
 * - Timestamp
 * - User context (if available from request)
 * - IP address
 * - Query parameters (sanitized - no sensitive data)
 * 
 * Configuration:
 * - DB_ACCESS_LOGGING_ENABLED: Set to 'true' to enable logging (default: false)
 * - DB_ACCESS_LOG_LEVEL: 'all' (all queries) or 'sensitive' (only sensitive tables) (default: 'sensitive')
 * 
 * Sensitive tables (always logged if enabled):
 * - users
 * - otp_requests (primary OTP table from final_db.sql)
 * - refresh_tokens
 * - auth_audit
 */

const db = require('../db');

const LOGGING_ENABLED = process.env.DB_ACCESS_LOGGING_ENABLED === 'true' || process.env.DB_ACCESS_LOGGING_ENABLED === '1';
const LOG_LEVEL = process.env.DB_ACCESS_LOG_LEVEL || 'sensitive'; // 'all' or 'sensitive'

// Tables that contain sensitive data (always logged)
const SENSITIVE_TABLES = [
  'users',
  'otp_requests', // Primary OTP table (from final_db.sql)
  'refresh_tokens',
  'auth_audit',
  'user_devices',
];

/**
 * Extract table names from SQL query
 * @param {string} query - SQL query text
 * @returns {string[]} - Array of table names
 */
function extractTableNames(query) {
  const tables = [];
  const upperQuery = query.toUpperCase();
  
  // Match FROM, JOIN, UPDATE, INSERT INTO patterns
  const patterns = [
    /FROM\s+([a-z_]+)/gi,
    /JOIN\s+([a-z_]+)/gi,
    /UPDATE\s+([a-z_]+)/gi,
    /INSERT\s+INTO\s+([a-z_]+)/gi,
    /DELETE\s+FROM\s+([a-z_]+)/gi,
  ];

  patterns.forEach(pattern => {
    const matches = query.matchAll(pattern);
    for (const match of matches) {
      if (match[1]) {
        tables.push(match[1].toLowerCase());
      }
    }
  });

  return [...new Set(tables)]; // Remove duplicates
}

/**
 * Determine query type from SQL
 * @param {string} query - SQL query text
 * @returns {string} - Query type (SELECT, INSERT, UPDATE, DELETE, etc.)
 */
function getQueryType(query) {
  const upperQuery = query.trim().toUpperCase();
  if (upperQuery.startsWith('SELECT')) return 'SELECT';
  if (upperQuery.startsWith('INSERT')) return 'INSERT';
  if (upperQuery.startsWith('UPDATE')) return 'UPDATE';
  if (upperQuery.startsWith('DELETE')) return 'DELETE';
  if (upperQuery.startsWith('CREATE')) return 'CREATE';
  if (upperQuery.startsWith('ALTER')) return 'ALTER';
  if (upperQuery.startsWith('DROP')) return 'DROP';
  return 'OTHER';
}

/**
 * Sanitize query parameters (remove sensitive data)
 * @param {Array} params - Query parameters
 * @returns {Array} - Sanitized parameters (sensitive values replaced with '[REDACTED]')
 */
function sanitizeParams(params) {
  if (!params || !Array.isArray(params)) {
    return [];
  }

  return params.map(param => {
    if (typeof param === 'string') {
      // Check if it looks like a phone number
      if (/^\+?\d{10,15}$/.test(param)) {
        return '[REDACTED_PHONE]';
      }
      // Check if it looks like a token or hash
      if (param.length > 50) {
        return '[REDACTED_TOKEN]';
      }
      // Check if it looks like an encrypted value (format: iv:authTag:data)
      if (param.includes(':') && param.split(':').length === 3) {
        return '[REDACTED_ENCRYPTED]';
      }
    }
    // For other types, return as-is (numbers, booleans, etc.)
    return param;
  });
}

/**
 * Check if query should be logged
 * @param {string} query - SQL query text
 * @returns {boolean}
 */
function shouldLogQuery(query) {
  if (!LOGGING_ENABLED) {
    return false;
  }

  if (LOG_LEVEL === 'all') {
    return true;
  }

  // Log sensitive tables
  const tables = extractTableNames(query);
  return tables.some(table => SENSITIVE_TABLES.includes(table));
}

/**
 * Log database access
 * @param {Object} logData - Log data
 */
async function logDbAccess(logData) {
  if (!LOGGING_ENABLED) {
    return;
  }

  try {
    // Ensure db_access_log table exists
    await ensureDbAccessLogTable();

    const {
      query,
      queryType,
      tables,
      params,
      userId = null,
      ipAddress = null,
      userAgent = null,
      duration = null,
    } = logData;

    await db.query(
      `INSERT INTO db_access_log (
        query_type, tables_accessed, query_text, params_sanitized,
        user_id, ip_address, user_agent, duration_ms, created_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())`,
      [
        queryType,
        JSON.stringify(tables),
        query.substring(0, 1000), // Truncate long queries
        JSON.stringify(sanitizeParams(params)),
        userId,
        ipAddress,
        userAgent,
        duration,
      ]
    );
  } catch (err) {
    // Don't throw - logging failures should not break the application
    console.error('[dbAccessLogger] Failed to log database access:', err.message);
  }
}

/**
 * Ensure db_access_log table exists
 */
async function ensureDbAccessLogTable() {
  try {
    await db.query(`
      CREATE TABLE IF NOT EXISTS db_access_log (
        id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
        query_type VARCHAR(20) NOT NULL,
        tables_accessed JSONB,
        query_text TEXT NOT NULL,
        params_sanitized JSONB,
        user_id UUID,
        ip_address VARCHAR(45),
        user_agent TEXT,
        duration_ms INTEGER,
        created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      );

      CREATE INDEX IF NOT EXISTS idx_db_access_log_created_at ON db_access_log(created_at);
      CREATE INDEX IF NOT EXISTS idx_db_access_log_user_id ON db_access_log(user_id);
      CREATE INDEX IF NOT EXISTS idx_db_access_log_tables ON db_access_log USING GIN(tables_accessed);
      CREATE INDEX IF NOT EXISTS idx_db_access_log_query_type ON db_access_log(query_type);
    `);
  } catch (err) {
    // Table might already exist or database might not be ready
    // This is fine, the insert will handle it
  }
}

/**
 * Wrap database query with logging
 * @param {string} query - SQL query
 * @param {Array} params - Query parameters
 * @param {Object} context - Request context (optional)
 * @returns {Promise} - Query result
 */
async function loggedQuery(query, params = [], context = {}) {
  const startTime = Date.now();
  const queryType = getQueryType(query);
  const tables = extractTableNames(query);

  // Check if we should log this query
  if (!shouldLogQuery(query)) {
    // Execute query without logging
    return db.query(query, params);
  }

  try {
    // Execute query
    const result = await db.query(query, params);
    
    const duration = Date.now() - startTime;

    // Log access (fire and forget)
    logDbAccess({
      query,
      queryType,
      tables,
      params,
      userId: context.userId || null,
      ipAddress: context.ipAddress || null,
      userAgent: context.userAgent || null,
      duration,
    }).catch(err => {
      console.error('[dbAccessLogger] Failed to log (non-blocking):', err.message);
    });

    return result;
  } catch (err) {
    // Log failed query too
    const duration = Date.now() - startTime;
    logDbAccess({
      query,
      queryType,
      tables,
      params,
      userId: context.userId || null,
      ipAddress: context.ipAddress || null,
      userAgent: context.userAgent || null,
      duration,
      error: err.message,
    }).catch(() => {
      // Ignore logging errors
    });

    throw err;
  }
}

module.exports = {
  loggedQuery,
  logDbAccess,
  shouldLogQuery,
  isLoggingEnabled: () => LOGGING_ENABLED,
};

