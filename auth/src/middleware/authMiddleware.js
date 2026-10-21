// src/middleware/authMiddleware.js
const { verifyAccessToken } = require('../services/accessTokenVerification');

async function authMiddleware(req, res, next) {
  const auth = req.headers.authorization || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;

  if (!token) {
    return res.status(401).json({ error: 'Missing Authorization header' });
  }

  let payload;
  try {
    payload = verifyAccessToken(token);
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }

  // === SECURITY HARDENING: GLOBAL LOGOUT ===
  // Validate token_version to ensure token hasn't been invalidated by logout-all-devices
  // We need to check the user's current token_version in the database
  const db = require('../db');
  try {
    const { rows } = await db.query(
      `SELECT COALESCE(token_version, 1) as token_version,
              is_active, deleted
         FROM users WHERE id = $1`,
      [payload.sub]
    );
    
    if (rows.length === 0) {
      return res.status(401).json({ error: 'User not found' });
    }

    const userTokenVersion = rows[0].token_version;
    const tokenVersion = payload.token_version || 1;

    if (!rows[0].is_active || rows[0].deleted) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }

    // If token version doesn't match, token has been invalidated
    if (tokenVersion !== userTokenVersion) {
      return res.status(401).json({ error: 'Invalid or expired token' });
    }
    if (payload.device_id) {
      const deviceResult = await db.query(
        `SELECT id FROM user_devices
         WHERE user_id = $1 AND device_identifier = $2 AND is_active = TRUE LIMIT 1`,
        [payload.sub, payload.device_id],
      );
      if (deviceResult.rows.length === 0) {
        return res.status(401).json({ error: 'Invalid or expired token' });
      }
    }
  } catch (dbErr) {
    // Handle missing token_version column gracefully
    if (dbErr.code === '42703' && dbErr.message && dbErr.message.includes('token_version')) {
      console.warn('token_version column not found; validating account status without version check');
      try {
        const { rows } = await db.query(
          'SELECT is_active, deleted FROM users WHERE id = $1', [payload.sub]
        );
        if (!rows.length || !rows[0].is_active || rows[0].deleted) {
          return res.status(401).json({ error: 'Invalid or expired token' });
        }
      } catch (statusErr) {
        console.error('Error validating account status:', statusErr.message);
        return res.status(500).json({ error: 'Internal server error' });
      }
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
    recovery_channel: payload.recovery_channel,
    recovery_verified_at: payload.recovery_verified_at,
    verified_channel: payload.verified_channel,
    factor_verified_at: payload.factor_verified_at,
  };
  next();
}

module.exports = authMiddleware;
