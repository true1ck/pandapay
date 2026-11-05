'use strict';

const { openPassword } = require('./imap_credentials');

const MAX_BATCH_SIZE = 100;

function validateBatchSize(batchSize) {
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > MAX_BATCH_SIZE) {
    throw new Error('imap_worker_batch_size_invalid');
  }
  return batchSize;
}

/**
 * One bounded batch of active connections. PostgreSQL returns only the sealed
 * credential; it is opened here, in the API process, with the keyring. A row
 * that cannot be opened (unknown key id, wrong binding, corruption) comes back
 * with credential_error=true and app_password=null so it never starves a batch.
 */
async function readImapWorkerBatch(client, keysById, { batchSize = MAX_BATCH_SIZE } = {}) {
  validateBatchSize(batchSize);
  if (!(keysById instanceof Map) || keysById.size < 1) {
    throw new Error('imap_worker_keyring_invalid');
  }
  const result = await client.query(
    `SELECT id, profile_id, email, imap_host, imap_port, sender_filter,
            last_poll_at, app_password_ciphertext, app_password_key_id
       FROM imap_worker.next_connections($1::integer)`,
    [batchSize],
  );
  if (!Array.isArray(result.rows) || result.rows.length > batchSize) {
    throw new Error('imap_worker_batch_result_invalid');
  }
  return result.rows.map((row) => {
    const { app_password_ciphertext: ciphertext, app_password_key_id: keyId, ...connection } = row;
    let password = null;
    let credentialError = false;
    try {
      password = openPassword({ keyId, ciphertext },
        { profileId: row.profile_id, connectionId: row.id }, keysById);
    } catch (_) {
      credentialError = true;
    }
    return { ...connection, app_password: password, credential_error: credentialError };
  });
}

async function deferImapWorkerBatch(client, lastAttemptedId) {
  await client.query('SELECT imap_worker.defer_connections($1::uuid)', [lastAttemptedId ?? null]);
}

module.exports = { readImapWorkerBatch, deferImapWorkerBatch, MAX_BATCH_SIZE, validateBatchSize };
