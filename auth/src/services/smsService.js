// src/services/smsService.js
const twilio = require('twilio');
// === SECURITY HARDENING: OTP LOGGING ===
const { logOtpForDebug, logOtpEvent } = require('../utils/otpLogger');

const {
  TWILIO_ACCOUNT_SID,
  TWILIO_AUTH_TOKEN,
  TWILIO_FROM_NUMBER,
  TWILIO_MESSAGING_SERVICE_SID,
} = process.env;

let client = null;

if (TWILIO_ACCOUNT_SID && TWILIO_AUTH_TOKEN) {
  client = twilio(TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN);
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
    logOtpForDebug(toPhone, code);
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
    logOtpForDebug(toPhone, code);
    logOtpEvent(toPhone, false);
    return { success: false, error: 'No Twilio sender configured' };
  }

  try {
    const msg = await client.messages.create(msgConfig);
    console.log('✅ Twilio SMS sent, SID:', msg.sid);
    logOtpEvent(toPhone, true);
    return { success: true, sid: msg.sid };
  } catch (err) {
    const errorMessage = err.message || 'Unknown error';
    console.error('❌ Failed to send SMS via Twilio:', errorMessage);
    
    // Check for specific Twilio error types
    const isShortCodeError = errorMessage.includes('Short Code');
    const isUnverifiedNumberError = errorMessage.includes('unverified');
    const isTrialAccountError = errorMessage.includes('Trial account');
    
    if (isShortCodeError) {
      console.warn('⚠️ Cannot send to short codes (5-6 digit numbers).');
    } else if (isUnverifiedNumberError || isTrialAccountError) {
      console.warn('⚠️ Trial account limitation: Verify the number at https://console.twilio.com/us1/develop/phone-numbers/manage/verified');
      console.warn('⚠️ Or upgrade to a paid account to send to any number.');
    }
    
    // === SECURITY HARDENING: OTP LOGGING ===
    // Use safe logging for fallback
    logOtpForDebug(toPhone, code);
    logOtpEvent(toPhone, false);
    return { success: false, error: errorMessage };
  }
}

module.exports = {
  sendOtpSms,
};
