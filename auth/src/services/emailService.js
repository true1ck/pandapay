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

// What each kind of code is for, so two codes sent for one action are not confused.
const CODE_PURPOSES = Object.freeze({
  signin: {
    subject: 'Your PandaPay Verification Code',
    heading: 'PandaPay Verification Code',
    lead: 'Your verification code is:',
    textLead: 'Your PandaPay verification code is:',
  },
  'recovery-email-signin': {
    subject: 'Confirm it is you: PandaPay recovery email',
    heading: 'Confirm it is you',
    lead: 'Someone is adding a recovery email to your PandaPay account. To confirm it is you, enter this code:',
  },
  'recovery-code': {
    subject: 'PandaPay account recovery code',
    heading: 'Account recovery',
    lead: 'Someone is recovering your PandaPay account. If that is you, enter this code to continue:',
  },
  'recovery-new-email': {
    subject: 'Confirm your new PandaPay sign-in email',
    heading: 'Confirm your new sign-in email',
    lead: 'This address is being set as the sign-in email for a PandaPay account. Enter this code to confirm it:',
  },
  'recovery-email-new': {
    subject: 'Your PandaPay recovery email code',
    heading: 'Confirm your recovery email',
    lead: 'This address is being added as a PandaPay recovery email. Enter this code to confirm it:',
  },
});

async function deliver(mailOptions, recipient, what) {
  try {
    if (!transporter) {
      return { success: false, error: 'Email delivery is not configured' };
    }
    const info = await otpAdmission.run('email', () => transporter.sendMail(mailOptions));
    const accepted = info.accepted || [];
    if (!accepted.some(address => String(address).toLowerCase() === recipient.toLowerCase())) {
      console.error(`[Email Service] SMTP did not accept the ${what} recipient`);
      return { success: false, error: 'Email recipient was not accepted' };
    }
    console.info(`${what} email delivery succeeded`);
    return { success: true, messageId: info.messageId };
  } catch (error) {
    if (error instanceof OtpCapacityError) return { success: false, error: 'Email delivery is temporarily busy', code: BUSY_CODE };
    console.error(`[Email Service] Failed to send ${what}:`, safeErrorCode(error, 'delivery_error'));
    return { success: false, error: 'Email delivery failed' };
  }
}

/**
 * Send an OTP code via Email
 * @param {string} email - Recipient email address
 * @param {string} code - The OTP code
 * @param {{purpose?: 'signin'|'recovery-email-signin'|'recovery-email-new'}} [options]
 * @returns {Promise<{success: boolean, messageId?: string, error?: string}>}
 */
async function sendOtpEmail(email, code, { purpose = 'signin' } = {}) {
  const wording = CODE_PURPOSES[purpose] || CODE_PURPOSES.signin;
  const mailOptions = {
    from: config.emailFrom || '"PandaPay" <noreply@example.com>',
    to: email,
    subject: wording.subject,
    disableFileAccess: true,
    disableUrlAccess: true,
    text: `${wording.textLead || wording.lead} ${code}\nThis code will expire in 1 minute. Do not share it with anyone.`,
    html: `
      <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto; padding: 20px; border: 1px solid #e0e0e0; border-radius: 5px;">
        <h2 style="color: #333; text-align: center;">${wording.heading}</h2>
        <p style="color: #555; font-size: 16px;">${wording.lead}</p>
        <div style="background-color: #f5f5f5; padding: 15px; border-radius: 4px; text-align: center; margin: 20px 0;">
          <strong style="font-size: 28px; letter-spacing: 5px; color: #000;">${code}</strong>
        </div>
        <p style="color: #777; font-size: 14px; text-align: center;">This code will expire in 1 minute.<br>Do not share this code with anyone.</p>
      </div>
    `,
  };
  return deliver(mailOptions, email, 'OTP');
}

/**
 * A plain security notice (no code): a recovery email was added, a sign-in email
 * changed, and so on. The body is text only and never contains a code or a link.
 */
async function sendSecurityNotice({ to, subject, text }) {
  const mailOptions = {
    from: config.emailFrom || '"PandaPay" <noreply@example.com>',
    to,
    subject,
    disableFileAccess: true,
    disableUrlAccess: true,
    text,
  };
  return deliver(mailOptions, to, 'security notice');
}

module.exports = {
  sendOtpEmail,
  sendSecurityNotice,
};
