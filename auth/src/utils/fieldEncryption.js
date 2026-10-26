'use strict';

// Preserve existing iv:tag:ciphertext and key bytes across provider moves.
const crypto = require('node:crypto');
const { TextDecoder } = require('node:util');
const enabled = ['true', '1'].includes(process.env.ENCRYPTION_ENABLED);
const hosted = ['production', 'staging'].includes(process.env.NODE_ENV);
const V2_AAD_PREFIX = Buffer.from('pandapay-field-encryption-v2\0', 'utf8');
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
function decodeCanonicalBase64(value) {
  const bytes = decodeBase64(value);
  if (bytes.toString('base64') !== value) throw failure('Invalid encrypted field encoding');
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
function initializeReadKeys() {
  const source = process.env.ENCRYPTION_READ_KEYS_JSON;
  if (source === undefined || source === null || source === '') return new Map();
  if (typeof source !== 'string' || Buffer.byteLength(source, 'utf8') > 8192) {
    throw failure('ENCRYPTION_READ_KEYS_JSON must be a JSON array of valid read keys');
  }
  try {
    const entries = JSON.parse(source);
    if (!Array.isArray(entries) || entries.length > 8) throw new Error('invalid read key list');
    const keys = new Map();
    for (const entry of entries) {
      if (!Array.isArray(entry) || entry.length !== 2) throw new Error('invalid read key pair');
      const [id, encodedKey] = entry;
      if (typeof id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(id) || keys.has(id)) {
        throw new Error('invalid or duplicate read key id');
      }
      if (typeof encodedKey !== 'string' || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)$/.test(encodedKey)) {
        throw new Error('invalid read key encoding');
      }
      const decoded = Buffer.from(encodedKey, 'base64');
      if (decoded.length !== 32 || decoded.toString('base64') !== encodedKey) {
        throw new Error('invalid read key length or encoding');
      }
      keys.set(id, decoded);
    }
    return keys;
  } catch (_) {
    throw failure('ENCRYPTION_READ_KEYS_JSON must contain up to 8 unique IDs and canonical base64 32-byte keys');
  }
}
function initializeV2Writer(keys) {
  const setting = process.env.ENCRYPTION_V2_WRITES_ENABLED;
  if (setting === undefined) return { enabled: false, keyId: null, key: null };
  if (setting !== 'true' && setting !== 'false') {
    throw failure('ENCRYPTION_V2_WRITES_ENABLED must be true or false');
  }
  if (setting === 'false') return { enabled: false, keyId: null, key: null };
  if (!key) throw failure('ENCRYPTION_V2_WRITES_ENABLED requires ENCRYPTION_ENABLED and a valid ENCRYPTION_KEY');
  const keyId = process.env.ENCRYPTION_WRITE_KEY_ID;
  if (typeof keyId !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(keyId)) {
    throw failure('ENCRYPTION_WRITE_KEY_ID must select a configured read key ID');
  }
  const writeKey = keys.get(keyId);
  if (!writeKey) throw failure('ENCRYPTION_WRITE_KEY_ID must select a configured read key ID');
  return { enabled: true, keyId, key: writeKey };
}
const key = initializeKey();
const readKeys = initializeReadKeys();
const v2Writer = initializeV2Writer(readKeys);
function encryptField(value) {
  if (!value || typeof value !== 'string') return value;
  if (!key) return value;
  const iv = crypto.randomBytes(12);
  if (v2Writer.enabled) {
    const cipher = crypto.createCipheriv('aes-256-gcm', v2Writer.key, iv);
    cipher.setAAD(Buffer.concat([V2_AAD_PREFIX, Buffer.from(v2Writer.keyId, 'utf8')]));
    const ciphertext = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
    const envelope = ['v2', v2Writer.keyId, iv, cipher.getAuthTag(), ciphertext]
      .map((part, index) => index < 2 ? part : part.toString('base64')).join(':');
    if (Buffer.byteLength(envelope, 'utf8') > 4096) throw failure('Encrypted field exceeds the supported envelope size');
    return envelope;
  }
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
  if (!value.startsWith('v2:') && !key) {
    throw failure('A valid encryption key is required to read encrypted fields');
  }
  try {
    if (value.startsWith('v2:') && Buffer.byteLength(value, 'utf8') > 4096) throw new Error('oversized envelope');
    const parts = value.split(':');
    if (parts[0] === 'v2') {
      if (parts.length !== 5 || !/^[A-Za-z0-9_-]{1,64}$/.test(parts[1])) throw new Error('invalid v2 envelope');
      const readKey = readKeys.get(parts[1]);
      if (!readKey) throw new Error('unknown v2 key');
      const [, keyId, ivText, tagText, ciphertextText] = parts;
      const iv = decodeCanonicalBase64(ivText);
      const tag = decodeCanonicalBase64(tagText);
      const ciphertext = decodeCanonicalBase64(ciphertextText);
      if (iv.length !== 12 || tag.length !== 16 || ciphertext.length === 0) throw new Error('invalid v2 lengths');
      const decipher = crypto.createDecipheriv('aes-256-gcm', readKey, iv);
      decipher.setAAD(Buffer.concat([V2_AAD_PREFIX, Buffer.from(keyId, 'utf8')]));
      decipher.setAuthTag(tag);
      const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
      return new TextDecoder('utf-8', { fatal: true }).decode(plaintext);
    }
    if (parts.length !== 3) throw new Error('unsupported format');
    const [iv, tag, ciphertext] = parts.map(decodeBase64);
    if (iv.length !== 12 || tag.length !== 16) throw new Error('invalid length');
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAuthTag(tag);
    const plaintext = Buffer.concat([decipher.update(ciphertext), decipher.final()]);
    return plaintext.toString('utf8');
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
  getWriteFormat: () => v2Writer.enabled ? 'v2' : 'legacy',
  getWriteKeyId: () => v2Writer.enabled ? v2Writer.keyId : null,
};
