'use strict';
/**
 * Encryption of the claimant's phone number for the join-request owner.
 *
 * AES-256-GCM in Node; the database only stores the packed bytes
 * (nonce 12 || tag 16 || ciphertext). The invitation id is the additional
 * authenticated data, so a ciphertext copied to another row will not decrypt.
 * Key ring: SHARED_EXPENSE_PHONE_ENC_KEYS = {"current":"k1","keys":{"k1":"<base64 32 bytes>"}}.
 * It is deliberately separate from ENCRYPTION_KEY and SHARED_EXPENSE_INVITE_SECRET.
 * A missing or malformed ring means "do not capture" (fail closed), never a throw.
 */
const crypto = require('node:crypto');

const KEY_ID = /^[A-Za-z0-9_.-]{1,32}$/;

/** Returns {current, keys:Map} or null when the ring is absent or unusable. */
function parseKeyRing(raw) {
  if (typeof raw !== 'string' || !raw.trim()) return null;
  let parsed;
  try { parsed = JSON.parse(raw); } catch (_) { return null; }
  if (!parsed || typeof parsed !== 'object' || typeof parsed.current !== 'string' || !parsed.keys || typeof parsed.keys !== 'object') return null;
  const keys = new Map();
  for (const [id, value] of Object.entries(parsed.keys)) {
    if (!KEY_ID.test(id) || typeof value !== 'string') return null;
    const key = Buffer.from(value, 'base64');
    if (key.length !== 32) return null;
    keys.set(id, key);
  }
  if (!keys.has(parsed.current)) return null;
  return { current: parsed.current, keys };
}

function aad(invitationId) {
  return Buffer.from(String(invitationId).toLowerCase().replace(/-/g, ''), 'hex');
}

function encryptPhone(ring, invitationId, e164) {
  if (!ring) return null;
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', ring.keys.get(ring.current), nonce);
  cipher.setAAD(aad(invitationId));
  const body = Buffer.concat([cipher.update(String(e164), 'utf8'), cipher.final()]);
  return { enc: Buffer.concat([nonce, cipher.getAuthTag(), body]), keyId: ring.current };
}

/** Plaintext e164, or null on any failure (unknown key, wrong row, tampering). */
function decryptPhone(ring, invitationId, enc, keyId) {
  try {
    const key = ring?.keys.get(keyId);
    if (!key || !Buffer.isBuffer(enc) || enc.length < 29) return null;
    const decipher = crypto.createDecipheriv('aes-256-gcm', key, enc.subarray(0, 12));
    decipher.setAAD(aad(invitationId));
    decipher.setAuthTag(enc.subarray(12, 28));
    const plain = Buffer.concat([decipher.update(enc.subarray(28)), decipher.final()]).toString('utf8');
    return /^\+[1-9][0-9]{6,14}$/.test(plain) ? plain : null;
  } catch (_) {
    return null;
  }
}

module.exports = { parseKeyRing, encryptPhone, decryptPhone };
