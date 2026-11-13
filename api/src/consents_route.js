'use strict';
// POST /consents, moved out of index.js (WP-S5). Behaviour without
// `clientMutationId` is identical to the previous inline route.
const { safeErrorCode } = require('./safeErrorCode');
const { isUuid } = require('./http_db_errors');

const RETURNING = 'RETURNING purpose, granted, granted_at, policy_version, source_screen';

function createConsentPostHandler({ withUserClient, CONSENT_PURPOSES }) {
  return async (req, res) => {
    const { purpose, granted, policyVersion, sourceScreen, clientMutationId } = req.body || {};
    if (!CONSENT_PURPOSES.includes(purpose)) {
      return res.status(400).json({ error: `purpose must be one of ${CONSENT_PURPOSES.join(', ')}` });
    }
    if (typeof granted !== 'boolean') {
      return res.status(400).json({ error: 'granted must be a boolean' });
    }
    if (!policyVersion || typeof policyVersion !== 'string') {
      return res.status(400).json({ error: 'policyVersion is required' });
    }
    if (clientMutationId !== undefined && clientMutationId !== null && !isUuid(clientMutationId)) {
      return res.status(400).json({ error: 'invalid_id' });
    }
    try {
      const out = await withUserClient(req.userId, async (client) => {
        if (purpose === 'sms_shared_learning') {
          // Match the feedback route's lock so revocation/purge cannot race an
          // in-flight contribution write under the previous grant.
          await client.query(
            'SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))',
            [`sms-shared-learning-consent:${req.userId}`],
          );
        }
        if (!clientMutationId) {
          const inserted = await client.query(
            `INSERT INTO user_consents (profile_id, purpose, policy_version, granted, source_screen)
             VALUES ($1, $2, $3, $4, $5)
             ${RETURNING}`,
            [req.userId, purpose, policyVersion, granted, sourceScreen || null]
          );
          // Revoking sms_shared_learning purges the v2 template data in the database
          // (trigger sms_v2_revoke_template_consent), inside this transaction.
          return { replayed: false, row: inserted.rows[0] };
        }
        // granted_at stays the server arrival time (it is the ordering key).
        // The AFTER INSERT revoke trigger does not fire for a skipped conflict.
        const inserted = await client.query(
          `INSERT INTO user_consents (profile_id, purpose, policy_version, granted, source_screen, client_mutation_id)
           VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (profile_id, client_mutation_id) WHERE client_mutation_id IS NOT NULL DO NOTHING
           ${RETURNING}`,
          [req.userId, purpose, policyVersion, granted, sourceScreen || null, clientMutationId]
        );
        if (inserted.rows.length) return { replayed: false, row: inserted.rows[0] };
        const existing = await client.query(
          `SELECT purpose, granted, granted_at, policy_version, source_screen
             FROM user_consents WHERE profile_id = $1 AND client_mutation_id = $2`,
          [req.userId, clientMutationId]
        );
        return { replayed: true, row: existing.rows[0] };
      });
      if (out.replayed) return res.status(200).json({ consent: out.row, replayed: true });
      return res.status(201).json({ consent: out.row });
    } catch (err) {
      console.error('POST /consents error', safeErrorCode(err));
      return res.status(500).json({ error: 'internal_error' });
    }
  };
}

function registerConsentRoute(app, { requireAuth, withUserClient, CONSENT_PURPOSES }) {
  app.post('/consents', requireAuth, createConsentPostHandler({ withUserClient, CONSENT_PURPOSES }));
}

module.exports = { createConsentPostHandler, registerConsentRoute };
