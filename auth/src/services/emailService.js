const { safeErrorCode } = require('../utils/safeErrorCode');
// src/services/emailService.js
const nodemailer = require('nodemailer');
const net = require('node:net');
const config = require('../config');
const { getOtpWorkAdmission, OtpCapacityError, BUSY_CODE } = require('./otpWorkAdmission');
const otpAdmission = getOtpWorkAdmission();

// Initialize Nodemailer transporter
let transporter = null;

if (config.emailHost && config.emailUser && config.emailPass) {
  const port = parseInt(config.emailPort || '587', 10);
  const hosted = config.isProduction || process.env.NODE_ENV === 'staging';
  const tlsOptions = { rejectUnauthorized: true };
  if (typeof config.emailHost === 'string' && net.isIP(config.emailHost) === 0) {
    tlsOptions.servername = config.emailHost;
  }
  transporter = nodemailer.createTransport({
    host: config.emailHost,
    port,
    secure: port === 465,
    requireTLS: hosted && port !== 465,
    tls: tlsOptions,
    connectionTimeout: 10000,
    greetingTimeout: 10000,
    socketTimeout: 15000,
    auth: {
      user: config.emailUser,
      pass: config.emailPass,
    },
  });
  console.info('Email delivery service initialized');
} else {
  console.warn('Email SMTP credentials missing. Email authentication delivery is unavailable.');
}

/**
 * Send an OTP code via Email
 * @param {string} email - Recipient email address
 * @param {string} code - The OTP code
 * @returns {Promise<{success: boolean, messageId?: string, error?: string}>}
 */
async function sendOtpEmail(email, code) {
  const mailOptions = {
    from: config.emailFrom || '"PandaPay" <noreply@example.com>',
    to: email,
    subject: 'Your PandaPay Verification Code',
    disableFileAccess: true,
    disableUrlAccess: true,
    text: `Your PandaPay verification code is: ${code}\nThis code will expire in 2 minutes. Do not share it with anyone.`,
    html: `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 5px;">
        <h2 style="color: #333; text-align: center;">PandaPay Verification Code</h2>
        <p style="color: #555; font-size: 16px;">Your verification code is:</p>
        <div style="background-color: #f5f5f5; padding: 15px; border-radius: 4px; text-align: center; margin: 20px 0;">
          <strong style="font-size: 28px; letter-spacing: 5px; color: #000;">${code}</strong>
        </div>
        <p style="color: #777; font-size: 14px; text-align: center;">This code will expire in 2 minutes.<br>Do not share this code with anyone.</p>
      </div>
    `,
  };

  try {
    if (!transporter) {
      return { success: false, error: 'Email delivery is not configured' };
    }

    const info = await otpAdmission.run('email', () => transporter.sendMail(mailOptions));
    const accepted = info.accepted || [];
    if (!accepted.some(address => String(address).toLowerCase() === email.toLowerCase())) {
      console.error('[Email Service] SMTP did not accept the OTP recipient');
      return { success: false, error: 'Email recipient was not accepted' };
    }
    console.info('OTP email delivery succeeded');
    return { success: true, messageId: info.messageId };
  } catch (error) {
    if (error instanceof OtpCapacityError) return { success: false, error: 'Email delivery is temporarily busy', code: BUSY_CODE };
    console.error('[Email Service] Failed to send OTP:', safeErrorCode(error, 'delivery_error'));
    return { success: false, error: 'Email delivery failed' };
  }
}

module.exports = {
  sendOtpEmail,
};
