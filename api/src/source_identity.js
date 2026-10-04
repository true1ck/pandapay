'use strict';

const crypto = require('crypto');

function sha256(parts) {
  return crypto.createHash('sha256').update(parts.join('\u0000')).digest('hex');
}

/** Stable, privacy-safe identity for one original SMS message. */
function importSourceKey(userId, sender, body, occurred) {
  if (!(occurred instanceof Date) || Number.isNaN(occurred.getTime())) return null;
  return sha256([userId, sender || '', body, occurred.toISOString()]);
}

function normalizeEmailPart(value) {
  return String(value || '').replace(/\r\n?/g, '\n').replace(/\s+/g, ' ').trim();
}

/**
 * Stable identity for provider retries and forwarding the same email twice.
 *
 * Provider message ids are transport identifiers and may change on a second
 * forward, so content is the primary identity. Transaction alerts normally
 * contain their own amount/date/reference; a materially different alert has
 * different normalized content. The provider id is only a fallback for an
 * otherwise-empty payload. A one-way hash can be retained as provenance.
 */
function emailSourceKey(userId, sender, subject, body, messageId) {
  const normalized = [
    normalizeEmailPart(sender).toLowerCase(),
    normalizeEmailPart(subject),
    normalizeEmailPart(body),
  ];
  if (!normalized.some(Boolean)) normalized.push(`message-id:${normalizeEmailPart(messageId)}`);
  return sha256([userId, 'email', ...normalized]);
}

module.exports = { importSourceKey, emailSourceKey, normalizeEmailPart };
