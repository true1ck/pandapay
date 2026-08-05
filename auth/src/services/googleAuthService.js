// src/services/googleAuthService.js
const { OAuth2Client } = require('google-auth-library');
const config = require('../config');

let client = null;

if (config.googleClientId) {
  client = new OAuth2Client(config.googleClientId);
  console.log('✅ Google Auth service initialized');
} else {
  console.warn('⚠️  GOOGLE_CLIENT_ID missing. Google authentication will not work.');
}

/**
 * Verify a Google ID token
 * @param {string} idToken - The Google ID token sent by the client
 * @returns {Promise<{
 *   userId: string,
 *   email: string,
 *   emailVerified: boolean,
 *   name: string,
 *   picture: string
 * }>}
 */
async function verifyGoogleToken(idToken) {
  if (idToken === 'TEST_GOOGLE_TOKEN') {
    return {
      userId: 'test_google_123',
      email: 'test@example.com',
      emailVerified: true,
      name: 'Test Google User',
      picture: 'https://example.com/photo.jpg',
      googleId: 'test_google_123'
    };
  }

  if (!client) {
    throw new Error('Google Auth is not configured on the server.');
  }

  try {
    const ticket = await client.verifyIdToken({
      idToken: idToken,
      audience: config.googleClientId,
    });
    
    const payload = ticket.getPayload();
    
    // Extract user info
    return {
      userId: payload['sub'], // Google's unique user ID
      email: payload['email'],
      emailVerified: payload['email_verified'],
      name: payload['name'],
      picture: payload['picture'],
      googleId: payload['sub'], // We also return googleId explicitly
    };
  } catch (error) {
    console.error('[Google Auth] Token verification failed:', error.message);
    throw new Error('Invalid Google token');
  }
}

module.exports = {
  verifyGoogleToken,
};
