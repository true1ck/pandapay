const crypto = require('node:crypto');

const aad = ({ profileId, connectionId }, keyId) =>
  Buffer.from(JSON.stringify(['pandapay-imap-v1', profileId, connectionId, keyId]));

/** AES-256-GCM in the API process; the key never reaches PostgreSQL. */
function sealPassword(password, binding, key) {
  const nonce = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key.bytes, nonce);
  cipher.setAAD(aad(binding, key.id));
  const body = Buffer.concat([cipher.update(password, 'utf8'), cipher.final()]);
  return { keyId: key.id, ciphertext: Buffer.concat([nonce, cipher.getAuthTag(), body]) };
}

function openPassword(sealed, binding, keysById) {
  const keyBytes = keysById.get(sealed.keyId);
  if (!keyBytes) throw new Error('imap_key_unavailable');
  const data = sealed.ciphertext;
  if (!Buffer.isBuffer(data) || data.length < 29) throw new Error('imap_ciphertext_invalid');
  const decipher = crypto.createDecipheriv('aes-256-gcm', keyBytes, data.subarray(0, 12));
  decipher.setAAD(aad(binding, sealed.keyId));
  decipher.setAuthTag(data.subarray(12, 28));
  return Buffer.concat([decipher.update(data.subarray(28)), decipher.final()]).toString('utf8');
}

const EMAIL = /^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$/;

/** Only explicit sender addresses; never the whole mailbox. */
function normalizeSenderFilter(raw) {
  const list = String(raw || '').split(',').map((s) => s.trim().toLowerCase()).filter(Boolean);
  if (list.length === 0 || list.some((s) => !EMAIL.test(s))) throw new Error('sender_filter_required');
  return [...new Set(list)];
}

const KEY_ID = /^[A-Za-z0-9._-]{1,32}$/;

function decodeKey(value, name) {
  const bytes = typeof value === 'string' && /^[A-Za-z0-9+/]+={0,2}$/.test(value.trim())
    ? Buffer.from(value.trim(), 'base64') : null;
  if (!bytes || bytes.length !== 32) throw new Error(`${name} must be 32 bytes encoded as base64`);
  return bytes;
}

/**
 * IMAP_ENCRYPTION_KEY (32 bytes, base64) seals new passwords under
 * IMAP_ENCRYPTION_KEY_ID (default k1). IMAP_ENCRYPTION_PREVIOUS_KEYS is an
 * optional JSON object {keyId: base64} that can still open older rows.
 * Returns null when no key is configured.
 */
function loadImapKeyring(env) {
  const raw = env.IMAP_ENCRYPTION_KEY;
  if (!raw) return null;
  const id = env.IMAP_ENCRYPTION_KEY_ID || 'k1';
  if (!KEY_ID.test(id)) throw new Error('IMAP_ENCRYPTION_KEY_ID must be 1-32 letters, digits, dot, dash or underscore');
  const current = { id, bytes: decodeKey(raw, 'IMAP_ENCRYPTION_KEY') };
  const byId = new Map([[id, current.bytes]]);
  if (env.IMAP_ENCRYPTION_PREVIOUS_KEYS) {
    let previous;
    try { previous = JSON.parse(env.IMAP_ENCRYPTION_PREVIOUS_KEYS); } catch { previous = null; }
    if (!previous || typeof previous !== 'object' || Array.isArray(previous)) {
      throw new Error('IMAP_ENCRYPTION_PREVIOUS_KEYS must be a JSON object of keyId to base64 key');
    }
    for (const [oldId, value] of Object.entries(previous)) {
      if (!KEY_ID.test(oldId) || byId.has(oldId)) throw new Error('IMAP_ENCRYPTION_PREVIOUS_KEYS has an invalid or duplicate key id');
      byId.set(oldId, decodeKey(value, 'IMAP_ENCRYPTION_PREVIOUS_KEYS entry'));
    }
  }
  return { current, byId };
}

module.exports = { sealPassword, openPassword, normalizeSenderFilter, loadImapKeyring };
