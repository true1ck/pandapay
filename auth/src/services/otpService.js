const { safeErrorCode } = require('../utils/safeErrorCode');
// src/services/otpService.js
const bcrypt = require('bcrypt');
const db = require('../db');
const config = require('../config');
const {
  markActiveOtp,
  clearActiveOtp,
  ActiveOtpError,
} = require('../middleware/rateLimitMiddleware');
const { TEST_OTP_CODE, isTestOtpIdentifier } = require('../utils/testOtp');
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
const { encryptPhoneNumber } = require('../utils/fieldEncryption');
const { phoneLookupHash } = require('../utils/encryptedPhoneSearch');
const { randomInt, randomUUID } = require('node:crypto');

// === SECURITY: TEST OTP BYPASS — DEV/TEST ONLY ===
// These fixed identifiers + code "1234" exist solely so local development
// and QA don't need a working SMS/email provider to sign in. This must
// never be reachable when config.isProduction is true — it was previously
// active unconditionally in every environment, which would have let anyone
// who knew these identifiers log in without ever receiving a real OTP.
//
// Gating on `!config.isProduction` alone is one missing/misconfigured
// NODE_ENV away from silently reopening exactly that hole in a real
// deployment — NODE_ENV defaults to non-production if it's ever unset. A
// second, explicit opt-in that itself defaults OFF means a deploy has to
// get TWO things wrong (not set NODE_ENV=production AND explicitly set
// ALLOW_TEST_OTP=true) before this bypass can be live, instead of one.
// === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
// OTP validity changed from 10 minutes to 2 minutes (120 seconds)
const OTP_TTL_SECONDS = parseInt(process.env.OTP_TTL_SECONDS || '120', 10); // 2 minutes
const OTP_EXPIRY_MS = OTP_TTL_SECONDS * 1000;
const MAX_OTP_ATTEMPTS = Number(process.env.OTP_VERIFY_MAX_ATTEMPTS || process.env.OTP_MAX_ATTEMPTS || 5);
const OTP_TYPES = new Set(['phone', 'email']);
const OTP_PURPOSES = new Set(['signin', 'recovery', 'replacement']);

function validateOtpScope(type, purpose) {
  if (!OTP_TYPES.has(type)) throw new TypeError('OTP type must be phone or email');
  if (!OTP_PURPOSES.has(purpose)) throw new TypeError('OTP purpose is invalid');
}

// Rows written before purpose binding have NULL purpose. They remain usable
// only for ordinary sign-in and can never prove recovery or replacement.
function purposePredicate(purpose, parameterIndex) {
  return purpose === 'signin'
    ? `(purpose = $${parameterIndex} OR purpose IS NULL)`
    : `purpose = $${parameterIndex}`;
}

// === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
// Pre-computed dummy hash for constant-time comparison when OTP not found
// This ensures bcrypt.compare() always executes with similar timing
// Generated once at module load to avoid performance impact
let dummyOtpHash = null;
async function getDummyOtpHash() {
  if (!dummyOtpHash) {
    // Generate a dummy hash that will never match any real OTP
    const dummyCode = 'DUMMY_OTP_' + Math.random().toString(36).substring(2, 15) + Date.now();
    dummyOtpHash = await bcrypt.hash(dummyCode, 10);
  }
  return dummyOtpHash;
}

/**
 * Extract country code from phone number (e.g., +91 from +919876543210)
 * @param {string} phoneNumber - Phone number in E.164 format
 * @returns {string} Country code (default: '+91')
 */
function extractCountryCode(phoneNumber) {
  if (!phoneNumber || !phoneNumber.startsWith('+')) {
    return '+91'; // Default to India
  }
  // Extract country code (typically 1-3 digits after +)
  const match = phoneNumber.match(/^\+(\d{1,3})/);
  return match ? `+${match[1]}` : '+91';
}

/**
 * Generate a random 4-digit OTP code
 */
function generateOtpCode() {
  return randomInt(1000, 10000).toString();
}

/**
 * Create and store an OTP for an identifier (phone or email)
 * @param {string} identifier - The phone number or email to send OTP to
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{code: string}>} - The generated OTP code
 */
async function createOtp(identifier, type = 'phone', purpose = 'signin') {
  validateOtpScope(type, purpose);
  if (typeof identifier !== 'string' || !identifier.trim()) throw new TypeError('OTP identifier is required');
  // === SECURITY: TEST OTP BYPASS — DEV/TEST ONLY, see constants above ===
  const normalizedIdentifier = identifier.trim().toLowerCase();
  const isTestIdentifier = isTestOtpIdentifier(normalizedIdentifier);

  const code = isTestIdentifier ? TEST_OTP_CODE : generateOtpCode();

  const requestId = randomUUID();
  const expiresAt = new Date(Date.now() + OTP_EXPIRY_MS);
  const otpHash = await bcrypt.hash(code, 10);

  let encryptedPhone = null;
  let phoneHash = null;
  let email = null;
  let countryCode = '+91';

  if (type === 'phone') {
    encryptedPhone = encryptPhoneNumber(identifier);
    phoneHash = phoneLookupHash(identifier);
    countryCode = extractCountryCode(identifier);
  } else if (type === 'email') {
    email = normalizedIdentifier;
  }

  // Atomically reserve this identifier/purpose before touching OTP rows. A
  // concurrent request sees the live claim and cannot send a second code.
  const claimed = await markActiveOtp(identifier, OTP_TTL_SECONDS, requestId, purpose);
  if (claimed === false) {
    throw typeof ActiveOtpError === 'function'
      ? new ActiveOtpError()
      : Object.assign(new Error('An OTP is already active'), { code: 'OTP_ACTIVE' });
  }

  try {
    // Mark existing OTPs as deleted using the canonical keyed phone digest.
    if (type === 'phone') {
      await db.query(
        `UPDATE otp_requests
         SET deleted = TRUE
         WHERE phone_lookup_hash = $1 AND type = 'phone' AND deleted = FALSE
           AND ${purposePredicate(purpose, 2)}`,
        [phoneHash, purpose]
      );
    } else {
      await db.query(
        `UPDATE otp_requests
         SET deleted = TRUE
         WHERE email = $1 AND type = 'email' AND deleted = FALSE
           AND ${purposePredicate(purpose, 2)}`,
        [email, purpose]
      );
    }

    // Append the generated UUID as $9 so historical parameter positions stay
    // stable for existing SQL instrumentation and integration fixtures.
    await db.query(
      `INSERT INTO otp_requests (phone_number, phone_lookup_hash, email, type, country_code, otp_hash, expires_at, attempt_count, deleted, purpose, id)
       VALUES ($1, $2, $3, $4, $5, $6, $7, 0, FALSE, $8, $9)
       RETURNING id`,
      [encryptedPhone, phoneHash, email, type, countryCode, otpHash, expiresAt, purpose, requestId]
    );
  } catch (error) {
    try {
      await clearActiveOtp(identifier, requestId, purpose);
    } catch (cleanupError) {
      console.error('Failed to clear OTP marker after database write failure', safeErrorCode(cleanupError));
    }
    throw error;
  }

  return { code, requestId };
}

/**
 * Verify an OTP code for an identifier
 * @param {string} identifier - The phone number or email
 * @param {string} code - The OTP code to verify
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{ok: boolean, reason?: string}>} - Whether the OTP is valid
 */
async function verifyOtp(identifier, code, type = 'phone', purpose = 'signin') {
  validateOtpScope(type, purpose);
  if (typeof identifier !== 'string' || !identifier.trim()) throw new TypeError('OTP identifier is required');
  const codeStr = String(code).trim();
  const normalizedIdentifier = identifier.trim().toLowerCase();

  let result;
  
  if (type === 'phone') {
    const lookupHash = phoneLookupHash(identifier);
    result = await db.query(
      `SELECT id, otp_hash, expires_at, attempt_count, consumed_at, deleted, created_at, type
       FROM otp_requests
       WHERE phone_lookup_hash = $1
         AND deleted = FALSE
         AND consumed_at IS NULL
         AND type = 'phone'
         AND ${purposePredicate(purpose, 2)}
       ORDER BY created_at DESC
       LIMIT 1`,
      [lookupHash, purpose]
    );
  } else if (type === 'email') {
    result = await db.query(
      `SELECT id, otp_hash, expires_at, attempt_count, consumed_at, deleted, created_at, type
       FROM otp_requests
       WHERE email = $1
         AND deleted = FALSE
         AND consumed_at IS NULL
         AND type = 'email'
         AND ${purposePredicate(purpose, 2)}
       ORDER BY created_at DESC
       LIMIT 1`,
      [normalizedIdentifier, purpose]
    );
  }

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Always perform bcrypt.compare() to maintain constant execution time
  // Use a dummy hash if OTP not found to prevent timing leaks
  // otpRecord is already set from the loop above (or null if not found)
  let isNotFound = false;
  let isExpired = false;
  let isMaxAttempts = false;
  let otpRecord = result.rows[0] || null;
  let hashToCompare;
  
  if (!otpRecord) {
    // OTP not found - use dummy hash to maintain constant time
    // This ensures bcrypt.compare() always executes with similar timing
    isNotFound = true;
    hashToCompare = await getDummyOtpHash();
    otpRecord = {
      id: null,
      otp_hash: hashToCompare, // Dummy hash for constant-time comparison
      expires_at: new Date(Date.now() + 1000), // Future date
      attempt_count: 0,
    };
  } else {
    hashToCompare = otpRecord.otp_hash;
    // Check if expired (but don't return early - continue to bcrypt.compare)
    isExpired = new Date() > new Date(otpRecord.expires_at);
    
    // Check if max attempts exceeded (but don't return early - continue to bcrypt.compare)
    isMaxAttempts = otpRecord.attempt_count >= MAX_OTP_ATTEMPTS;
    
  }

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Always perform bcrypt.compare() regardless of expiration/attempts status
  // This ensures all code paths take similar time
  // Even if we know the OTP is expired or max attempts exceeded, we still compare
  // to prevent attackers from distinguishing between different failure modes
  const matches = await bcrypt.compare(codeStr, hashToCompare);

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Determine the actual result after constant-time comparison
  // Priority: not_found > expired > max_attempts > invalid > valid
  if (isNotFound) {
    // OTP not found - return generic error
    return { ok: false, reason: 'not_found' };
  }

  if (isExpired) {
    // Expired OTPs are consumed only if another request has not already won.
    await db.query(
      `UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1 AND consumed_at IS NULL AND deleted = FALSE
         AND ${purposePredicate(purpose, 2)}`,
      [otpRecord.id, purpose]
    );
    return { ok: false, reason: 'expired' };
  }

  if (isMaxAttempts) {
    // Max attempts exceeded - mark as consumed (but we already did bcrypt.compare for constant time)
    await db.query(
      `UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1 AND consumed_at IS NULL AND deleted = FALSE
         AND ${purposePredicate(purpose, 2)}`,
      [otpRecord.id, purpose]
    );
    return { ok: false, reason: 'max_attempts' };
  }

  // Check if code matches (only if not expired and not max attempts)
  if (!matches) {
    // === ADDED FOR OTP ATTEMPT LIMIT ===
    // Increment attempt count
    if (otpRecord.id) {
      const updateResult = await db.query(
        `UPDATE otp_requests SET attempt_count = attempt_count + 1
         WHERE id = $1 AND consumed_at IS NULL AND deleted = FALSE
           AND ${purposePredicate(purpose, 2)} RETURNING attempt_count`,
        [otpRecord.id, purpose]
      );
      const newAttemptCount = updateResult.rows[0]?.attempt_count || 0;
      
      // If max attempts reached, mark as consumed
      if (newAttemptCount >= MAX_OTP_ATTEMPTS) {
        await db.query(
          `UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1 AND consumed_at IS NULL AND deleted = FALSE
             AND ${purposePredicate(purpose, 2)}`,
          [otpRecord.id, purpose]
        );
      }
    }
    return { ok: false, reason: 'invalid' };
  }
  
  // Compare happens before an atomic conditional consume. Two concurrent
  // requests can both match bcrypt, but exactly one can observe a returned
  // row from this UPDATE and proceed to create a session.
  const consumed = await db.query(
    `UPDATE otp_requests SET consumed_at = NOW()
     WHERE id = $1 AND consumed_at IS NULL AND deleted = FALSE
       AND expires_at > NOW() AND attempt_count < $2
       AND ${purposePredicate(purpose, 3)}
     RETURNING id`,
    [otpRecord.id, MAX_OTP_ATTEMPTS, purpose],
  );
  if (consumed.rows.length !== 1) return { ok: false, reason: 'consumed_or_expired' };
  // Clear only this code's resend marker. The helper compares the stored
  // request id before deleting, so a late verification cannot clear a newer
  // OTP's cooldown for the same identifier.
  try {
    await clearActiveOtp(identifier, otpRecord.id, purpose);
  } catch (error) {
    // Authentication already consumed the OTP atomically. Cleanup is
    // best-effort; an abuse-store outage must not turn a successful sign-in into a
    // client-visible failure. The cooldown marker still expires by TTL.
    console.error('Failed to clear OTP resend marker', safeErrorCode(error));
  }
  return { ok: true };
}

/**
 * Clean up expired OTPs (can be called periodically)
 * Marks expired OTPs as consumed instead of deleting (matches final_db.sql schema)
 */
async function cleanupExpiredOtps() {
  await db.query(
    `UPDATE otp_requests 
     SET consumed_at = NOW() 
     WHERE expires_at < NOW() 
       AND consumed_at IS NULL 
       AND deleted = FALSE`
  );
}

/** Discard an OTP that could not be delivered so the user can retry at once. */
async function discardUndeliveredOtp(identifier, type, requestId, purpose = 'signin') {
  validateOtpScope(type, purpose);
  if (typeof identifier !== 'string' || !identifier.trim()) throw new TypeError('OTP identifier is required');
  if (!requestId) throw new Error('OTP request id is required for delivery cleanup');
  const normalizedIdentifier = identifier.trim().toLowerCase();
  if (type === 'email') {
    await db.query(
      `UPDATE otp_requests
       SET deleted = TRUE
       WHERE id = $1 AND email = $2 AND type = 'email' AND deleted = FALSE AND consumed_at IS NULL
         AND ${purposePredicate(purpose, 3)}`,
      [requestId, normalizedIdentifier, purpose]
    );
  } else {
    const lookupHash = phoneLookupHash(identifier);
    await db.query(
      `UPDATE otp_requests
       SET deleted = TRUE
       WHERE id = $1 AND phone_lookup_hash = $2 AND type = 'phone'
         AND deleted = FALSE AND consumed_at IS NULL
         AND ${purposePredicate(purpose, 3)}`,
      [requestId, lookupHash, purpose]
    );
  }
  await clearActiveOtp(identifier, requestId, purpose);
}

module.exports = {
  createOtp,
  verifyOtp,
  cleanupExpiredOtps,
  discardUndeliveredOtp,
};
