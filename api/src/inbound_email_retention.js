'use strict';

/**
 * A forwarded email's text is kept only until a transaction has been made
 * from it. This links the email to its transaction and drops the text in the
 * same statement. Emails that were not parsed keep their text until
 * purge_after (30 days) so the user can review them.
 */
async function markInboundEmailConverted(client, emailId, transactionId) {
  await client.query(
    `UPDATE inbound_emails SET produced_txn_id = $1, body_text = NULL WHERE id = $2`,
    [transactionId, emailId],
  );
}

module.exports = { markInboundEmailConverted };
