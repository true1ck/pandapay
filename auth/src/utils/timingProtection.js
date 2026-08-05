// src/utils/timingProtection.js
// === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
// Constant-time delay utilities to prevent timing-based enumeration attacks
//
// Purpose:
//   - Prevent phone number enumeration via response time analysis
//   - Ensure all code paths take similar time regardless of outcome
//   - Add artificial delays to normalize response times

/**
 * Sleep for a specified number of milliseconds
 * @param {number} ms - Milliseconds to sleep
 * @returns {Promise<void>}
 */
function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Configuration for timing protection
 * Can be adjusted via environment variables
 */
const TIMING_CONFIG = {
  // Base delay for OTP requests (ms)
  // This ensures all requests take at least this long
  OTP_REQUEST_MIN_DELAY: parseInt(process.env.OTP_REQUEST_MIN_DELAY || '500', 10),
  
  // Base delay for OTP verification (ms)
  // This ensures all verification attempts take at least this long
  OTP_VERIFY_MIN_DELAY: parseInt(process.env.OTP_VERIFY_MIN_DELAY || '300', 10),
  
  // Maximum random jitter to add (ms)
  // Adds randomness to prevent pattern detection
  MAX_JITTER: parseInt(process.env.TIMING_MAX_JITTER || '100', 10),
};

/**
 * Add a constant-time delay with optional jitter
 * This ensures all code paths take similar time regardless of outcome
 * 
 * @param {number} baseDelayMs - Base delay in milliseconds
 * @param {boolean} addJitter - Whether to add random jitter (default: true)
 * @returns {Promise<void>}
 */
async function constantTimeDelay(baseDelayMs, addJitter = true) {
  let delay = baseDelayMs;
  
  if (addJitter && TIMING_CONFIG.MAX_JITTER > 0) {
    // Add random jitter to prevent pattern detection
    const jitter = Math.floor(Math.random() * TIMING_CONFIG.MAX_JITTER);
    delay += jitter;
  }
  
  await sleep(delay);
}

/**
 * Measure execution time and ensure minimum delay
 * This function ensures that the total execution time (including the work)
 * meets the minimum delay requirement
 * 
 * @param {Function} workFn - Async function to execute
 * @param {number} minTotalDelayMs - Minimum total delay in milliseconds
 * @param {boolean} addJitter - Whether to add random jitter (default: true)
 * @returns {Promise<*>} Result of workFn
 */
async function executeWithTimingProtection(workFn, minTotalDelayMs, addJitter = true) {
  const startTime = Date.now();
  
  try {
    // Execute the work
    const result = await workFn();
    
    // Calculate elapsed time
    const elapsed = Date.now() - startTime;
    const remainingDelay = Math.max(0, minTotalDelayMs - elapsed);
    
    // Add remaining delay to meet minimum time requirement
    if (remainingDelay > 0) {
      await constantTimeDelay(remainingDelay, addJitter);
    }
    
    return result;
  } catch (error) {
    // Even on error, ensure minimum delay
    const elapsed = Date.now() - startTime;
    const remainingDelay = Math.max(0, minTotalDelayMs - elapsed);
    
    if (remainingDelay > 0) {
      await constantTimeDelay(remainingDelay, addJitter);
    }
    
    throw error;
  }
}

/**
 * Constant-time delay for OTP requests
 * Ensures all OTP requests take similar time regardless of whether phone exists
 * 
 * @returns {Promise<void>}
 */
async function otpRequestDelay() {
  await constantTimeDelay(TIMING_CONFIG.OTP_REQUEST_MIN_DELAY, true);
}

/**
 * Constant-time delay for OTP verification
 * Ensures all OTP verifications take similar time regardless of outcome
 * 
 * @returns {Promise<void>}
 */
async function otpVerifyDelay() {
  await constantTimeDelay(TIMING_CONFIG.OTP_VERIFY_MIN_DELAY, true);
}

/**
 * Execute OTP request work with timing protection
 * 
 * @param {Function} workFn - Async function to execute
 * @returns {Promise<*>} Result of workFn
 */
async function executeOtpRequestWithTiming(workFn) {
  return executeWithTimingProtection(workFn, TIMING_CONFIG.OTP_REQUEST_MIN_DELAY, true);
}

/**
 * Execute OTP verification work with timing protection
 * 
 * @param {Function} workFn - Async function to execute
 * @returns {Promise<*>} Result of workFn
 */
async function executeOtpVerifyWithTiming(workFn) {
  return executeWithTimingProtection(workFn, TIMING_CONFIG.OTP_VERIFY_MIN_DELAY, true);
}

module.exports = {
  sleep,
  constantTimeDelay,
  executeWithTimingProtection,
  otpRequestDelay,
  otpVerifyDelay,
  executeOtpRequestWithTiming,
  executeOtpVerifyWithTiming,
  TIMING_CONFIG,
};
