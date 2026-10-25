'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APPLY_SQL = 'SELECT auth_private.apply_account_deletion($1::uuid,$2::uuid,$3::bigint) AS first_application';
const LIST_SQL = 'SELECT * FROM auth_private.list_deletion_tombstones($1::uuid,$2::integer)';
function validDeletionJob(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(k => !['request_id', 'user_id', 'generation'].includes(k))) return false;
  return typeof value.request_id === 'string' && UUID.test(value.request_id) && typeof value.user_id === 'string' && UUID.test(value.user_id)
    && (typeof value.generation === 'string' || Number.isSafeInteger(value.generation))
    && /^[1-9][0-9]{0,18}$/.test(String(value.generation)) && BigInt(value.generation) <= 9223372036854775807n;
}
async function applyAccountDeletion(executor, job) {
  if (!validDeletionJob(job)) { const error = new Error('Invalid deletion job'); error.code = 'invalid_deletion_job'; throw error; }
  // The single database function commits ledger + user denial + session/device
  // revocation atomically. Repeated calls reapply denial after snapshot restore.
  await executor.query(APPLY_SQL, [job.request_id, job.user_id, String(job.generation)]);
  return { applied: true };
}
function createAccountDeletionHandler({ executor, enabled = false, logger = console }) {
  return async (req, res) => {
    if (!enabled) return res.status(503).json({ error: 'account_lifecycle_disabled' });
    if (!validDeletionJob(req.body)) return res.status(400).json({ error: 'invalid_deletion_job' });
    try { return res.json(await applyAccountDeletion(executor, req.body)); }
    catch (_) { logger.error?.('Account lifecycle application unavailable'); return res.status(503).json({ error: 'account_lifecycle_unavailable' }); }
  };
}
module.exports = { applyAccountDeletion, createAccountDeletionHandler, validDeletionJob, APPLY_SQL, LIST_SQL };
