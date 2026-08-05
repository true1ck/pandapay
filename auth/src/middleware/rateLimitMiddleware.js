// src/middleware/rateLimitMiddleware.js
// === ADDED FOR RATE LIMITING ===
// Rate limiting middleware for OTP requests and verification

const { getRedisClient, isRedisReady } = require('../services/redisClient');

// In-memory fallback store (used when Redis is not available)
// Unified store for all rate limiting keys
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
const config = {
  // OTP request limits
  OTP_REQ_PHONE_10MIN_LIMIT: parseInt(process.env.OTP_REQ_PHONE_10MIN_LIMIT || '3', 10),
  OTP_REQ_PHONE_DAY_LIMIT: parseInt(process.env.OTP_REQ_PHONE_DAY_LIMIT || '10', 10),
  OTP_REQ_EMAIL_10MIN_LIMIT: parseInt(process.env.OTP_REQ_EMAIL_10MIN_LIMIT || '3', 10),
  OTP_REQ_EMAIL_DAY_LIMIT: parseInt(process.env.OTP_REQ_EMAIL_DAY_LIMIT || '10', 10),
  OTP_REQ_IP_10MIN_LIMIT: parseInt(process.env.OTP_REQ_IP_10MIN_LIMIT || '20', 10),
  OTP_REQ_IP_DAY_LIMIT: parseInt(process.env.OTP_REQ_IP_DAY_LIMIT || '100', 10),
  
  // OTP verification limits
  OTP_VERIFY_MAX_ATTEMPTS: parseInt(process.env.OTP_VERIFY_MAX_ATTEMPTS || '5', 10),
  OTP_VERIFY_FAILED_PER_HOUR_LIMIT: parseInt(process.env.OTP_VERIFY_FAILED_PER_HOUR_LIMIT || '10', 10),
  
  // OTP validity
  OTP_TTL_SECONDS: parseInt(process.env.OTP_TTL_SECONDS || '120', 10), // 2 minutes
  
  // === SECURITY HARDENING: ENUMERATION PROTECTION ===
  // Stricter limits when enumeration is detected
  ENUMERATION_IP_10MIN_LIMIT: parseInt(process.env.ENUMERATION_IP_10MIN_LIMIT || '2', 10), // Reduced from 20
  ENUMERATION_IP_HOUR_LIMIT: parseInt(process.env.ENUMERATION_IP_HOUR_LIMIT || '5', 10), // Reduced from 100
  ENUMERATION_BLOCK_DURATION: parseInt(process.env.ENUMERATION_BLOCK_DURATION || '3600', 10), // 1 hour block
};

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
 * Helper: Check if key exists in Redis or memory store
 */
async function exists(key) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      const result = await redis.exists(key);
      return result === 1;
    } catch (err) {
      console.error('Redis exists error, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  if (memoryStore[key] && memoryStore[key].expiresAt > Date.now()) {
    return true;
  }
  
  return false;
}

/**
 * Helper: Set key with TTL in Redis or memory store
 */
async function setWithTTL(key, value, ttlSeconds) {
  const redis = await getRedisClient();
  
  if (isRedisReady() && redis) {
    try {
      await redis.setEx(key, ttlSeconds, value);
      return true;
    } catch (err) {
      console.error('Redis setEx error, falling back to memory:', err);
      // Fall through to memory store
    }
  }
  
  // Memory store fallback
  memoryStore[key] = {
    value,
    expiresAt: Date.now() + ttlSeconds * 1000,
  };
  
  return true;
}

/**
 * Helper: Normalize phone number (same logic as in routes)
 * This ensures consistent normalization across all checks
 * @param {string} phone - Phone number to normalize
 * @returns {string|null} Normalized phone number or null if invalid
 */
function normalizePhoneForOtp(phone) {
  if (!phone) return null;
  const p = phone.trim().replace(/\s+/g, ''); // Remove spaces
  if (p.startsWith('+')) return p;
  // if user enters 10-digit, prepend +91
  if (p.length === 10) return '+91' + p;
  return p; // fallback
}

/**
 * === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
 * Middleware: Check if there's an active OTP for the phone number
 * Prevents sending a new OTP if one is already active (within 2 minutes)
 * This check is GLOBAL per phone number (works across all devices)
 */
async function checkActiveOtpForPhone(req, res, next) {
  try {
    const { phone_number } = req.body;
    if (!phone_number) {
      return next(); // Let validation handle this
    }

    // Normalize phone using the same logic as route handler
    const normalizedPhone = normalizePhoneForOtp(phone_number);
    if (!normalizedPhone) {
      return next(); // Let validation handle this
    }

    const activeOtpKey = `otp_active:phone:${normalizedPhone}`;
    const hasActiveOtp = await exists(activeOtpKey);

    if (hasActiveOtp) {
      console.log(`[Rate Limit] Blocked OTP request for ${normalizedPhone.replace(/\d(?=\d{4})/g, '*')} - Active OTP exists`);
      return res.status(429).json({
        success: false,
        message: 'An OTP is already active. Please wait a moment before requesting a new one.',
      });
    }

    next();
  } catch (err) {
    console.error('checkActiveOtpForPhone error:', err);
    // On error, allow the request to proceed (fail open)
    next();
  }
}

/**
 * === ADDED FOR RATE LIMITING ===
 * Middleware: Rate limit OTP requests per phone number
 */
async function rateLimitRequestOtpByPhone(req, res, next) {
  try {
    const { phone_number } = req.body;
    if (!phone_number) {
      return next(); // Let validation handle this
    }

    // Normalize phone using the same logic as route handler
    const phone = normalizePhoneForOtp(phone_number);
    if (!phone) {
      return next(); // Let validation handle this
    }

    // Check 10-minute limit
    const key10min = `otp_req:phone:${phone}:10min`;
    const count10min = await incrementCounter(key10min, 600); // 10 minutes = 600 seconds

    if (count10min > config.OTP_REQ_PHONE_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:phone:${phone}:day`;
    const countDay = await incrementCounter(keyDay, 86400); // 24 hours = 86400 seconds

    if (countDay > config.OTP_REQ_PHONE_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    console.error('rateLimitRequestOtpByPhone error:', err);
    // On error, allow the request to proceed (fail open)
    next();
  }
}

/**
 * Middleware: Check if there's an active OTP for the email
 */
async function checkActiveOtpForEmail(req, res, next) {
  try {
    const { email } = req.body;
    if (!email) return next();

    const normalizedEmail = email.trim().toLowerCase();
    const activeOtpKey = `otp_active:email:${normalizedEmail}`;
    const hasActiveOtp = await exists(activeOtpKey);

    if (hasActiveOtp) {
      return res.status(429).json({
        success: false,
        message: 'An OTP is already active. Please wait a moment before requesting a new one.',
      });
    }

    next();
  } catch (err) {
    console.error('checkActiveOtpForEmail error:', err);
    next();
  }
}

/**
 * Middleware: Rate limit OTP requests per email
 */
async function rateLimitRequestOtpByEmail(req, res, next) {
  try {
    const { email } = req.body;
    if (!email) return next();

    const normalizedEmail = email.trim().toLowerCase();

    // Check 10-minute limit
    const key10min = `otp_req:email:${normalizedEmail}:10min`;
    const count10min = await incrementCounter(key10min, 600); 

    if (count10min > config.OTP_REQ_EMAIL_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:email:${normalizedEmail}:day`;
    const countDay = await incrementCounter(keyDay, 86400);

    if (countDay > config.OTP_REQ_EMAIL_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    console.error('rateLimitRequestOtpByEmail error:', err);
    next();
  }
}


/**
 * === ADDED FOR RATE LIMITING ===
 * Middleware: Rate limit OTP requests per IP address
 */
async function rateLimitRequestOtpByIp(req, res, next) {
  try {
    // Get client IP (considering proxies)
    const ip = req.ip || req.connection.remoteAddress || 'unknown';

    // Check 10-minute limit
    const key10min = `otp_req:ip:${ip}:10min`;
    const count10min = await incrementCounter(key10min, 600); // 10 minutes = 600 seconds

    if (count10min > config.OTP_REQ_IP_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:ip:${ip}:day`;
    const countDay = await incrementCounter(keyDay, 86400); // 24 hours = 86400 seconds

    if (countDay > config.OTP_REQ_IP_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    console.error('rateLimitRequestOtpByIp error:', err);
    // On error, allow the request to proceed (fail open)
    next();
  }
}

/**
 * === ADDED FOR OTP ATTEMPT LIMIT ===
 * Middleware: Rate limit failed OTP verification attempts per phone
 */
async function rateLimitVerifyOtpByPhone(req, res, next) {
  try {
    const { phone_number } = req.body;
    if (!phone_number) {
      return next(); // Let validation handle this
    }

    // Normalize phone using the same logic as route handler
    const phone = normalizePhoneForOtp(phone_number);
    if (!phone) {
      return next(); // Let validation handle this
    }

    // Check failed verification limit per hour
    const key = `otp_verify_failed:phone:${phone}:hour`;
    const count = await getCounter(key);

    if (count >= config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many attempts. Please try again later.',
      });
    }

    next();
  } catch (err) {
    console.error('rateLimitVerifyOtpByPhone error:', err);
    // On error, allow the request to proceed (fail open)
    next();
  }
}

/**
 * Middleware: Rate limit failed OTP verification attempts per email
 */
async function rateLimitVerifyOtpByEmail(req, res, next) {
  try {
    const { email } = req.body;
    if (!email) return next();

    const normalizedEmail = email.trim().toLowerCase();
    const key = `otp_verify_failed:email:${normalizedEmail}:hour`;
    const count = await getCounter(key);

    if (count >= config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many attempts. Please try again later.',
      });
    }

    next();
  } catch (err) {
    console.error('rateLimitVerifyOtpByEmail error:', err);
    next();
  }
}

/**
 * Helper: Mark active OTP (called after OTP is created)
 * This marks the identifier as having an active OTP globally
 * @param {string} identifier - Phone number or email
 * @param {number} ttlSeconds - Time to live in seconds
 */
async function markActiveOtp(identifier, ttlSeconds) {
  const isEmail = identifier.includes('@');
  let normalized = identifier.trim().toLowerCase();
  
  if (!isEmail) {
    normalized = normalizePhoneForOtp(identifier);
    if (!normalized) return;
  }
  
  const type = isEmail ? 'email' : 'phone';
  const key = `otp_active:${type}:${normalized}`;
  await setWithTTL(key, '1', ttlSeconds);
}

/**
 * Helper: Increment failed verification counter
 */
async function incrementFailedVerify(identifier) {
  const isEmail = identifier.includes('@');
  let normalized = identifier.trim().toLowerCase();
  
  if (!isEmail) {
    normalized = normalizePhoneForOtp(identifier);
    if (!normalized) return;
  }
  
  const type = isEmail ? 'email' : 'phone';
  const key = `otp_verify_failed:${type}:${normalized}:hour`;
  await incrementCounter(key, 3600); // 1 hour = 3600 seconds
}

/**
 * === SECURITY HARDENING: ENUMERATION PROTECTION ===
 * Check if an IP is blocked due to enumeration attempts
 * 
 * @param {string} ip - IP address to check
 * @returns {Promise<boolean>} True if IP is blocked
 */
async function isIpBlockedForEnumeration(ip) {
  const key = `enumeration:blocked:ip:${ip}`;
  return await exists(key);
}

/**
 * === SECURITY HARDENING: ENUMERATION PROTECTION ===
 * Block an IP address due to enumeration attempts
 * 
 * @param {string} ip - IP address to block
 * @param {number} durationSeconds - Block duration in seconds (default: from config)
 * @returns {Promise<void>}
 */
async function blockIpForEnumeration(ip, durationSeconds = null) {
  const key = `enumeration:blocked:ip:${ip}`;
  const duration = durationSeconds || config.ENUMERATION_BLOCK_DURATION;
  await setWithTTL(key, '1', duration);
  console.warn(`[ENUMERATION PROTECTION] Blocked IP ${ip} for ${duration} seconds due to enumeration attempts`);
}

/**
 * === SECURITY HARDENING: ENUMERATION PROTECTION ===
 * Apply stricter rate limiting for IPs with enumeration attempts
 * This middleware should be used when enumeration is detected
 * 
 * @param {string} ip - IP address
 * @returns {Promise<{allowed: boolean, reason?: string}>}
 */
async function checkEnumerationRateLimit(ip) {
  // Check if IP is already blocked
  if (await isIpBlockedForEnumeration(ip)) {
    return {
      allowed: false,
      reason: 'IP blocked due to enumeration attempts',
    };
  }

  // Apply stricter limits
  const key10min = `enumeration:rate_limit:ip:${ip}:10min`;
  const keyHour = `enumeration:rate_limit:ip:${ip}:hour`;
  
  const count10min = await incrementCounter(key10min, 600); // 10 minutes
  const countHour = await incrementCounter(keyHour, 3600); // 1 hour

  // Check stricter limits
  if (count10min > config.ENUMERATION_IP_10MIN_LIMIT) {
    // Block IP for enumeration
    await blockIpForEnumeration(ip);
    return {
      allowed: false,
      reason: 'Too many requests. IP blocked due to enumeration attempts.',
    };
  }

  if (countHour > config.ENUMERATION_IP_HOUR_LIMIT) {
    // Block IP for enumeration
    await blockIpForEnumeration(ip);
    return {
      allowed: false,
      reason: 'Too many requests. IP blocked due to enumeration attempts.',
    };
  }

  return { allowed: true };
}

module.exports = {
  checkActiveOtpForPhone,
  rateLimitRequestOtpByPhone,
  checkActiveOtpForEmail,
  rateLimitRequestOtpByEmail,
  rateLimitRequestOtpByIp,
  rateLimitVerifyOtpByPhone,
  rateLimitVerifyOtpByEmail,
  markActiveOtp,
  incrementFailedVerify,
  isIpBlockedForEnumeration,
  blockIpForEnumeration,
  checkEnumerationRateLimit,
  config,
};

