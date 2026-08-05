// src/services/auditLogger.js
// === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
// Enhanced audit logging with risk levels and anomaly detection
//
// === SECURITY HARDENING: ACTIVE ALERTING ===
// Configuration:
//   - SECURITY_ALERT_WEBHOOK_URL: Webhook URL for security alerts (Slack, Discord, or custom)
//     Example: https://hooks.slack.com/services/YOUR/WEBHOOK/URL
//   - SECURITY_ALERT_MIN_LEVEL: Minimum risk level to trigger alerts
//     Values: 'INFO', 'SUSPICIOUS', 'HIGH_RISK' (default: 'HIGH_RISK')
//     Only events with risk level >= this value will trigger webhook alerts
//
// How it works:
//   - After an audit event is logged to DB, if risk_level >= SECURITY_ALERT_MIN_LEVEL,
//     a webhook alert is sent (if webhook URL is configured)
//   - Anomaly detection (checkAnomalies) can also flag events for alerting
//   - Alerting failures are logged but never break the main request flow

const db = require('../db');
const https = require('https');
const http = require('http');
const { URL } = require('url');

// === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
// Risk levels for audit events
const RISK_LEVELS = {
  INFO: 'INFO',
  SUSPICIOUS: 'SUSPICIOUS',
  HIGH_RISK: 'HIGH_RISK',
};

// === SECURITY HARDENING: ACTIVE ALERTING ===
// Configuration from environment variables
const SECURITY_ALERT_WEBHOOK_URL = process.env.SECURITY_ALERT_WEBHOOK_URL || null;
const SECURITY_ALERT_MIN_LEVEL = process.env.SECURITY_ALERT_MIN_LEVEL || 'HIGH_RISK';

// Risk level hierarchy for comparison (higher number = higher risk)
const RISK_LEVEL_HIERARCHY = {
  INFO: 1,
  SUSPICIOUS: 2,
  HIGH_RISK: 3,
};

/**
 * Map risk level to severity string for webhook payloads
 * @param {string} riskLevel - Risk level (INFO, SUSPICIOUS, HIGH_RISK)
 * @returns {string} Severity string (low, medium, high)
 */
function mapRiskLevelToSeverity(riskLevel) {
  const mapping = {
    [RISK_LEVELS.INFO]: 'low',
    [RISK_LEVELS.SUSPICIOUS]: 'medium',
    [RISK_LEVELS.HIGH_RISK]: 'high',
  };
  return mapping[riskLevel] || 'unknown';
}

/**
 * === SECURITY HARDENING: ACTIVE ALERTING ===
 * Check if a risk level meets the minimum threshold for alerting
 * @param {string} riskLevel - Risk level to check
 * @returns {boolean} True if risk level is high enough to trigger alert
 */
function shouldAlert(riskLevel) {
  const eventRisk = RISK_LEVEL_HIERARCHY[riskLevel] || 0;
  const minRisk = RISK_LEVEL_HIERARCHY[SECURITY_ALERT_MIN_LEVEL] || 3;
  return eventRisk >= minRisk;
}

// Alias for backward compatibility
const shouldTriggerAlert = shouldAlert;

/**
 * Log an authentication event with risk level
 * 
 * @param {Object} params
 * @param {string} params.userId - User ID (can be null for failed attempts)
 * @param {string} params.action - Action type (e.g., 'login', 'token_refresh', 'otp_request', 'otp_verify')
 * @param {string} params.status - Status ('success', 'failed', 'blocked')
 * @param {string} params.riskLevel - Risk level (INFO, SUSPICIOUS, HIGH_RISK)
 * @param {string} params.deviceId - Device identifier
 * @param {string} params.ipAddress - IP address
 * @param {string} params.userAgent - User agent
 * @param {Object} params.meta - Additional metadata
 */
async function logAuthEvent({
  userId = null,
  action,
  status,
  riskLevel = RISK_LEVELS.INFO,
  deviceId = null,
  ipAddress = null,
  userAgent = null,
  meta = {},
}) {
  try {
    // Ensure risk_level column exists (add if not present)
    await ensureRiskLevelColumn();

    const result = await db.query(
      `INSERT INTO auth_audit (
        user_id, action, status, risk_level, device_id, ip_address, user_agent, meta
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
      RETURNING id, created_at`,
      [
        userId,
        action,
        status,
        riskLevel,
        deviceId,
        ipAddress,
        userAgent,
        JSON.stringify(meta),
      ]
    );

    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Automatically trigger security alert for all SUSPICIOUS and HIGH_RISK events
    if (result.rows.length > 0) {
      const eventRecord = {
        id: result.rows[0].id,
        userId,
        action,
        status,
        riskLevel,
        deviceId,
        ipAddress,
        userAgent,
        meta,
        created_at: result.rows[0].created_at,
      };

      // Check for anomalies that might require alerting
      const anomalyAlert = await checkAnomalies(userId, action, ipAddress);
      
      // === SECURITY HARDENING: ACTIVE ALERTING ===
      // Automatically trigger alert if:
      // 1. Risk level meets minimum threshold (SUSPICIOUS or HIGH_RISK)
      // 2. OR anomaly detected
      const shouldTrigger = shouldAlert(riskLevel) || anomalyAlert?.shouldAlert;
      
      if (shouldTrigger) {
        // Fire and forget - don't await to avoid blocking main request flow
        sendSecurityAlert(eventRecord, anomalyAlert).catch(err => {
          console.error('[auditLogger] Alert trigger failed (non-blocking):', err.message);
        });
      }
    }
  } catch (err) {
    console.error('Failed to log auth event:', err);
    // Don't throw - audit logging should not break the main flow
  }
}

/**
 * Ensure risk_level column exists in auth_audit table
 */
async function ensureRiskLevelColumn() {
  try {
    await db.query(`
      DO $$
      BEGIN
        IF NOT EXISTS (
          SELECT 1 FROM information_schema.columns
          WHERE table_name = 'auth_audit' AND column_name = 'risk_level'
        ) THEN
          ALTER TABLE auth_audit ADD COLUMN risk_level VARCHAR(20) DEFAULT 'INFO';
          CREATE INDEX IF NOT EXISTS idx_auth_audit_risk_level ON auth_audit(risk_level);
        END IF;
      END $$;
    `);
  } catch (err) {
    // Column might already exist or table might not exist yet
    // This is fine, the insert will handle it
  }
}

/**
 * Log suspicious OTP verification attempts
 */
async function logSuspiciousOtpAttempt(identifier, ipAddress, userAgent, reason) {
  const isEmail = identifier.includes('@');
  const type = isEmail ? 'email' : 'phone';
  
  let maskedIdentifier = identifier;
  if (isEmail) {
    const [localPart, domain] = identifier.split('@');
    const maskedLocal = localPart.length > 3 ? localPart.substring(0, 3) + '***' : '***';
    maskedIdentifier = `${maskedLocal}@${domain}`;
  } else {
    maskedIdentifier = identifier.replace(/\d(?=\d{4})/g, '*');
  }

  await logAuthEvent({
    userId: null, // Identifier not yet linked to user
    action: 'otp_verify',
    status: 'failed',
    riskLevel: RISK_LEVELS.SUSPICIOUS,
    ipAddress,
    userAgent,
    meta: {
      [type]: maskedIdentifier,
      reason,
      message: 'Multiple failed OTP attempts detected',
    },
  });
}

/**
 * Log blocked login from disallowed IP
 */
async function logBlockedIpLogin(ipAddress, userAgent, userId = null) {
  await logAuthEvent({
    userId,
    action: 'login',
    status: 'blocked',
    riskLevel: RISK_LEVELS.HIGH_RISK,
    ipAddress,
    userAgent,
    meta: {
      reason: 'blocked_ip_range',
      message: 'Login attempt from blocked IP range',
    },
  });
}

/**
 * Log suspicious refresh event
 */
async function logSuspiciousRefresh(userId, deviceId, ipAddress, userAgent, riskScore, reasons) {
  await logAuthEvent({
    userId,
    action: 'token_refresh',
    status: 'success', // Token was issued, but suspicious
    riskLevel: riskScore >= 50 ? RISK_LEVELS.HIGH_RISK : RISK_LEVELS.SUSPICIOUS,
    deviceId,
    ipAddress,
    userAgent,
    meta: {
      risk_score: riskScore,
      risk_reasons: reasons,
      message: 'Token refresh from suspicious environment',
    },
  });
}

/**
 * Log step-up authentication requirement
 */
async function logStepUpAuthRequired(userId, action, ipAddress, userAgent) {
  await logAuthEvent({
    userId,
    action: `step_up_${action}`,
    status: 'failed',
    riskLevel: RISK_LEVELS.SUSPICIOUS,
    ipAddress,
    userAgent,
    meta: {
      reason: 'step_up_required',
      message: 'Sensitive action requires step-up authentication',
    },
  });
}

/**
 * Helper to check for anomaly patterns (for alerting)
 * This can be extended to query recent events and detect patterns
 * 
 * @param {string|null} userId - User ID
 * @param {string} action - Action type
 * @param {string|null} ipAddress - IP address
 * @returns {Promise<Object|null>} Object with shouldAlert flag and details, or null
 */
async function checkAnomalies(userId, action, ipAddress) {
  try {
    let shouldAlert = false;
    let anomalyDetails = null;

    // Example: Check for multiple failed attempts in short time
    if (action === 'otp_verify' && userId) {
      const result = await db.query(
        `SELECT COUNT(*) as count
         FROM auth_audit
         WHERE user_id = $1
           AND action = 'otp_verify'
           AND status = 'failed'
           AND risk_level IN ('SUSPICIOUS', 'HIGH_RISK')
           AND created_at > NOW() - INTERVAL '1 hour'`,
        [userId]
      );

      const failedCount = parseInt(result.rows[0]?.count || 0, 10);
      if (failedCount >= 5) {
        shouldAlert = true;
        anomalyDetails = {
          type: 'multiple_failed_otp',
          count: failedCount,
          window: '1 hour',
        };
        console.warn(`[ANOMALY] User ${userId} has ${failedCount} failed OTP attempts in last hour`);
      }
    }

    // Check for multiple HIGH_RISK events from same IP in short time
    if (ipAddress) {
      const ipResult = await db.query(
        `SELECT COUNT(*) as count
         FROM auth_audit
         WHERE ip_address = $1
           AND risk_level = 'HIGH_RISK'
           AND created_at > NOW() - INTERVAL '15 minutes'`,
        [ipAddress]
      );

      const highRiskCount = parseInt(ipResult.rows[0]?.count || 0, 10);
      if (highRiskCount >= 3) {
        shouldAlert = true;
        anomalyDetails = {
          ...anomalyDetails,
          type: anomalyDetails ? 'multiple_anomalies' : 'multiple_high_risk_ip',
          high_risk_count: highRiskCount,
          ip_address: ipAddress,
        };
        console.warn(`[ANOMALY] IP ${ipAddress} has ${highRiskCount} HIGH_RISK events in last 15 minutes`);
      }
    }

    return shouldAlert ? { shouldAlert: true, details: anomalyDetails } : null;
  } catch (err) {
    console.error('Error checking anomalies:', err);
    return null;
  }
}

/**
 * === SECURITY HARDENING: ACTIVE ALERTING ===
 * Send security alert via webhook (Slack, Discord, or custom webhook)
 * Automatically triggered for all SUSPICIOUS and HIGH_RISK events
 * 
 * @param {Object} eventRecord - Audit event record from database
 * @param {Object|null} anomalyAlert - Anomaly detection result (if any)
 * @param {number} retryCount - Internal retry counter (default: 0)
 * @returns {Promise<void>}
 */
async function sendSecurityAlert(eventRecord, anomalyAlert = null, retryCount = 0) {
  // === SECURITY HARDENING: ACTIVE ALERTING ===
  // If no webhook URL configured, log and return gracefully (no error)
  if (!SECURITY_ALERT_WEBHOOK_URL) {
    if (process.env.NODE_ENV !== 'test') {
      console.log('[SECURITY ALERT DISABLED] No SECURITY_ALERT_WEBHOOK_URL configured');
    }
    return;
  }

  try {
    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Extract and mask identifier (phone or email) from meta if present
    let maskedIdentifier = null;
    let identifierType = 'Identifier';
    if (eventRecord.meta?.phone) {
      maskedIdentifier = eventRecord.meta.phone;
      identifierType = 'Phone';
    } else if (eventRecord.meta?.email) {
      maskedIdentifier = eventRecord.meta.email;
      identifierType = 'Email';
    } else if (eventRecord.userId) {
      // Try to get identifier from user record (would need DB query, but for now use meta)
      maskedIdentifier = eventRecord.meta?.phone || eventRecord.meta?.email || null;
      if (eventRecord.meta?.phone) identifierType = 'Phone';
      if (eventRecord.meta?.email) identifierType = 'Email';
    }

    // Format timestamp
    const timestamp = eventRecord.created_at 
      ? new Date(eventRecord.created_at).toISOString()
      : new Date().toISOString();

    // Determine color based on risk level
    let color = '#36a64f'; // green (INFO)
    if (eventRecord.riskLevel === RISK_LEVELS.HIGH_RISK) {
      color = '#ff0000'; // red
    } else if (eventRecord.riskLevel === RISK_LEVELS.SUSPICIOUS) {
      color = '#ffa500'; // orange
    }

    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Build Slack-friendly JSON payload structure
    const payload = {
      text: '*SECURITY ALERT* 🚨',
      attachments: [
        {
          color: color,
          fields: [
            {
              title: 'Event',
              value: eventRecord.action || 'unknown',
              short: true,
            },
            {
              title: 'Risk Level',
              value: eventRecord.riskLevel || 'INFO',
              short: true,
            },
            ...(eventRecord.userId ? [{
              title: 'User',
              value: eventRecord.userId,
              short: true,
            }] : []),
            ...(maskedIdentifier ? [{
              title: identifierType,
              value: maskedIdentifier,
              short: true,
            }] : []),
            ...(eventRecord.ipAddress ? [{
              title: 'IP',
              value: eventRecord.ipAddress,
              short: true,
            }] : []),
            ...(eventRecord.userAgent ? [{
              title: 'User Agent',
              value: eventRecord.userAgent.length > 50 
                ? eventRecord.userAgent.substring(0, 50) + '...' 
                : eventRecord.userAgent,
              short: false,
            }] : []),
            {
              title: 'Status',
              value: eventRecord.status || 'unknown',
              short: true,
            },
            {
              title: 'When',
              value: timestamp,
              short: false,
            },
            ...(anomalyAlert?.details ? [{
              title: 'Anomaly',
              value: JSON.stringify(anomalyAlert.details),
              short: false,
            }] : []),
          ],
          footer: 'Farm Auth Service',
          ts: Math.floor(new Date(eventRecord.created_at || Date.now()).getTime() / 1000),
        },
      ],
      // Additional metadata for custom webhooks
      event_type: eventRecord.action,
      risk_level: eventRecord.riskLevel,
      user_id: eventRecord.userId || null,
      phone_number: identifierType === 'Phone' ? maskedIdentifier : null,
      email: identifierType === 'Email' ? maskedIdentifier : null,
      ip_address: eventRecord.ipAddress || null,
      user_agent: eventRecord.userAgent || null,
      timestamp: timestamp,
      device_id: eventRecord.deviceId || null,
      status: eventRecord.status,
      ...(anomalyAlert?.details ? { anomaly: anomalyAlert.details } : {}),
    };

    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Parse webhook URL
    const webhookUrl = new URL(SECURITY_ALERT_WEBHOOK_URL);
    const isHttps = webhookUrl.protocol === 'https:';
    const httpModule = isHttps ? https : http;

    // Prepare request options
    const postData = JSON.stringify(payload);
    const options = {
      hostname: webhookUrl.hostname,
      port: webhookUrl.port || (isHttps ? 443 : 80),
      path: webhookUrl.pathname + webhookUrl.search,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(postData),
      },
      timeout: 5000, // 5 second timeout
    };

    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Send webhook request with retry logic
    await new Promise((resolve, reject) => {
      const req = httpModule.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk; });
        res.on('end', () => {
          if (res.statusCode >= 200 && res.statusCode < 300) {
            resolve();
          } else {
            reject(new Error(`Webhook returned status ${res.statusCode}: ${data}`));
          }
        });
      });

      req.on('error', (err) => {
        reject(err);
      });

      req.on('timeout', () => {
        req.destroy();
        reject(new Error('Webhook request timeout'));
      });

      req.write(postData);
      req.end();
    });

    console.log(`[auditLogger] Security alert sent for ${eventRecord.riskLevel} event: ${eventRecord.action}`);
  } catch (err) {
    // === SECURITY HARDENING: ACTIVE ALERTING ===
    // Global FAILSAFE: Retry once after 3 seconds if webhook fails
    if (retryCount === 0) {
      console.warn(`[auditLogger] Webhook failed, retrying in 3 seconds... (${err.message})`);
      
      // Wait 3 seconds then retry once
      setTimeout(async () => {
        try {
          await sendSecurityAlert(eventRecord, anomalyAlert, 1);
        } catch (retryErr) {
          console.error('[auditLogger] Webhook retry also failed:', retryErr.message);
        }
      }, 3000);
      
      return; // Don't log error yet, wait for retry
    }
    
    // If retry also failed, log error but don't throw - alerting failures should not break the main flow
    console.error('[auditLogger] Failed to send security alert (after retry):', err.message);
    // Optionally log full error in development
    if (process.env.NODE_ENV === 'development') {
      console.error('[auditLogger] Alert error details:', err);
    }
  }
}

// Alias for backward compatibility
const triggerSecurityAlert = sendSecurityAlert;

module.exports = {
  logAuthEvent,
  logSuspiciousOtpAttempt,
  logBlockedIpLogin,
  logSuspiciousRefresh,
  logStepUpAuthRequired,
  checkAnomalies,
  sendSecurityAlert,
  shouldAlert,
  RISK_LEVELS,
};


