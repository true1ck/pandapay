const { safeErrorCode } = require('../utils/safeErrorCode');
const express = require('express');
const jwt = require('jsonwebtoken');
const { randomUUID, createHash } = require('crypto');
const db = require('../db');
const config = require('../config');
const auth = require('../middleware/authMiddleware');
const { userRateLimitSensitive } = require('../middleware/userRateLimit');
const {
  RateLimitStorageError,
  RateLimitExceededError,
  ActiveOtpError,
  consumeReplacementBudget,
} = require('../middleware/rateLimitMiddleware');
const { getActiveKey, getKeySecret, getIssuer, getAudience } = require('../services/jwtKeys');
const { createOtp, verifyOtp, discardUndeliveredOtp, createOtpV2, verifyOtpV2, discardUndeliveredOtpV2, V2_TTL_SECONDS } = require('../services/otpService');
const { sendOtpEmail } = require('../services/emailService');
const { sendOtpSms } = require('../services/smsService');
const { OtpCapacityError, BUSY_CODE, respondOtpCapacityUnavailable } = require('../services/otpWorkAdmission');
const { encryptPhoneNumber, decryptPhoneNumber } = require('../utils/fieldEncryption');
const { preparePhoneSearchParams, phoneLookupHash } = require('../utils/encryptedPhoneSearch');
const { maskEmail, maskPhone, maskPhonePrefix } = require('../utils/recoveryContacts');

const router = express.Router();
const fingerprint = value => createHash('sha256').update(value || '').digest('hex');
const audience = (versioned = false) => `${getAudience()}:contact-replacement${versioned ? ':v2' : ''}`;
const DEVICE = /^[A-Za-z0-9:_-]{4,128}$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const deviceFingerprint = value => fingerprint(`pandapay-contact-device-v2\0${value}`);

router.use((_req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

function admitProtocol(req, res, versioned, verify = false) {
  if (!versioned) {
    if (config.retireLegacyOtp === true) {
      res.status(410).json({ error: 'client_update_required', message: 'Please update PandaPay to continue signing in.' });
      return false;
    }
    return true;
  }
  const allowed = verify ? ['challenge', 'code', 'device_id'] : ['identifier', 'device_id'];
  if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body) ||
      Object.keys(req.body).some(key => !allowed.includes(key)) || Object.keys(req.query || {}).length ||
      typeof req.body.device_id !== 'string' || !DEVICE.test(req.body.device_id)) {
    res.status(400).json({ error: 'invalid_v2_contact_request' });
    return false;
  }
  // Only the authenticated, signed device claim authorizes the binding.
  if (req.user.device_id !== req.body.device_id) {
    res.status(403).json({ error: 'This verification does not match your recovery request.' });
    return false;
  }
  return true;
}
const ABUSE_STORE_UNAVAILABLE_MESSAGE = 'Authentication is temporarily unavailable. Please try again shortly.';

function isRateLimitStorageError(error) {
  return typeof RateLimitStorageError === 'function' && error instanceof RateLimitStorageError;
}

function isActiveOtpError(error) {
  return typeof ActiveOtpError === 'function' && error instanceof ActiveOtpError;
}

function isRateLimitExceededError(error) {
  return typeof RateLimitExceededError === 'function' && error instanceof RateLimitExceededError;
}

function respondReplacementBudgetExceeded(res) {
  return res.status(429).json({ error: 'Too many contact replacement attempts. Please try again later.' });
}

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
    ? ['SELECT id FROM users WHERE lower(email) = $1 AND deleted = FALSE AND id <> $2', [value, userId]]
    : ['SELECT id FROM users WHERE phone_lookup_hash = $1 AND deleted = FALSE AND id <> $2',
      [...preparePhoneSearchParams(value), userId]];
  return (await db.query(...query)).rows.length === 0;
}

async function requestReplacement(req, res, versioned = false) {
  try {
    if (!admitProtocol(req, res, versioned)) return;
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
    await consumeReplacementBudget(user.id, channel, 'request');
    // Keep replacement OTPs separate from sign-in OTPs and bind the code
    // to this account through a short-lived, signed challenge.
    const otpIdentifier = `replacement-${randomUUID()}@recovery.invalid`;
    const issuedAt = Date.now();
    const { code, requestId } = versioned
      ? await createOtpV2(otpIdentifier, 'email', 'replacement', req.body.device_id)
      : await createOtp(otpIdentifier, 'email', 'replacement');
    const discard = () => versioned
      ? discardUndeliveredOtpV2(otpIdentifier, 'email', requestId, 'replacement', req.body.device_id)
      : discardUndeliveredOtp(otpIdentifier, 'email', requestId, 'replacement');
    let delivery;
    try {
      delivery = channel === 'email' ? await sendOtpEmail(value, code) : await sendOtpSms(value, code);
    } catch (error) {
      if (!versioned) throw error;
      await discard();
      return res.status(503).json({ error: 'Unable to send the verification code. Your contact has not been changed.' });
    }
    const expiresIn = versioned ? Math.max(0, V2_TTL_SECONDS - Math.ceil((Date.now() - issuedAt) / 1000)) : 120;
    if (!delivery?.success || expiresIn < 1) {
      await discard();
      if (delivery?.code === BUSY_CODE) return respondOtpCapacityUnavailable(res);
      return res.status(503).json({ error: 'Unable to send the verification code. Your contact has not been changed.' });
    }
    const active = getActiveKey();
    const challenge = jwt.sign({
      sub: user.id, channel, value, otp_identifier: otpIdentifier,
      previous: fingerprint(channel === 'email' ? user.email : user.phone_number),
      ...(versioned ? { protocol_version: 2, purpose: 'replacement', otp_request_id: requestId, device_binding_hash: deviceFingerprint(req.body.device_id) } : {}),
    }, active.secret, { issuer: getIssuer(), audience: audience(versioned), expiresIn, keyid: active.keyId });
    return res.json({ challenge, contact_hint: channel === 'email' ? maskEmail(value) : maskPhone(value),
      ...(versioned ? { version: 2, code_length: 6, expires_in: expiresIn } : {}) });
  } catch (error) {
    console.error('Recovery contact request failed:', safeErrorCode(error));
    if (error instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
    if (isRateLimitExceededError(error)) return respondReplacementBudgetExceeded(res);
    if (isActiveOtpError(error)) return res.status(429).json({ error: 'An OTP is already active. Please wait a moment before requesting a new one.' });
    if (isRateLimitStorageError(error)) return res.status(503).json({ error: ABUSE_STORE_UNAVAILABLE_MESSAGE });
    return res.status(500).json({ error: 'Unable to request verification. Please try again.' });
  }
}

async function verifyReplacement(req, res, versioned = false) {
  try {
    if (!admitProtocol(req, res, versioned, true)) return;
    const { challenge, code } = req.body;
    if (typeof challenge !== 'string' || challenge.length > 4096 ||
        (versioned ? (typeof code !== 'string' || !/^\d{6}$/.test(code)) : !/^\d{4}$/.test(String(code)))) {
      return res.status(400).json({ error: `Enter the ${versioned ? 6 : 4}-digit verification code.` });
    }
    let proof;
    try {
      const decoded = jwt.decode(challenge, { complete: true });
      const secret = getKeySecret(decoded?.header?.kid);
      if (!secret) throw new Error('Unknown key');
      proof = jwt.verify(challenge, secret, { issuer: getIssuer(), audience: audience(versioned), algorithms: ['HS256'] });
    } catch (_) {
      return res.status(400).json({ error: 'Verification expired. Request a new code.' });
    }
    const channel = req.user.recovery_channel === 'email' ? 'phone' : 'email';
    if (proof.sub !== req.user.id || proof.channel !== channel ||
        (versioned && (proof.protocol_version !== 2 || proof.purpose !== 'replacement' ||
          !UUID.test(proof.otp_request_id || '') || proof.device_binding_hash !== deviceFingerprint(req.body.device_id) ||
          normalize(proof.value, channel) !== proof.value || !/^replacement-[0-9a-f-]{36}@recovery\.invalid$/i.test(proof.otp_identifier || '')))) {
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
    await consumeReplacementBudget(user.id, channel, 'verify');
    const verified = versioned
      ? await verifyOtpV2(proof.otp_identifier, code, 'email', 'replacement', req.body.device_id, proof.otp_request_id)
      : await verifyOtp(proof.otp_identifier, String(code), 'email', 'replacement');
    if (!verified.ok) return res.status(400).json({ error: 'Invalid or expired code. Your contact has not been changed.' });
    const column = channel === 'email' ? 'email' : 'phone_number';
    const flag = channel === 'email' ? 'is_email_verified' : 'is_phone_verified';
    const value = channel === 'email' ? proof.value : encryptPhoneNumber(proof.value);
    const updated = channel === 'email'
      ? await db.query(
          `UPDATE users SET email = $1, is_email_verified = TRUE, updated_at = NOW()
           WHERE id = $2 AND email IS NOT DISTINCT FROM $3 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
          [value, user.id, previous]
        )
      : await db.query(
          `UPDATE users SET phone_number = $1, phone_lookup_hash = $2,
                            is_phone_verified = TRUE, updated_at = NOW()
           WHERE id = $3 AND phone_number IS NOT DISTINCT FROM $4 AND deleted = FALSE AND is_active = TRUE RETURNING id`,
          [value, phoneLookupHash(proof.value), user.id, previous]
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
      phone_hint: req.user?.recovery_channel ? maskPhonePrefix(decryptPhoneNumber(user.phone_number)) : maskPhone(decryptPhoneNumber(user.phone_number)),
    });
  } catch (error) {
    if (error.code === '23505') return res.status(409).json({ error: 'This contact cannot be linked. Use another contact.' });
    console.error('Recovery contact verification failed:', safeErrorCode(error));
    if (error instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
    if (isRateLimitExceededError(error)) return respondReplacementBudgetExceeded(res);
    if (isRateLimitStorageError(error)) return res.status(503).json({ error: ABUSE_STORE_UNAVAILABLE_MESSAGE });
    return res.status(500).json({ error: 'Unable to update the contact. Please try again.' });
  }
}

router.post('/request', (req, res) => requestReplacement(req, res));
router.post('/verify', (req, res) => verifyReplacement(req, res));
router.post('/v2/request', (req, res) => requestReplacement(req, res, true));
router.post('/v2/verify', (req, res) => verifyReplacement(req, res, true));

module.exports = router;
