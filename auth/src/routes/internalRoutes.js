const { safeErrorCode } = require('../utils/safeErrorCode');
'use strict';

const express = require('express');
const { createHash, timingSafeEqual } = require('node:crypto');
const config = require('../config');
const avatars = require('../services/userAvatar');
const { verifyCurrentSession } = require('../services/currentSessionVerification');

const router = express.Router();

function serviceAuthenticated(req) {
  const expected = config.authInternalServiceSecret;
  const provided = req.get('x-auth-service-secret');
  if (typeof expected !== 'string' || Buffer.byteLength(expected) < 32 || typeof provided !== 'string') {
    return false;
  }
  const expectedDigest = createHash('sha256').update(expected).digest();
  const providedDigest = createHash('sha256').update(provided).digest();
  return timingSafeEqual(expectedDigest, providedDigest);
}

function serviceSecretConfigured() {
  return typeof config.authInternalServiceSecret === 'string' &&
    Buffer.byteLength(config.authInternalServiceSecret) >= 32;
}

router.post('/session/verify', async (req, res) => {
  if (!serviceAuthenticated(req)) {
    const configured = serviceSecretConfigured();
    return res.status(configured ? 401 : 503)
      .json({ error: configured ? 'Unauthorized service' : 'Internal session verification is not configured' });
  }
  const authorization = req.get('authorization') || '';
  const token = authorization.startsWith('Bearer ') ? authorization.slice(7) : null;
  if (!token) return res.status(400).json({ error: 'Bearer access token is required' });

  try {
    const result = await verifyCurrentSession(token);
    return res.json(result);
  } catch (error) {
    // Invalid token details and any contact data stay out of responses/logs.
    if (error.message !== 'invalid_token') {
      console.error('Internal session verification unavailable:', safeErrorCode(error, 'verification_error'));
      return res.status(503).json({ error: 'Session verification is temporarily unavailable' });
    }
    return res.json({
      token_valid: false,
      valid: false,
      subject: null,
      session: { active: false, revoked: false, expires_at: null, revocation: null },
      auth_proof: { channel: null, verified_at: null },
      verified_contacts: {
        email: { verified: false, value: null },
        phone: { verified: false, value: null },
      },
      claimed_contacts: { phone: { claimed: false, value: null } },
      phone_on_file: { present: false, value: null },
      phone_gate: { required: false, satisfied: false },
    });
  }
});

// Avatars of OTHER people, for the API service. Who may look (a shared Split group)
// is the API's decision; here only the owner's consent is enforced. Every miss
// (unknown, deleted, inactive, private photo, no photo) is the same 404.
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Loaded on first use so this module stays importable without the database config.
const avatarQuery = (...args) => require('../db').query(...args);

function avatarGate(req, res, next) {
  if (!serviceAuthenticated(req)) {
    const configured = serviceSecretConfigured();
    return res.status(configured ? 401 : 503)
      .json({ error: configured ? 'Unauthorized service' : 'Internal session verification is not configured' });
  }
  if (!UUID.test(req.params.userId)) return res.status(400).json({ error: 'invalid_user_id' });
  res.setHeader('Cache-Control', 'no-store');
  return next();
}

const notFound = res => res.status(404).json({ error: 'not_found' });

router.get('/avatar/:userId', avatarGate, async (req, res) => {
  try {
    const avatar = await avatars.getPublicAvatar({ query: avatarQuery, userId: req.params.userId });
    return avatar ? res.json(avatar) : notFound(res);
  } catch (error) {
    console.error('Internal avatar unavailable:', safeErrorCode(error, 'avatar_error'));
    return res.status(503).json({ error: 'Avatar is temporarily unavailable' });
  }
});

router.get('/avatar/:userId/photo', avatarGate, async (req, res) => {
  try {
    const photo = await avatars.getPublicPhoto({ query: avatarQuery, userId: req.params.userId });
    if (!photo) return notFound(res);
    res.setHeader('Content-Type', photo.type);
    res.setHeader('Content-Length', String(photo.bytes.length));
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('Content-Security-Policy', "default-src 'none'; sandbox");
    return res.end(photo.bytes);
  } catch (error) {
    console.error('Internal avatar unavailable:', safeErrorCode(error, 'avatar_error'));
    return res.status(503).json({ error: 'Avatar is temporarily unavailable' });
  }
});

module.exports = router;
module.exports.serviceAuthenticated = serviceAuthenticated;
