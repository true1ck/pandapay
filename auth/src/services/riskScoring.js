// src/services/riskScoring.js
// === SECURITY HARDENING: IP/DEVICE RISK ===
// Basic risk scoring for IP addresses and device fingerprinting

const crypto = require('crypto');
const db = require('../db');

// === SECURITY HARDENING: IP/DEVICE RISK ===
// Configuration for suspicious IP ranges
// Can be set via environment variable as comma-separated CIDR blocks
// Example: BLOCKED_IP_RANGES=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16
const BLOCKED_IP_RANGES = (process.env.BLOCKED_IP_RANGES || '')
  .split(',')
  .map(r => r.trim())
  .filter(Boolean);

// === SECURITY HARDENING: IP/DEVICE RISK ===
// Whether to require OTP re-verification on suspicious refresh
const REQUIRE_OTP_ON_SUSPICIOUS_REFRESH = process.env.REQUIRE_OTP_ON_SUSPICIOUS_REFRESH === 'true';

/**
 * Check if an IP address is in a blocked CIDR range
 * Simple implementation for common private ranges
 */
function isIpBlocked(ip) {
  if (!ip || ip === 'unknown') return false;

  // Check against configured blocked ranges
  for (const range of BLOCKED_IP_RANGES) {
    if (isIpInRange(ip, range)) {
      return true;
    }
  }

  // Block common private/test ranges by default
  const privateRanges = [
    { start: '10.0.0.0', end: '10.255.255.255' },
    { start: '172.16.0.0', end: '172.31.255.255' },
    { start: '192.168.0.0', end: '192.168.255.255' },
    { start: '127.0.0.0', end: '127.255.255.255' },
  ];

  for (const range of privateRanges) {
    if (isIpInRange(ip, range.start, range.end)) {
      return true;
    }
  }

  return false;
}

/**
 * Simple IP range check (for IPv4)
 */
function isIpInRange(ip, startOrCidr, end) {
  if (!ip) return false;

  // Handle CIDR notation
  if (startOrCidr.includes('/')) {
    const [network, prefix] = startOrCidr.split('/');
    const mask = parseInt(prefix, 10);
    const ipNum = ipToNumber(ip);
    const networkNum = ipToNumber(network);
    const maskNum = (0xFFFFFFFF << (32 - mask)) >>> 0;
    return (ipNum & maskNum) === (networkNum & maskNum);
  }

  // Handle start-end range
  if (end) {
    const ipNum = ipToNumber(ip);
    const startNum = ipToNumber(startOrCidr);
    const endNum = ipToNumber(end);
    return ipNum >= startNum && ipNum <= endNum;
  }

  return false;
}

/**
 * Convert IPv4 address to number
 */
function ipToNumber(ip) {
  const parts = ip.split('.');
  if (parts.length !== 4) return 0;
  return parts.reduce((acc, part) => (acc << 8) + parseInt(part, 10), 0) >>> 0;
}

/**
 * Create a device fingerprint from user agent and device info
 */
function createDeviceFingerprint(userAgent, deviceInfo = {}) {
  const components = [
    userAgent || 'unknown',
    deviceInfo.platform || 'unknown',
    deviceInfo.model || 'unknown',
    deviceInfo.os_version || 'unknown',
  ];

  const fingerprint = components.join('|');
  return crypto.createHash('sha256').update(fingerprint).digest('hex').slice(0, 32);
}

/**
 * Calculate risk score for a login/refresh attempt
 * Returns: { score: number (0-100), reasons: string[], isSuspicious: boolean }
 */
async function calculateRiskScore({
  userId,
  currentIp,
  currentUserAgent,
  currentDeviceId,
  currentDeviceInfo,
  previousIp,
  previousUserAgent,
  previousDeviceId,
}) {
  const reasons = [];
  let score = 0;

  // Check if IP is blocked
  if (isIpBlocked(currentIp)) {
    score += 50;
    reasons.push('blocked_ip_range');
  }

  // Check for IP change
  if (previousIp && currentIp !== previousIp) {
    // Check if IP changed significantly (different subnet)
    const ipChanged = !areIpsSimilar(currentIp, previousIp);
    if (ipChanged) {
      score += 20;
      reasons.push('ip_change');
    }
  }

  // Check for device change
  if (previousDeviceId && currentDeviceId !== previousDeviceId) {
    score += 30;
    reasons.push('device_change');
  }

  // Check for user agent change
  if (previousUserAgent && currentUserAgent !== previousUserAgent) {
    const uaChanged = !areUserAgentsSimilar(currentUserAgent, previousUserAgent);
    if (uaChanged) {
      score += 15;
      reasons.push('user_agent_change');
    }
  }

  // Check for new device (no previous data)
  if (!previousIp && !previousDeviceId) {
    // First login is normal, but still track it
    reasons.push('first_login');
  }

  const isSuspicious = score >= 30; // Threshold for suspicious activity

  return {
    score: Math.min(score, 100),
    reasons,
    isSuspicious,
  };
}

/**
 * Check if two IPs are in similar ranges (same /24 subnet)
 */
function areIpsSimilar(ip1, ip2) {
  if (!ip1 || !ip2) return false;
  const num1 = ipToNumber(ip1);
  const num2 = ipToNumber(ip2);
  // Same /24 subnet (first 24 bits match)
  return (num1 >>> 8) === (num2 >>> 8);
}

/**
 * Check if two user agents are similar (basic check)
 */
function areUserAgentsSimilar(ua1, ua2) {
  if (!ua1 || !ua2) return false;
  // Extract browser/OS from user agent (simplified)
  const extractKey = (ua) => {
    const lower = ua.toLowerCase();
    if (lower.includes('chrome')) return 'chrome';
    if (lower.includes('firefox')) return 'firefox';
    if (lower.includes('safari')) return 'safari';
    if (lower.includes('android')) return 'android';
    if (lower.includes('ios')) return 'ios';
    return 'unknown';
  };
  return extractKey(ua1) === extractKey(ua2);
}

/**
 * Get previous login/refresh information for a user
 */
async function getPreviousAuthInfo(userId, deviceId) {
  try {
    // Get most recent successful auth for this user
    const result = await db.query(
      `SELECT ip_address, user_agent, device_id
       FROM auth_audit
       WHERE user_id = $1 
         AND status = 'success'
         AND action IN ('login', 'token_refresh')
       ORDER BY created_at DESC
       LIMIT 1`,
      [userId]
    );

    if (result.rows.length > 0) {
      return {
        previousIp: result.rows[0].ip_address,
        previousUserAgent: result.rows[0].user_agent,
        previousDeviceId: result.rows[0].device_id,
      };
    }

    // Fallback: check user_devices for this device
    if (deviceId) {
      const deviceResult = await db.query(
        `SELECT device_identifier, last_seen_at
         FROM user_devices
         WHERE user_id = $1 AND device_identifier = $2
         ORDER BY last_seen_at DESC
         LIMIT 1`,
        [userId, deviceId]
      );

      // Device info available but IP/user_agent not tracked in user_devices table
      // Return deviceId as previousDeviceId
      if (deviceResult.rows.length > 0) {
        return {
          previousIp: null, // Not tracked in new schema
          previousUserAgent: null, // Not tracked in new schema
          previousDeviceId: deviceId,
        };
      }
    }

    return {
      previousIp: null,
      previousUserAgent: null,
      previousDeviceId: null,
    };
  } catch (err) {
    console.error('Error getting previous auth info:', err);
    return {
      previousIp: null,
      previousUserAgent: null,
      previousDeviceId: null,
    };
  }
}

module.exports = {
  isIpBlocked,
  createDeviceFingerprint,
  calculateRiskScore,
  getPreviousAuthInfo,
  REQUIRE_OTP_ON_SUSPICIOUS_REFRESH,
};
