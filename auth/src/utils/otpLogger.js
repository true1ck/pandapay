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
  logOtpEvent,
};









