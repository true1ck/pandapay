'use strict';

const express = require('express');
const db = require('../db');
const config = require('../config');
const auth = require('../middleware/authMiddleware');
const { userRateLimitRead, userRateLimitSensitive } = require('../middleware/userRateLimit');
const { RateLimitStorageError, RateLimitExceededError, consumeBudget } = require('../middleware/rateLimitMiddleware');
const { PhoneClaimError, claimPhone, getPhoneClaimStatus } = require('../services/phoneClaim');
const { safeErrorCode } = require('../utils/safeErrorCode');

const router = express.Router();

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

module.exports = router;
