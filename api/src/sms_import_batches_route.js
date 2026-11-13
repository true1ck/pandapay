'use strict';
// POST /sms-import-batches (WP-S5): optional clientMutationId makes the
// summary row idempotent. Without it the behaviour is the previous inline route.
const { safeErrorCode } = require('./safeErrorCode');
const { isUuid } = require('./http_db_errors');

function createSmsImportBatchPostHandler({ withUserClient }) {
  return async (req, res) => {
    const { messageCount, parsedCount, failedCount, clientMutationId } = req.body || {};
    if (clientMutationId !== undefined && clientMutationId !== null && !isUuid(clientMutationId)) {
      return res.status(400).json({ error: 'invalid_id' });
    }
    try {
      const out = await withUserClient(req.userId, async (client) => {
        if (!clientMutationId) {
          const r = await client.query(
            `INSERT INTO sms_import_batches (profile_id, message_count, parsed_count, failed_count)
             VALUES ($1, $2, $3, $4) RETURNING id, profile_id, message_count, parsed_count, failed_count, imported_at`,
            [req.userId, messageCount ?? 0, parsedCount ?? 0, failedCount ?? 0]
          );
          return { replayed: false, row: r.rows[0] };
        }
        const r = await client.query(
          `INSERT INTO sms_import_batches (profile_id, message_count, parsed_count, failed_count, client_mutation_id)
           VALUES ($1, $2, $3, $4, $5)
           ON CONFLICT (profile_id, client_mutation_id) WHERE client_mutation_id IS NOT NULL DO NOTHING
           RETURNING id, profile_id, message_count, parsed_count, failed_count, imported_at`,
          [req.userId, messageCount ?? 0, parsedCount ?? 0, failedCount ?? 0, clientMutationId]
        );
        if (r.rows.length) return { replayed: false, row: r.rows[0] };
        const existing = await client.query(
          'SELECT id, profile_id, message_count, parsed_count, failed_count, imported_at FROM sms_import_batches WHERE profile_id = $1 AND client_mutation_id = $2',
          [req.userId, clientMutationId]
        );
        return { replayed: true, row: existing.rows[0] };
      });
      if (out.replayed) return res.status(200).json({ smsImportBatch: out.row, replayed: true });
      return res.status(201).json({ smsImportBatch: out.row });
    } catch (err) {
      console.error('POST /sms-import-batches error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

module.exports = { createSmsImportBatchPostHandler };
