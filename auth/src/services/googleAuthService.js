'use strict';

const { OAuth2Client } = require('google-auth-library');
const config = require('../config');

class GoogleTokenError extends Error {
  constructor(code = 'GOOGLE_TOKEN_INVALID') {
    super(code === 'GOOGLE_AUTH_UNAVAILABLE' ? 'Google authentication is unavailable' : 'Invalid Google token');
    this.name = 'GoogleTokenError';
    this.code = code;
  }
}

// The library verifies Google's signature, expiry, issuer and audience. Check
// identity fields too: email is contact information; sub is identity.
function verifiedGoogleIdentity(payload, audience) {
  if (!payload || !audience || !['accounts.google.com', 'https://accounts.google.com'].includes(payload.iss) ||
      payload.aud !== audience ||
      typeof payload.sub !== 'string' || !/^[A-Za-z0-9_-]{1,255}$/.test(payload.sub) ||
      payload.email_verified !== true || typeof payload.email !== 'string' ||
      payload.email.length > 255 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(payload.email) ||
      !Number.isInteger(payload.exp) || payload.exp <= Math.floor(Date.now() / 1000)) {
    throw new GoogleTokenError();
  }
  const email = payload.email.trim().toLowerCase();
  // Google cannot assert current ownership of arbitrary third-party email.
  const emailAuthoritative = email.endsWith('@gmail.com') ||
    (typeof payload.hd === 'string' && payload.hd.trim().length > 0);
  return {
    userId: payload.sub,
    googleId: payload.sub,
    email,
    emailVerified: true,
    emailAuthoritative,
    name: typeof payload.name === 'string' ? payload.name.slice(0, 255) : null,
    picture: typeof payload.picture === 'string' && payload.picture.length <= 2048 ? payload.picture : null,
  };
}

function createGoogleTokenVerifier({ audience, client }) {
  return async function verify(idToken) {
    if (!audience || !client) throw new GoogleTokenError('GOOGLE_AUTH_UNAVAILABLE');
    if (typeof idToken !== 'string' || idToken.length < 1 || idToken.length > 8192) throw new GoogleTokenError();
    try {
      const ticket = await client.verifyIdToken({ idToken, audience });
      return verifiedGoogleIdentity(ticket.getPayload(), audience);
    } catch (error) {
      if (error instanceof GoogleTokenError) throw error;
      // No token, provider response or contact data in logs.
      throw new GoogleTokenError();
    }
  };
}

const verifyGoogleToken = createGoogleTokenVerifier({
  audience: config.googleClientId,
  client: config.googleClientId ? new OAuth2Client(config.googleClientId) : null,
});

module.exports = { verifyGoogleToken, createGoogleTokenVerifier, verifiedGoogleIdentity, GoogleTokenError };
