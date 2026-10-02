const crypto = require('node:crypto');

/**
 * Normalize the parts of an imported message that identify the message,
 * rather than the delivery event. Android can expose the same SMS through
 * the live broadcast and the inbox provider with different receive times;
 * receive time is therefore not an idempotency identity.
 */
function normalizeMessagePart(value) {
  return String(value || '')
    .replace(/\r\n?/g, '\n')
    .replace(/\s+/g, ' ')
    .trim();
}

/**
 * Stable identity for one imported message.
 *
 * The sender and normalized body are the only values used deliberately. The
 * body carries the bank's transaction reference/date when one exists, while
 * excluding the device delivery timestamp makes foreground and inbox
 * reconciliation idempotent. The profile id keeps identical bank templates
 * isolated between users, and the raw SMS is never stored in the hash input
 * column itself.
 *
 * The fourth argument is accepted for compatibility with older callers while
 * migrations roll out; it is intentionally ignored.
 */
function importSourceKey(userId, sender, body, _occurred) {
  return crypto
    .createHash('sha256')
    .update(JSON.stringify([
      String(userId),
      normalizeMessagePart(sender).toUpperCase(),
      normalizeMessagePart(body),
    ]))
    .digest('hex');
}

module.exports = { importSourceKey, normalizeMessagePart };
