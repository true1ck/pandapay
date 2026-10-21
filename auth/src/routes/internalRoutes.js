'use strict';

const express = require('express');
const { createHash, timingSafeEqual } = require('node:crypto');
const config = require('../config');
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
      console.error('Internal session verification unavailable:', error.code || error.name || 'verification_error');
      return res.status(503).json({ error: 'Session verification is temporarily unavailable' });
    }
    return res.json({
      token_valid: false,
      valid: false,
      subject: null,
      session: { active: false, revoked: false, expires_at: null, revocation: null },
      guest: false,
      auth_proof: { channel: null, verified_at: null },
      verified_contacts: {
        email: { verified: false, value: null },
        phone: { verified: false, value: null },
      },
    });
  }
});

module.exports = router;
module.exports.serviceAuthenticated = serviceAuthenticated;
