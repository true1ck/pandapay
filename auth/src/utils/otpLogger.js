// src/utils/otpLogger.js
// === SECURITY HARDENING: OTP LOGGING ===
// Safe OTP logging helper that only logs in development and never to centralized logs

const isDevelopment = process.env.NODE_ENV === 'development';
const isProduction = process.env.NODE_ENV === 'production';

/**
 * Safely log OTP code for debugging purposes
 * - Only logs in development mode
 * - Never logs to production or centralized logging systems
 * - Uses console.log (not console.error) to avoid log aggregation
 * - Clearly marked as DEV-ONLY
 * 
 * @param {string} phone - Phone number (can be partially masked)
 * @param {string} otp - OTP code (will be logged only in dev)
 */
function logOtpForDebug(phone, otp) {
  if (!isDevelopment) {
    // In production, never log OTPs
    return;
  }

  // Mask phone number for additional safety (show only last 4 digits)
  const maskedPhone = phone.length > 4 
    ? phone.slice(0, -4).replace(/\d/g, '*') + phone.slice(-4)
    : '****';

  // Use console.log (not error/warn) to avoid log aggregation systems
  // Prefix with [DEV-ONLY] to make it clear this is development-only
  console.log('[DEV-ONLY] OTP generated:', {
    phone: maskedPhone,
    code: otp,
    warning: 'This log should NEVER appear in production logs'
  });
}

/**
 * Log OTP generation event without exposing the code
 * Safe for production use
 * 
 * @param {string} phone - Phone number (masked)
 * @param {boolean} smsSent - Whether SMS was successfully sent
 */
function logOtpEvent(phone, smsSent) {
  const maskedPhone = phone.length > 4 
    ? phone.slice(0, -4).replace(/\d/g, '*') + phone.slice(-4)
    : '****';

  if (smsSent) {
    console.log('OTP sent via SMS:', maskedPhone);
  } else {
    console.warn('OTP generated but SMS failed:', maskedPhone);
  }
}

module.exports = {
  logOtpForDebug,
  logOtpEvent,
};









