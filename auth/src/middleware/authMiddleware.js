// src/middleware/authMiddleware.js
const jwt = require('jsonwebtoken');
// === SECURITY HARDENING: JWT KEY ROTATION ===
const {
  getKeySecret,
  getAllKeys,
  validateTokenClaims,
} = require('../services/jwtKeys');

async function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;

  if (!token) {
    return res.status(401).json({ error: 'Missing Authorization header' });
  }

  // === SECURITY HARDENING: JWT KEY ROTATION ===
  // Decode token to get key ID from header
  let decoded;
  try {
    decoded = jwt.decode(token, { complete: true });
    if (!decoded || !decoded.header) {
      return res.status(401).json({ error: 'Invalid token format' });
    }
  } catch (err) {
    return res.status(401).json({ error: 'Invalid token' });
  }

  // Get secret for the key ID (if present) or try all keys
  const keyId = decoded.header.kid;
  let payload = null;
  let verified = false;

  if (keyId) {
    const secret = getKeySecret(keyId);
    if (secret) {
      try {
        payload = jwt.verify(token, secret);
        verified = true;
      } catch (err) {
        // Key ID specified but verification failed
        return res.status(401).json({ error: 'Invalid or expired token' });
      }
    }
  }

  // If key ID not found or not specified, try all keys (for rotation support)
  if (!verified) {
    const allKeys = getAllKeys();
    for (const [kid, keySecret] of Object.entries(allKeys)) {
      try {
        payload = jwt.verify(token, keySecret);
        verified = true;
        break;
      } catch (err) {
        // Try next key
        continue;
      }
    }
  }

  if (!verified || !payload) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }

  // === SECURITY HARDENING: JWT KEY ROTATION ===
  // Validate JWT claims (iss, aud, exp, iat, nbf)
  const claimsValidation = validateTokenClaims(payload);
  if (!claimsValidation.valid) {
    return res.status(401).json({ error: 'Invalid token claims' });
  }

  // === SECURITY HARDENING: GLOBAL LOGOUT ===
  // Validate token_version to ensure token hasn't been invalidated by logout-all-devices
  // We need to check the user's current token_version in the database
  const db = require('../db');
  try {
    const { rows } = await db.query(
      `SELECT COALESCE(token_version, 1) as token_version FROM users WHERE id = $1`,
      [payload.sub]
    );
    
    if (rows.length === 0) {
      return res.status(401).json({ error: 'User not found' });
    }

    const userTokenVersion = rows[0].token_version;
    const tokenVersion = payload.token_version || 1;

    // If token version doesn't match, token has been invalidated
    if (tokenVersion !== userTokenVersion) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
  } catch (dbErr) {
    // Handle missing token_version column gracefully
    if (dbErr.code === '42703' && dbErr.message && dbErr.message.includes('token_version')) {
      console.warn('token_version column not found in database, skipping version check');
      // Continue without token version validation (backward compatibility)
      // Token will still be validated for expiry and signature
    } else {
      console.error('Error validating token version:', dbErr);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }

  req.user = {
    id: payload.sub,
    phone_number: payload.phone_number,
    role: payload.user_role || payload.role, // Fallback to role for older tokens
    user_type: payload.user_type,
    // === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
    high_assurance: payload.high_assurance || false,
  };
  next();
}

module.exports = authMiddleware;
