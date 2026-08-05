// src/utils/fieldEncryption.js
// === SECURITY HARDENING: FIELD-LEVEL ENCRYPTION ===
// Field-level encryption for PII (Personally Identifiable Information)
// Encrypts sensitive fields like phone numbers before storing in database

/**
 * Field-Level Encryption for PII
 * 
 * Uses AES-256-GCM for authenticated encryption
 * 
 * Configuration:
 * - ENCRYPTION_KEY: 32-byte (256-bit) key for AES-256, base64 encoded
 *   Generate with: node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
 * - ENCRYPTION_ENABLED: Set to 'true' to enable encryption (default: false for backward compatibility)
 * 
 * Security Notes:
 * - Encryption key should be stored in secrets manager (AWS Secrets Manager, HashiCorp Vault, etc.)
 * - Never commit encryption keys to version control
 * - Rotate keys periodically (requires re-encryption of existing data)
 * 
 * TODO: In production, load encryption key from secrets manager
 */

const crypto = require('crypto');

const ENCRYPTION_ENABLED = process.env.ENCRYPTION_ENABLED === 'true' || process.env.ENCRYPTION_ENABLED === '1';
const ENCRYPTION_KEY = process.env.ENCRYPTION_KEY;

// Algorithm: AES-256-GCM (Galois/Counter Mode) for authenticated encryption
const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 12; // 96 bits for GCM
const AUTH_TAG_LENGTH = 16; // 128 bits for authentication tag
const SALT_LENGTH = 32; // For key derivation (if needed in future)

let encryptionKey = null;

/**
 * Initialize encryption key from environment
 */
function initializeEncryptionKey() {
  if (!ENCRYPTION_ENABLED) {
    return null;
  }

  if (!ENCRYPTION_KEY) {
    console.warn('⚠️ ENCRYPTION_ENABLED is true but ENCRYPTION_KEY is not set. Encryption disabled.');
    return null;
  }

  try {
    // Decode base64 key
    const keyBuffer = Buffer.from(ENCRYPTION_KEY, 'base64');
    
    // Validate key length (AES-256 requires 32 bytes)
    if (keyBuffer.length !== 32) {
      throw new Error(`ENCRYPTION_KEY must be 32 bytes (256 bits). Got ${keyBuffer.length} bytes.`);
    }

    encryptionKey = keyBuffer;
    console.log('✅ Field-level encryption enabled');
    return encryptionKey;
  } catch (err) {
    console.error('❌ Failed to initialize encryption key:', err.message);
    console.warn('⚠️ Encryption disabled. Set valid ENCRYPTION_KEY to enable.');
    return null;
  }
}

// Initialize on module load
initializeEncryptionKey();

/**
 * Encrypt a plaintext value (e.g., phone number)
 * @param {string} plaintext - The value to encrypt
 * @returns {string} - Encrypted value in format: iv:authTag:encryptedData (all base64)
 */
function encryptField(plaintext) {
  // If encryption is disabled, return plaintext (for backward compatibility)
  if (!ENCRYPTION_ENABLED || !encryptionKey) {
    return plaintext;
  }

  if (!plaintext || typeof plaintext !== 'string') {
    return plaintext;
  }

  try {
    // Generate random IV for each encryption
    const iv = crypto.randomBytes(IV_LENGTH);
    
    // Create cipher
    const cipher = crypto.createCipheriv(ALGORITHM, encryptionKey, iv);
    
    // Encrypt
    let encrypted = cipher.update(plaintext, 'utf8', 'base64');
    encrypted += cipher.final('base64');
    
    // Get authentication tag
    const authTag = cipher.getAuthTag();
    
    // Return format: iv:authTag:encryptedData (all base64)
    return `${iv.toString('base64')}:${authTag.toString('base64')}:${encrypted}`;
  } catch (err) {
    console.error('Encryption error:', err);
    throw new Error('Failed to encrypt field');
  }
}

/**
 * Decrypt an encrypted value
 * @param {string} encryptedValue - The encrypted value in format: iv:authTag:encryptedData
 * @returns {string} - Decrypted plaintext
 */
function decryptField(encryptedValue) {
  // If encryption is disabled, return as-is (for backward compatibility)
  if (!ENCRYPTION_ENABLED || !encryptionKey) {
    return encryptedValue;
  }

  if (!encryptedValue || typeof encryptedValue !== 'string') {
    return encryptedValue;
  }

  // Check if value is encrypted (format: iv:authTag:encryptedData)
  // If not in this format, assume it's plaintext (for backward compatibility with existing data)
  const parts = encryptedValue.split(':');
  if (parts.length !== 3) {
    // Not encrypted, return as-is (backward compatibility)
    return encryptedValue;
  }

  try {
    const [ivBase64, authTagBase64, encrypted] = parts;
    
    // Decode base64 components
    const iv = Buffer.from(ivBase64, 'base64');
    const authTag = Buffer.from(authTagBase64, 'base64');
    
    // Create decipher
    const decipher = crypto.createDecipheriv(ALGORITHM, encryptionKey, iv);
    decipher.setAuthTag(authTag);
    
    // Decrypt
    let decrypted = decipher.update(encrypted, 'base64', 'utf8');
    decrypted += decipher.final('utf8');
    
    return decrypted;
  } catch (err) {
    console.error('Decryption error:', err);
    // If decryption fails, it might be plaintext (backward compatibility)
    // Return as-is but log warning
    console.warn('⚠️ Failed to decrypt field, assuming plaintext (backward compatibility)');
    return encryptedValue;
  }
}

/**
 * Encrypt phone number before storing in database
 * @param {string} phoneNumber - Plaintext phone number
 * @returns {string} - Encrypted phone number
 */
function encryptPhoneNumber(phoneNumber) {
  return encryptField(phoneNumber);
}

/**
 * Decrypt phone number after reading from database
 * @param {string} encryptedPhoneNumber - Encrypted phone number
 * @returns {string} - Plaintext phone number
 */
function decryptPhoneNumber(encryptedPhoneNumber) {
  return decryptField(encryptedPhoneNumber);
}

/**
 * Check if encryption is enabled
 * @returns {boolean}
 */
function isEncryptionEnabled() {
  return ENCRYPTION_ENABLED && encryptionKey !== null;
}

module.exports = {
  encryptField,
  decryptField,
  encryptPhoneNumber,
  decryptPhoneNumber,
  isEncryptionEnabled,
};

