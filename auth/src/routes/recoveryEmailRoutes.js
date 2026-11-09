'use strict';

const express = require('express');
const jwt = require('jsonwebtoken');
const db = require('../db');
const auth = require('../middleware/authMiddleware');
const { userRateLimitRead, userRateLimitSensitive } = require('../middleware/userRateLimit');
const { requireRecentOtpOrReauth } = require('../middleware/stepUpAuth');
const { RateLimitStorageError, RateLimitExceededError, consumeBudget } = require('../middleware/rateLimitMiddleware');
const { getActiveKey, getKeySecret, getIssuer, getAudience } = require('../services/jwtKeys');
const { createOtpV2, verifyOtpV2, discardUndeliveredOtpV2, V2_TTL_SECONDS } = require('../services/otpService');
const { sendOtpEmail, sendSecurityNotice } = require('../services/emailService');
const { OtpCapacityError, respondOtpCapacityUnavailable } = require('../services/otpWorkAdmission');
const recoveryEmail = require('../services/recoveryEmail');
const { safeErrorCode } = require('../utils/safeErrorCode');

const router = express.Router();
const { RecoveryEmailError } = recoveryEmail;

const DEVICE = /^[A-Za-z0-9:_-]{4,128}$/;
const MESSAGES = Object.freeze({
  email_invalid: 'Enter a valid email address.',
  email_not_allowed: 'Please use your regular email address, not a temporary one.',
  same_as_sign_in: 'That is already your sign-in email. Use a different address as your recovery email.',
  email_unavailable: "This email can't be used as a recovery email. Choose another address.",
  sign_in_email_required: 'Your account needs a verified sign-in email before it can have a recovery email.',
  delivery_failed: 'We could not send the codes right now. Please try again shortly.',
  challenge_invalid: 'That request expired. Start again and use the newest codes.',
  code_invalid: 'One of the codes is wrong or has expired. Start again and use the newest codes.',
  account_unavailable: 'Please sign in again.',
  nothing_to_remove: 'There is no recovery email to remove.',
});

// Each try sends two emails and counts toward a guess limit, so the numbers are small.
const START_PER_USER_DAY = 5;
const START_PER_IP_DAY = 20;
const FINISH_PER_USER_HOUR = 10;

const jwtApi = {
  sign(claims, expiresIn) {
    const active = getActiveKey();
    return jwt.sign(claims, active.secret, {
      issuer: getIssuer(), audience: `${getAudience()}:recovery-email:v2`, expiresIn, keyid: active.keyId,
    });
  },
  verify(token) {
    if (typeof token !== 'string' || token.length > 4096) throw new Error('invalid');
    const decoded = jwt.decode(token, { complete: true });
    const secret = getKeySecret(decoded?.header?.kid);
    if (!secret) throw new Error('unknown key');
    return jwt.verify(token, secret, {
      algorithms: ['HS256'], issuer: getIssuer(), audience: `${getAudience()}:recovery-email:v2`,
    });
  },
};

router.use((_req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

async function writeAudit(req, action, status, outcome) {
  try {
    await db.query(
      `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address, user_agent, meta)
       VALUES ($1, $2, $3, $4, $5, $6, $7)`,
      [req.user.id, action, status, req.user.device_id || null, req.ip || null,
        req.headers['user-agent'] || null, JSON.stringify({ outcome })],
    );
  } catch (error) {
    console.error('[recovery-email] audit write failed', safeErrorCode(error));
  }
}

function fail(res, error) {
  if (error instanceof RateLimitExceededError) {
    return res.status(429).json({ error: 'too_many_attempts', message: 'Too many tries. Please try again later or contact support.' });
  }
  if (error instanceof RateLimitStorageError) {
    return res.status(503).json({ error: 'temporarily_unavailable', message: 'Please try again shortly.' });
  }
  if (error instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
  if (error instanceof RecoveryEmailError) {
    if (error.busy === 'otp_capacity_unavailable') return respondOtpCapacityUnavailable(res);
    return res.status(error.status).json({ error: error.code, message: MESSAGES[error.code] });
  }
  console.error('[recovery-email] failed', safeErrorCode(error));
  return res.status(500).json({ error: 'Internal server error' });
}

// Only a normal, device-bound session may change recovery details. A recovery
// session proves one contact only.
function requireOrdinarySession(req, res, next) {
  if (req.user.recovery_channel) {
    return res.status(403).json({ error: 'recovery_session', message: 'Sign in normally to change your recovery email.' });
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

// GET /users/me/recovery-email
router.get('/', auth, userRateLimitRead, async (req, res) => {
  try {
    return res.json(await recoveryEmail.getStatus({ query: (...a) => db.query(...a), userId: req.user.id }));
  } catch (error) {
    return fail(res, error);
  }
});

// POST /users/me/recovery-email/request  { email, device_id }
router.post('/request', auth, userRateLimitSensitive, requireOrdinarySession, async (req, res) => {
  if (!exactBody(req, ['email', 'device_id']) || req.body.device_id !== req.user.device_id) {
    return res.status(400).json({ error: 'email_invalid', message: MESSAGES.email_invalid });
  }
  try {
    await consumeBudget('recovery-email-start-user', req.user.id, START_PER_USER_DAY, 86400);
    await consumeBudget('recovery-email-start-ip', req.ip || 'unknown', START_PER_IP_DAY, 86400);
    const result = await recoveryEmail.startChange({
      query: (...a) => db.query(...a),
      userId: req.user.id,
      email: req.body.email,
      deviceId: req.user.device_id,
      otp: { createOtpV2, discardUndeliveredOtpV2 },
      mail: { sendOtpEmail },
      jwtApi,
      ttlSeconds: V2_TTL_SECONDS,
    });
    await writeAudit(req, 'recovery_email_request', 'success', 'codes_sent');
    return res.json({ ...result, version: 2, code_length: 6 });
  } catch (error) {
    if (error instanceof RecoveryEmailError) await writeAudit(req, 'recovery_email_request', 'failed', error.code);
    return fail(res, error);
  }
});

// POST /users/me/recovery-email/verify  { challenge, signin_code, recovery_code, device_id }
router.post('/verify', auth, userRateLimitSensitive, requireOrdinarySession, async (req, res) => {
  if (!exactBody(req, ['challenge', 'signin_code', 'recovery_code', 'device_id']) ||
      req.body.device_id !== req.user.device_id ||
      !/^\d{6}$/.test(req.body.signin_code) || !/^\d{6}$/.test(req.body.recovery_code)) {
    return res.status(400).json({ error: 'code_invalid', message: 'Enter both 6-digit codes.' });
  }
  try {
    await consumeBudget('recovery-email-finish-user', req.user.id, FINISH_PER_USER_HOUR, 3600);
    const result = await recoveryEmail.finishChange({
      query: (...a) => db.query(...a),
      userId: req.user.id,
      deviceId: req.user.device_id,
      challenge: req.body.challenge,
      signInCode: req.body.signin_code,
      newCode: req.body.recovery_code,
      otp: { verifyOtpV2 },
      mail: { sendSecurityNotice },
      jwtApi,
    });
    await writeAudit(req, 'recovery_email_set', 'success', 'saved');
    return res.json({ ok: true, ...result });
  } catch (error) {
    if (error instanceof RecoveryEmailError) await writeAudit(req, 'recovery_email_set', 'failed', error.code);
    return fail(res, error);
  }
});

// DELETE /users/me/recovery-email  (needs a recent sign-in code)
router.delete('/', auth, userRateLimitSensitive, requireOrdinarySession, requireRecentOtpOrReauth, async (req, res) => {
  try {
    const result = await recoveryEmail.removeRecoveryEmail({
      query: (...a) => db.query(...a), userId: req.user.id, mail: { sendSecurityNotice },
    });
    await writeAudit(req, 'recovery_email_removed', 'success', 'removed');
    return res.json({ ok: true, ...result });
  } catch (error) {
    return fail(res, error);
  }
});

module.exports = router;
