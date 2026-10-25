const { safeErrorCode } = require('../utils/safeErrorCode');
// src/middleware/dbAccessLogger.js
// === SECURITY HARDENING: DATABASE ACCESS LOGGING ===
// Optional best-effort database access metadata; not a durable audit ledger.

/**
 * Database Access Logging
 * 
 * Records selected query metadata when explicitly enabled:
 * - Query type (SELECT, INSERT, UPDATE, DELETE)
 * - Table names accessed
 * - Timestamp
 * - User context (if available from request)
 * - IP address
 * - Parameter count only; query text and parameter values are omitted
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
 * @returns {Object} - Bounded parameter count, without any values
 */
function sanitizeParams(params) {
  if (!params || !Array.isArray(params)) {
    return { count: 0, truncated: false };
  }

  // A shape denylist leaks short tokens, emails, nested JSON and numbers.
  // Retain only a bounded count, never the values or their types.
  return { count: Math.min(params.length, 1000), truncated: params.length > 1000 };
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
async function logDbAccess(logData, executor) {
  if (!LOGGING_ENABLED || !executor || typeof executor.query !== 'function') {
    return;
  }

  try {
    const {
      queryType,
      tables,
      params,
      userId = null,
      ipAddress = null,
      userAgent = null,
      duration = null,
    } = logData;

    await executor.query(
      `INSERT INTO public.db_access_log (
        query_type, tables_accessed, query_text, params_sanitized,
        user_id, ip_address, user_agent, duration_ms, created_at
      ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())`,
      [
        queryType,
        JSON.stringify(tables),
        '[query omitted]',
        JSON.stringify(sanitizeParams(params)),
        userId,
        ipAddress,
        userAgent,
        duration,
      ]
    );
  } catch (err) {
    // Don't throw - logging failures should not break the application
    console.error('Database access audit write failed', safeErrorCode(err));
  }
}

/**
 * Wrap database query with logging
 * @param {string} query - SQL query
 * @param {Array} params - Query parameters
 * @param {Object} context - Request context (optional)
 * @returns {Promise} - Query result
 */
async function loggedQuery(query, params = [], context = {}, executor) {
  if (!executor || typeof executor.query !== 'function') {
    throw new TypeError('loggedQuery requires a database executor');
  }
  const queryText = typeof query === 'string' ? query : query?.text;
  if (typeof queryText !== 'string') return executor.query(query, params);
  const queryParams = Array.isArray(query?.values) ? query.values : params;
  const startTime = Date.now();
  const queryType = getQueryType(queryText);
  const tables = extractTableNames(queryText);

  // Check if we should log this query
  if (!shouldLogQuery(queryText)) {
    // Execute query without logging
    return executor.query(query, params);
  }

  try {
    // Execute query
    const result = await executor.query(query, params);
    
    const duration = Date.now() - startTime;

    // Log access (fire and forget)
    logDbAccess({
      query: queryText,
      queryType,
      tables,
      params: queryParams,
      userId: context.userId || null,
      ipAddress: context.ipAddress || null,
      userAgent: context.userAgent || null,
      duration,
    }, executor).catch(err => {
    console.error('Non-blocking database audit write failed', safeErrorCode(err));
    });

    return result;
  } catch (err) {
    // Log failed query too
    const duration = Date.now() - startTime;
    logDbAccess({
      query: queryText,
      queryType,
      tables,
      params: queryParams,
      userId: context.userId || null,
      ipAddress: context.ipAddress || null,
      userAgent: context.userAgent || null,
      duration,
    }, executor).catch(() => {
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

