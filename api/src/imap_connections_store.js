'use strict';

const crypto = require('node:crypto');
const { sealPassword, openPassword, normalizeSenderFilter } = require('./imap_credentials');

/**
 * Create or replace the caller's connection to one mailbox. The sealed
 * password is bound to (profile, connection id, key id), so the id has to be
 * known before sealing: an existing row keeps its id, a new one gets a UUID
 * generated here and inserted explicitly. Runs inside the caller's
 * transaction (withUserClient).
 */
async function saveImapConnection(client, { profileId, email, appPassword, imapHost, imapPort, senderFilter }, key) {
  const senders = normalizeSenderFilter(senderFilter);
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const existing = await client.query(
      'SELECT id FROM imap_connections WHERE profile_id = $1 AND email = $2 FOR UPDATE',
      [profileId, email],
    );
    const connectionId = existing.rows[0]?.id ?? crypto.randomUUID();
    const sealed = sealPassword(appPassword, { profileId, connectionId }, key);
    const saved = await client.query(
      `INSERT INTO imap_connections
         (id, profile_id, email, app_password_ciphertext, app_password_key_id, imap_host, imap_port, sender_filter)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (profile_id, email) DO UPDATE
         SET app_password_ciphertext = EXCLUDED.app_password_ciphertext,
             app_password_key_id = EXCLUDED.app_password_key_id,
             imap_host = EXCLUDED.imap_host,
             imap_port = EXCLUDED.imap_port,
             sender_filter = EXCLUDED.sender_filter,
             verified_at = NULL,
             is_active = true
         WHERE imap_connections.id = EXCLUDED.id
       RETURNING id, profile_id, email, imap_host, imap_port, sender_filter, is_active,
                 verified_at, last_poll_at, last_poll_status, created_at`,
      [connectionId, profileId, email, sealed.ciphertext, sealed.keyId, imapHost, imapPort ?? 993, senders.join(',')],
    );
    // No row means a concurrent save created this mailbox under another id
    // between our read and write; seal again for the id that won.
    if (saved.rows[0]) return saved.rows[0];
  }
  throw new Error('imap_connection_save_conflict');
}

/** The mailbox password, opened in memory for one test login. Never returned to a client. */
async function openStoredImapPassword(client, { connectionId, profileId }, keysById) {
  const result = await client.query(
    `SELECT id, email, imap_host, imap_port, app_password_ciphertext, app_password_key_id
       FROM imap_connections WHERE id = $1 AND profile_id = $2`,
    [connectionId, profileId],
  );
  const row = result.rows[0];
  if (!row) return null;
  const { app_password_ciphertext: ciphertext, app_password_key_id: keyId, ...connection } = row;
  let password = null;
  try {
    password = openPassword({ keyId, ciphertext }, { profileId, connectionId: row.id }, keysById);
  } catch (_) {
    password = null;
  }
  return { ...connection, app_password: password };
}

/** Disconnect: the row, and with it the sealed password, is deleted. */
async function deleteImapConnection(client, { connectionId, profileId }) {
  const result = await client.query(
    'DELETE FROM imap_connections WHERE id = $1 AND profile_id = $2',
    [connectionId, profileId],
  );
  return result.rowCount === 1;
}

/**
 * Bank sender addresses the email parser already knows: an address must
 * contain an active email parser pattern's sender_pattern to be accepted.
 */
async function bankSenderPatterns(client) {
  const result = await client.query(
    `SELECT DISTINCT lower(sender_pattern) AS sender_pattern
       FROM parser_patterns
      WHERE channel = 'email' AND is_active AND sender_pattern IS NOT NULL AND sender_pattern <> ''`,
  );
  return result.rows.map((row) => row.sender_pattern);
}

function requireBankSenders(senders, patterns) {
  const outside = senders.filter((s) => !patterns.some((p) => s.includes(p)));
  if (outside.length > 0) throw new Error('sender_filter_not_bank');
}

module.exports = {
  saveImapConnection, openStoredImapPassword, deleteImapConnection, bankSenderPatterns, requireBankSenders,
};
