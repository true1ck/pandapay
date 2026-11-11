'use strict';

const express = require('express');
const db = require('../db');
const auth = require('../middleware/authMiddleware');
const { userRateLimitRead, userRateLimitWrite } = require('../middleware/userRateLimit');
const avatars = require('../services/userAvatar');
const { safeErrorCode } = require('../utils/safeErrorCode');

const router = express.Router();
const { AvatarError, MAX_PHOTO_BYTES } = avatars;

const MESSAGES = Object.freeze({
  preset_invalid: 'Choose one of the avatars on the list.',
  sharing_invalid: 'Send share_photo as true or false.',
  photo_invalid: 'That photo could not be used. Choose a different one.',
  photo_too_large: 'That photo is too large. Choose a smaller one.',
  photo_type_unsupported: 'Use a JPEG or PNG photo.',
  no_photo: 'There is no photo on this account.',
  account_unavailable: 'Please sign in again.',
});

const query = (...args) => db.query(...args);

router.use((_req, res, next) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Pragma', 'no-cache');
  next();
});

function fail(res, error) {
  if (error instanceof AvatarError) {
    return res.status(error.status).json({ error: error.code, message: MESSAGES[error.code] });
  }
  console.error('[avatar] failed', safeErrorCode(error));
  return res.status(500).json({ error: 'Internal server error' });
}

// A recovery session proves one contact only; it does not edit the profile.
function ordinarySession(req, res, next) {
  if (req.user.recovery_channel) {
    return res.status(403).json({ error: 'recovery_session', message: 'Sign in normally to change your avatar.' });
  }
  return next();
}

// GET /users/me/avatar -> { preset, has_photo, share_photo, version }
router.get('/', auth, userRateLimitRead, async (req, res) => {
  try {
    return res.json(await avatars.getAvatar({ query, userId: req.user.id }));
  } catch (error) { return fail(res, error); }
});

// PUT /users/me/avatar/preset  { preset: "panda" | null }
router.put('/preset', auth, userRateLimitWrite, ordinarySession, async (req, res) => {
  const body = req.body;
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some(key => key !== 'preset') || !Object.hasOwn(body, 'preset')) {
    return res.status(400).json({ error: 'preset_invalid', message: MESSAGES.preset_invalid });
  }
  try {
    return res.json(await avatars.setPreset({ query, userId: req.user.id, preset: body.preset }));
  } catch (error) { return fail(res, error); }
});

// PUT /users/me/avatar/sharing  { share_photo: true | false }
router.put('/sharing', auth, userRateLimitWrite, ordinarySession, async (req, res) => {
  const body = req.body;
  if (!body || typeof body !== 'object' || Array.isArray(body) ||
      Object.keys(body).some(key => key !== 'share_photo') || typeof body.share_photo !== 'boolean') {
    return res.status(400).json({ error: 'sharing_invalid', message: MESSAGES.sharing_invalid });
  }
  try {
    return res.json(await avatars.setSharing({ query, userId: req.user.id, share: body.share_photo }));
  } catch (error) { return fail(res, error); }
});

// PUT /users/me/avatar/photo   raw JPEG or PNG bytes (not JSON, not multipart)
router.put(
  '/photo',
  auth,
  userRateLimitWrite,
  ordinarySession,
  express.raw({ type: ['image/jpeg', 'image/png'], limit: MAX_PHOTO_BYTES }),
  async (req, res) => {
    if (!Buffer.isBuffer(req.body)) {
      return res.status(415).json({ error: 'photo_type_unsupported', message: MESSAGES.photo_type_unsupported });
    }
    try {
      const declaredType = String(req.headers['content-type'] || '').split(';')[0].trim().toLowerCase();
      return res.json(await avatars.setPhoto({ query, userId: req.user.id, bytes: req.body, declaredType }));
    } catch (error) { return fail(res, error); }
  },
);

// GET /users/me/avatar/photo -> the owner's own photo bytes
router.get('/photo', auth, userRateLimitRead, async (req, res) => {
  try {
    const photo = await avatars.getPhoto({ query, userId: req.user.id });
    res.setHeader('Content-Type', photo.type);
    res.setHeader('Content-Length', String(photo.bytes.length));
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
    return res.end(photo.bytes);
  } catch (error) { return fail(res, error); }
});

// DELETE /users/me/avatar/photo
router.delete('/photo', auth, userRateLimitWrite, ordinarySession, async (req, res) => {
  try {
    return res.json(await avatars.removePhoto({ query, userId: req.user.id }));
  } catch (error) { return fail(res, error); }
});

// An oversized body is stopped by express.raw before the handler runs.
router.use((error, _req, res, next) => {
  if (error?.type === 'entity.too.large') {
    return res.status(413).json({ error: 'photo_too_large', message: MESSAGES.photo_too_large });
  }
  return next(error);
});

module.exports = router;
