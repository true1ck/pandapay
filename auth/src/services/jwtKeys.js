// src/services/jwtKeys.js
// === SECURITY HARDENING: JWT KEY ROTATION ===
// JWT key management with support for key rotation and multiple signing keys

/**
 * JWT Key Management
 * 
 * Supports:
 * - Multiple signing keys with key IDs (kid)
 * - Active key for signing new tokens
 * - Multiple verification keys for token rotation
 * - Key rotation without breaking existing tokens
 * 
 * Configuration:
 * - JWT_ACTIVE_KEY_ID: The key ID to use for signing new tokens (default: '1')
 * - JWT_KEYS_JSON: JSON object mapping key IDs to secrets
 *   Example: {"1": "secret1", "2": "secret2"}
 * - JWT_ISSUER: Issuer claim (iss) for tokens (default: 'pandapay-auth')
 * - JWT_AUDIENCE: Audience claim (aud) for tokens (default: 'mobile-app')
 * 
 * TODO: In production, load keys from a secrets manager (AWS Secrets Manager, 
 *       HashiCorp Vault, etc.) instead of environment variables
 */

const crypto = require('crypto');

// === SECURITY HARDENING: JWT KEY ROTATION ===
// Load keys from environment
const ACTIVE_KEY_ID = process.env.JWT_ACTIVE_KEY_ID || '1';
const JWT_ISSUER = process.env.JWT_ISSUER || 'pandapay-auth';
const JWT_AUDIENCE = process.env.JWT_AUDIENCE || 'mobile-app';

// Parse keys from environment
// Format: JWT_KEYS_JSON='{"1":"secret1","2":"secret2"}'
// OR use legacy single keys: JWT_ACCESS_SECRET, JWT_REFRESH_SECRET
let keys = {};

function loadKeys() {
  // Try new format first (JWT_KEYS_JSON)
  if (process.env.JWT_KEYS_JSON) {
    try {
      keys = JSON.parse(process.env.JWT_KEYS_JSON);
    } catch (err) {
      console.error('Failed to parse JWT_KEYS_JSON:', err);
      keys = {};
    }
  }

  // Fallback to legacy format for backward compatibility
  if (Object.keys(keys).length === 0) {
    if (process.env.JWT_ACCESS_SECRET) {
      keys['1'] = process.env.JWT_ACCESS_SECRET;
    }
    if (process.env.JWT_REFRESH_SECRET && !keys['1']) {
      keys['1'] = process.env.JWT_REFRESH_SECRET;
    }
  }

  // Ensure we have at least one key
  if (Object.keys(keys).length === 0) {
    throw new Error('No JWT keys configured. Set JWT_KEYS_JSON or JWT_ACCESS_SECRET');
  }

  // Ensure active key exists
  if (!keys[ACTIVE_KEY_ID]) {
    console.warn(`Active key ID ${ACTIVE_KEY_ID} not found, using first available key`);
    const firstKeyId = Object.keys(keys)[0];
    return { keys, activeKeyId: firstKeyId };
  }

  return { keys, activeKeyId: ACTIVE_KEY_ID };
}

const { keys: loadedKeys, activeKeyId } = loadKeys();

/**
 * Get the secret for a specific key ID
 */
function getKeySecret(keyId) {
  return loadedKeys[keyId] || null;
}

/**
 * Get the active key ID and secret for signing new tokens
 */
function getActiveKey() {
  return {
    keyId: activeKeyId,
    secret: loadedKeys[activeKeyId],
  };
}

/**
 * Get all keys (for verification during rotation)
 */
function getAllKeys() {
  return loadedKeys;
}

/**
 * Get issuer claim
 */
function getIssuer() {
  return JWT_ISSUER;
}

/**
 * Get audience claim
 */
function getAudience() {
  return JWT_AUDIENCE;
}

/**
 * Validate JWT claims (iss, aud, exp, iat, nbf)
 */
function validateTokenClaims(payload, options = {}) {
  const {
    allowExpired = false,
    clockSkewSeconds = 60, // Allow 60 seconds clock skew
  } = options;

  const now = Math.floor(Date.now() / 1000);
  const skew = clockSkewSeconds;

  // Validate issuer
  if (payload.iss && payload.iss !== JWT_ISSUER) {
    return { valid: false, reason: 'invalid_issuer' };
  }

  // Validate audience
  if (payload.aud && payload.aud !== JWT_AUDIENCE) {
    return { valid: false, reason: 'invalid_audience' };
  }

  // Validate expiration
  if (payload.exp) {
    if (!allowExpired && payload.exp < now - skew) {
      return { valid: false, reason: 'expired' };
    }
  }

  // Validate issued at (should not be in the future beyond clock skew)
  if (payload.iat) {
    if (payload.iat > now + skew) {
      return { valid: false, reason: 'issued_in_future' };
    }
  }

  // Validate not before (if present)
  if (payload.nbf) {
    if (payload.nbf > now + skew) {
      return { valid: false, reason: 'not_yet_valid' };
    }
  }

  return { valid: true };
}

/**
 * TODO: Load keys from secrets manager
 * Example implementation for AWS Secrets Manager:
 * 
 * async function loadKeysFromSecretsManager() {
 *   const AWS = require('aws-sdk');
 *   const secretsManager = new AWS.SecretsManager();
 *   
 *   const secret = await secretsManager.getSecretValue({
 *     SecretId: process.env.JWT_SECRETS_ARN
 *   }).promise();
 *   
 *   return JSON.parse(secret.SecretString);
 * }
 */

module.exports = {
  getKeySecret,
  getActiveKey,
  getAllKeys,
  getIssuer,
  getAudience,
  validateTokenClaims,
};









