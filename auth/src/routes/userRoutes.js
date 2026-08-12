// src/routes/userRoutes.js
const express = require('express');
const db = require('../db');
const auth = require('../middleware/authMiddleware');
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
const { decryptPhoneNumber } = require('../utils/fieldEncryption');

// === SECURITY HARDENING: STEP-UP AUTH ===
const { requireRecentOtpOrReauth } = require('../middleware/stepUpAuth');

// === SECURITY HARDENING: RATE LIMITING ===
const {
  userRateLimitRead,
  userRateLimitWrite,
  userRateLimitSensitive,
} = require('../middleware/userRateLimit');

// === VALIDATION: USER ROUTES ===
const {
  validateDeviceIdParam,
  validateLogoutOthersBody,
} = require('../middleware/validation');

const router = express.Router();

// GET /users/me
// Rate limited: Read operation (100 requests per 15 minutes per user)
router.get('/me', auth, userRateLimitRead, async (req, res) => {
  try {
    const { rows } = await db.query(
      `SELECT id, phone_number, name, role, avatar_url, language, timezone,
              country_code, created_at, last_login_at
       FROM users
       WHERE id = $1 AND deleted = FALSE`,
      [req.user.id]
    );

    if (rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = rows[0];

    // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
    // Decrypt phone number before returning to client
    if (user.phone_number) {
      user.phone_number = decryptPhoneNumber(user.phone_number);
    }

    // Get active devices count
    const deviceCountResult = await db.query(
      `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
      [req.user.id]
    );
    const activeDevicesCount = parseInt(deviceCountResult.rows[0].count, 10);

    return res.json({
      id: user.id,
      phone_number: user.phone_number,
      name: user.name,
      role: user.role,
      avatar_url: user.avatar_url,
      language: user.language,
      timezone: user.timezone,
      country_code: user.country_code || '+91',
      created_at: user.created_at,
      last_login_at: user.last_login_at,
      active_devices_count: activeDevicesCount,
    });
  } catch (err) {
    console.error('get me error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});


// GET /users/me/recovery-status - Can this user still get in if they lose their phone?
// Rate limited: Read operation
//
// Plan Phase 1.3. Authentication here is OTP-only — there is no password, by
// design — so the ability to sign in is exactly the ability to receive a code
// on a channel. A user whose only verified channel is a phone number loses
// their entire account with the SIM: every card, every transaction, the whole
// history. Nothing in the product told them that, and nothing asked them to
// set up a second channel.
//
// Both sign-in paths already exist (`/auth/request-otp` on phone,
// `/auth/request-email-otp` on email) and `users` already carries
// `is_phone_verified` / `is_email_verified`. So recovery needs no new
// mechanism — it needs the app to be able to SEE the gap and prompt. That is
// what this returns.
//
// Deliberately returns booleans and a masked hint, never the raw secondary
// address. This is read with an ordinary access token (no step-up), so it must
// not become a way for a stolen token to harvest a full email address; a
// masked hint is enough for the user to recognise their own.
router.get('/me/recovery-status', auth, userRateLimitRead, async (req, res) => {
  try {
    const { rows } = await db.query(
      `SELECT phone_number, email, is_phone_verified, is_email_verified
         FROM users WHERE id = $1 AND deleted = FALSE`,
      [req.user.id]
    );
    if (rows.length === 0) {
      return res.status(404).json({ error: 'User not found' });
    }

    const user = rows[0];
    const phoneVerified = Boolean(user.phone_number) && user.is_phone_verified;
    const emailVerified = Boolean(user.email) && user.is_email_verified;
    const verifiedCount = (phoneVerified ? 1 : 0) + (emailVerified ? 1 : 0);

    return res.json({
      phone_verified: phoneVerified,
      email_verified: emailVerified,
      // The whole point of the endpoint: with only one verified channel there
      // is no way back into the account if that channel is lost.
      has_backup_channel: verifiedCount >= 2,
      // Which channel to offer, so the client doesn't have to re-derive it.
      missing_channel: verifiedCount >= 2 ? null : phoneVerified ? 'email' : 'phone',
      email_hint: emailVerified ? maskEmail(user.email) : null,
    });
  } catch (err) {
    console.error('recovery status error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

/**
 * Masks an email for display: `aarav.sharma@gmail.com` -> `aa••••••••@gmail.com`.
 * Enough for someone to recognise their own address, not enough for a stolen
 * access token to learn one. The domain is kept because that is what makes it
 * recognisable, and a domain alone is not a contactable identifier.
 */
function maskEmail(email) {
  if (!email || !email.includes('@')) return null;
  const [local, domain] = email.split('@');
  const head = local.slice(0, Math.min(2, local.length));
  return `${head}${'•'.repeat(Math.max(local.length - head.length, 1))}@${domain}`;
}

// PUT /users/me
// Update user profile (name only).
router.put(
  '/me',
  auth,
  requireRecentOtpOrReauth,
  async (req, res) => {
    try {
      const { name } = req.body;

      if (!name || name.trim() === '') {
        return res.status(400).json({ error: 'name is required' });
      }

      const { rows } = await db.query(
        `UPDATE users
         SET name = $1, updated_at = NOW()
         WHERE id = $2 AND deleted = FALSE
         RETURNING id, phone_number, name, role`,
        [name.trim(), req.user.id]
      );

      if (rows.length === 0) {
        return res.status(404).json({ error: 'User not found' });
      }

      const updatedUser = rows[0];

      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Decrypt phone number before returning to client
      if (updatedUser.phone_number) {
        updatedUser.phone_number = decryptPhoneNumber(updatedUser.phone_number);
      }

      return res.json(updatedUser);
    } catch (err) {
      console.error('update me error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);


// GET /users/me/devices - List all active devices
// Rate limited: Read operation (100 requests per 15 minutes per user)
router.get('/me/devices', auth, userRateLimitRead, async (req, res) => {
  try {
    const { rows } = await db.query(
      `
      SELECT 
        device_identifier,
        device_platform,
        device_model,
        os_version,
        app_version,
        language_code,
        timezone,
        first_seen_at,
        last_seen_at,
        is_active
      FROM user_devices
      WHERE user_id = $1 AND is_active = true
      ORDER BY last_seen_at DESC
      `,
      [req.user.id]
    );

    return res.json({ devices: rows });
  } catch (err) {
    console.error('get devices error', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
});

// DELETE /users/me/devices/:device_id - Revoke/logout a specific device
// Rate limited: Sensitive operation (10 requests per hour per user)
// Validates: device_id param (string, max 100 chars)
router.delete(
  '/me/devices/:device_id',
  auth,
  userRateLimitSensitive,
  requireRecentOtpOrReauth,
  validateDeviceIdParam,
  async (req, res) => {
    try {
      const { device_id } = req.params;

      if (!device_id) {
        return res.status(400).json({ error: 'device_id is required' });
      }

      // Mark device as inactive
      await db.query(
        `UPDATE user_devices SET is_active = false WHERE user_id = $1 AND device_identifier = $2`,
        [req.user.id, device_id]
      );

      // Revoke all refresh tokens for this device
      const { revokeRefreshToken } = require('../services/tokenService');
      await revokeRefreshToken(req.user.id, device_id);

      // Log the action
      try {
        await db.query(
          `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address, user_agent, meta)
         VALUES ($1, 'device_revoked', 'success', $2, $3, $4, $5)`,
          [
            req.user.id,
            device_id,
            req.ip,
            req.headers['user-agent'],
            JSON.stringify({ revoked_by: 'user' }),
          ]
        );
      } catch (auditErr) {
        console.error('Failed to log device revocation', auditErr);
      }

      return res.json({ ok: true, message: 'Device logged out successfully' });
    } catch (err) {
      console.error('revoke device error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /users/me/logout-all-other-devices - Logout all other devices (keep current)
// Rate limited: Sensitive operation (10 requests per hour per user)
// Validates: current_device_id (optional string, max 100 chars if provided)
router.post(
  '/me/logout-all-other-devices',
  auth,
  userRateLimitSensitive,
  requireRecentOtpOrReauth,
  validateLogoutOthersBody,
  async (req, res) => {
    try {
      // Get current device_id from refresh token if available, or from request
      // For now, we'll need device_id in request body or header
      const currentDeviceId = req.headers['x-device-id'] || req.body.current_device_id;

      if (!currentDeviceId) {
        return res.status(400).json({ error: 'current_device_id is required in header or body' });
      }

      // Mark all other devices as inactive
      const result = await db.query(
        `UPDATE user_devices 
       SET is_active = false 
       WHERE user_id = $1 AND device_identifier != $2 AND is_active = true
       RETURNING device_identifier`,
        [req.user.id, currentDeviceId]
      );

      const revokedDevices = result.rows.map((row) => row.device_identifier);

      // Revoke refresh tokens for all other devices
      const { revokeRefreshToken } = require('../services/tokenService');
      for (const deviceId of revokedDevices) {
        await revokeRefreshToken(req.user.id, deviceId);
      }

      // Log the action
      try {
        await db.query(
          `INSERT INTO auth_audit (user_id, action, status, device_id, ip_address, user_agent, meta)
         VALUES ($1, 'logout_all_other_devices', 'success', $2, $3, $4, $5)`,
          [
            req.user.id,
            currentDeviceId,
            req.ip,
            req.headers['user-agent'],
            JSON.stringify({
              revoked_devices_count: revokedDevices.length,
              revoked_devices: revokedDevices,
            }),
          ]
        );
      } catch (auditErr) {
        console.error('Failed to log logout all action', auditErr);
      }

      return res.json({
        ok: true,
        message: `Logged out ${revokedDevices.length} device(s)`,
        revoked_devices_count: revokedDevices.length,
      });
    } catch (err) {
      console.error('logout all other devices error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /users/me/logout-all-devices - Logout from ALL devices (including current)
// === SECURITY HARDENING: GLOBAL LOGOUT ===
// Rate limited: Sensitive operation (10 requests per hour per user)
// Requires step-up authentication (recent OTP or high_assurance token)
// Logs HIGH_RISK security event for audit
router.post(
  '/me/logout-all-devices',
  auth,
  userRateLimitSensitive,
  requireRecentOtpOrReauth,
  async (req, res) => {
    try {
      const { logAuthEvent, RISK_LEVELS } = require('../services/auditLogger');
      const { revokeAllUserTokens } = require('../services/tokenService');

      // Revoke all refresh tokens and invalidate all access tokens
      const result = await revokeAllUserTokens(req.user.id);

      // Log HIGH_RISK security event for audit
      await logAuthEvent({
        userId: req.user.id,
        action: 'logout_all_devices',
        status: 'success',
        riskLevel: RISK_LEVELS.HIGH_RISK,
        deviceId: req.headers['x-device-id'] || null,
        ipAddress: req.ip || req.connection.remoteAddress || 'unknown',
        userAgent: req.headers['user-agent'],
        meta: {
          revoked_tokens_count: result.revokedTokensCount,
          new_token_version: result.newTokenVersion,
          reason: 'user_initiated_global_logout',
          message: 'User initiated logout from all devices - security breach suspected',
        },
      });

      return res.json({
        ok: true,
        message: 'Logged out from all devices successfully',
        revoked_tokens_count: result.revokedTokensCount,
      });
    } catch (err) {
      console.error('logout all devices error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// PUT /users/me/device/fcm-token - Update FCM token for current device
// Rate limited: Write operation (20 requests per 15 minutes per user)
router.put(
  '/me/device/fcm-token',
  auth,
  userRateLimitWrite,
  async (req, res) => {
    try {
      const userId = req.user.id;
      const { fcm_token } = req.body;
      const deviceId = req.headers['x-device-id'] || req.body.device_id ||
        req.headers['device-id'] || req.body.deviceId;

      if (!fcm_token) {
        return res.status(400).json({
          success: false,
          message: 'fcm_token is required'
        });
      }

      // Sanitize device ID if provided
      const sanitizeDeviceId = (devId) => {
        if (!devId) return null;
        const sanitized = devId.replace(/[^a-zA-Z0-9_-]/g, '').substring(0, 255);
        return sanitized || null;
      };

      let devId = sanitizeDeviceId(deviceId);

      if (!devId) {
        // If no device ID, try to find the most recent active device for this user
        const deviceResult = await db.query(
          `SELECT device_identifier FROM user_devices 
           WHERE user_id = $1 AND is_active = true 
           ORDER BY last_seen_at DESC LIMIT 1`,
          [userId]
        );

        if (deviceResult.rows.length === 0) {
          return res.status(404).json({
            success: false,
            message: 'No active device found for this user'
          });
        }
        devId = deviceResult.rows[0].device_identifier;
      }

      // Update FCM token for user's current device
      const updateResult = await db.query(
        `
        UPDATE user_devices
        SET fcm_token = $1,
            updated_at = NOW(),
            last_seen_at = NOW()
        WHERE user_id = $2 
          AND device_identifier = $3
          AND is_active = true
        RETURNING id
        `,
        [fcm_token, userId, devId]
      );

      // If no device found, create one (shouldn't happen, but handle edge case)
      if (updateResult.rows.length === 0) {
        await db.query(
          `
          INSERT INTO user_devices (
            user_id, device_identifier, device_platform, fcm_token, last_seen_at
          )
          VALUES ($1, $2, 'android', $3, NOW())
          ON CONFLICT (user_id, device_identifier)
          DO UPDATE SET fcm_token = EXCLUDED.fcm_token,
                        updated_at = NOW(),
                        last_seen_at = NOW()
          `,
          [userId, devId, fcm_token]
        );
      }

      return res.json({
        success: true,
        message: 'FCM token updated successfully'
      });
    } catch (err) {
      console.error('update-fcm-token error', err);
      return res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }
);

// NOTE: Location management is out of scope for this identity service.
// Auth service only handles authentication, sessions, and basic profile

module.exports = router;

