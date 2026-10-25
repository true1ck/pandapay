const { safeErrorCode } = require('../utils/safeErrorCode');
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
const { resolveGoogleAccount, GoogleIdentityError } = require('../services/googleIdentity');
const { newAccountsPaused, respondPaused, CODE: REGISTRATION_PAUSED } = require('../services/newAccountAdmission');
const { verifyAccessToken } = require('../services/accessTokenVerification');
const { verifyCurrentSession } = require('../services/currentSessionVerification');
const {
  createOtp,
  verifyOtp,
  discardUndeliveredOtp,
  createOtpV2, verifyOtpV2, discardUndeliveredOtpV2,
} = require('../services/otpService');
const {isVersionedOtpRequest}=require('./versionedOtpRoutes');
const { OtpCapacityError, BUSY_CODE, respondOtpCapacityUnavailable } = require('../services/otpWorkAdmission');
const { isTestOtpIdentifier } = require('../utils/testOtp');
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
  RateLimitStorageError,
  ActiveOtpError,
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
const { preparePhoneSearchParams, phoneLookupHash } = require('../utils/encryptedPhoneSearch');
// === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
const { executeOtpRequestWithTiming, otpRequestDelay, executeOtpVerifyWithTiming, otpVerifyDelay } = require('../utils/timingProtection');
// === SECURITY HARDENING: ENUMERATION DETECTION ===
const { detectAndLogEnumeration } = require('../utils/enumerationDetection');

const router = express.Router();
const {createLegacyAuthAdmission}=require('../middleware/legacyAuthAdmission');
router.use(createLegacyAuthAdmission({retireLegacyOtp:config.retireLegacyOtp,retirePublicLookup:config.retirePublicLookup}));
function createChallenge(req,identifier,type,purpose){
  return isVersionedOtpRequest(req)?createOtpV2(identifier,type,purpose,req.body.device_id):createOtp(identifier,type,purpose);
}
function verifyChallenge(req,identifier,code,type,purpose){
  return isVersionedOtpRequest(req)?verifyOtpV2(identifier,code,type,purpose,req.body.device_id,req.body.challenge_id):verifyOtp(identifier,code,type,purpose);
}
function discardChallenge(req,identifier,type,id,purpose){
  return isVersionedOtpRequest(req)?discardUndeliveredOtpV2(identifier,type,id,purpose,req.body.device_id):discardUndeliveredOtp(identifier,type,id,purpose);
}
function requestSuccess(req,result){
  return isVersionedOtpRequest(req)?{ok:true,version:2,challenge_id:result.requestId,code_length:6,expires_in:120}:{ok:true};
}
const ABUSE_STORE_UNAVAILABLE_MESSAGE = 'Authentication is temporarily unavailable. Please try again shortly.';

function isRateLimitStorageError(error) {
  return typeof RateLimitStorageError === 'function' && error instanceof RateLimitStorageError;
}

function respondAbuseStoreUnavailable(res) {
  return res.status(503).json({ error: ABUSE_STORE_UNAVAILABLE_MESSAGE });
}

function isActiveOtpError(error) {
  return typeof ActiveOtpError === 'function' && error instanceof ActiveOtpError;
}

function respondActiveOtp(res) {
  return res.status(429).json({
    success: false,
    message: 'An OTP is already active. Please wait a moment before requesting a new one.',
  });
}

function logAuthError(event, error) {
  console.error(`[auth] ${event}`, safeErrorCode(error));
}

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
    try {
      if (await isIpBlockedForEnumeration(clientIp)) {
        return res.status(429).json({
          success: false,
          message: 'Too many requests. Please try again later.',
        });
      }
      // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
      // Execute all work with timing protection to prevent enumeration
      // This ensures all requests take similar time regardless of phone existence
      const result = await executeOtpRequestWithTiming(async () => {
        const { phone_number, recovery_only } = req.body;
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

        const purpose = recovery_only === true ? 'recovery' : 'signin';
        const { code, requestId } = await createChallenge(req, normalizedPhone, 'phone', purpose);

        // A generated code is not useful unless the SMS provider accepted it.
        // Only the explicit dev/test allowlist may bypass an external SMS
        // provider. Production OTPs still require provider acceptance.
        const smsResult = !isVersionedOtpRequest(req) && isTestOtpIdentifier(normalizedPhone)
          ? { success: true, testMode: true }
          : await sendOtpSms(normalizedPhone, code);

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

        if (!smsResult || !smsResult.success) {
          console.warn('⚠️ SMS delivery failed; discarding undelivered OTP');
          await discardChallenge(req, normalizedPhone, 'phone', requestId, purpose);
          return { error: 'Unable to send a sign-in code right now. Please try again later.', status: 503, capacityBusy: smsResult?.code === BUSY_CODE };
        }

        return { ok: true, status: 200, requestId };
      });

      // Handle errors or return success
      if (result.capacityBusy) return respondOtpCapacityUnavailable(res);
      if (result.error) {
        return res.status(result.status || 500).json({ error: result.error });
      }

      return res.json(requestSuccess(req,result));

    } catch (err) {
      logAuthError('request-otp failed', err);
      if (err instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
      if (isActiveOtpError(err)) return respondActiveOtp(res);
      if (isRateLimitStorageError(err)) return respondAbuseStoreUnavailable(res);
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
      // This legacy endpoint reveals registration state, so apply the same
      // shared enumeration budget before querying the phone lookup index.
      // It remains a compatibility endpoint (responses still distinguish
      // found/not-found); the quota limits probing rather than removing it.
      const enumerationLimit = await checkEnumerationRateLimit(clientIp);
      if (!enumerationLimit.allowed) {
        return res.status(429).json({
          success: false,
          message: 'Too many requests. Please try again later.',
        });
      }

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

      // Search the keyed canonical phone digest. Random-IV ciphertext cannot
      // be used for equality lookups.
      const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);

      // Check if user exists and has a name (fully registered)
      const found = await db.query(
        `SELECT id, name FROM users 
         WHERE phone_lookup_hash = $1
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
      logAuthError('check-user failed', err);
      if (isRateLimitStorageError(err)) return respondAbuseStoreUnavailable(res);
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
    logAuthError('guest-login failed', err);
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
        const { phone_number, code, device_id, device_info, recovery_only } = req.body;

        if (!phone_number || !code) {
          return { error: 'phone_number and code are required', status: 400 };
        }

        const normalizedPhone = normalizePhone(phone_number);

        // Ensure code is a string (handle case where it might come as number from JSON)
        // bcrypt.compare requires string, and validation expects string
        // Note: If code comes as number, leading zeros may be lost - client should send as string
        const codeString = String(code);

        const result = await verifyChallenge(
          req, normalizedPhone,
          codeString,
          'phone',
          recovery_only === true ? 'recovery' : 'signin',
        );

        // === ADDED FOR OTP ATTEMPT LIMIT ===
        // === SECURITY HARDENING: AUDIT LOGS & ANOMALY FLAGS ===
        // Use generic error message to avoid leaking information
        if (!result.ok) {
          // Increment failed verification counter
          await incrementFailedVerify(normalizedPhone, recovery_only === true ? 'recovery' : 'signin');

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

        return { ok: true, normalizedPhone, device_id, device_info, recovery_only };
      });

      // Handle verification failure
      if (verificationResult.error || !verificationResult.ok) {
        return res.status(verificationResult.status || 400).json({
          success: false,
          message: verificationResult.message || 'OTP invalid or expired. Please request a new one.'
        });
      }

      // Continue with successful verification
      const { normalizedPhone, device_id, device_info, recovery_only } = verificationResult;

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
       WHERE phone_lookup_hash = $1
         AND deleted = FALSE`,
        phoneSearchParams
      );

      if (found.rows.length === 0) {
        if (recovery_only === true) {
          // Recovery must verify an account that already exists. Never let
          // an OTP sent to an unlinked phone create a new/empty account.
          await logSuspiciousOtpAttempt(
            normalizedPhone,
            clientIp,
            req.headers['user-agent'],
            'recovery_account_not_found'
          );
          return res.status(400).json({
            success: false,
            message: 'OTP invalid or expired. Please request a new one.',
          });
        }
        if (newAccountsPaused()) return respondPaused(res);
        // User not found - create a minimal user for signup flow
        // Extract country code from phone number
        const countryCode = normalizedPhone.startsWith('+')
          ? normalizedPhone.match(/^\+(\d{1,3})/)?.[0] || '+91'
          : '+91';

        // Create new user with minimal data (name will be added via signup endpoint)
        const newUserResult = await db.query(
          `INSERT INTO users (phone_number, phone_lookup_hash, country_code, language, timezone, is_phone_verified)
         VALUES ($1, $2, $3, $4, $5, TRUE)
         RETURNING id, phone_number, name, role,
                   COALESCE(token_version, 1) as token_version`,
          [
            encryptedPhone,
            phoneLookupHash(normalizedPhone),
            countryCode,
            device_info?.language_code || null,
            device_info?.timezone || null
          ]
        );

        user = newUserResult.rows[0];
      } else {
        user = found.rows[0];
        // A successful code proves control of this number on every login path.
        await db.query('UPDATE users SET is_phone_verified = TRUE WHERE id = $1', [user.id]);
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
      const accessToken = signAccessToken(user, {
        highAssurance: true, deviceId: devId,
        verifiedChannel: 'phone',
        recoveryChannel: recovery_only === true ? 'phone' : undefined,
      });
      const refreshToken = recovery_only === true ? null : await issueRefreshToken({
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
      logAuthError('verify-otp failed', err);
      if (err instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
      if (isRateLimitStorageError(err)) return respondAbuseStoreUnavailable(res);
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

    try {
      if (await isIpBlockedForEnumeration(clientIp)) {
        return res.status(429).json({ success: false, message: 'Too many requests. Please try again later.' });
      }
      const result = await executeOtpRequestWithTiming(async () => {
        const { email, phone_number, is_signup, recovery_only } = req.body;
        const normalizedEmail = email.trim().toLowerCase();
        const normalizedPhone = phone_number ? normalizePhone(phone_number) : null;

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
        if (normalizedPhone) {
          const phoneSearchParams = preparePhoneSearchParams(normalizedPhone);
          const usersResult = await db.query(
            `SELECT id, email, phone_number, phone_lookup_hash, is_phone_verified
             FROM users
             WHERE (lower(email) = $1 OR phone_lookup_hash = $2)
               AND deleted = FALSE`,
            [normalizedEmail, phoneSearchParams[0]]
          );
          const users = usersResult.rows;

          if (users && users.length > 0) {
            const sameEmailUser = users.find(u => String(u.email || '').trim().toLowerCase() === normalizedEmail);
            const samePhoneUser = users.find(u => u.phone_lookup_hash === phoneSearchParams[0]);

            if (is_signup === true || is_signup === 'true') {
              // If signing up, these must NOT exist
              if (sameEmailUser || samePhoneUser) {
                return { error: 'An account with this email or phone number already exists. Please log in.', status: 409 };
              }
            } else {
              // If logging in, they MUST match if they both exist on an account
              if (sameEmailUser && sameEmailUser.phone_number &&
                  (!sameEmailUser.is_phone_verified || sameEmailUser.phone_lookup_hash !== phoneSearchParams[0])) {
                return { error: 'This email is registered with a different phone number.', status: 409 };
              }

              if (samePhoneUser && samePhoneUser.email &&
                  String(samePhoneUser.email).trim().toLowerCase() !== normalizedEmail) {
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

        const purpose = recovery_only === true ? 'recovery' : 'signin';
        const { code, requestId } = await createChallenge(req, normalizedEmail, 'email', purpose);
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
          await discardChallenge(req, normalizedEmail, 'email', requestId, purpose);
          return {
            error: 'Unable to send a sign-in code right now. Please try again later.',
            status: 503,
            capacityBusy: emailResult?.code === BUSY_CODE,
          };
        }

        return { ok: true, status: 200, requestId };
      });

      if (result.capacityBusy) return respondOtpCapacityUnavailable(res);
      if (result.error) return res.status(result.status || 500).json({ error: result.error });
      return res.json(requestSuccess(req,result));
    } catch (err) {
      logAuthError('request-email-otp failed', err);
      if (err instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
      if (isActiveOtpError(err)) return respondActiveOtp(res);
      if (isRateLimitStorageError(err)) return respondAbuseStoreUnavailable(res);
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
      const { email, phone_number, code, device_id, device_info, recovery_only } = req.body;
      const normalizedEmail = email.trim().toLowerCase();
      // Email-only recovery is intentionally supported by the mobile app. Do
      // not treat a missing phone as a phone mismatch, and do not overwrite a
      // previously verified phone with NULL during recovery.
      const normalizedPhone = typeof phone_number === 'string' && phone_number.trim()
        ? normalizePhone(phone_number)
        : null;
      const hasPhone = Boolean(normalizedPhone);
      // Only encrypt phone number if one was actually supplied and we need to
      // link/update it. Calling the helper with undefined is harmless when
      // encryption is disabled, but makes the recovery branch ambiguous.
      const encryptedPhone = hasPhone ? encryptPhoneNumber(normalizedPhone) : null;

      const verificationResult = await executeOtpVerifyWithTiming(async () => {
        // CRITICAL FIX: verifyOtp() resolves to an object — {ok: true} or
        // {ok: false, reason: ...} — never null/undefined. `!isValid` on a
        // non-null object is always false in JS regardless of `.ok`, so
        // this previously accepted ANY code for ANY email that had ever
        // requested an OTP: a wrong/expired/never-issued code still hit the
        // `return { success: true, ... }` line below and went on to mint
        // real access+refresh tokens. Must check `.ok`, same as the phone
        // path (verify-otp route, above) already correctly does.
        const isValid = await verifyChallenge(
          req, normalizedEmail,
          code,
          'email',
          recovery_only === true ? 'recovery' : 'signin',
        );
        if (!isValid.ok) {
          await incrementFailedVerify(normalizedEmail, recovery_only === true ? 'recovery' : 'signin');
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

      // Resolve the verified email first. A phone supplied in this request is
      // only a claim; it cannot be added to or used to select an account.
      const foundByEmail = await db.query(
        `SELECT id, email, phone_number, phone_lookup_hash, is_phone_verified,
                is_email_verified, name, role, COALESCE(token_version, 1) as token_version
         FROM users WHERE lower(email) = $1 AND deleted = FALSE`,
        [normalizedEmail]
      );

      const foundByPhone = hasPhone
        ? await db.query(
            `SELECT id, email, phone_number, phone_lookup_hash, is_phone_verified,
                    is_email_verified, name, role, COALESCE(token_version, 1) as token_version
             FROM users WHERE phone_lookup_hash = $1 AND deleted = FALSE`,
            preparePhoneSearchParams(normalizedPhone)
          )
        : { rows: [] };

      if (recovery_only === true && foundByEmail.rows.length === 0) {
        // Recovery may only authenticate an existing account by the exact
        // verified email. It must never attach an email to a phone-only
        // account or create a new account from a valid OTP.
        await logSuspiciousOtpAttempt(
          normalizedEmail,
          clientIp,
          req.headers['user-agent'],
          'recovery_account_not_found'
        );
        await otpVerifyDelay();
        return res.status(400).json({ error: 'Invalid or expired code' });
      }

      if (foundByEmail.rows.length > 0) {
        user = foundByEmail.rows[0];
        if (foundByPhone.rows.some(phoneUser => phoneUser.id !== user.id)) {
          return res.status(409).json({ error: 'This email and phone number belong to different accounts.' });
        }
        if (!user.is_email_verified && user.is_phone_verified) {
          return res.status(409).json({
            error: 'Verify the existing sign-in method before linking this email to the account.',
            code: 'existing_factor_required',
          });
        }
        if (hasPhone && (!user.is_phone_verified || user.phone_lookup_hash !== phoneLookupHash(normalizedPhone))) {
          return res.status(409).json({
            error: 'The supplied phone is not a verified contact on this account. Verify the existing sign-in method before linking it.',
            code: 'existing_factor_required',
          });
        }
        await db.query('UPDATE users SET is_email_verified = TRUE WHERE id = $1', [user.id]);
      } else {
        // A supplied phone is only an unverified claim. If it already belongs
        // to any account, that account must be entered through its existing
        // factor and the contact-recovery flow. New email users remain
        // email-only until another factor is verified separately.
        if (recovery_only === true || foundByPhone.rows.length > 0) {
          return res.status(400).json({ error: 'Invalid or expired code' });
        }
        if (newAccountsPaused()) return respondPaused(res);
        const newUserResult = await db.query(
          `INSERT INTO users (email, language, timezone, is_email_verified)
           VALUES ($1, $2, $3, TRUE)
           RETURNING id, email, name, role, COALESCE(token_version, 1) as token_version`,
          [normalizedEmail, device_info?.language_code || null, device_info?.timezone || null]
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

      const accessToken = signAccessToken(user, {
        highAssurance: true, deviceId: devId,
        verifiedChannel: 'email',
        recoveryChannel: recovery_only === true ? 'email' : undefined,
      });
      const refreshToken = recovery_only === true ? null : await issueRefreshToken({
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
      logAuthError('verify-email-otp failed', err);
      if (err instanceof OtpCapacityError) return respondOtpCapacityUnavailable(res);
      if (isRateLimitStorageError(err)) return respondAbuseStoreUnavailable(res);
      await otpVerifyDelay();
      if (err.code === '23505' && err.constraint === 'uq_users_active_email_lower') {
        return res.status(409).json({ error: 'An account with this email already exists. Please sign in instead.' });
      }
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

      const devId = sanitizeDeviceId(device_id);
      // Linking is explicit and requires current, recent existing-account
      // proof. An email match by itself never grants access to that UUID.
      let linkingToken = null;
      if (req.body.link_account === true) {
        const header = req.headers.authorization || '';
        if (!/^Bearer [^ ]+$/.test(header)) {
          return res.status(401).json({ error: 'Sign in before linking Google.', code: 'GOOGLE_LINK_AUTH_REQUIRED' });
        }
        linkingToken = header.slice(7);
      }
      const { user, isNewAccount } = await resolveGoogleAccount({
        pool: await db.pool,
        googleUser,
        deviceInfo: device_info,
        linkingToken,
        verifySession: verifyCurrentSession,
      });

      const existingDevice = await db.query(
        `SELECT id FROM user_devices WHERE user_id = $1 AND device_identifier = $2`,
        [user.id, devId]
      );
      const isNewDevice = existingDevice.rows.length === 0;

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
          is_new_device: isNewDevice, is_new_account: isNewAccount,
          platform: device_info?.platform || 'unknown',
          risk_score: riskScore.score, risk_reasons: riskScore.reasons,
        },
      });

      await checkAnomalies(user.id, 'google_login', clientIp);

      const accessToken = signAccessToken(user, {
        highAssurance: true, deviceId: devId, verifiedChannel: 'google',
      });
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
        is_new_account: isNewAccount,
        active_devices_count: parseInt(deviceCountResult.rows[0].count, 10),
      });
    } catch (err) {
      if (err.code === REGISTRATION_PAUSED) return respondPaused(res);
      if (err instanceof GoogleIdentityError) {
        return res.status(err.status).json({ error: err.message, code: err.code });
      }
      if (err.code === 'GOOGLE_TOKEN_INVALID') {
        return res.status(400).json({ error: 'Invalid Google token', code: err.code });
      }
      if (err.code === 'GOOGLE_AUTH_UNAVAILABLE') {
        return res.status(503).json({ error: 'Google authentication is temporarily unavailable.', code: err.code });
      }
      logAuthError('google login failed', err);
      if (err.code === '23505' && err.constraint === 'uq_users_active_email_lower') {
        return res.status(409).json({ error: 'An account with this email already exists. Please sign in instead.' });
      }
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

      const requestId = req.body.refresh_request_id;
      const verification = await verifyRefreshToken(refresh_token, { requestId });
      if (!verification || verification.reuseDetected) {

        return res.status(401).json({ error: 'Invalid refresh token' });
      }

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

      const newAccess = signAccessToken(user, { highAssurance: hasRecentOtp, deviceId });

      const newRefresh = await rotateRefreshToken({
        tokenRow,
        userAgent: req.headers['user-agent'],
        ip: clientIp,
        requestId,
      });

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
          logAuthError('refresh device timestamp update failed', deviceErr);
          // Don't fail the refresh if device update fails
        }
      }

      return res.json({ access_token: newAccess, refresh_token: newRefresh });
    } catch (err) {
      if (err.statusCode === 401) {
        return res.status(401).json({ error: 'Invalid refresh token' });
      }
      logAuthError('refresh failed', err);
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
        console.error('[auth] logout subject mismatch');
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
        logAuthError('logout device update failed', deviceErr);
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
      logAuthError('logout failed', err);
      return res.status(500).json({ error: 'Internal server error' });
    }
  }
);

// POST /auth/signup
// Signup endpoint: Create new user with name, phone, and location
router.post(
  '/signup',
  auth,
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
      const { name, phone_number, device_id, device_info } = req.body;

      // Normalize phone number
      const normalizedPhone = phone_number ? normalizePhone(phone_number) : null;

      // Validate phone number format
      if (normalizedPhone && !isValidPhoneNumber(normalizedPhone)) {
        return res.status(400).json({
          success: false,
          message: 'Invalid phone number format. Please use E.164 format (e.g., +919876543210)',
        });
      }

      // Signup completes a profile created by a verified authentication
      // factor. It must never create an identity from request-body contacts.
      const existingUser = await db.query(
        `SELECT id, phone_number, phone_lookup_hash, is_phone_verified,
                is_email_verified, country_code, name, role, NULL::text as user_type,
                COALESCE(token_version, 1) as token_version
         FROM users
         WHERE id = $1 AND deleted = FALSE`,
        [req.user.id]
      ).catch(async (err) => {
        if (err.code === '42703' && err.message.includes('token_version')) {
          return await db.query(
            `SELECT id, phone_number, phone_lookup_hash, is_phone_verified,
                    is_email_verified, country_code, name, role, NULL::text as user_type,
                    1 as token_version
             FROM users WHERE id = $1 AND deleted = FALSE`,
            [req.user.id]
          );
        }
        throw err;
      });

      if (existingUser.rows.length === 0) {
        return res.status(404).json({ success: false, message: 'Verified account not found.' });
      }
      const existing = existingUser.rows[0];
      if (!existing.is_phone_verified && !existing.is_email_verified) {
        return res.status(403).json({ success: false, message: 'Complete a verified sign-in before creating a profile.' });
      }
      if (normalizedPhone && (!existing.is_phone_verified ||
          existing.phone_lookup_hash !== phoneLookupHash(normalizedPhone))) {
        return res.status(409).json({
          success: false,
          code: 'existing_factor_required',
          message: 'The supplied phone is not a verified contact on this account.',
        });
      }
      const profilePhone = normalizedPhone || (existing.is_phone_verified && existing.phone_number
        ? decryptPhoneNumber(existing.phone_number)
        : null);

      if (existingUser.rows.length > 0) {
        // Check if user was just created by verify-otp (has no name) - allow update
        if (!existing.name || existing.name.trim() === '') {
          // User exists but has no name (was just created by verify-otp), update it with signup data
          const countryCode = profilePhone?.startsWith('+')
            ? profilePhone.match(/^\+(\d{1,3})/)?.[0] || '+91'
            : existing.country_code || '+91';

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

          // Legacy signup accepted address fields, but the auth schema no
          // longer has a locations table. Keep accepting the old request body
          // for client compatibility; address capture is deprecated and is
          // not persisted here. Retain the response field as null.
          const locationId = null;

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

      // An authenticated subject must resolve to the profile row above;
      // signup is never an identity-creation endpoint.
      return res.status(404).json({ success: false, message: 'Verified account not found.' });

    } catch (err) {
      logAuthError('signup failed', err);

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
          message: 'Unable to complete signup. Please try again.',
        });
      }

      return res.status(500).json({
        success: false,
        message: 'Internal server error',
      });
    }
  }
);

// POST /auth/validate-token
// Endpoint for other services (like BuySellService) to validate JWT tokens
// This allows centralized token validation
router.post('/validate-token', async (req, res) => {
  try {
    const { token } = req.body;
    if (!token) {
      return res.status(400).json({ valid: false, error: 'Token is required' });
    }

    let payload;
    try {
      payload = verifyAccessToken(token);
    } catch (_) {
      return res.json({ valid: false, error: 'Invalid or expired token' });
    }

    try {
      const session = await verifyCurrentSession(token);
      if (payload.is_guest === true || !session.valid || !session.session?.active ||
          session.session?.revoked || session.subject !== payload.sub) {
        return res.json({ valid: false, error: 'Invalid or expired token' });
      }
    } catch (error) {
      if (error?.message === 'invalid_token') {
        return res.json({ valid: false, error: 'Invalid or expired token' });
      }
      logAuthError('validate-token session verification unavailable', error);
      return res.status(503).json({
        valid: false,
        error: 'Session verification is temporarily unavailable',
      });
    }

    return res.json({
      valid: true,
      payload: {
        sub: payload.sub,
        role: payload.role,
        user_type: payload.user_type,
        token_version: payload.token_version || 1,
        high_assurance: payload.high_assurance || false,
        is_guest: payload.is_guest || false,
      },
    });
  } catch (err) {
    logAuthError('validate-token failed', err);
    return res.status(503).json({ valid: false, error: 'Session verification is temporarily unavailable' });
  }
});

module.exports = router;
