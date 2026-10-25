'use strict';

const REQUEST_SQL = 'SELECT * FROM account_lifecycle.request_deletion($1::uuid)';
const CANCEL_SQL = 'SELECT * FROM account_lifecycle.cancel_deletion($1::uuid)';
const ASSERT_ACCESS_SQL = 'SELECT account_lifecycle.assert_access($1::uuid)';
const LEGACY_REQUEST_SQL = `UPDATE profiles SET deletion_requested_at=now(),deletion_due_at=now()+interval '30 days'
  WHERE id=$1 RETURNING deletion_requested_at,deletion_due_at`;
const LEGACY_CANCEL_SQL = `UPDATE profiles SET deletion_requested_at=null,deletion_due_at=null
  WHERE id=$1 RETURNING deletion_requested_at,deletion_due_at`;

function createAccountLifecycleHandlers({ withUserClient, enabled = false, logger = console }) {
  if (typeof withUserClient !== 'function') throw new TypeError('withUserClient is required');
  const handler = cancel => async (req, res) => {
    try {
      const result = await withUserClient(req.userId, client => client.query(
        enabled ? (cancel ? CANCEL_SQL : REQUEST_SQL) : (cancel ? LEGACY_CANCEL_SQL : LEGACY_REQUEST_SQL),
        [req.userId],
      ));
      const row = result.rows[0];
      return res.json({ profile: row ? {
        deletion_requested_at: row.deletion_requested_at,
        deletion_due_at: row.deletion_due_at,
      } : null });
    } catch (error) {
      if (enabled && error.code === '55000') return res.status(409).json({ error: 'account_deletion_processing' });
      if (enabled && error.code === '42501') return res.status(403).json({ error: 'account_access_denied' });
      logger.error?.('Account deletion request unavailable');
      return res.status(500).json({ error: 'internal_error' });
    }
  };
  return { requestDeletion: handler(false), cancelDeletion: handler(true) };
}

module.exports = { createAccountLifecycleHandlers, REQUEST_SQL, CANCEL_SQL, ASSERT_ACCESS_SQL };
