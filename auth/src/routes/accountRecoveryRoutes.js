'use strict';

const express = require('express');
const db = require('../db');
const config = require('../config');
const { RateLimitStorageError, RateLimitExceededError, consumeBudget } = require('../middleware/rateLimitMiddleware');
const { createOtpV2, verifyOtpV2, discardUndeliveredOtpV2 } = require('../services/otpService');
const { sendOtpEmail, sendSecurityNotice } = require('../services/emailService');
const { OtpCapacityError, respondOtpCapacityUnavailable } = require('../services/otpWorkAdmission');
const { signAccessToken, issueRefreshToken } = require('../services/tokenService');
const { cardFact } = require('../services/productApiClient');
const { createAccountRecovery, RecoveryError } = require('../services/accountRecovery');
const { safeErrorCode } = require('../utils/safeErrorCode');

const MESSAGES = Object.freeze({
  invalid_request: 'Check the details and try again.',
  recovery_failed: 'That did not match. Check the details, or use the newest code.',
  too_many_attempts: 'Too many tries. Please try again later, or contact support.',
  email_invalid: 'Enter a valid email address.',
  email_not_allowed: 'Please use your regular email address, not a temporary one.',
  same_as_old_email: 'That is the email you are replacing. Enter a different address.',
  email_unavailable: "This email can't be used. Choose another address.",
  code_invalid: 'That code is wrong or has expired. Check it and try again.',
  hold_not_over: 'The 24 hours are not over yet.',
  nothing_pending: 'There is no recovery waiting.',
  account_unavailable: 'This account is not available. Contact support.',
  delivery_failed: 'We could not send the code right now. Please try again shortly.',
});

const recovery = createAccountRecovery({
  query: (...a) => db.query(...a),
  transaction: async work => {
    const pool = await db.pool;
    const client = await pool.connect();
    try {
      await client.query('BEGIN');
      const result = await work(client);
      await client.query('COMMIT');
      return result;
    } catch (error) {
      try { await client.query('ROLLBACK'); } catch (_) { /* original error wins */ }
      throw error;
    } finally {
      client.release();
    }
  },
  otp: { createOtpV2, verifyOtpV2, discardUndeliveredOtpV2 },
  mail: { sendOtpEmail, sendSecurityNotice },
  cardFact,
  budget: consumeBudget,
  publicBaseUrl: config.authPublicBaseUrl,
  issueSession: async ({ client, user, deviceId, ip, userAgent }) => ({
    access_token: signAccessToken(user, { highAssurance: true, deviceId, verifiedChannel: 'email' }),
    refresh_token: await issueRefreshToken({ userId: user.id, deviceId, userAgent, ip, executor: client }),
    user: { id: user.id, email: user.email, name: user.name, role: user.role },
  }),
});

const publicRouter = express.Router();
publicRouter.use((_req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

function exact(req, required, optional = []) {
  const b = req.body;
  if (!b || typeof b !== 'object' || Array.isArray(b)) return false;
  const keys = Object.keys(b);
  return keys.every(k => required.includes(k) || optional.includes(k)) && required.every(k => typeof b[k] === 'string') &&
    optional.every(k => b[k] === undefined || typeof b[k] === 'string' || typeof b[k] === 'boolean');
}

function respondError(res, error) {
  if (error instanceof RateLimitExceededError) return res.status(429).json({ error: 'too_many_attempts', message: MESSAGES.too_many_attempts });
  if (error instanceof RateLimitStorageError) return res.status(503).json({ error: 'temporarily_unavailable', message: 'Please try again shortly.' });
  if (error instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
  if (error instanceof RecoveryError) {
    return res.status(error.status).json({
      error: error.code, message: MESSAGES[error.code] || MESSAGES.invalid_request,
      ...(error.hold_until ? { hold_until: error.hold_until } : {}),
    });
  }
  console.error('[recovery] failed', safeErrorCode(error));
  return res.status(500).json({ error: 'Internal server error' });
}

// A step is limited per attempt and per address, whatever its outcome.
async function stepBudget(req, attemptId) {
  await consumeBudget('recovery-step-attempt', String(attemptId || 'none').slice(0, 64).replace(/[^A-Za-z0-9-]/g, '') || 'none', 30, 3600);
  await consumeBudget('recovery-step-ip', req.ip || 'unknown', 120, 3600);
}

function route(path, required, optional, handler) {
  publicRouter.post(path, async (req, res) => {
    if (!exact(req, required, optional)) return res.status(400).json({ error: 'invalid_request', message: MESSAGES.invalid_request });
    try {
      if (path !== '/start') await stepBudget(req, req.body.attempt_id);
      return res.json(await handler(req));
    } catch (error) {
      return respondError(res, error);
    }
  });
}

route('/start', ['lost_email', 'phone', 'fact', 'device_id'], [], req => recovery.start({
  lostEmail: req.body.lost_email, phone: req.body.phone, fact: req.body.fact, deviceId: req.body.device_id, ip: req.ip,
}));
route('/verify-code', ['attempt_id', 'code', 'device_id'], [], req => recovery.verifyCode({
  attemptId: req.body.attempt_id, code: req.body.code, deviceId: req.body.device_id,
}));
route('/no-recovery-email', ['attempt_id', 'device_id'], [], req => recovery.noRecoveryEmail({
  attemptId: req.body.attempt_id, deviceId: req.body.device_id,
}));
route('/new-email', ['attempt_id', 'device_id'], ['new_email', 'use_recovery_email'], req => recovery.setNewEmail({
  attemptId: req.body.attempt_id, deviceId: req.body.device_id, newEmail: req.body.new_email,
  useRecoveryEmail: req.body.use_recovery_email === true,
}));
route('/complete', ['attempt_id', 'device_id'], ['code'], req => recovery.complete({
  attemptId: req.body.attempt_id, deviceId: req.body.device_id, newEmailCode: req.body.code,
  ip: req.ip, userAgent: req.headers['user-agent'],
}));
route('/finish', ['attempt_id', 'device_id', 'resume_token'], [], req => recovery.finish({
  attemptId: req.body.attempt_id, deviceId: req.body.device_id, resumeToken: req.body.resume_token,
  ip: req.ip, userAgent: req.headers['user-agent'],
}));

// The links in recovery emails. A browser opening a link must never change anything
// by itself (mail scanners open links), so GET only shows a button; the button POSTs.
const PAGE = (title, body) => `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
  `<meta name="viewport" content="width=device-width, initial-scale=1"><title>${title}</title></head>` +
  `<body><main><h1>${title}</h1>${body}</main></body></html>`;
const escapeHtml = value => String(value).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

publicRouter.get('/stop', (req, res) => {
  const stopToken = typeof req.query.token === 'string' ? req.query.token : '';
  res.status(200).type('html').send(PAGE('Stop this recovery', stopToken
    ? `<p>If you did not ask to change the sign-in email on your PandaPay account, stop it now. ` +
      `If a recovery is waiting it is cancelled; if it already happened your account is frozen until you contact support.</p>` +
      `<form method="post" action="/auth/recovery/stop"><input type="hidden" name="token" value="${escapeHtml(stopToken)}">` +
      `<button type="submit">Stop it</button></form>`
    : '<p>This link is not valid.</p>'));
});

publicRouter.post('/stop', express.urlencoded({ extended: false, limit: '2kb' }), async (req, res) => {
  try {
    await consumeBudget('recovery-stop-ip', req.ip || 'unknown', 30, 3600);
    const { outcome } = await recovery.stopByToken({ token: req.body?.token });
    const text = {
      cancelled: ['Recovery cancelled', 'The change was cancelled. Nothing on your account has changed.'],
      frozen: ['Account frozen', 'Your account is frozen and every session is signed out. Contact PandaPay support from the Help screen with the details of your account.'],
      expired: ['Too late for this link', 'This link has expired. If something is wrong, contact PandaPay support.'],
      unknown: ['Link not valid', 'This link is not valid.'],
    }[outcome] || ['Link not valid', 'This link is not valid.'];
    res.status(200).type('html').send(PAGE(text[0], `<p>${text[1]}</p>`));
  } catch (error) {
    if (error instanceof RateLimitExceededError) return res.status(429).type('html').send(PAGE('Too many tries', '<p>Please try again later.</p>'));
    console.error('[recovery] stop failed', safeErrorCode(error));
    return res.status(500).type('html').send(PAGE('Something went wrong', '<p>Please try again shortly.</p>'));
  }
});

// From a device that is already signed in: is a recovery waiting, and cancel it.
const auth = require('../middleware/authMiddleware');
const { userRateLimitRead, userRateLimitSensitive } = require('../middleware/userRateLimit');
const pendingRouter = express.Router();
pendingRouter.use((_req, res, next) => { res.setHeader('Cache-Control', 'no-store'); next(); });
pendingRouter.get('/', auth, userRateLimitRead, async (req, res) => {
  try { return res.json(await recovery.pendingForUser(req.user.id)); } catch (error) { return respondError(res, error); }
});
pendingRouter.post('/cancel', auth, userRateLimitSensitive, async (req, res) => {
  if (req.user.recovery_channel) return res.status(403).json({ error: 'recovery_session', message: 'Sign in normally to cancel a recovery.' });
  try { return res.json(await recovery.cancelForUser(req.user.id)); } catch (error) { return respondError(res, error); }
});

module.exports = { publicRouter, pendingRouter, recovery };
