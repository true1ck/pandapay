'use strict';

const express = require('express');
const db = require('../db');
const config = require('../config');
const auth = require('../middleware/authMiddleware');
const { userRateLimitRead, userRateLimitSensitive } = require('../middleware/userRateLimit');
const { RateLimitStorageError, RateLimitExceededError, consumeBudget } = require('../middleware/rateLimitMiddleware');
const { PhoneClaimError, claimPhone, getPhoneClaimStatus } = require('../services/phoneClaim');
const { safeErrorCode } = require('../utils/safeErrorCode');
const jwt = require('jsonwebtoken');
const { getActiveKey, getKeySecret, getIssuer, getAudience } = require('../services/jwtKeys');
const { createOtpV2, verifyOtpV2, discardUndeliveredOtpV2, V2_TTL_SECONDS } = require('../services/otpService');
const { sendOtpEmail, sendSecurityNotice } = require('../services/emailService');
const { OtpCapacityError, respondOtpCapacityUnavailable } = require('../services/otpWorkAdmission');
const phoneChange = require('../services/phoneChange');

const { PhoneChangeError } = phoneChange;
const router = express.Router();

const DEVICE = /^[A-Za-z0-9:_-]{4,128}$/;
// Each start sends one email and each finish is a code guess, so the numbers are small.
const CHANGE_START_PER_USER_DAY = 5;
const CHANGE_START_PER_IP_DAY = 20;
const CHANGE_FINISH_PER_USER_HOUR = 10;

const jwtApi = {
  sign(claims, expiresIn) {
    const active = getActiveKey();
    return jwt.sign(claims, active.secret, {
      issuer: getIssuer(), audience: `${getAudience()}:phone-change:v1`, expiresIn, keyid: active.keyId,
    });
  },
  verify(token) {
    if (typeof token !== 'string' || token.length > 4096) throw new Error('invalid');
    const decoded = jwt.decode(token, { complete: true });
    const secret = getKeySecret(decoded?.header?.kid);
    if (!secret) throw new Error('unknown key');
    return jwt.verify(token, secret, {
      algorithms: ['HS256'], issuer: getIssuer(), audience: `${getAudience()}:phone-change:v1`,
    });
  },
};

// A claimed number tells the caller whether the number is already registered,
// so the number of tries is small. One person, and one address, per day.
const USER_TRIES_PER_DAY = 5;
const IP_TRIES_PER_DAY = 30;
const DAY_SECONDS = 86400;

// What the person is told. The refusal never says which account holds a number.
const MESSAGES = Object.freeze({
  phone_invalid: 'Enter a valid 10-digit mobile number.',
  phone_country_unsupported: 'We only support Indian mobile numbers for now.',
  phone_unavailable: "This number can't be used. If it is yours, sign in with the email you first used, or contact support.",
  phone_already_set: 'A phone number is already saved on this account. Contact support to change it.',
  account_unavailable: 'Please sign in again.',
});

router.use((_req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

async function writeAudit(req, status, outcome) {
  try {
    await db.query(
      `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address, user_agent, meta)
       VALUES ($1, 'phone_claim', $2, $3, $4, $5, $6)`,
      [req.user.id, status, req.user.device_id || null, req.ip || null,
        req.headers['user-agent'] || null, JSON.stringify({ outcome })],
    );
  } catch (error) {
    console.error('[phone-claim] audit write failed', safeErrorCode(error));
  }
}

// GET /users/me/phone — is a phone on this account, and does the lock need one?
router.get('/', auth, userRateLimitRead, async (req, res) => {
  try {
    const status = await getPhoneClaimStatus({ query: (...args) => db.query(...args), userId: req.user.id });
    return res.json(status);
  } catch (error) {
    if (error instanceof PhoneClaimError) return res.status(error.status).json({ error: error.code, message: MESSAGES[error.code] });
    console.error('[phone-claim] status failed', safeErrorCode(error));
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// POST /users/me/phone — type a number; it is locked to this account.
router.post('/', auth, userRateLimitSensitive, async (req, res) => {
  // A recovery session proves one contact only. It must not set a phone.
  if (req.user.recovery_channel) {
    return res.status(403).json({ error: 'recovery_session', message: 'Sign in normally to add a phone number.' });
  }
  const body = req.body;
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some(key => key !== 'phone_number') || typeof body.phone_number !== 'string') {
    return res.status(400).json({ error: 'phone_invalid', message: MESSAGES.phone_invalid });
  }
  try {
    await consumeBudget('phone-claim-user', req.user.id, USER_TRIES_PER_DAY, DAY_SECONDS);
    await consumeBudget('phone-claim-ip', req.ip || 'unknown', IP_TRIES_PER_DAY, DAY_SECONDS);
    const result = await claimPhone({
      pool: await db.pool,
      userId: req.user.id,
      phone: body.phone_number,
      countries: config.allowedPhoneCountries,
    });
    await writeAudit(req, 'success', result.already ? 'already_set' : 'claimed');
    return res.json({ ok: true, phone_hint: result.phone_hint });
  } catch (error) {
    if (error instanceof RateLimitExceededError) {
      return res.status(429).json({ error: 'too_many_attempts', message: 'Too many tries today. Please try again tomorrow or contact support.' });
    }
    if (error instanceof RateLimitStorageError) {
      return res.status(503).json({ error: 'temporarily_unavailable', message: 'Please try again shortly.' });
    }
    if (error instanceof PhoneClaimError) {
      await writeAudit(req, 'failed', error.code);
      return res.status(error.status).json({ error: error.code, message: MESSAGES[error.code] });
    }
    console.error('[phone-claim] failed', safeErrorCode(error));
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// ---- Add or change the phone, confirmed with a code sent to the sign-in email ----

const CHANGE_MESSAGES = Object.freeze({
  ...MESSAGES,
  phone_already_set: 'This number is tied to your sign-in and can only be changed by support.',
  same_phone: 'That is already the number on your account.',
  sign_in_email_required: 'Your account needs a verified sign-in email before you can change your phone number.',
  delivery_failed: 'We could not send the code right now. Please try again shortly.',
  challenge_invalid: 'That request expired. Start again and use the newest code.',
  code_invalid: 'That code is wrong or has expired. Start again and use the newest code.',
});

function requireOrdinarySession(req, res, next) {
  if (req.user.recovery_channel) {
    return res.status(403).json({ error: 'recovery_session', message: 'Sign in normally to change your phone number.' });
  }
  if (typeof req.user.device_id !== 'string' || !DEVICE.test(req.user.device_id)) {
    return res.status(403).json({ error: 'device_required', message: 'Please sign in again.' });
  }
  return next();
}

function exactBody(req, allowed) {
  const body = req.body;
  return body && typeof body === 'object' && !Array.isArray(body) &&
    Object.keys(body).every(key => allowed.includes(key)) &&
    allowed.every(key => typeof body[key] === 'string');
}

function failChange(res, error) {
  if (error instanceof RateLimitExceededError) {
    return res.status(429).json({ error: 'too_many_attempts', message: 'Too many tries. Please try again later or contact support.' });
  }
  if (error instanceof RateLimitStorageError) {
    return res.status(503).json({ error: 'temporarily_unavailable', message: 'Please try again shortly.' });
  }
  if (error instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
  if (error instanceof PhoneChangeError) {
    if (error.busy === 'otp_capacity_unavailable') return respondOtpCapacityUnavailable(res);
    return res.status(error.status).json({ error: error.code, message: CHANGE_MESSAGES[error.code] });
  }
  console.error('[phone-change] failed', safeErrorCode(error));
  return res.status(500).json({ error: 'Internal server error' });
}

// POST /users/me/phone/change/request  { phone_number, device_id }
router.post('/change/request', auth, userRateLimitSensitive, requireOrdinarySession, async (req, res) => {
  if (!exactBody(req, ['phone_number', 'device_id']) || req.body.device_id !== req.user.device_id) {
    return res.status(400).json({ error: 'phone_invalid', message: MESSAGES.phone_invalid });
  }
  try {
    await consumeBudget('phone-change-start-user', req.user.id, CHANGE_START_PER_USER_DAY, DAY_SECONDS);
    await consumeBudget('phone-change-start-ip', req.ip || 'unknown', CHANGE_START_PER_IP_DAY, DAY_SECONDS);
    const result = await phoneChange.startChange({
      query: (...args) => db.query(...args),
      userId: req.user.id,
      phone: req.body.phone_number,
      deviceId: req.user.device_id,
      countries: config.allowedPhoneCountries,
      otp: { createOtpV2, discardUndeliveredOtpV2 },
      mail: { sendOtpEmail },
      jwtApi,
      ttlSeconds: V2_TTL_SECONDS,
    });
    await writeAudit(req, 'success', 'change_code_sent');
    return res.json({ ...result, code_length: 6 });
  } catch (error) {
    if (error instanceof PhoneChangeError) await writeAudit(req, 'failed', `change_request_${error.code}`);
    return failChange(res, error);
  }
});

// POST /users/me/phone/change/confirm  { challenge, code, device_id }
router.post('/change/confirm', auth, userRateLimitSensitive, requireOrdinarySession, async (req, res) => {
  if (!exactBody(req, ['challenge', 'code', 'device_id']) || req.body.device_id !== req.user.device_id ||
      !/^\d{6}$/.test(req.body.code)) {
    return res.status(400).json({ error: 'code_invalid', message: 'Enter the 6-digit code.' });
  }
  try {
    await consumeBudget('phone-change-finish-user', req.user.id, CHANGE_FINISH_PER_USER_HOUR, 3600);
    const result = await phoneChange.finishChange({
      query: (...args) => db.query(...args),
      pool: await db.pool,
      userId: req.user.id,
      deviceId: req.user.device_id,
      countries: config.allowedPhoneCountries,
      challenge: req.body.challenge,
      code: req.body.code,
      otp: { verifyOtpV2 },
      mail: { sendSecurityNotice },
      jwtApi,
    });
    await writeAudit(req, 'success', result.had_phone ? 'changed' : 'added');
    return res.json({ ok: true, phone_hint: result.phone_hint });
  } catch (error) {
    if (error instanceof PhoneChangeError) await writeAudit(req, 'failed', `change_confirm_${error.code}`);
    return failChange(res, error);
  }
});

module.exports = router;
