const { safeErrorCode } = require('../utils/safeErrorCode');
// src/services/smsService.js
const twilio = require('twilio');
const { getOtpWorkAdmission, OtpCapacityError, BUSY_CODE } = require('./otpWorkAdmission');
const otpAdmission = getOtpWorkAdmission();
// === SECURITY HARDENING: OTP LOGGING ===
const { logOtpEvent } = require('../utils/otpLogger');

const {
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_FROM_NUMBER,
  TWILIO_MESSAGING_SERVICE_SID,
} = process.env;

let client = null;

if (TWILIO_ACCOUNT_SID && TWILIO_AUTH_TOKEN) {
  // Twilio's SDK defaults to a 30s request timeout. Keep provider calls bounded
  // and disable automatic 429 retries so OTP delivery cannot duplicate sends.
  client = twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, {
    timeout: 10000,
    autoRetry: false,
    maxRetries: 0,
  });
} else {
  console.warn('⚠️ Twilio credentials are not set. SMS sending will be disabled.');
}

/**
 * Send OTP SMS using Twilio
 * @param {string} toPhone E.164 format, e.g. +919876543210
 * @param {string} code OTP code
 */
async function sendOtpSms(toPhone, code) {
  // === SECURITY HARDENING: OTP LOGGING ===
  // Use safe OTP logging (only in development)
  if (!client) {
    logOtpEvent(toPhone, false);
    return { success: false, error: 'Twilio not configured' };
  }

  // === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
  // OTP validity changed to 2 minutes
  const messageBody = `Your verification code is ${code}. It will expire in 2 minutes.`;

  const msgConfig = {
    body: messageBody,
    to: toPhone,
  };

  // Prefer Messaging Service if provided
  if (TWILIO_MESSAGING_SERVICE_SID) {
    msgConfig.messagingServiceSid = TWILIO_MESSAGING_SERVICE_SID;
  } else if (TWILIO_FROM_NUMBER) {
    msgConfig.from = TWILIO_FROM_NUMBER;
  } else {
    // === SECURITY HARDENING: OTP LOGGING ===
    // Use safe logging instead of direct console.log
    logOtpEvent(toPhone, false);
    return { success: false, error: 'No Twilio sender configured' };
  }

  try {
    const msg = await otpAdmission.run('sms', () => client.messages.create(msgConfig));
    console.info('OTP SMS delivery succeeded');
    logOtpEvent(toPhone, true);
    return { success: true, sid: msg.sid };
  } catch (err) {
    if (err instanceof OtpCapacityError) return { success: false, error: 'SMS delivery is temporarily busy', code: BUSY_CODE };
    // Provider messages may contain recipient, URL, or credential details.
    // Keep only a bounded machine code in logs and return a fixed error.
    console.error('[SMS Service] provider delivery failed:', safeErrorCode(err, 'delivery_error'));
    logOtpEvent(toPhone, false);
    return { success: false, error: 'SMS delivery failed' };
  }
}

module.exports = {
  sendOtpSms,
};
