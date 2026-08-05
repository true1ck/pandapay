// src/routes/adminRoutes.js
// === ADMIN SECURITY VISUALIZER ===
// Admin API endpoints for security event monitoring
// Protected by: auth + adminAuth middleware

const express = require('express');
const db = require('../db');
const { logAuthEvent, RISK_LEVELS } = require('../services/auditLogger');

const router = express.Router();

// === SECURITY HARDENING: INPUT VALIDATION ===
// Valid risk levels for filtering
const VALID_RISK_LEVELS = [RISK_LEVELS.INFO, RISK_LEVELS.SUSPICIOUS, RISK_LEVELS.HIGH_RISK];

/**
 * Sanitize string input to prevent injection
 * @param {string} str - Input string
 * @returns {string} Sanitized string
 */
function sanitizeString(str) {
  if (typeof str !== 'string') return '';
  // Remove null bytes and trim
  return str.replace(/\0/g, '').trim();
}

/**
 * Sanitize number input
 * @param {any} value - Input value
 * @param {number} defaultValue - Default if invalid
 * @param {number} min - Minimum value
 * @param {number} max - Maximum value
 * @returns {number} Sanitized number
 */
function sanitizeNumber(value, defaultValue, min = 1, max = 1000) {
  const num = parseInt(value, 10);
  if (isNaN(num) || num < min || num > max) {
    return defaultValue;
  }
  return num;
}

/**
 * GET /admin/security-events
 * Retrieve security audit events with filtering and pagination
 * 
 * Query parameters:
 * - risk_level: Filter by risk level (INFO, SUSPICIOUS, HIGH_RISK) - optional
 * - limit: Number of results (1-1000, default: 200)
 * - offset: Pagination offset (default: 0)
 * - search: Search in user_id, phone (from meta), or ip_address - optional
 */
router.get('/security-events', async (req, res) => {
  try {
    // === SECURITY HARDENING: INPUT VALIDATION ===
    // Validate and sanitize query parameters
    const riskLevel = req.query.risk_level 
      ? sanitizeString(req.query.risk_level).toUpperCase()
      : null;
    
    // Validate risk level if provided
    if (riskLevel && !VALID_RISK_LEVELS.includes(riskLevel)) {
      return res.status(400).json({ 
        error: 'Invalid risk_level',
        valid_values: VALID_RISK_LEVELS 
      });
    }

    const limit = sanitizeNumber(req.query.limit, 200, 1, 1000);
    const offset = sanitizeNumber(req.query.offset, 0, 0, 100000);
    const search = req.query.search ? sanitizeString(req.query.search) : null;

    // === SECURITY HARDENING: SQL INJECTION PREVENTION ===
    // Build query with parameterized values only
    let query = `
      SELECT 
        aa.id,
        aa.user_id,
        aa.action,
        aa.status,
        aa.risk_level,
        aa.ip_address,
        aa.user_agent,
        aa.device_id,
        aa.meta,
        aa.created_at,
        u.phone_number
      FROM auth_audit aa
      LEFT JOIN users u ON aa.user_id = u.id
      WHERE 1=1
    `;
    
    const queryParams = [];
    let paramIndex = 1;

    // Add risk level filter
    if (riskLevel) {
      query += ` AND aa.risk_level = $${paramIndex}`;
      queryParams.push(riskLevel);
      paramIndex++;
    }

    // Add search filter (safe parameterized query)
    if (search) {
      query += ` AND (
        aa.user_id::text ILIKE $${paramIndex}
        OR aa.ip_address ILIKE $${paramIndex}
        OR u.phone_number ILIKE $${paramIndex}
        OR aa.meta::text ILIKE $${paramIndex}
      )`;
      queryParams.push(`%${search}%`);
      paramIndex++;
    }

    // Order by created_at descending (most recent first)
    query += ` ORDER BY aa.created_at DESC`;

    // Add limit and offset
    query += ` LIMIT $${paramIndex} OFFSET $${paramIndex + 1}`;
    queryParams.push(limit, offset);

    // Execute query
    const result = await db.query(query, queryParams);

    // === SECURITY HARDENING: OUTPUT SANITIZATION ===
    // Sanitize all fields before returning
    const events = result.rows.map(row => {
      // Extract phone from meta if not in users table
      let phone = row.phone_number;
      if (!phone && row.meta && typeof row.meta === 'object') {
        phone = row.meta.phone || null;
      }
      
      // Mask phone number for security (keep last 4 digits)
      const maskedPhone = phone 
        ? phone.replace(/\d(?=\d{4})/g, '*')
        : null;

      return {
        id: String(row.id || ''),
        user_id: row.user_id ? String(row.user_id) : null,
        action: sanitizeString(row.action || ''),
        status: sanitizeString(row.status || ''),
        risk_level: sanitizeString(row.risk_level || RISK_LEVELS.INFO),
        ip_address: sanitizeString(row.ip_address || ''),
        user_agent: sanitizeString(row.user_agent || ''),
        device_id: row.device_id ? sanitizeString(row.device_id) : null,
        phone: maskedPhone,
        meta: row.meta || {},
        created_at: row.created_at ? new Date(row.created_at).toISOString() : null,
      };
    });

    // Get total count for pagination
    let countQuery = `
      SELECT COUNT(*) as total
      FROM auth_audit aa
      LEFT JOIN users u ON aa.user_id = u.id
      WHERE 1=1
    `;
    const countParams = [];
    let countParamIndex = 1;

    if (riskLevel) {
      countQuery += ` AND aa.risk_level = $${countParamIndex}`;
      countParams.push(riskLevel);
      countParamIndex++;
    }

    if (search) {
      countQuery += ` AND (
        aa.user_id::text ILIKE $${countParamIndex}
        OR aa.ip_address ILIKE $${countParamIndex}
        OR u.phone_number ILIKE $${countParamIndex}
        OR aa.meta::text ILIKE $${countParamIndex}
      )`;
      countParams.push(`%${search}%`);
    }

    const countResult = await db.query(countQuery, countParams);
    const total = parseInt(countResult.rows[0]?.total || 0, 10);

    // Get statistics
    const statsQuery = `
      SELECT 
        COUNT(*) as total_events,
        COUNT(*) FILTER (WHERE risk_level = 'HIGH_RISK') as high_risk_count,
        COUNT(*) FILTER (WHERE risk_level = 'SUSPICIOUS') as suspicious_count,
        COUNT(*) FILTER (WHERE risk_level = 'INFO') as info_count
      FROM auth_audit
      WHERE created_at > NOW() - INTERVAL '24 hours'
    `;
    const statsResult = await db.query(statsQuery);
    const stats = statsResult.rows[0] || {
      total_events: 0,
      high_risk_count: 0,
      suspicious_count: 0,
      info_count: 0,
    };

    // === SECURITY HARDENING: AUDIT LOGGING ===
    // Log admin access to security events
    await logAuthEvent({
      userId: req.user.id,
      action: 'admin_view_security_events',
      status: 'success',
      riskLevel: RISK_LEVELS.INFO,
      ipAddress: req.ip || req.connection.remoteAddress,
      userAgent: req.headers['user-agent'],
      meta: {
        filters: { risk_level: riskLevel, search, limit, offset },
      },
    }).catch(err => {
      // Don't break the response if logging fails
      console.error('Failed to log admin access:', err);
    });

    return res.json({
      events,
      pagination: {
        total,
        limit,
        offset,
        has_more: offset + limit < total,
      },
      stats: {
        last_24h: {
          total: parseInt(stats.total_events, 10),
          high_risk: parseInt(stats.high_risk_count, 10),
          suspicious: parseInt(stats.suspicious_count, 10),
          info: parseInt(stats.info_count, 10),
        },
      },
    });
  } catch (err) {
    console.error('[adminRoutes] Error fetching security events:', err);
    
    // === SECURITY HARDENING: AUDIT LOGGING ===
    // Log admin access error
    await logAuthEvent({
      userId: req.user?.id,
      action: 'admin_view_security_events',
      status: 'failed',
      riskLevel: RISK_LEVELS.SUSPICIOUS,
      ipAddress: req.ip || req.connection.remoteAddress,
      userAgent: req.headers['user-agent'],
      meta: {
        error: err.message,
      },
    }).catch(() => {
      // Ignore logging errors
    });

    return res.status(500).json({ error: 'Internal server error' });
  }
});

module.exports = router;

