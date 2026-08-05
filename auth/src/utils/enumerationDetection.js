// src/utils/enumerationDetection.js
// === SECURITY HARDENING: ENUMERATION DETECTION ===
// Detects and monitors phone number enumeration attempts
//
// Purpose:
//   - Detect patterns that indicate enumeration attacks
//   - Monitor for suspicious behavior (many unique phone numbers from same IP)
//   - Log and alert on enumeration attempts

const { getRedisClient, isRedisReady } = require('../services/redisClient');
const { logAuthEvent, RISK_LEVELS } = require('../services/auditLogger');

// Re-export RISK_LEVELS for convenience
const ENUM_RISK_LEVELS = RISK_LEVELS;

// In-memory fallback store (used when Redis is not available)
const memoryStore = {};

// Clean up expired entries from memory store periodically
setInterval(() => {
  const now = Date.now();
  Object.keys(memoryStore).forEach((key) => {
    if (memoryStore[key].expiresAt && memoryStore[key].expiresAt < now) {
      delete memoryStore[key];
    }
  });
}, 60000); // Clean up every minute

// Configuration from environment variables
const ENUMERATION_CONFIG = {
  // Maximum unique phone numbers per IP in a time window
  MAX_UNIQUE_PHONES_PER_IP_10MIN: parseInt(process.env.ENUMERATION_MAX_PHONES_PER_IP_10MIN || '5', 10),
  MAX_UNIQUE_PHONES_PER_IP_HOUR: parseInt(process.env.ENUMERATION_MAX_PHONES_PER_IP_HOUR || '20', 10),
  
  // Time windows (in seconds)
  WINDOW_10MIN: 600, // 10 minutes
  WINDOW_HOUR: 3600, // 1 hour
  
  // Alert threshold - number of unique phones that triggers alert
  ALERT_THRESHOLD_10MIN: parseInt(process.env.ENUMERATION_ALERT_THRESHOLD_10MIN || '10', 10),
  ALERT_THRESHOLD_HOUR: parseInt(process.env.ENUMERATION_ALERT_THRESHOLD_HOUR || '50', 10),
};

/**
 * Helper: Get counter value from Redis or memory store
 */
async function getCounter(key) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      const count = await redis.get(key);
      return count ? parseInt(count, 10) : 0;
    } catch (err) {
      console.error('Redis get error, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  if (memoryStore[key] && memoryStore[key].expiresAt > Date.now()) {
    return memoryStore[key].count || 0;
  }
  
  return 0;
}

/**
 * Helper: Increment counter in Redis or memory store
 */
async function incrementCounter(key, ttlSeconds) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      const count = await redis.incr(key);
      if (count === 1) {
        // First increment, set TTL
        await redis.expire(key, ttlSeconds);
      }
      return count;
    } catch (err) {
      console.error('Redis increment error, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  const now = Date.now();
  if (!memoryStore[key]) {
    memoryStore[key] = {
      count: 0,
      expiresAt: now + ttlSeconds * 1000,
    };
  }
  
  memoryStore[key].count++;
  return memoryStore[key].count;
}

/**
 * Helper: Add phone number to set and get count
 */
async function addToSetAndGetCount(key, value, ttlSeconds) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      // Use Redis set to track unique phone numbers
      // In Redis v4+, try camelCase first (sAdd, sCard), then fallback to lowercase
      if (typeof redis.sAdd === 'function') {
        // Redis v4+ uses camelCase method names
        await redis.sAdd(key, value);
        await redis.expire(key, ttlSeconds);
        const count = await redis.sCard(key);
        return count;
      } else if (typeof redis.sadd === 'function') {
        // Fallback for lowercase API
        await redis.sadd(key, value);
        await redis.expire(key, ttlSeconds);
        const count = await redis.scard(key);
        return count;
      } else {
        // If neither method exists, the client might not be properly initialized
        // This shouldn't happen, but handle gracefully
        console.warn('Redis set methods not available, using memory fallback');
        throw new Error('Redis client does not have set methods available');
      }
    } catch (err) {
      console.error('Redis set operation error, falling back to memory:', err.message);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback - use Set to track unique values
  const now = Date.now();
  if (!memoryStore[key]) {
    memoryStore[key] = {
      set: new Set(),
      expiresAt: now + ttlSeconds * 1000,
    };
  }
  
  memoryStore[key].set.add(value);
  return memoryStore[key].set.size;
}

/**
 * Check if an IP address is attempting enumeration
 * 
 * @param {string} ipAddress - IP address to check
 * @param {string} identifier - Phone number or email being requested
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{isEnumeration: boolean, riskLevel: string, details: Object}>}
 */
async function checkEnumerationAttempt(ipAddress, identifier, type = 'phone') {
  try {
    // Track unique identifiers per IP
    const key10min = `enumeration:ip:${ipAddress}:${type}s:10min`;
    const keyHour = `enumeration:ip:${ipAddress}:${type}s:hour`;
    
    // Add identifier to sets and get counts
    const count10min = await addToSetAndGetCount(key10min, identifier, ENUMERATION_CONFIG.WINDOW_10MIN);
    const countHour = await addToSetAndGetCount(keyHour, identifier, ENUMERATION_CONFIG.WINDOW_HOUR);
    
    // Check thresholds
    const exceeds10minLimit = count10min > ENUMERATION_CONFIG.MAX_UNIQUE_PHONES_PER_IP_10MIN;
    const exceedsHourLimit = countHour > ENUMERATION_CONFIG.MAX_UNIQUE_PHONES_PER_IP_HOUR;
    
    // Determine risk level
    let isEnumeration = false;
    let riskLevel = RISK_LEVELS.INFO;
    let details = {
      [`unique_${type}s_10min`]: count10min,
      [`unique_${type}s_hour`]: countHour,
      ip_address: ipAddress,
    };
    
    if (exceeds10minLimit || exceedsHourLimit) {
      isEnumeration = true;
      
      // Determine severity
      if (count10min >= ENUMERATION_CONFIG.ALERT_THRESHOLD_10MIN || 
          countHour >= ENUMERATION_CONFIG.ALERT_THRESHOLD_HOUR) {
        riskLevel = RISK_LEVELS.HIGH_RISK;
        details.severity = 'high';
        details.message = `Potential enumeration attack detected - high volume of unique ${type}s`;
      } else {
        riskLevel = RISK_LEVELS.SUSPICIOUS;
        details.severity = 'medium';
        details.message = `Potential enumeration attempt - unusual number of unique ${type}s`;
      }
    }
    
    return {
      isEnumeration,
      riskLevel,
      details,
    };
  } catch (err) {
    console.error('Error checking enumeration attempt:', err);
    // On error, return safe default (no enumeration detected)
    return {
      isEnumeration: false,
      riskLevel: RISK_LEVELS.INFO,
      details: { error: 'check_failed' },
    };
  }
}

/**
 * Log enumeration attempt for monitoring and alerting
 * 
 * @param {string} ipAddress - IP address
 * @param {string} identifier - Phone number or email
 * @param {string} riskLevel - Risk level
 * @param {Object} details - Additional details
 * @param {string} userAgent - User agent string
 * @param {string} type - 'phone' or 'email'
 */
async function logEnumerationAttempt(ipAddress, identifier, riskLevel, details, userAgent, type = 'phone') {
  try {
    let maskedIdentifier = identifier;
    if (type === 'email') {
      const [localPart, domain] = identifier.split('@');
      const maskedLocal = localPart.length > 3 ? localPart.substring(0, 3) + '***' : '***';
      maskedIdentifier = `${maskedLocal}@${domain}`;
    } else {
      maskedIdentifier = identifier.replace(/\d(?=\d{4})/g, '*');
    }

    await logAuthEvent({
      userId: null,
      action: 'enumeration_attempt',
      status: 'detected',
      riskLevel,
      ipAddress,
      userAgent,
      meta: {
        [type]: maskedIdentifier,
        ...details,
      },
    });
  } catch (err) {
    console.error('Error logging enumeration attempt:', err);
    // Don't throw - logging failures shouldn't break the flow
  }
}

/**
 * Check and log enumeration attempt for OTP request
 * This should be called before processing OTP requests
 * 
 * @param {string} ipAddress - IP address
 * @param {string} identifier - Phone number or email
 * @param {string} userAgent - User agent string
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{shouldBlock: boolean, riskLevel: string}>}
 */
async function detectAndLogEnumeration(ipAddress, identifier, userAgent, type = 'phone') {
  const detection = await checkEnumerationAttempt(ipAddress, identifier, type);
  
  // Log if enumeration detected
  if (detection.isEnumeration) {
    await logEnumerationAttempt(
      ipAddress,
      identifier,
      detection.riskLevel,
      detection.details,
      userAgent,
      type
    );
  }
  
  // Block if high risk
  const shouldBlock = detection.isEnumeration && detection.riskLevel === RISK_LEVELS.HIGH_RISK;
  
  return {
    shouldBlock,
    riskLevel: detection.riskLevel,
    details: detection.details,
  };
}

module.exports = {
  checkEnumerationAttempt,
  logEnumerationAttempt,
  detectAndLogEnumeration,
  ENUMERATION_CONFIG,
};
