'use strict';

// Preserve existing iv:tag:ciphertext and key bytes across provider moves.
const crypto = require('node:crypto');
const enabled = ['true', '1'].includes(process.env.ENCRYPTION_ENABLED);
const hosted = ['production', 'staging'].includes(process.env.NODE_ENV);
function failure(message) {
  const error = new Error(message);
  error.code = 'FIELD_ENCRYPTION_ERROR';
  return error;
}
function decodeBase64(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/]+={0,2}$/.test(value)) {
    throw failure('Invalid encrypted field encoding');
  }
  const bytes = Buffer.from(value, 'base64');
  if (bytes.toString('base64').replace(/=+$/, '') !== value.replace(/=+$/, '')) {
    throw failure('Invalid encrypted field encoding');
  }
  return bytes;
}
function initializeKey() {
  if (!enabled) {
    if (hosted) throw failure('Field encryption must be enabled in production and staging');
    return null; // Explicit legacy local development mode.
  }
  try {
    const key = decodeBase64(process.env.ENCRYPTION_KEY);
    if (key.length !== 32) throw new Error('invalid length');
    return key;
  } catch (_) {
    throw failure('ENCRYPTION_KEY must be a base64-encoded 32-byte key');
  }
}
const key = initializeKey();
function encryptField(value) {
  if (!value || typeof value !== 'string') return value;
  if (!key) return value;
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return [iv, cipher.getAuthTag(), ciphertext].map(bytes => bytes.toString('base64')).join(':');
}
function decryptField(value) {
  if (!value || typeof value !== 'string') return value;
  // Recognized legacy plaintext remains readable during additive migration.
  if (!value.includes(':')) {
    // Only known legacy phone forms qualify as plaintext. A damaged envelope
    // with lost separators must not be emitted as a user's phone number.
    const normalized = value.trim().replace(/[\s().-]/g, '');
    if (/^\d{10}$/.test(normalized) || /^\+[1-9]\d{1,14}$/.test(normalized)) return value;
    throw failure('Unrecognized legacy phone encoding');
  }
  if (!key) throw failure('A valid encryption key is required to read encrypted fields');
  try {
    const parts = value.split(':');
    if (parts.length !== 3) throw new Error('unsupported format');
    const [iv, tag, ciphertext] = parts.map(decodeBase64);
    if (iv.length !== 12 || tag.length !== 16) throw new Error('invalid length');
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
  } catch (_) {
    // Neither log the secret-bearing exception nor return damaged ciphertext
    // as plaintext. The caller must preserve the row and report a repair need.
    throw failure('Encrypted field authentication failed');
  }
}
module.exports = {
  encryptField, decryptField,
  encryptPhoneNumber: encryptField,
  decryptPhoneNumber: decryptField,
  isEncryptionEnabled: () => key !== null,
};
