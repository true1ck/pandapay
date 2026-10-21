// src/services/emailService.js
const nodemailer = require('nodemailer');
const config = require('../config');
const { maskEmail } = require('../utils/recoveryContacts');

// Initialize Nodemailer transporter
let transporter = null;

if (config.emailHost && config.emailUser && config.emailPass) {
  transporter = nodemailer.createTransport({
    host: config.emailHost,
    port: parseInt(config.emailPort || '587', 10),
    secure: parseInt(config.emailPort || '587', 10) === 465, // true for 465, false for other ports
    auth: {
      user: config.emailUser,
      pass: config.emailPass,
    },
  });
  console.log('✅ Email service initialized');
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
    from: config.emailFrom || '"PandaPal.Ai" <noreply@example.com>',
    to: email,
    subject: 'Your PandaPal.Ai Verification Code',
    text: `Your PandaPal.Ai verification code is: ${code}\nThis code will expire in 2 minutes. Do not share it with anyone.`,
    html: `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 5px;">
        <h2 style="color: #333; text-align: center;">PandaPal.Ai Verification Code</h2>
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

    const info = await transporter.sendMail(mailOptions);
    const accepted = info.accepted || [];
    if (!accepted.some(address => String(address).toLowerCase() === email.toLowerCase())) {
      console.error('[Email Service] SMTP did not accept the OTP recipient');
      return { success: false, error: 'Email recipient was not accepted' };
    }
    console.log(`[Email Service] OTP sent to ${maskEmail(email)} (Message ID: ${info.messageId})`);
    return { success: true, messageId: info.messageId };
  } catch (error) {
    console.error('[Email Service] Failed to send OTP:', error.code || error.name || 'delivery_error');
    return { success: false, error: error.message };
  }
}

module.exports = {
  sendOtpEmail,
};
