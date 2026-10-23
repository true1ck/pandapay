const { safeErrorCode } = require('../utils/safeErrorCode');
// src/middleware/rateLimitMiddleware.js
// === ADDED FOR RATE LIMITING ===
// Rate limiting middleware for OTP requests and verification

const {
  RateLimitStorageError,
  RateLimitExceededError,
  ActiveOtpError,
  createRateLimitStore,
} = require('../services/authAbuseStore');
const rateLimitStore = createRateLimitStore();

function logRateLimitError(event, error) {
  console.error(`[rate-limit] ${event}`, safeErrorCode(error));
}

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

function serviceUnavailable(res) {
  return res.status(503).json({
    success: false,
    message: 'Authentication is temporarily unavailable. Please try again shortly.',
  });
}

async function incrementCounter(key, ttlSeconds, saturation) {
  return rateLimitStore.increment(key, ttlSeconds, saturation);
}

async function getCounter(key) {
  return rateLimitStore.get(key);
}

async function exists(key) {
  return rateLimitStore.exists(key);
}

async function setWithTTL(key, value, ttlSeconds) {
  return rateLimitStore.setWithTTL(key, value, ttlSeconds);
}

function validateReplacementBudgetInput(userId, channel, action) {
  if (typeof userId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(userId)) {
    throw new TypeError('Replacement budget user ID is invalid');
  }
  if (channel !== 'phone' && channel !== 'email') {
    throw new TypeError('Replacement budget channel is invalid');
  }
  if (action !== 'request' && action !== 'verify') {
    throw new TypeError('Replacement budget action is invalid');
  }
}

/** Consume an account-scoped budget before a replacement OTP attempt. */
async function consumeReplacementBudget(userId, channel, action = 'request') {
  validateReplacementBudgetInput(userId, channel, action);
  if (action === 'verify') {
    const key = `replacement:verify:user:${userId}:${channel}:hour`;
    const count = await incrementCounter(key, 3600, config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT + 1);
    if (count > config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT) throw new RateLimitExceededError();
    return count;
  }

  const shortLimit = channel === 'phone'
    ? config.OTP_REQ_PHONE_10MIN_LIMIT : config.OTP_REQ_EMAIL_10MIN_LIMIT;
  const dayLimit = channel === 'phone'
    ? config.OTP_REQ_PHONE_DAY_LIMIT : config.OTP_REQ_EMAIL_DAY_LIMIT;
  const shortKey = `replacement:request:user:${userId}:${channel}:hour`;
  const dayKey = `replacement:request:user:${userId}:${channel}:day`;
  // Use the same limits as ordinary requests while applying them to the
  // stable authenticated account ID instead of the mutable replacement ID.
  const shortCount = await incrementCounter(shortKey, 600, shortLimit + 1);
  const dayCount = await incrementCounter(dayKey, 86400, dayLimit + 1);
  if (shortCount > shortLimit || dayCount > dayLimit) throw new RateLimitExceededError();
  return { shortCount, dayCount };
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

function otpPurpose(req) {
  return req.body?.recovery_only === true ? 'recovery' : 'signin';
}

/**
 * === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
 * Middleware: Check if there's an active OTP for the phone number
 * Prevents sending a new OTP if one is already active (within 2 minutes)
 * This check is shared across devices for the same identifier and OTP purpose.
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

    const activeOtpKey = `otp_active:phone:${normalizedPhone}:${otpPurpose(req)}`;
    const hasActiveOtp = await exists(activeOtpKey);

    if (hasActiveOtp) {
      return res.status(429).json({
        success: false,
        message: 'An OTP is already active. Please wait a moment before requesting a new one.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('phone active challenge check failed', err);
    return serviceUnavailable(res);
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
    const purpose = otpPurpose(req);
    const key10min = `otp_req:phone:${phone}:${purpose}:10min`;
    const count10min = await incrementCounter(key10min, 600, config.OTP_REQ_PHONE_10MIN_LIMIT + 1);

    if (count10min > config.OTP_REQ_PHONE_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:phone:${phone}:${purpose}:day`;
    const countDay = await incrementCounter(keyDay, 86400, config.OTP_REQ_PHONE_DAY_LIMIT + 1);

    if (countDay > config.OTP_REQ_PHONE_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('phone request quota check failed', err);
    return serviceUnavailable(res);
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
    const activeOtpKey = `otp_active:email:${normalizedEmail}:${otpPurpose(req)}`;
    const hasActiveOtp = await exists(activeOtpKey);

    if (hasActiveOtp) {
      return res.status(429).json({
        success: false,
        message: 'An OTP is already active. Please wait a moment before requesting a new one.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('email active challenge check failed', err);
    return serviceUnavailable(res);
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
    const purpose = otpPurpose(req);
    const key10min = `otp_req:email:${normalizedEmail}:${purpose}:10min`;
    const count10min = await incrementCounter(key10min, 600, config.OTP_REQ_EMAIL_10MIN_LIMIT + 1);

    if (count10min > config.OTP_REQ_EMAIL_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:email:${normalizedEmail}:${purpose}:day`;
    const countDay = await incrementCounter(keyDay, 86400, config.OTP_REQ_EMAIL_DAY_LIMIT + 1);

    if (countDay > config.OTP_REQ_EMAIL_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('email request quota check failed', err);
    return serviceUnavailable(res);
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
    const count10min = await incrementCounter(key10min, 600, config.OTP_REQ_IP_10MIN_LIMIT + 1);

    if (count10min > config.OTP_REQ_IP_10MIN_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    // Check 24-hour limit
    const keyDay = `otp_req:ip:${ip}:day`;
    const countDay = await incrementCounter(keyDay, 86400, config.OTP_REQ_IP_DAY_LIMIT + 1);

    if (countDay > config.OTP_REQ_IP_DAY_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many OTP requests. Please try again later.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('IP request quota check failed', err);
    return serviceUnavailable(res);
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
    const key = `otp_verify_failed:phone:${phone}:${otpPurpose(req)}:hour`;
    const count = await getCounter(key);

    if (count >= config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many attempts. Please try again later.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('phone verification quota check failed', err);
    return serviceUnavailable(res);
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
    const key = `otp_verify_failed:email:${normalizedEmail}:${otpPurpose(req)}:hour`;
    const count = await getCounter(key);

    if (count >= config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT) {
      return res.status(429).json({
        success: false,
        message: 'Too many attempts. Please try again later.',
      });
    }

    next();
  } catch (err) {
    logRateLimitError('email verification quota check failed', err);
    return serviceUnavailable(res);
  }
}

/**
 * Helper: Claim the active OTP marker before creating an OTP row.
 * @param {string} identifier - Phone number or email
 * @param {number} ttlSeconds - Time to live in seconds
 */
async function markActiveOtp(identifier, ttlSeconds, requestId = '1', purpose = 'signin') {
  const isEmail = identifier.includes('@');
  let normalized = identifier.trim().toLowerCase();
  
  if (!isEmail) {
    normalized = normalizePhoneForOtp(identifier);
    if (!normalized) return;
  }
  
  const type = isEmail ? 'email' : 'phone';
  const key = `otp_active:${type}:${normalized}:${purpose}`;
  const claimed = await rateLimitStore.claimMarker(key, String(requestId), ttlSeconds);
  if (!claimed) throw new ActiveOtpError();
}

/** Clear an active OTP marker when delivery failed and the code was discarded. */
async function clearActiveOtp(identifier, requestId, purpose = 'signin') {
  if (!requestId) return;
  const isEmail = identifier.includes('@');
  let normalized = identifier.trim().toLowerCase();
  if (!isEmail) {
    normalized = normalizePhoneForOtp(identifier);
    if (!normalized) return;
  }

  const type = isEmail ? 'email' : 'phone';
  const key = `otp_active:${type}:${normalized}:${purpose}`;
  try {
    await rateLimitStore.compareDelete(key, requestId);
  } catch (err) {
    logRateLimitError('active challenge marker deletion failed', err);
    throw err;
  }
}

/**
 * Helper: Increment failed verification counter
 */
async function incrementFailedVerify(identifier, purpose = 'signin') {
  const isEmail = identifier.includes('@');
  let normalized = identifier.trim().toLowerCase();
  
  if (!isEmail) {
    normalized = normalizePhoneForOtp(identifier);
    if (!normalized) return;
  }
  
  const type = isEmail ? 'email' : 'phone';
  const key = `otp_verify_failed:${type}:${normalized}:${purpose}:hour`;
  await incrementCounter(key, 3600, config.OTP_VERIFY_FAILED_PER_HOUR_LIMIT + 1);
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
  console.warn(`Enumeration protection blocked an IP for ${duration} seconds`);
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
  
  const count10min = await incrementCounter(key10min, 600, config.ENUMERATION_IP_10MIN_LIMIT + 1);
  const countHour = await incrementCounter(keyHour, 3600, config.ENUMERATION_IP_HOUR_LIMIT + 1);

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
  clearActiveOtp,
  incrementFailedVerify,
  isIpBlockedForEnumeration,
  blockIpForEnumeration,
  checkEnumerationRateLimit,
  config,
  RateLimitStorageError,
  RateLimitExceededError,
  ActiveOtpError,
  consumeReplacementBudget,
};

