// src/utils/otpLogger.js
// OTP values are never written to logs, including development and tests.

/**
 * Log OTP generation event without exposing the code
 * Safe for production use
 * 
 * @param {string} phone - Phone number (masked)
 * @param {boolean} smsSent - Whether SMS was successfully sent
 */
function logOtpEvent(phone, smsSent) {
  if (smsSent) {
    console.info('OTP sent via SMS');
  } else {
    console.warn('OTP delivery failed');
  }
}

module.exports = {
  logOtpEvent,
};









