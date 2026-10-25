'use strict';

const MAX_BATCH_SIZE = 100;

function validateBatchSize(batchSize) {
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > MAX_BATCH_SIZE) {
    throw new Error('imap_worker_batch_size_invalid');
  }
  return batchSize;
}

async function readImapWorkerBatch(client, encryptionKey, { batchSize = MAX_BATCH_SIZE } = {}) {
  validateBatchSize(batchSize);
  if (typeof encryptionKey !== 'string' || Buffer.byteLength(encryptionKey, 'utf8') < 1 ||
      Buffer.byteLength(encryptionKey, 'utf8') > 4096 || encryptionKey.includes('\0')) {
    throw new Error('imap_worker_encryption_key_invalid');
  }
  // The key only travels as a bound parameter. Never stringify args/results,
  // log this query's parameters, or put decrypted credentials in status data.
  const result = await client.query(
    `SELECT id, profile_id, email, imap_host, imap_port, sender_filter,
            last_poll_at, app_password, credential_error
       FROM imap_worker.next_connections($1::text, $2::integer)`,
    [encryptionKey, batchSize],
  );
  if (!Array.isArray(result.rows) || result.rows.length > batchSize) {
    throw new Error('imap_worker_batch_result_invalid');
  }
  return result.rows;
}

async function deferImapWorkerBatch(client, lastAttemptedId) {
  await client.query('SELECT imap_worker.defer_connections($1::uuid)', [lastAttemptedId ?? null]);
}

module.exports = { readImapWorkerBatch, deferImapWorkerBatch, MAX_BATCH_SIZE, validateBatchSize };
