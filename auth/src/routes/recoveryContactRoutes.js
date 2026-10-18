const express = require('express');
const jwt = require('jsonwebtoken');
const { randomUUID, createHash } = require('crypto');
const db = require('../db');
const config = require('../config');
const auth = require('../middleware/authMiddleware');
const { userRateLimitSensitive } = require('../middleware/userRateLimit');
const { getActiveKey, getKeySecret, getIssuer, getAudience } = require('../services/jwtKeys');
const { createOtp, verifyOtp, discardUndeliveredOtp } = require('../services/otpService');
const { sendOtpEmail } = require('../services/emailService');
const { sendOtpSms } = require('../services/smsService');
const { encryptPhoneNumber, decryptPhoneNumber } = require('../utils/fieldEncryption');
const { preparePhoneSearchParams } = require('../utils/encryptedPhoneSearch');
const { maskEmail, maskPhone } = require('../utils/recoveryContacts');

const router = express.Router();
const fingerprint = value => createHash('sha256').update(value || '').digest('hex');
const audience = () => `${getAudience()}:contact-replacement`;

// Only a recent, signed recovery OTP proof can replace the OTHER contact.
// A normal session or a client-provided channel is insufficient.
router.use(auth, userRateLimitSensitive, (req, res, next) => {
  const verifiedAt = req.user.recovery_verified_at;
  if (!['email', 'phone'].includes(req.user.recovery_channel) ||
      !Number.isInteger(verifiedAt) || verifiedAt > Date.now() / 1000 ||
      Date.now() / 1000 - verifiedAt > 300) {
    return res.status(403).json({ error: 'Verify the contact you can still access again before replacing the other one.' });
  }
  next();
});

async function currentUser(id) {
  const { rows } = await db.query(
    'SELECT id, email, phone_number, is_email_verified, is_phone_verified FROM users WHERE id = $1 AND deleted = FALSE', [id]
  );
  return rows[0];
}

function normalize(value, channel) {
  if (typeof value !== 'string') return null;
  if (channel === 'email') {
    const email = value.trim().toLowerCase();
    return email.length <= 255 && /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email) ? email : null;
  }
  let phone = value.trim().replace(/[\s().-]/g, '');
  if (/^\d{10}$/.test(phone)) phone = `+91${phone}`;
  return /^\+[1-9]\d{9,14}$/.test(phone) ? phone : null;
}

async function contactAvailable(value, channel, userId) {
  const query = channel === 'email'
    ? ['SELECT id FROM users WHERE lower(email) = $1 AND id <> $2', [value, userId]]
    : ['SELECT id FROM users WHERE (phone_number = $1 OR phone_number = $2) AND id <> $3',
      [...preparePhoneSearchParams(value), userId]];
  return (await db.query(...query)).rows.length === 0;
}

router.post('/request', async (req, res) => {
  try {
    const channel = req.user.recovery_channel === 'email' ? 'phone' : 'email';
    const value = normalize(req.body.identifier, channel);
    if (!value) return res.status(400).json({ error: `Enter a valid new ${channel === 'phone' ? 'phone number with country code' : 'email address'}.` });
    if (channel === 'phone' ? !config.enablePhoneOtp : !config.enableEmailOtp) {
      return res.status(403).json({ error: `${channel === 'phone' ? 'SMS' : 'Email'} verification is currently unavailable. Your linked contact has not been changed.` });
    }
    const user = await currentUser(req.user.id);
    if (!user) return res.status(404).json({ error: 'Account not found' });
    if (!await contactAvailable(value, channel, user.id)) {
      return res.status(409).json({ error: 'This contact cannot be linked. Use another contact.' });
    }
    // Keep replacement OTPs separate from sign-in OTPs and bind the code
    // to this account through a short-lived, signed challenge.
    const otpIdentifier = `replacement-${randomUUID()}@recovery.invalid`;
    const { code, requestId } = await createOtp(otpIdentifier, 'email', 'replacement');
    const delivery = channel === 'email' ? await sendOtpEmail(value, code) : await sendOtpSms(value, code);
    if (!delivery?.success) {
      await discardUndeliveredOtp(otpIdentifier, 'email', requestId, 'replacement');
      return res.status(503).json({ error: 'Unable to send the verification code. Your contact has not been changed.' });
    }
    const active = getActiveKey();
    const challenge = jwt.sign({
      sub: user.id, channel, value, otp_identifier: otpIdentifier,
      previous: fingerprint(channel === 'email' ? user.email : user.phone_number),
    }, active.secret, { issuer: getIssuer(), audience: audience(), expiresIn: '2m', keyid: active.keyId });
    return res.json({ challenge, contact_hint: channel === 'email' ? maskEmail(value) : maskPhone(value) });
  } catch (error) {
    console.error('Recovery contact request failed:', error.code || error.name);
    return res.status(500).json({ error: 'Unable to request verification. Please try again.' });
  }
});

router.post('/verify', async (req, res) => {
  try {
    const { challenge, code } = req.body;
    if (typeof challenge !== 'string' || challenge.length > 4096 || !/^\d{4}$/.test(String(code))) {
      return res.status(400).json({ error: 'Enter the 4-digit verification code.' });
    }
    let proof;
    try {
      const decoded = jwt.decode(challenge, { complete: true });
      const secret = getKeySecret(decoded?.header?.kid);
      if (!secret) throw new Error('Unknown key');
      proof = jwt.verify(challenge, secret, { issuer: getIssuer(), audience: audience(), algorithms: ['HS256'] });
    } catch (_) {
      return res.status(400).json({ error: 'Verification expired. Request a new code.' });
    }
    const channel = req.user.recovery_channel === 'email' ? 'phone' : 'email';
    if (proof.sub !== req.user.id || proof.channel !== channel) {
      return res.status(403).json({ error: 'This verification does not match your recovery request.' });
    }
    const user = await currentUser(req.user.id);
    if (!user) return res.status(404).json({ error: 'Account not found' });
    const previous = channel === 'email' ? user.email : user.phone_number;
    if (proof.previous !== fingerprint(previous)) {
      return res.status(409).json({ error: 'Your linked contact changed. Start verification again.' });
    }
    if (!await contactAvailable(proof.value, channel, user.id)) {
      return res.status(409).json({ error: 'This contact cannot be linked. Use another contact.' });
    }
    const verified = await verifyOtp(proof.otp_identifier, String(code), 'email');
    if (!verified.ok) return res.status(400).json({ error: 'Invalid or expired code. Your contact has not been changed.' });
    const column = channel === 'email' ? 'email' : 'phone_number';
    const flag = channel === 'email' ? 'is_email_verified' : 'is_phone_verified';
    const value = channel === 'email' ? proof.value : encryptPhoneNumber(proof.value);
    const updated = await db.query(
      `UPDATE users SET ${column} = $1, ${flag} = TRUE, updated_at = NOW()
       WHERE id = $2 AND ${column} IS NOT DISTINCT FROM $3 AND deleted = FALSE RETURNING id`,
      [value, user.id, previous]
    );
    if (!updated.rows.length) return res.status(409).json({ error: 'Your linked contact changed. Start verification again.' });
    user[column] = value;
    user[flag] = true;
    const phoneVerified = Boolean(user.phone_number && user.is_phone_verified);
    const emailVerified = Boolean(user.email && user.is_email_verified);
    return res.json({
      ok: true,
      phone_verified: phoneVerified, email_verified: emailVerified,
      has_backup_channel: phoneVerified && emailVerified,
      missing_channel: phoneVerified && emailVerified ? null : phoneVerified ? 'email' : 'phone',
      email_hint: maskEmail(user.email),
      phone_hint: maskPhone(decryptPhoneNumber(user.phone_number)),
    });
  } catch (error) {
    if (error.code === '23505') return res.status(409).json({ error: 'This contact cannot be linked. Use another contact.' });
    console.error('Recovery contact verification failed:', error.code || error.name);
    return res.status(500).json({ error: 'Unable to update the contact. Please try again.' });
  }
});

module.exports = router;
