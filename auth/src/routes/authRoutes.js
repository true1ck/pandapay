// src/routes/authRoutes.js
const express = require('express');
const crypto = require('crypto');
const { randomUUID } = require('crypto');
const db = require('../db');
const config = require('../config');
const auth = require('../middleware/authMiddleware');
const { sendOtpSms } = require('../services/smsService');
const { sendOtpEmail } = require('../services/emailService');
const { verifyGoogleToken } = require('../services/googleAuthService');
const { createOtp, verifyOtp } = require('../services/otpService');
const {
  signAccessToken,
  issueRefreshToken,
  verifyRefreshToken,
  rotateRefreshToken,
  revokeRefreshToken,
} = require('../services/tokenService');
// === ADDED FOR RATE LIMITING ===
const {
  checkActiveOtpForPhone,
  rateLimitRequestOtpByPhone,
  checkActiveOtpForEmail,
  rateLimitRequestOtpByEmail,
  rateLimitRequestOtpByIp,
  rateLimitVerifyOtpByPhone,
  rateLimitVerifyOtpByEmail,
  incrementFailedVerify,
  checkEnumerationRateLimit,
  blockIpForEnumeration,
  isIpBlockedForEnumeration,
} = require('../middleware/rateLimitMiddleware');
// === SECURITY HARDENING: INPUT VALIDATION ===
const {
  validateRequestOtpBody,
  validateVerifyOtpBody,
  validateRequestEmailOtpBody,
  validateVerifyEmailOtpBody,
  validateGoogleLoginBody,
  validateRefreshTokenBody,
  validateLogoutBody,
  validateSignupBody,
} = require('../middleware/validation');
// === SECURITY HARDENING: IP/DEVICE RISK ===
const {
  isIpBlocked,
  calculateRiskScore,
  getPreviousAuthInfo,
  REQUIRE_OTP_ON_SUSPICIOUS_REFRESH,
} = require('../services/riskScoring');
// === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
const {
  logAuthEvent,
  logSuspiciousOtpAttempt,
  logBlockedIpLogin,
  logSuspiciousRefresh,
  checkAnomalies,
  RISK_LEVELS,
} = require('../services/auditLogger');
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
const { encryptPhoneNumber, decryptPhoneNumber } = require('../utils/fieldEncryption');
const { preparePhoneSearchParams } = require('../utils/encryptedPhoneSearch');
// === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
const { executeOtpRequestWithTiming, otpRequestDelay, executeOtpVerifyWithTiming, otpVerifyDelay } = require('../utils/timingProtection');
// === SECURITY HARDENING: ENUMERATION DETECTION ===
const { detectAndLogEnumeration } = require('../utils/enumerationDetection');

const router = express.Router();

// helper: normalize phone
function normalizePhone(phone) {
  const p = phone.trim().replace(/\s+/g, ''); // Remove spaces
  if (p.startsWith('+')) return p;
  // if user enters 10-digit, prepend +91
  if (p.length === 10) return '+91' + p;
  return p; // fallback
}

// helper: validate phone number format
function isValidPhoneNumber(phone) {
  // E.164 format: + followed by 1-15 digits
  // Reject short codes (5-6 digits)
  const e164Pattern = /^\+[1-9]\d{1,14}$/;

  if (!e164Pattern.test(phone)) {
    return false;
  }

  // Reject short codes (typically 5-6 digits total)
  const digitsOnly = phone.replace(/\D/g, '');
  if (digitsOnly.length <= 6) {
    return false; // Likely a short code
  }

  return true;
}


function sanitizeDeviceId(deviceId) {
  if (!deviceId || typeof deviceId !== 'string') {
    return 'unknown-device';
  }
  const trimmed = deviceId.trim();
  if (/^[A-Za-z0-9:_-]{4,128}$/.test(trimmed)) {
    return trimmed;
  }
  const hash = crypto
    .createHash('sha256')
    .update(trimmed)
    .digest('hex')
    .slice(0, 32);
  return `anon-${hash}`;
}

// POST /auth/request-otp
// === SECURITY HARDENING: INPUT VALIDATION ===
// === ADDED FOR RATE LIMITING ===
// Middleware order matters:
// 1. Input validation
// 2. Check for active OTP first (2-minute no-resend rule)
// 3. Rate limit by phone number
// 4. Rate limit by IP address
// 5. IP blocking check
router.post(
  '/request-otp',
  validateRequestOtpBody,
  checkActiveOtpForPhone,
  rateLimitRequestOtpByPhone,
  rateLimitRequestOtpByIp,
  async (req, res) => {
    // === FEATURE FLAGS ===
    if (!config.enablePhoneOtp) {
      return res.status(403).json({ success: false, message: 'Phone authentication is currently disabled' });
    }

    // === SECURITY HARDENING: IP/DEVICE RISK ===
    // Check if IP is blocked
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({
        success: false,
        message: 'Access denied from this location.',
      });
    }

    // === SECURITY HARDENING: ENUMERATION PROTECTION ===
    // Check if IP is blocked for enumeration attempts
    if (await isIpBlockedForEnumeration(clientIp)) {
      return res.status(429).json({
        success: false,
        message: 'Too many requests. Please try again later.',
      });
    }

    try {
      // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
      // Execute all work with timing protection to prevent enumeration
      // This ensures all requests take similar time regardless of phone existence
      const result = await executeOtpRequestWithTiming(async () => {
        const { phone_number } = req.body;
        if (!phone_number) {
          return { error: 'phone_number is required', status: 400 };
        }

        const normalizedPhone = normalizePhone(phone_number);

        // === SECURITY HARDENING: ENUMERATION DETECTION ===
        // Check for enumeration attempts before processing
        const enumerationCheck = await detectAndLogEnumeration(
          clientIp,
          normalizedPhone,
          req.headers['user-agent']
        );

        // Apply stricter rate limiting if enumeration detected
        if (enumerationCheck.isEnumeration) {
          const enumRateLimit = await checkEnumerationRateLimit(clientIp);
          if (!enumRateLimit.allowed) {
            // Block IP if enumeration rate limit exceeded
            await blockIpForEnumeration(clientIp);
            return {
              error: enumRateLimit.reason || 'Too many requests. Please try again later.',
              status: 429,
            };
          }
        }

        // Block high-risk enumeration attempts immediately
        if (enumerationCheck.shouldBlock) {
          await blockIpForEnumeration(clientIp);
          return {
            error: 'Too many requests. IP blocked due to enumeration attempts.',
            status: 429,
          };
        }

        // Validate phone number format
        if (!isValidPhoneNumber(normalizedPhone)) {
          return {
            error: 'Invalid phone number format. Please use E.164 format (e.g., +919876543210)',
            status: 400
          };
        }

        const { code } = await createOtp(normalizedPhone);

        // Attempt to send SMS (will fallback to safe logging if Twilio fails)
        const smsResult = await sendOtpSms(normalizedPhone, code);

        // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
        // Log OTP request event
        await logAuthEvent({
          action: 'otp_request',
          status: smsResult?.success ? 'success' : 'failed',
          riskLevel: RISK_LEVELS.INFO,
          ipAddress: clientIp,
          userAgent: req.headers['user-agent'],
          meta: {
            phone: normalizedPhone.replace(/\d(?=\d{4})/g, '*'), // Mask phone
          },
        });

        // Even if SMS fails, we still return success because OTP is generated
        // In production, you may want to return an error if SMS fails
        if (!smsResult || !smsResult.success) {
          console.warn('⚠️ SMS sending failed, but OTP was generated');
          // Option 1: Still return success (current behavior - allows testing)
          // Option 2: Return error (uncomment below for production)
          // return { error: 'Failed to send OTP via SMS', status: 500 };
        }

        return { ok: true, status: 200 };
      });

      // Handle errors or return success
      if (result.error) {
        return res.status(result.status || 500).json({ error: result.error });
      }

      return res.json({ ok: true });

    } catch (err) {
      console.error('request-otp error', err);
      // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
      // Even on error, ensure minimum delay to prevent timing leaks
      await otpRequestDelay();
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/check-user
// Check if user exists by phone number (for sign-in flow)
// This prevents sending OTP to non-existent users
router.post(
  '/check-user',
  validateRequestOtpBody, // Reuse phone number validation
  async (req, res) => {
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';

    // Check if IP is blocked
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({
        success: false,
        message: 'Access denied from this location.',
      });
    }

    try {
      const { phone_number } = req.body;

      if (!phone_number) {
        return res.status(400).json({
          success: false,
          message: 'phone_number is required',
        });
      }

      // Normalize phone number
      const normalizedPhone = normalizePhone(phone_number);

      // Validate phone number format
      if (!isValidPhoneNumber(normalizedPhone)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid phone number format. Please use E.164 format (e.g., +919876543210)',
        });
      }

      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Encrypt phone number before searching
      const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);

      // Check if user exists and has a name (fully registered)
      const found = await db.query(
        `SELECT id, name FROM users 
         WHERE (phone_number = $1 OR phone_number = $2)
           AND deleted = FALSE`,
        phoneSearchParams
      );

      if (found.rows.length === 0) {
        // User not found
        return res.status(404).json({
          success: false,
          error: 'USER_NOT_FOUND',
          message: 'User is not registered. Please sign up to create a new account.',
          user_exists: false
        });
      }

      const user = found.rows[0];
      // Check if user has a name (fully registered)
      const isFullyRegistered = user.name && user.name.trim() !== '';

      if (isFullyRegistered) {
        // User exists and is fully registered - should sign in
        return res.json({
          success: true,
          message: 'User is already registered. Please sign in instead.',
          user_exists: true
        });
      } else {
        // User exists but doesn't have a name (incomplete signup) - allow signup to continue
        return res.status(404).json({
          success: false,
          error: 'USER_NOT_FOUND',
          message: 'User is not registered. Please sign up to create a new account.',
          user_exists: false
        });
      }

    } catch (err) {
      console.error('check-user error', err);
      return res.status(500).json({
        success: false,
        message: 'Internal server error'
      });
    }
  }
);

// POST /auth/guest-login
// Generate guest JWT tokens without requiring phone authentication
// No database record is created - guest tokens are stateless
router.post('/guest-login', async (req, res) => {
  const clientIp = req.ip || req.connection.remoteAddress || 'unknown';

  // Check if IP is blocked
  if (isIpBlocked(clientIp)) {
    await logBlockedIpLogin(clientIp, req.headers['user-agent']);
    return res.status(403).json({
      success: false,
      message: 'Access denied from this location.',
    });
  }

  try {
    const { device_id } = req.body;

    // Generate unique guest identifier - MUST be UUID for database compatibility
    // We use UUID for guest ID but can track device_id separately in token
    const guestId = randomUUID();
    const sanitizedDeviceId = device_id ? sanitizeDeviceId(device_id) : 'guest-device';

    // Create guest token payload (NO DATABASE RECORD)
    const guestUser = {
      id: guestId,
      phone_number: null,
      role: 'user',
      user_type: null,
      token_version: 1,
      is_guest: true  // Key flag
    };

    // Generate tokens
    // === GUEST LOGIN SUPPORT ===
    // Guest tokens expire after 24 hours (1 day) instead of default 15 minutes
    const accessToken = signAccessToken(guestUser, {
      deviceId: sanitizedDeviceId,
      expiresIn: '24h'  // 24 hours expiration for guest tokens
    });

    // === GUEST LOGIN SUPPORT ===
    // Skip refresh tokens for guests - refresh_tokens table has FK constraint to users table
    // Guests don't have user records, so we can't store refresh tokens
    // Guests can re-login as guest when access token expires
    const refreshToken = null;

    // === GUEST LOGIN SUPPORT ===
    // Skip audit logging for guests - auth_audit table has FK constraint on user_id
    // Guests don't have user records, so we can't log with user_id
    // Log to console instead for debugging
    console.log(`[AUTH] Guest login event - guestId=${guestId}, deviceId=${device_id || 'none'}, ip=${clientIp}`);
    // Note: We could log with userId=null if the FK constraint allows it, but safer to skip

    console.log(`[AUTH] Guest login successful - guestId=${guestId}, deviceId=${device_id || 'none'}, ip=${clientIp}`);

    return res.json({
      success: true,
      access_token: accessToken,
      refresh_token: refreshToken,  // null for guests
      is_guest: true,
      user: {
        id: guestId,
        phone_number: null,
        name: null,
        role: 'user',
        user_type: null,
        is_guest: true
      }
    });
  } catch (err) {
    console.error('guest-login error', err);
    return res.status(500).json({
      success: false,
      message: 'Internal server error'
    });
  }
});

// POST /auth/verify-otp
// === SECURITY HARDENING: INPUT VALIDATION ===
// === ADDED FOR OTP ATTEMPT LIMIT ===
// Rate limit failed verification attempts per phone
router.post(
  '/verify-otp',
  validateVerifyOtpBody,
  rateLimitVerifyOtpByPhone,
  async (req, res) => {
    // === FEATURE FLAGS ===
    if (!config.enablePhoneOtp) {
      return res.status(403).json({ success: false, message: 'Phone authentication is currently disabled' });
    }

    // === SECURITY HARDENING: IP/DEVICE RISK ===
    // Check if IP is blocked
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({
        success: false,
        message: 'Access denied from this location.',
      });
    }
    try {
      // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
      // Execute all verification work with timing protection
      // This ensures all verification attempts take similar time regardless of outcome
      const verificationResult = await executeOtpVerifyWithTiming(async () => {
        const { phone_number, code, device_id, device_info } = req.body;

        // Debug: Log entire request body to see what's being received
        console.log('[verify-otp] Request body keys:', Object.keys(req.body || {}));
        console.log('[verify-otp] device_info type:', typeof device_info);
        console.log('[verify-otp] device_info value:', JSON.stringify(device_info));

        if (!phone_number || !code) {
          return { error: 'phone_number and code are required', status: 400 };
        }

        const normalizedPhone = normalizePhone(phone_number);

        // Ensure code is a string (handle case where it might come as number from JSON)
        // bcrypt.compare requires string, and validation expects string
        // Note: If code comes as number, leading zeros may be lost - client should send as string
        const codeString = String(code);

        // Debug logging (remove in production or use proper logger)
        console.log('[OTP Verify] Request body:', JSON.stringify({
          phone_number: normalizedPhone.replace(/\d(?=\d{4})/g, '*'),
          code: codeString,
          code_type: typeof code,
          code_length: codeString.length,
          device_id: device_id?.substring(0, 20) + '...'
        }));

        const result = await verifyOtp(normalizedPhone, codeString);

        // === ADDED FOR OTP ATTEMPT LIMIT ===
        // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
        // Use generic error message to avoid leaking information
        if (!result.ok) {
          // Increment failed verification counter
          try {
            await incrementFailedVerify(normalizedPhone);
          } catch (err) {
            console.error('Failed to increment failed verify counter:', err);
            // Don't fail the request if counter increment fails
          }

          // Log suspicious OTP attempt
          await logSuspiciousOtpAttempt(
            normalizedPhone,
            clientIp,
            req.headers['user-agent'],
            result.reason || 'invalid'
          );

          return {
            success: false,
            message: 'OTP invalid or expired. Please request a new one.',
            status: 400
          };
        }

        return { ok: true, normalizedPhone, device_id, device_info };
      });

      // Handle verification failure
      if (verificationResult.error || !verificationResult.ok) {
        return res.status(verificationResult.status || 400).json({
          success: false,
          message: verificationResult.message || 'OTP invalid or expired. Please request a new one.'
        });
      }

      // Continue with successful verification
      const { normalizedPhone, device_id, device_info } = verificationResult;

      // find or create user
      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Encrypt phone number before storing/searching
      const encryptedPhone = encryptPhoneNumber(normalizedPhone);
      const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);

      let user;
      // Check if token_version column exists, use it if available, otherwise default to 1
      const found = await db.query(
        `SELECT id, phone_number, name, role,
              COALESCE(token_version, 1) as token_version
       FROM users
       WHERE (phone_number = $1 OR phone_number = $2)
         AND deleted = FALSE`,
        phoneSearchParams
      );

      if (found.rows.length === 0) {
        // User not found - create a minimal user for signup flow
        // Extract country code from phone number
        const countryCode = normalizedPhone.startsWith('+')
          ? normalizedPhone.match(/^\+(\d{1,3})/)?.[0] || '+91'
          : '+91';

        // Create new user with minimal data (name will be added via signup endpoint)
        const newUserResult = await db.query(
          `INSERT INTO users (phone_number, country_code, language, timezone, is_phone_verified)
         VALUES ($1, $2, $3, $4, TRUE)
         RETURNING id, phone_number, name, role,
                   COALESCE(token_version, 1) as token_version`,
          [
            encryptedPhone,
            countryCode,
            device_info?.language_code || null,
            device_info?.timezone || null
          ]
        );

        user = newUserResult.rows[0];
      } else {
        user = found.rows[0];
      }

      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Decrypt phone number before returning to client
      if (user.phone_number) {
        user.phone_number = decryptPhoneNumber(user.phone_number);
      }

      // update last_login_at
      await db.query(
        `UPDATE users SET last_login_at = NOW() WHERE id = $1`,
        [user.id]
      );

      const devId = sanitizeDeviceId(device_id);

      // Check if this is a new device for existing account
      const existingDevice = await db.query(
        `SELECT id FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      const isNewDevice = existingDevice.rows.length === 0;
      // Check if this is a new account (user was just created or has no name)
      const isExistingAccount = user.name && user.name.trim() !== '';

      // Log FCM token for debugging
      if (device_info?.fcm_token) {
        console.log(`[verify-otp] FCM token received: ${device_info.fcm_token.substring(0, 20)}...`);
      } else {
        console.log(`[verify-otp] No FCM token in device_info. Device info:`, JSON.stringify(device_info || {}));
      }

      // upsert user_devices row
      await db.query(
        `
      INSERT INTO user_devices (
        user_id, device_identifier, device_platform, device_model,
        os_version, app_version, language_code, timezone, fcm_token, last_seen_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
      ON CONFLICT (user_id, device_identifier)
      DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at,
                    device_platform = EXCLUDED.device_platform,
                    device_model = EXCLUDED.device_model,
                    os_version = EXCLUDED.os_version,
                    app_version = EXCLUDED.app_version,
                    language_code = EXCLUDED.language_code,
                    timezone = EXCLUDED.timezone,
                    fcm_token = EXCLUDED.fcm_token,
                    is_active = true
      `,
        [
          user.id,
          devId,
          device_info?.platform || 'unknown',
          device_info?.model || null,
          device_info?.os_version || null,
          device_info?.app_version || null,
          device_info?.language_code || null,
          device_info?.timezone || null,
          device_info?.fcm_token || null,  // Will be null if not provided or Firebase not initialized
        ]
      );

      // Additional debug: Log what was actually saved
      const savedDeviceResult = await db.query(
        `SELECT fcm_token FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      if (savedDeviceResult.rows.length > 0) {
        const savedFcmToken = savedDeviceResult.rows[0].fcm_token;
        if (savedFcmToken) {
          console.log(`[verify-otp] FCM token successfully saved to DB: ${savedFcmToken.substring(0, 20)}...`);
        } else {
          console.log(`[verify-otp] WARNING: FCM token is NULL in database after save`);
        }
      }

      // === SECURITY HARDENING: IP/DEVICE RISK ===
      // Calculate risk score for this login
      const previousAuth = await getPreviousAuthInfo(user.id, devId);
      const riskScore = await calculateRiskScore({
        userId: user.id,
        currentIp: clientIp,
        currentUserAgent: req.headers['user-agent'],
        currentDeviceId: devId,
        currentDeviceInfo: device_info,
        previousIp: previousAuth.previousIp,
        previousUserAgent: previousAuth.previousUserAgent,
        previousDeviceId: previousAuth.previousDeviceId,
      });

      // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
      // Log OTP verification event with risk level (needed for step-up authentication)
      await logAuthEvent({
        userId: user.id,
        action: 'otp_verify',
        status: 'success',
        riskLevel: riskScore.isSuspicious
          ? (riskScore.score >= 50 ? RISK_LEVELS.HIGH_RISK : RISK_LEVELS.SUSPICIOUS)
          : RISK_LEVELS.INFO,
        deviceId: devId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
        meta: {
          is_new_device: isNewDevice,
          is_new_account: !isExistingAccount,
          platform: device_info?.platform || 'unknown',
          risk_score: riskScore.score,
          risk_reasons: riskScore.reasons,
        },
      });

      // Check for anomalies
      await checkAnomalies(user.id, 'otp_verify', clientIp);

      // === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
      // Issue access token with high_assurance flag if this is a fresh OTP verification
      // This allows step-up auth for sensitive actions
      const accessToken = signAccessToken(user, { highAssurance: true, deviceId: devId });
      const refreshToken = await issueRefreshToken({
        userId: user.id,
        deviceId: devId,
        userAgent: req.headers['user-agent'],
        ip: clientIp,
      });

      const needsProfile = !user.name;

      // Get count of active devices
      const deviceCountResult = await db.query(
        `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
        [user.id]
      );
      const activeDevicesCount = parseInt(deviceCountResult.rows[0].count, 10);

      return res.json({
        user,
        access_token: accessToken,
        refresh_token: refreshToken,
        needs_profile: needsProfile,
        is_new_device: isNewDevice,
        is_new_account: !isExistingAccount,
        active_devices_count: activeDevicesCount,
      });
    } catch (err) {
      console.error('verify-otp error', err);
      // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
      // Even on error, ensure minimum delay to prevent timing leaks
      await otpVerifyDelay();
      return res.status(500).json({ error: 'Internal server error' });
    }
  });
// POST /auth/request-email-otp
router.post(
  '/request-email-otp',
  validateRequestEmailOtpBody,
  checkActiveOtpForEmail,
  rateLimitRequestOtpByEmail,
  rateLimitRequestOtpByIp,
  async (req, res) => {
    // === FEATURE FLAGS ===
    if (!config.enableEmailOtp) {
      return res.status(403).json({ success: false, message: 'Email authentication is currently disabled' });
    }

    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({ success: false, message: 'Access denied from this location.' });
    }

    if (await isIpBlockedForEnumeration(clientIp)) {
      return res.status(429).json({ success: false, message: 'Too many requests. Please try again later.' });
    }

    try {
      const result = await executeOtpRequestWithTiming(async () => {
        const { email, phone_number, is_signup } = req.body;
        const normalizedEmail = email.trim().toLowerCase();

        const enumerationCheck = await detectAndLogEnumeration(clientIp, normalizedEmail, req.headers['user-agent'], 'email');

        if (enumerationCheck.isEnumeration) {
          const enumRateLimit = await checkEnumerationRateLimit(clientIp);
          if (!enumRateLimit.allowed) {
            await blockIpForEnumeration(clientIp);
            return { error: enumRateLimit.reason || 'Too many requests.', status: 429 };
          }
        }

        if (enumerationCheck.shouldBlock) {
          await blockIpForEnumeration(clientIp);
          return { error: 'Too many requests. IP blocked due to enumeration attempts.', status: 429 };
        }
        
        // Ensure email and phone aren't linked to different accounts before sending OTP
        if (phone_number) {
          const phoneSearchParams = preparePhoneSearchParams(phone_number);
          const usersResult = await db.query(
            `SELECT id, email, phone_number FROM users WHERE email = $1 OR phone_number = $2 OR phone_number = $3`,
            [normalizedEmail, phoneSearchParams[0], phoneSearchParams[1]]
          );
          const users = usersResult.rows;
          
          if (users && users.length > 0) {
            const sameEmailUser = users.find(u => u.email === normalizedEmail);
            const samePhoneUser = users.find(u => u.phone_number === phoneSearchParams[0] || u.phone_number === phoneSearchParams[1]);

            if (is_signup === true || is_signup === 'true') {
              // If signing up, these must NOT exist
              if (sameEmailUser || samePhoneUser) {
                return { error: 'An account with this email or phone number already exists. Please log in.', status: 409 };
              }
            } else {
              // If logging in, they MUST match if they both exist on an account
              if (sameEmailUser && sameEmailUser.phone_number && sameEmailUser.phone_number !== phoneSearchParams[0] && sameEmailUser.phone_number !== phoneSearchParams[1]) {
                return { error: 'This email is registered with a different phone number.', status: 409 };
              }

              if (samePhoneUser && samePhoneUser.email && samePhoneUser.email !== normalizedEmail) {
                return { error: 'This phone number is registered with a different email.', status: 409 };
              }
            }
          } else {
            // No users found in DB
            if (is_signup !== true && is_signup !== 'true') {
              return { error: 'Account not found. Please sign up first.', status: 404 };
            }
          }
        }

        const { code } = await createOtp(normalizedEmail, 'email');
        const emailResult = await sendOtpEmail(normalizedEmail, code);

        await logAuthEvent({
          action: 'otp_request_email',
          status: emailResult?.success ? 'success' : 'failed',
          riskLevel: RISK_LEVELS.INFO,
          ipAddress: clientIp,
          userAgent: req.headers['user-agent'],
          meta: { email: normalizedEmail.replace(/(?<=^.{3}).*(?=@)/, '***') },
        });

        if (!emailResult || !emailResult.success) {
          console.warn('⚠️ Email sending failed, but OTP was generated');
        }

        return { ok: true, status: 200 };
      });

      if (result.error) return res.status(result.status || 500).json({ error: result.error });
      return res.json({ ok: true });
    } catch (err) {
      console.error('request-email-otp error', err);
      await otpRequestDelay();
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/verify-email-otp
router.post(
  '/verify-email-otp',
  validateVerifyEmailOtpBody,
  rateLimitVerifyOtpByEmail,
  async (req, res) => {
    // === FEATURE FLAGS ===
    if (!config.enableEmailOtp) {
      return res.status(403).json({ success: false, message: 'Email authentication is currently disabled' });
    }

    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({ success: false, message: 'Access denied from this location.' });
    }

    try {
      const { email, phone_number, code, device_id, device_info } = req.body;
      const normalizedEmail = email.trim().toLowerCase();
      // Only encrypt phone number if we are storing it securely
      const encryptedPhone = encryptPhoneNumber(phone_number);
      
      const verificationResult = await executeOtpVerifyWithTiming(async () => {
        // CRITICAL FIX: verifyOtp() resolves to an object — {ok: true} or
        // {ok: false, reason: ...} — never null/undefined. `!isValid` on a
        // non-null object is always false in JS regardless of `.ok`, so
        // this previously accepted ANY code for ANY email that had ever
        // requested an OTP: a wrong/expired/never-issued code still hit the
        // `return { success: true, ... }` line below and went on to mint
        // real access+refresh tokens. Must check `.ok`, same as the phone
        // path (verify-otp route, above) already correctly does.
        const isValid = await verifyOtp(normalizedEmail, code, 'email');
        if (!isValid.ok) {
          await incrementFailedVerify(normalizedEmail);
          return { error: 'Invalid or expired code', status: 400 };
        }
        return { success: true, normalizedEmail, device_id, device_info };
      });

      if (verificationResult.error) {
        await logSuspiciousOtpAttempt(normalizedEmail, clientIp, req.headers['user-agent'], 'invalid_otp');
        return res.status(verificationResult.status || 500).json({ error: verificationResult.error });
      }

      const devId = sanitizeDeviceId(device_id);

      let user;

      // === SECURITY HARDENING: CROSS-ACCOUNT UNIQUE CHECK ===
      // Ensure that email and phone number are not registered to DIFFERENT accounts.
      const foundByEmail = await db.query(
        `SELECT id, email, phone_number, name, role, COALESCE(token_version, 1) as token_version
         FROM users WHERE email = $1 AND deleted = FALSE`,
        [normalizedEmail]
      );
      
      const phoneSearchParams = preparePhoneSearchParams(phone_number);
      const foundByPhone = await db.query(
        `SELECT id, email, phone_number, name, role, COALESCE(token_version, 1) as token_version
         FROM users WHERE (phone_number = $1 OR phone_number = $2) AND deleted = FALSE`,
        phoneSearchParams
      );

      if (foundByEmail.rows.length > 0 && foundByPhone.rows.length > 0) {
        if (foundByEmail.rows[0].id !== foundByPhone.rows[0].id) {
          return res.status(409).json({ error: 'This email and phone number belong to different accounts.' });
        }
        user = foundByEmail.rows[0];
        // Ensure email is marked verified
        await db.query(`UPDATE users SET is_email_verified = TRUE WHERE id = $1`, [user.id]);
      } else if (foundByEmail.rows.length > 0) {
        user = foundByEmail.rows[0];
        // User exists with this email, but not this phone. Is another phone already set?
        // Note: decrypt the phone in DB or just compare with encrypted and unencrypted.
        // It's safer to check if phone_number is simply present.
        if (user.phone_number && user.phone_number !== phoneSearchParams[0] && user.phone_number !== phoneSearchParams[1]) {
          return res.status(409).json({ error: 'This email is registered with a different phone number.' });
        }
        await db.query(`UPDATE users SET is_email_verified = TRUE, phone_number = $2 WHERE id = $1`, [user.id, encryptedPhone]);
      } else if (foundByPhone.rows.length > 0) {
        user = foundByPhone.rows[0];
        // User exists with this phone, but not this email. Is another email already set?
        if (user.email && user.email !== normalizedEmail) {
          return res.status(409).json({ error: 'This phone number is registered with a different email.' });
        }
        await db.query(`UPDATE users SET is_email_verified = TRUE, email = $2 WHERE id = $1`, [user.id, normalizedEmail]);
      } else {
        const newUserResult = await db.query(
          `INSERT INTO users (email, phone_number, language, timezone, is_email_verified)
           VALUES ($1, $2, $3, $4, TRUE)
           RETURNING id, email, name, role, COALESCE(token_version, 1) as token_version`,
          [normalizedEmail, encryptedPhone, device_info?.language_code || null, device_info?.timezone || null]
        );
        user = newUserResult.rows[0];
      }

      await db.query(`UPDATE users SET last_login_at = NOW() WHERE id = $1`, [user.id]);

      const existingDevice = await db.query(
        `SELECT id FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      const isNewDevice = existingDevice.rows.length === 0;
      const isExistingAccount = user.name && user.name.trim() !== '';

      await db.query(
        `INSERT INTO user_devices (
          user_id, device_identifier, device_platform, device_model,
          os_version, app_version, language_code, timezone, fcm_token, last_seen_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
        ON CONFLICT (user_id, device_identifier)
        DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at,
                      device_platform = EXCLUDED.device_platform,
                      device_model = EXCLUDED.device_model,
                      os_version = EXCLUDED.os_version,
                      app_version = EXCLUDED.app_version,
                      language_code = EXCLUDED.language_code,
                      timezone = EXCLUDED.timezone,
                      fcm_token = EXCLUDED.fcm_token,
                      is_active = true`,
        [
          user.id, devId,
          device_info?.platform || 'unknown', device_info?.model || null,
          device_info?.os_version || null, device_info?.app_version || null,
          device_info?.language_code || null, device_info?.timezone || null,
          device_info?.fcm_token || null
        ]
      );

      const previousAuth = await getPreviousAuthInfo(user.id, devId);
      const riskScore = await calculateRiskScore({
        userId: user.id, currentIp: clientIp, currentUserAgent: req.headers['user-agent'],
        currentDeviceId: devId, currentDeviceInfo: device_info,
        previousIp: previousAuth.previousIp, previousUserAgent: previousAuth.previousUserAgent,
        previousDeviceId: previousAuth.previousDeviceId,
      });

      await logAuthEvent({
        userId: user.id,
        action: 'otp_verify_email',
        status: 'success',
        riskLevel: riskScore.isSuspicious ? (riskScore.score >= 50 ? RISK_LEVELS.HIGH_RISK : RISK_LEVELS.SUSPICIOUS) : RISK_LEVELS.INFO,
        deviceId: devId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
        meta: {
          is_new_device: isNewDevice, is_new_account: !isExistingAccount,
          platform: device_info?.platform || 'unknown',
          risk_score: riskScore.score, risk_reasons: riskScore.reasons,
        },
      });

      await checkAnomalies(user.id, 'otp_verify_email', clientIp);

      const accessToken = signAccessToken(user, { highAssurance: true, deviceId: devId });
      const refreshToken = await issueRefreshToken({
        userId: user.id, deviceId: devId, userAgent: req.headers['user-agent'], ip: clientIp,
      });

      const needsProfile = !user.name;
      const deviceCountResult = await db.query(
        `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
        [user.id]
      );
      
      return res.json({
        user,
        access_token: accessToken,
        refresh_token: refreshToken,
        needs_profile: needsProfile,
        is_new_device: isNewDevice,
        is_new_account: !isExistingAccount,
        active_devices_count: parseInt(deviceCountResult.rows[0].count, 10),
      });
    } catch (err) {
      console.error('verify-email-otp error', err);
      await otpVerifyDelay();
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/google
router.post(
  '/google',
  validateGoogleLoginBody,
  async (req, res) => {
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({ success: false, message: 'Access denied from this location.' });
    }

    try {
      const { id_token, device_id, device_info } = req.body;
      
      const googleUser = await verifyGoogleToken(id_token);
      if (!googleUser) {
        return res.status(400).json({ error: 'Invalid Google token' });
      }

      const { email, name, picture, googleId } = googleUser;
      const devId = sanitizeDeviceId(device_id);

      let user;
      const found = await db.query(
        `SELECT id, email, name, role, COALESCE(token_version, 1) as token_version
         FROM users WHERE email = $1 AND deleted = FALSE`,
        [email]
      );

      if (found.rows.length === 0) {
        const newUserResult = await db.query(
          `INSERT INTO users (email, name, avatar_url, google_id, language, timezone, is_email_verified)
           VALUES ($1, $2, $3, $4, $5, $6, TRUE)
           RETURNING id, email, name, role, COALESCE(token_version, 1) as token_version`,
          [email, name, picture, googleId, device_info?.language_code || null, device_info?.timezone || null]
        );
        user = newUserResult.rows[0];
      } else {
        user = found.rows[0];
        // Ensure email is marked verified and google_id is linked if not present
        await db.query(`UPDATE users SET is_email_verified = TRUE, google_id = COALESCE(google_id, $2) WHERE id = $1`, [user.id, googleId]);
      }

      await db.query(`UPDATE users SET last_login_at = NOW() WHERE id = $1`, [user.id]);

      const existingDevice = await db.query(
        `SELECT id FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      const isNewDevice = existingDevice.rows.length === 0;
      const isExistingAccount = user.name && user.name.trim() !== '';

      await db.query(
        `INSERT INTO user_devices (
          user_id, device_identifier, device_platform, device_model,
          os_version, app_version, language_code, timezone, fcm_token, last_seen_at
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
        ON CONFLICT (user_id, device_identifier)
        DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at,
                      device_platform = EXCLUDED.device_platform,
                      device_model = EXCLUDED.device_model,
                      os_version = EXCLUDED.os_version,
                      app_version = EXCLUDED.app_version,
                      language_code = EXCLUDED.language_code,
                      timezone = EXCLUDED.timezone,
                      fcm_token = EXCLUDED.fcm_token,
                      is_active = true`,
        [
          user.id, devId,
          device_info?.platform || 'unknown', device_info?.model || null,
          device_info?.os_version || null, device_info?.app_version || null,
          device_info?.language_code || null, device_info?.timezone || null,
          device_info?.fcm_token || null
        ]
      );

      const previousAuth = await getPreviousAuthInfo(user.id, devId);
      const riskScore = await calculateRiskScore({
        userId: user.id, currentIp: clientIp, currentUserAgent: req.headers['user-agent'],
        currentDeviceId: devId, currentDeviceInfo: device_info,
        previousIp: previousAuth.previousIp, previousUserAgent: previousAuth.previousUserAgent,
        previousDeviceId: previousAuth.previousDeviceId,
      });

      await logAuthEvent({
        userId: user.id,
        action: 'google_login',
        status: 'success',
        riskLevel: riskScore.isSuspicious ? (riskScore.score >= 50 ? RISK_LEVELS.HIGH_RISK : RISK_LEVELS.SUSPICIOUS) : RISK_LEVELS.INFO,
        deviceId: devId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
        meta: {
          is_new_device: isNewDevice, is_new_account: !isExistingAccount,
          platform: device_info?.platform || 'unknown',
          risk_score: riskScore.score, risk_reasons: riskScore.reasons,
        },
      });

      await checkAnomalies(user.id, 'google_login', clientIp);

      const accessToken = signAccessToken(user, { highAssurance: true, deviceId: devId });
      const refreshToken = await issueRefreshToken({
        userId: user.id, deviceId: devId, userAgent: req.headers['user-agent'], ip: clientIp,
      });

      const needsProfile = !user.name;
      const deviceCountResult = await db.query(
        `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
        [user.id]
      );
      
      return res.json({
        user,
        access_token: accessToken,
        refresh_token: refreshToken,
        needs_profile: needsProfile,
        is_new_device: isNewDevice,
        is_new_account: !isExistingAccount,
        active_devices_count: parseInt(deviceCountResult.rows[0].count, 10),
      });
    } catch (err) {
      console.error('google login error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/refresh
// === SECURITY HARDENING: INPUT VALIDATION ===
// === SECURITY HARDENING: REFRESH TOKEN THEFT MITIGATION ===
// === SECURITY HARDENING: CSRF (FUTURE-PROOFING) ===
// NOTE: If tokens are ever moved to HTTP-only cookies, CSRF protection becomes mandatory.
// Consider implementing: SameSite cookie attribute + CSRF token validation
router.post(
  '/refresh',
  validateRefreshTokenBody,
  async (req, res) => {
    try {
      const { refresh_token } = req.body;
      const clientIp = req.ip || req.connection.remoteAddress || 'unknown';

      // === SECURITY HARDENING: IP/DEVICE RISK ===
      // Check if IP is blocked
      if (isIpBlocked(clientIp)) {
        await logBlockedIpLogin(clientIp, req.headers['user-agent']);
        return res.status(403).json({ error: 'Access denied from this location.' });
      }

      console.log(`[AUTH] Refresh token request received: ip=${clientIp}, userAgent=${req.headers['user-agent']}`);
      const verification = await verifyRefreshToken(refresh_token);
      if (!verification || verification.reuseDetected) {
        console.log(`[AUTH] Refresh token verification failed: reuseDetected=${verification?.reuseDetected || false}`);
        return res.status(401).json({ error: 'Invalid refresh token' });
      }
      console.log(`[AUTH] Refresh token verified: userId=${verification.userId}, deviceId=${verification.deviceId}`);

      const { userId, deviceId, row: tokenRow } = verification;

      // === GUEST LOGIN SUPPORT ===
      // Check if user exists in database (guests don't have user records)
      const { rows } = await db.query(
        `SELECT id, phone_number, name, role, COALESCE(token_version, 1) as token_version FROM users WHERE id = $1`,
        [userId]
      );

      let user;
      if (rows.length === 0) {
        // Guest user - create guest user object (no DB record)
        console.log(`[AUTH] Refresh token for guest user: userId=${userId}`);
        user = {
          id: userId,
          phone_number: null,
          name: null,
          role: 'user',
          token_version: 1,
          is_guest: true
        };
      } else {
        // Regular user
        user = rows[0];
        user.is_guest = false;
      }

      // === GUEST LOGIN SUPPORT ===
      // Skip risk scoring and OTP checks for guests (they don't have user records)
      let riskScore = { isSuspicious: false, score: 0, reasons: [] };
      let hasRecentOtp = false;

      if (!user.is_guest) {
        // === SECURITY HARDENING: REFRESH TOKEN THEFT MITIGATION ===
        // Calculate risk score for refresh from different environment (only for regular users)
        const previousAuth = await getPreviousAuthInfo(userId, deviceId);
        riskScore = await calculateRiskScore({
          userId,
          currentIp: clientIp,
          currentUserAgent: req.headers['user-agent'],
          currentDeviceId: deviceId,
          currentDeviceInfo: null,
          previousIp: tokenRow.ip_address || previousAuth.previousIp,
          previousUserAgent: tokenRow.user_agent || previousAuth.previousUserAgent,
          previousDeviceId: deviceId,
        });

        // === SECURITY HARDENING: REFRESH TOKEN THEFT MITIGATION ===
        // If refresh is from suspicious environment, log it
        if (riskScore.isSuspicious) {
          await logSuspiciousRefresh(
            userId,
            deviceId,
            clientIp,
            req.headers['user-agent'],
            riskScore.score,
            riskScore.reasons
          );

          // Optionally require OTP re-verification for suspicious refreshes
          if (REQUIRE_OTP_ON_SUSPICIOUS_REFRESH) {
            return res.status(403).json({
              error: 'step_up_required',
              message: 'Additional verification required. Please verify your OTP.',
              requires_otp: true,
            });
          }
        }

        // === SECURITY HARDENING: ACCESS TOKEN REPLAY MITIGATION ===
        // Preserve high_assurance status if there's been a recent OTP verification
        // This ensures step-up authentication remains valid after token refresh
        const RECENT_OTP_WINDOW_MINUTES = parseInt(process.env.STEP_UP_OTP_WINDOW_MINUTES || '5', 10);
        const recentOtpCheck = await db.query(
          `SELECT created_at
           FROM auth_audit
           WHERE user_id = $1
             AND action = 'otp_verify'
             AND status = 'success'
             AND created_at > NOW() - INTERVAL '${RECENT_OTP_WINDOW_MINUTES} minutes'
           ORDER BY created_at DESC
           LIMIT 1`,
          [userId]
        );
        hasRecentOtp = recentOtpCheck.rows.length > 0;
      }

      console.log(`[AUTH] Token refresh: userId=${userId}, deviceId=${deviceId}, ip=${clientIp}`);

      const newAccess = signAccessToken(user, { highAssurance: hasRecentOtp, deviceId });
      console.log(`[AUTH] New access token generated: userId=${userId}, expiresIn=${config.jwtAccessTtl}`);

      const newRefresh = await rotateRefreshToken({
        tokenRow,
        userAgent: req.headers['user-agent'],
        ip: clientIp,
      });
      console.log(`[AUTH] New refresh token generated and rotated: userId=${userId}, deviceId=${deviceId}`);

      // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
      // Log refresh event
      await logAuthEvent({
        userId,
        action: 'token_refresh',
        status: 'success',
        riskLevel: riskScore.isSuspicious
          ? (riskScore.score >= 50 ? RISK_LEVELS.HIGH_RISK : RISK_LEVELS.SUSPICIOUS)
          : RISK_LEVELS.INFO,
        deviceId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
        meta: {
          risk_score: riskScore.score,
          risk_reasons: riskScore.reasons,
        },
      });

      // Update device last_seen_at when tokens are refreshed (only for regular users)
      if (!user.is_guest) {
        try {
          await db.query(
            `UPDATE user_devices SET last_seen_at = NOW() WHERE user_id = $1 AND device_identifier = $2`,
            [userId, deviceId]
          );
        } catch (deviceErr) {
          console.error('Failed to update device last_seen_at', deviceErr);
          // Don't fail the refresh if device update fails
        }
      }

      console.log(`[AUTH] Token refresh successful: userId=${userId}, deviceId=${deviceId}`);
      return res.json({ access_token: newAccess, refresh_token: newRefresh });
    } catch (err) {
      console.error('[AUTH] refresh error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  });

// POST /auth/logout
// === SECURITY HARDENING: AUTHENTICATION & INPUT VALIDATION ===
router.post(
  '/logout',
  auth,
  validateLogoutBody,
  async (req, res) => {
    try {
      const { refresh_token } = req.body;
      const clientIp = req.ip || req.connection.remoteAddress || 'unknown';
      const authenticatedUserId = req.user.id;

      const info = await verifyRefreshToken(refresh_token);
      if (!info || info.reuseDetected) {
        return res.status(200).json({ ok: true }); // already invalid -> treat as logged out
      }

      // === SECURITY HARDENING: VERIFY USER MATCH ===
      // Ensure the authenticated user matches the refresh token's user
      if (info.userId !== authenticatedUserId) {
        console.error(`[AUTH] Logout user mismatch: authenticated=${authenticatedUserId}, refreshToken=${info.userId}`);
        return res.status(403).json({ error: 'Refresh token does not belong to authenticated user' });
      }

      await revokeRefreshToken(info.userId, info.deviceId);

      // Mark this specific device as inactive so its access tokens are rejected
      try {
        await db.query(
          `UPDATE user_devices SET is_active = false WHERE user_id = $1 AND device_identifier = $2`,
          [info.userId, info.deviceId]
        );
      } catch (deviceErr) {
        console.error('[AUTH] Failed to mark device as inactive on logout', deviceErr);
      }

      // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
      await logAuthEvent({
        userId: info.userId,
        action: 'logout',
        status: 'success',
        riskLevel: RISK_LEVELS.INFO,
        deviceId: info.deviceId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
      });

      return res.json({ ok: true });
    } catch (err) {
      console.error('logout error', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/signup
// Signup endpoint: Create new user with name, phone, and location
router.post(
  '/signup',
  validateSignupBody,
  async (req, res) => {
    const clientIp = req.ip || req.connection.remoteAddress || 'unknown';

    // Check if IP is blocked
    if (isIpBlocked(clientIp)) {
      await logBlockedIpLogin(clientIp, req.headers['user-agent']);
      return res.status(403).json({
        success: false,
        message: 'Access denied from this location.',
      });
    }

    try {
      const { name, phone_number, state, district, city_village, device_id, device_info } = req.body;

      // Debug: Log entire request body to see what's being received
      console.log('[signup] Request body keys:', Object.keys(req.body || {}));
      console.log('[signup] Location data:', { state, district, city_village, city_village_type: typeof city_village, city_village_length: city_village?.length });
      console.log('[signup] device_info type:', typeof device_info);
      console.log('[signup] device_info value:', JSON.stringify(device_info));

      // Normalize phone number
      const normalizedPhone = normalizePhone(phone_number);

      // Validate phone number format
      if (!isValidPhoneNumber(normalizedPhone)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid phone number format. Please use E.164 format (e.g., +919876543210)',
        });
      }

      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Encrypt phone number before storing/searching
      const encryptedPhone = encryptPhoneNumber(normalizedPhone);
      const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);

      // Check if user already exists
      const existingUser = await db.query(
        `SELECT id, phone_number, name, role, NULL::text as user_type, 
                COALESCE(token_version, 1) as token_version
         FROM users
         WHERE (phone_number = $1 OR phone_number = $2)
           AND deleted = FALSE`,
        phoneSearchParams
      ).catch(async (err) => {
        if (err.code === '42703' && err.message.includes('token_version')) {
          return await db.query(
            `SELECT id, phone_number, name, role, NULL::text as user_type, 1 as token_version
             FROM users
             WHERE (phone_number = $1 OR phone_number = $2)
               AND deleted = FALSE`,
            phoneSearchParams
          );
        }
        throw err;
      });

      if (existingUser.rows.length > 0) {
        const existing = existingUser.rows[0];
        // Check if user was just created by verify-otp (has no name) - allow update
        if (!existing.name || existing.name.trim() === '') {
          // User exists but has no name (was just created by verify-otp), update it with signup data
          const countryCode = normalizedPhone.startsWith('+')
            ? normalizedPhone.match(/^\+(\d{1,3})/)?.[0] || '+91'
            : '+91';

          // Update user with name, country code, language, and timezone
          const updatedUser = await db.query(
            `UPDATE users 
             SET name = $1, country_code = $2, language = $4, timezone = $5
             WHERE id = $3
             RETURNING id, phone_number, name, role, NULL::text as user_type, 
                       COALESCE(token_version, 1) as token_version, country_code, created_at`,
            [
              name,
              countryCode,
              existing.id,
              device_info?.language_code || null,
              device_info?.timezone || null
            ]
          ).catch(async (err) => {
            if (err.code === '42703' && err.message.includes('token_version')) {
              const result = await db.query(
                `UPDATE users 
                 SET name = $1, country_code = $2, language = $4, timezone = $5
                 WHERE id = $3
                 RETURNING id, phone_number, name, role, NULL::text as user_type, 
                           1 as token_version, country_code, created_at`,
                [
                  name,
                  countryCode,
                  existing.id,
                  device_info?.language_code || null,
                  device_info?.timezone || null
                ]
              );
              result.rows[0].token_version = 1;
              return result;
            }
            throw err;
          });

          const user = updatedUser.rows[0];

          // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
          // Decrypt phone number before returning to client
          if (user.phone_number) {
            user.phone_number = decryptPhoneNumber(user.phone_number);
          }

          // Create location entry if location data provided
          let locationId = null;
          if (state || district || city_village) {
            const locationResult = await db.query(
              `INSERT INTO locations (user_id, state, district, city_village, is_saved_address, location_type, source_type, source_confidence)
               VALUES ($1, $2, $3, $4, TRUE, 'home', 'manual', 'high')
               RETURNING id`,
              [user.id, state || null, district || null, city_village || null]
            );
            locationId = locationResult.rows[0]?.id;
          }

          // Update last_login_at
          await db.query(
            `UPDATE users SET last_login_at = NOW() WHERE id = $1`,
            [user.id]
          );

          const devId = sanitizeDeviceId(device_id);

          // Upsert user_devices row
          await db.query(
            `
            INSERT INTO user_devices (
              user_id, device_identifier, device_platform, device_model,
              os_version, app_version, language_code, timezone, last_seen_at
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW())
            ON CONFLICT (user_id, device_identifier)
            DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at,
                          device_platform = EXCLUDED.device_platform,
                          device_model = EXCLUDED.device_model,
                          os_version = EXCLUDED.os_version,
                          app_version = EXCLUDED.app_version,
                          language_code = EXCLUDED.language_code,
                          timezone = EXCLUDED.timezone,
                          is_active = true
            `,
            [
              user.id,
              devId,
              device_info?.platform || 'android',
              device_info?.model || null,
              device_info?.os_version || null,
              device_info?.app_version || null,
              device_info?.language_code || null,
              device_info?.timezone || null,
            ]
          );

          // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
          await logAuthEvent({
            userId: user.id,
            action: 'signup',
            status: 'success',
            riskLevel: RISK_LEVELS.INFO,
            deviceId: devId,
            ipAddress: clientIp,
            userAgent: req.headers['user-agent'],
            meta: {
              is_new_account: false,
              is_profile_completed: true,
              platform: device_info?.platform || 'android',
            },
          });

          // Issue tokens
          const accessToken = signAccessToken(user, { highAssurance: true });
          const refreshToken = await issueRefreshToken({
            userId: user.id,
            deviceId: devId,
            userAgent: req.headers['user-agent'],
            ip: clientIp,
          });

          const needsProfile = !user.name;

          // Get count of active devices
          const deviceCountResult = await db.query(
            `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
            [user.id]
          );
          const activeDevicesCount = parseInt(deviceCountResult.rows[0].count, 10);

          return res.json({
            success: true,
            user: {
              id: user.id,
              phone_number: user.phone_number,
              name: user.name,
              country_code: user.country_code,
              created_at: user.created_at,
            },
            access_token: accessToken,
            refresh_token: refreshToken,
            needs_profile: needsProfile,
            is_new_account: false,
            is_new_device: true,
            active_devices_count: activeDevicesCount,
            location_id: locationId,
          });
        } else {
          // User already exists with a name - they should sign in instead
          return res.status(409).json({
            success: false,
            message: 'User with this phone number already exists. Please sign in instead.',
            user_exists: true,
          });
        }
      }

      // Extract country code from phone number
      const countryCode = normalizedPhone.startsWith('+')
        ? normalizedPhone.match(/^\+(\d{1,3})/)?.[0] || '+91'
        : '+91';

      // Create new user with all available data
      const newUser = await db.query(
        `INSERT INTO users (phone_number, name, country_code, language, timezone)
         VALUES ($1, $2, $3, $4, $5)
         RETURNING id, phone_number, name, role, NULL::text as user_type, 
                   COALESCE(token_version, 1) as token_version, country_code, created_at`,
        [
          encryptedPhone,
          name,
          countryCode,
          device_info?.language_code || null,
          device_info?.timezone || null
        ]
      ).catch(async (err) => {
        if (err.code === '42703' && err.message.includes('token_version')) {
          const result = await db.query(
            `INSERT INTO users (phone_number, name, country_code, language, timezone)
             VALUES ($1, $2, $3, $4, $5)
             RETURNING id, phone_number, name, role, NULL::text as user_type, 
                       1 as token_version, country_code, created_at`,
            [
              encryptedPhone,
              name,
              countryCode,
              device_info?.language_code || null,
              device_info?.timezone || null
            ]
          );
          result.rows[0].token_version = 1;
          return result;
        }
        throw err;
      });

      const user = newUser.rows[0];

      // === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
      // Decrypt phone number before returning to client
      if (user.phone_number) {
        user.phone_number = decryptPhoneNumber(user.phone_number);
      }

      // Create location entry if location data provided
      let locationId = null;
      if (state || district || city_village) {
        const locationResult = await db.query(
          `INSERT INTO locations (user_id, state, district, city_village, is_saved_address, location_type, source_type, source_confidence)
           VALUES ($1, $2, $3, $4, TRUE, 'home', 'manual', 'high')
           RETURNING id`,
          [user.id, state || null, district || null, city_village || null]
        );
        locationId = locationResult.rows[0]?.id;
      }

      // Update last_login_at
      await db.query(
        `UPDATE users SET last_login_at = NOW() WHERE id = $1`,
        [user.id]
      );

      const devId = sanitizeDeviceId(device_id);

      // Log FCM token for debugging
      if (device_info?.fcm_token) {
        console.log(`[signup] FCM token received: ${device_info.fcm_token.substring(0, 20)}...`);
      } else {
        console.log(`[signup] No FCM token in device_info. Device info:`, JSON.stringify(device_info || {}));
      }

      // Upsert user_devices row
      await db.query(
        `
        INSERT INTO user_devices (
          user_id, device_identifier, device_platform, device_model,
          os_version, app_version, language_code, timezone, fcm_token, last_seen_at
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, NOW())
        ON CONFLICT (user_id, device_identifier)
        DO UPDATE SET last_seen_at = EXCLUDED.last_seen_at,
                      device_platform = EXCLUDED.device_platform,
                      device_model = EXCLUDED.device_model,
                      os_version = EXCLUDED.os_version,
                      app_version = EXCLUDED.app_version,
                      language_code = EXCLUDED.language_code,
                      timezone = EXCLUDED.timezone,
                      fcm_token = EXCLUDED.fcm_token,
                      is_active = true
        `,
        [
          user.id,
          devId,
          device_info?.platform || 'android',
          device_info?.model || null,
          device_info?.os_version || null,
          device_info?.app_version || null,
          device_info?.language_code || null,
          device_info?.timezone || null,
          device_info?.fcm_token || null,  // Will be null if not provided or Firebase not initialized
        ]
      );

      // Additional debug: Log what was actually saved
      const savedDeviceResult = await db.query(
        `SELECT fcm_token FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      if (savedDeviceResult.rows.length > 0) {
        const savedFcmToken = savedDeviceResult.rows[0].fcm_token;
        if (savedFcmToken) {
          console.log(`[signup] FCM token successfully saved to DB: ${savedFcmToken.substring(0, 20)}...`);
        } else {
          console.log(`[signup] WARNING: FCM token is NULL in database after save`);
        }
      }

      // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
      await logAuthEvent({
        userId: user.id,
        action: 'signup',
        status: 'success',
        riskLevel: RISK_LEVELS.INFO,
        deviceId: devId,
        ipAddress: clientIp,
        userAgent: req.headers['user-agent'],
        meta: {
          is_new_account: true,
          platform: device_info?.platform || 'android',
        },
      });

      // Issue tokens
      const accessToken = signAccessToken(user, { highAssurance: true, deviceId: devId });
      const refreshToken = await issueRefreshToken({
        userId: user.id,
        deviceId: devId,
        userAgent: req.headers['user-agent'],
        ip: clientIp,
      });

      const needsProfile = !user.name;

      // Get count of active devices
      const deviceCountResult = await db.query(
        `SELECT COUNT(*) as count FROM user_devices WHERE user_id = $1 AND is_active = true`,
        [user.id]
      );
      const activeDevicesCount = parseInt(deviceCountResult.rows[0].count, 10);

      return res.json({
        success: true,
        user: {
          id: user.id,
          phone_number: user.phone_number,
          name: user.name,
          country_code: user.country_code,
          created_at: user.created_at,
        },
        access_token: accessToken,
        refresh_token: refreshToken,
        needs_profile: needsProfile,
        is_new_account: true,
        is_new_device: true,
        active_devices_count: activeDevicesCount,
        location_id: locationId,
      });
    } catch (err) {
      console.error('[signup] Error details:', {
        message: err.message,
        stack: err.stack,
        code: err.code,
        constraint: err.constraint,
        detail: err.detail,
        body: req.body
      });

      // Handle unique constraint violation (phone number already exists)
      if (err.code === '23505' && err.constraint === 'users_phone_number_key') {
        return res.status(409).json({
          success: false,
          message: 'User with this phone number already exists. Please sign in instead.',
          user_exists: true,
        });
      }

      // Handle database constraint violations
      if (err.code === '23505') {
        return res.status(400).json({
          success: false,
          message: `Database constraint violation: ${err.detail || err.message}`,
        });
      }

      return res.status(500).json({
        success: false,
        message: 'Internal server error',
        error: process.env.NODE_ENV === 'development' ? err.message : undefined,
      });
    }
  }
);

// POST /auth/validate-token
// Endpoint for other services (like BuySellService) to validate JWT tokens
// This allows centralized token validation
router.post('/validate-token', async (req, res) => {
  const clientIp = req.ip || req.headers['x-forwarded-for']?.split(',')[0]?.trim() || req.headers['x-real-ip'] || 'unknown';
  const userAgent = req.headers['user-agent'] || 'unknown';

  console.log(`[Auth Service] POST /auth/validate-token - Request received`);
  console.log(`[Auth Service] Client IP: ${clientIp}`);
  console.log(`[Auth Service] User-Agent: ${userAgent.substring(0, 80)}`);
  console.log(`[Auth Service] Request body contains token: ${!!req.body?.token}`);

  try {
    const { token } = req.body;

    if (!token) {
      console.log(`[Auth Service] ❌ FAILED: Token is missing in request body`);
      return res.status(400).json({
        valid: false,
        error: 'Token is required'
      });
    }

    console.log(`[Auth Service] Token received (length: ${token.length} characters)`);

    // Use the auth middleware logic to validate token
    const jwt = require('jsonwebtoken');
    const { getKeySecret, getAllKeys, validateTokenClaims } = require('../services/jwtKeys');
    const db = require('../db');

    // Decode token to get key ID from header
    let decoded;
    try {
      decoded = jwt.decode(token, { complete: true });
      if (!decoded || !decoded.header) {
        console.log(`[Auth Service] ❌ FAILED: Invalid token format - unable to decode header`);
        return res.json({ valid: false, error: 'Invalid token format' });
      }
      console.log(`[Auth Service] Token decoded successfully`);
      console.log(`[Auth Service] Token header:`, {
        alg: decoded.header.alg,
        kid: decoded.header.kid || 'NOT SET',
        typ: decoded.header.typ,
      });
    } catch (err) {
      console.log(`[Auth Service] ❌ FAILED: Error decoding token - ${err.message}`);
      return res.json({ valid: false, error: 'Invalid token' });
    }

    // Get secret for the key ID (if present) or try all keys
    const keyId = decoded.header.kid;
    let payload = null;
    let verified = false;
    let verificationMethod = null;

    if (keyId) {
      console.log(`[Auth Service] Key ID found in token: ${keyId}`);
      const secret = getKeySecret(keyId);
      if (secret) {
        console.log(`[Auth Service] Attempting verification with key ID: ${keyId}`);
        try {
          payload = jwt.verify(token, secret);
          verified = true;
          verificationMethod = `keyId: ${keyId}`;
          console.log(`[Auth Service] ✅ Token verified successfully using key ID: ${keyId}`);
        } catch (err) {
          console.log(`[Auth Service] ❌ Verification failed with key ID ${keyId}: ${err.message}`);
          return res.json({ valid: false, error: 'Invalid or expired token' });
        }
      } else {
        console.log(`[Auth Service] ⚠️ Key ID ${keyId} not found in available keys, will try all keys`);
      }
    } else {
      console.log(`[Auth Service] ⚠️ No key ID in token header, trying all available keys`);
    }

    // If key ID not found or not specified, try all keys (for rotation support)
    if (!verified) {
      const allKeys = getAllKeys();
      console.log(`[Auth Service] Attempting verification with ${Object.keys(allKeys).length} available keys`);
      for (const [kid, keySecret] of Object.entries(allKeys)) {
        try {
          payload = jwt.verify(token, keySecret);
          verified = true;
          verificationMethod = `allKeys: ${kid}`;
          console.log(`[Auth Service] ✅ Token verified successfully using key: ${kid}`);
          break;
        } catch (err) {
          // Try next key silently
          continue;
        }
      }
      if (!verified) {
        console.log(`[Auth Service] ❌ FAILED: Token verification failed with all available keys`);
      }
    }

    if (!verified || !payload) {
      console.log(`[Auth Service] ❌ FINAL RESULT: Token is invalid or expired`);
      return res.json({ valid: false, error: 'Invalid or expired token' });
    }

    console.log(`[Auth Service] Token payload extracted:`, {
      userId: payload.sub,
      role: payload.role,
      userType: payload.user_type,
      exp: payload.exp ? new Date(payload.exp * 1000).toISOString() : 'NOT SET',
      iat: payload.iat ? new Date(payload.iat * 1000).toISOString() : 'NOT SET',
      tokenVersion: payload.token_version || 1,
    });

    // Validate JWT claims (iss, aud, exp, iat, nbf)
    console.log(`[Auth Service] Validating JWT claims...`);
    const claimsValidation = validateTokenClaims(payload);
    if (!claimsValidation.valid) {
      console.log(`[Auth Service] ❌ FAILED: Claims validation failed - ${claimsValidation.reason}`);
      return res.json({ valid: false, error: 'Invalid token claims' });
    }
    console.log(`[Auth Service] ✅ Claims validation passed`);

    // === GUEST LOGIN SUPPORT ===
    // Check if guest token FIRST (before database lookup)
    if (payload.is_guest === true) {
      console.log(`[Auth Service] Guest token detected - skipping database lookup for guestId=${payload.sub}`);
      // For guests: Skip database lookup, just validate token signature/expiry
      // This is safe because guest tokens don't have user records
      return res.json({
        valid: true,
        payload: {
          sub: payload.sub,
          role: payload.role || 'user',
          user_type: payload.user_type || null,
          phone_number: payload.phone_number || null,
          token_version: payload.token_version || 1,
          high_assurance: payload.high_assurance || false,
          is_guest: true,
        },
      });
    }

    // EXISTING LOGIC BELOW - DO NOT MODIFY
    // For regular users: Check database (existing logic - UNCHANGED)
    // Validate token_version to ensure token hasn't been invalidated by logout-all-devices
    console.log(`[Auth Service] Checking token version in database for user: ${payload.sub}`);
    try {
      const { rows } = await db.query(
        `SELECT COALESCE(token_version, 1) as token_version FROM users WHERE id = $1`,
        [payload.sub]
      );

      if (rows.length === 0) {
        console.log(`[Auth Service] ❌ FAILED: User not found in database: ${payload.sub}`);
        return res.json({ valid: false, error: 'User not found' });
      }

      const userTokenVersion = rows[0].token_version;
      const tokenVersion = payload.token_version || 1;

      console.log(`[Auth Service] Token version check:`, {
        tokenVersion,
        userTokenVersion,
        match: tokenVersion === userTokenVersion,
      });

      // If token version doesn't match, token has been invalidated
      if (tokenVersion !== userTokenVersion) {
        console.log(`[Auth Service] ❌ FAILED: Token version mismatch - token has been invalidated`);
        return res.json({ valid: false, error: 'Token has been invalidated' });
      }
      console.log(`[Auth Service] ✅ Token version check passed`);
    } catch (dbErr) {
      // Handle missing token_version column gracefully
      if (dbErr.code === '42703' && dbErr.message && dbErr.message.includes('token_version')) {
        console.warn('[Auth Service] ⚠️ token_version column not found in database, skipping version check');
        // Continue without token version validation
      } else {
        console.error('[Auth Service] ❌ Error validating token version:', dbErr);
        return res.status(500).json({ valid: false, error: 'Internal server error' });
      }
    }

    // Optional per-device invalidation based on device_id claim
    if (payload.device_id) {
      console.log(
        `[Auth Service] Checking device status for user ${payload.sub}, device ${payload.device_id}`
      );
      try {
        const deviceResult = await db.query(
          `SELECT is_active FROM user_devices WHERE user_id = $1 AND device_identifier = $2 LIMIT 1`,
          [payload.sub, payload.device_id]
        );

        if (deviceResult.rows.length === 0) {
          console.log('[Auth Service] ❌ FAILED: Device not found or already logged out');
          return res.json({ valid: false, error: 'Device is logged out' });
        }

        if (deviceResult.rows[0].is_active === false) {
          console.log('[Auth Service] ❌ FAILED: Device is inactive - token has been logged out');
          return res.json({ valid: false, error: 'Token has been logged out for this device' });
        }

        console.log('[Auth Service] ✅ Device is active for this token');
      } catch (deviceErr) {
        console.error('[Auth Service] ❌ Error validating device status:', deviceErr);
        return res.status(500).json({ valid: false, error: 'Internal server error' });
      }
    }

    // Token is valid - return user info
    console.log(`[Auth Service] ✅ FINAL RESULT: Token is VALID`);
    console.log(`[Auth Service] Returning user info:`, {
      userId: payload.sub,
      role: payload.role,
      userType: payload.user_type,
      verificationMethod,
    });

    return res.json({
      valid: true,
      payload: {
        sub: payload.sub,
        role: payload.role,
        user_type: payload.user_type,
        phone_number: payload.phone_number,
        token_version: payload.token_version || 1,
        high_assurance: payload.high_assurance || false,
        is_guest: payload.is_guest || false,
      },
    });
  } catch (err) {
    console.error('[Auth Service] ❌ UNEXPECTED ERROR in validate-token:', err);
    console.error('[Auth Service] Error stack:', err.stack);
    return res.status(500).json({ valid: false, error: 'Internal server error' });
  }
});

module.exports = router;
