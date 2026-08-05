// src/services/otpService.js
const bcrypt = require('bcrypt');
const db = require('../db');
const { markActiveOtp } = require('../middleware/rateLimitMiddleware');
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
const { encryptPhoneNumber } = require('../utils/fieldEncryption');

// === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
// OTP validity changed from 10 minutes to 2 minutes (120 seconds)
const OTP_TTL_SECONDS = parseInt(process.env.OTP_TTL_SECONDS || '120', 10); // 2 minutes
const OTP_EXPIRY_MS = OTP_TTL_SECONDS * 1000;
const MAX_OTP_ATTEMPTS = Number(process.env.OTP_VERIFY_MAX_ATTEMPTS || process.env.OTP_MAX_ATTEMPTS || 5);

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
  return Math.floor(1000 + Math.random() * 9000).toString();
}

/**
 * Create and store an OTP for an identifier (phone or email)
 * @param {string} identifier - The phone number or email to send OTP to
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{code: string}>} - The generated OTP code
 */
async function createOtp(identifier, type = 'phone') {
  // === DEBUGGING: TEST OTP BYPASS ===
  const testIdentifiers = ["1234567890", "+911234567890", "test@example.com"];
  const testOtpCode = "1234";
  const normalizedIdentifier = identifier.trim().toLowerCase();
  
  const code = testIdentifiers.includes(normalizedIdentifier) ? testOtpCode : generateOtpCode();
  
  if (testIdentifiers.includes(normalizedIdentifier)) {
    console.log(`[OTP Service] 🔧 DEBUG MODE: Test OTP generated for ${type}:`, normalizedIdentifier, '- Code:', testOtpCode);
  }
  
  const expiresAt = new Date(Date.now() + OTP_EXPIRY_MS);
  const otpHash = await bcrypt.hash(code, 10);

  let encryptedPhone = null;
  let email = null;
  let countryCode = '+91';

  if (type === 'phone') {
    encryptedPhone = encryptPhoneNumber(identifier);
    countryCode = extractCountryCode(identifier);
  } else if (type === 'email') {
    email = normalizedIdentifier;
  }

  // Mark existing OTPs as deleted for this identifier
  if (type === 'phone') {
    await db.query(
      `UPDATE otp_requests 
       SET deleted = TRUE 
       WHERE (phone_number = $1 OR phone_number = $2) AND deleted = FALSE`,
      [encryptedPhone, identifier]
    );
  } else if (type === 'email') {
    await db.query(
      `UPDATE otp_requests 
       SET deleted = TRUE 
       WHERE email = $1 AND deleted = FALSE`,
      [email]
    );
  }

  // Insert new OTP with type and identifier
  await db.query(
    `INSERT INTO otp_requests (phone_number, email, type, country_code, otp_hash, expires_at, attempt_count, deleted)
     VALUES ($1, $2, $3, $4, $5, $6, 0, FALSE)`,
    [encryptedPhone, email, type, countryCode, otpHash, expiresAt]
  );

  // Mark OTP as active in Redis/memory store
  try {
    await markActiveOtp(identifier, OTP_TTL_SECONDS);
  } catch (err) {
    console.error('Failed to mark active OTP in rate limiter:', err);
  }

  return { code };
}

/**
 * Verify an OTP code for an identifier
 * @param {string} identifier - The phone number or email
 * @param {string} code - The OTP code to verify
 * @param {string} type - 'phone' or 'email'
 * @returns {Promise<{ok: boolean, reason?: string}>} - Whether the OTP is valid
 */
async function verifyOtp(identifier, code, type = 'phone') {
  const testIdentifiers = ["1234567890", "+911234567890", "test@example.com", "newuser4@example.com"];
  const testOtpCode = "1234";
  
  const codeStr = String(code).trim();
  const normalizedIdentifier = identifier.trim().toLowerCase();
  
  if (testIdentifiers.includes(normalizedIdentifier) && codeStr === testOtpCode) {
    console.log(`[OTP Service] 🔧 DEBUG MODE: Test OTP bypass activated for ${type}:`, normalizedIdentifier);
    return { ok: true };
  }
  
  console.log(`[OTP Service] Verifying OTP for ${type}:`, type === 'phone' ? identifier.replace(/\d(?=\d{4})/g, '*') : identifier, 'Code:', code);
  
  let result;
  
  if (type === 'phone') {
    const encryptedPhone = encryptPhoneNumber(identifier);
    result = await db.query(
      `SELECT id, otp_hash, expires_at, attempt_count, phone_number, email, consumed_at, deleted, created_at, type
       FROM otp_requests
       WHERE (phone_number = $1 OR phone_number = $2)
         AND deleted = FALSE
         AND consumed_at IS NULL
       ORDER BY created_at DESC
       LIMIT 5`,
      [encryptedPhone, identifier]
    );
  } else if (type === 'email') {
    result = await db.query(
      `SELECT id, otp_hash, expires_at, attempt_count, phone_number, email, consumed_at, deleted, created_at, type
       FROM otp_requests
       WHERE email = $1
         AND deleted = FALSE
         AND consumed_at IS NULL
       ORDER BY created_at DESC
       LIMIT 5`,
      [normalizedIdentifier]
    );
  }
  
  let otpRecord = null;
  if (result.rows.length > 0) {
    if (type === 'email') {
      otpRecord = result.rows[0];
    } else {
      // phone logic
      for (const row of result.rows) {
        if (row.phone_number === identifier) {
          otpRecord = row;
          break;
        }
        try {
          const { decryptPhoneNumber } = require('../utils/fieldEncryption');
          const decrypted = decryptPhoneNumber(row.phone_number);
          if (decrypted === identifier) {
            otpRecord = row;
            break;
          }
        } catch (err) {
          continue;
        }
      }
    }
  }
  
  if (!otpRecord && result.rows.length > 0) {
    result.rows = [];
  } else if (otpRecord) {
    result.rows = [otpRecord];
  }
  
  if (result.rows.length > 0) {
    const record = result.rows[0];
    console.log('[OTP Service] OTP record - attempt_count:', record.attempt_count, 'expires_at:', record.expires_at, 'consumed_at:', record.consumed_at);
  } else {
    // For logging, check if it was consumed
    let queryArgs = type === 'phone' ? [encryptPhoneNumber(identifier), identifier] : [normalizedIdentifier];
    let queryStr = type === 'phone' ? `WHERE (phone_number = $1 OR phone_number = $2)` : `WHERE email = $1`;
    
    const allRecords = await db.query(
      `SELECT id, attempt_count, consumed_at, deleted, created_at, phone_number, email
       FROM otp_requests
       ${queryStr}
       ORDER BY created_at DESC
       LIMIT 3`,
      queryArgs
    );
    if (allRecords.rows.length > 0) {
      allRecords.rows.forEach((r, i) => {
        const storedId = type === 'phone' ? r.phone_number : r.email;
        console.log(`[OTP Service] Record ${i + 1}: id=${storedId}, consumed_at=${r.consumed_at}, deleted=${r.deleted}, attempts=${r.attempt_count}`);
      });
    }
  }

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Always perform bcrypt.compare() to maintain constant execution time
  // Use a dummy hash if OTP not found to prevent timing leaks
  // otpRecord is already set from the loop above (or null if not found)
  let isNotFound = false;
  let isExpired = false;
  let isMaxAttempts = false;
  let hashToCompare = null;
  
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
    
    console.log('[OTP Service] OTP record details:', {
      id: otpRecord.id,
      attempt_count: otpRecord.attempt_count,
      isExpired: isExpired,
      isMaxAttempts: isMaxAttempts,
      expires_at: otpRecord.expires_at,
      hash_length: hashToCompare?.length
    });
  }

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Always perform bcrypt.compare() regardless of expiration/attempts status
  // This ensures all code paths take similar time
  // Even if we know the OTP is expired or max attempts exceeded, we still compare
  // to prevent attackers from distinguishing between different failure modes
  console.log('[OTP Service] Comparing code:', code, 'with hash (first 20 chars):', hashToCompare?.substring(0, 20) + '...');
  const matches = await bcrypt.compare(code, hashToCompare);
  console.log('[OTP Service] bcrypt.compare result:', matches);

  // === SECURITY HARDENING: TIMING ATTACK PROTECTION ===
  // Determine the actual result after constant-time comparison
  // Priority: not_found > expired > max_attempts > invalid > valid
  if (isNotFound) {
    // OTP not found - return generic error
    return { ok: false, reason: 'not_found' };
  }

  if (isExpired) {
    // OTP expired - mark as consumed (but we already did bcrypt.compare for constant time)
    await db.query(
      'UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1',
      [otpRecord.id]
    );
    return { ok: false, reason: 'expired' };
  }

  if (isMaxAttempts) {
    // Max attempts exceeded - mark as consumed (but we already did bcrypt.compare for constant time)
    await db.query(
      'UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1',
      [otpRecord.id]
    );
    return { ok: false, reason: 'max_attempts' };
  }

  // Check if code matches (only if not expired and not max attempts)
  if (!matches) {
    console.log('[OTP Service] ❌ Code mismatch! Code provided:', code, 'does not match stored hash');
    // === ADDED FOR OTP ATTEMPT LIMIT ===
    // Increment attempt count
    if (otpRecord.id) {
      const updateResult = await db.query(
        'UPDATE otp_requests SET attempt_count = attempt_count + 1 WHERE id = $1 RETURNING attempt_count',
        [otpRecord.id]
      );
      const newAttemptCount = updateResult.rows[0]?.attempt_count || 0;
      console.log('[OTP Service] Code mismatch. Incremented attempt_count to:', newAttemptCount);
      
      // If max attempts reached, mark as consumed
      if (newAttemptCount >= MAX_OTP_ATTEMPTS) {
        console.log('[OTP Service] Max attempts reached, marking as consumed');
        await db.query(
          'UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1',
          [otpRecord.id]
        );
      }
    }
    return { ok: false, reason: 'invalid' };
  }
  
  console.log('[OTP Service] ✅ Code matches! OTP verified successfully');

  // === ADDED FOR 2-MIN OTP VALIDITY & NO-RESEND ===
  // Mark OTP as consumed once verified to prevent reuse
  // Using consumed_at instead of deleting (matches final_db.sql schema)
  await db.query(
    'UPDATE otp_requests SET consumed_at = NOW() WHERE id = $1',
    [otpRecord.id]
  );

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

module.exports = {
  createOtp,
  verifyOtp,
  cleanupExpiredOtps,
};
