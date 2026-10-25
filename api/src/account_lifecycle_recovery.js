'use strict';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const APPLY_SQL = 'SELECT auth_private.apply_account_deletion($1::uuid,$2::uuid,$3::bigint) AS first_application';
const AUTH_LIST_SQL = 'SELECT * FROM auth_private.list_deletion_tombstones($1::uuid,$2::integer)';
const validDeletionJob = value => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).every(k => ['request_id','user_id','generation'].includes(k))
  && typeof value.request_id === 'string' && UUID.test(value.request_id)
  && typeof value.user_id === 'string' && UUID.test(value.user_id)
  && (typeof value.generation === 'string' || Number.isSafeInteger(value.generation))
  && /^[1-9][0-9]{0,18}$/.test(String(value.generation)) && BigInt(value.generation)<=9223372036854775807n;
const PRODUCT_LIST_SQL = 'SELECT * FROM account_lifecycle.list_tombstones($1::uuid,$2::integer)';
const PRODUCT_REPLAY_SQL = 'SELECT account_lifecycle.replay_tombstone($1::uuid,$2::uuid,$3::bigint)';

/** Explicit recovery action after restoring either database and before serving
 * traffic. Both services/workers must remain quiesced for the entire operation.
 * Replay an independently retained, verified latest tombstone journal when both
 * restored databases predate deletions; old paired dumps alone cannot supply it.
 * Connections are operator-provided and must be verified/restricted by caller.
 */
async function reconcileAccountLifecycleTombstones({ product, auth, quiesced = false, additionalTombstones = [], maxPages = 1000 }) {
  if (quiesced !== true) throw new Error('Account lifecycle replay requires quiesced services');
  if (!product?.query || !auth?.query || !Number.isInteger(maxPages) || maxPages < 1 || maxPages > 1000) {
    throw new Error('Invalid lifecycle replay configuration');
  }
  const result = { journalRecords: 0, productRecords: 0, authRecords: 0 };
  async function applyBoth(record) {
    if (!validDeletionJob(record)) throw new Error('Invalid retained deletion tombstone');
    await product.query(PRODUCT_REPLAY_SQL, [record.request_id, record.user_id, String(record.generation)]);
    await auth.query(APPLY_SQL, [record.request_id, record.user_id, String(record.generation)]);
  }
  // Streaming journal import is bounded even for a malformed/infinite source.
  for await (const record of additionalTombstones) {
    if (result.journalRecords >= 100000) throw new Error('Retained deletion journal exceeds replay limit');
    await applyBoth(record); result.journalRecords += 1;
  }
  for (const side of ['product', 'auth']) {
    let cursor = null, exhausted = false;
    for (let page = 0; page < maxPages; page += 1) {
      const source = side === 'product' ? product : auth;
      const batch = await source.query(side === 'product' ? PRODUCT_LIST_SQL : AUTH_LIST_SQL, [cursor, 100]);
      if (!Array.isArray(batch.rows) || batch.rows.length > 100) throw new Error('Invalid lifecycle replay page');
      for (const row of batch.rows) {
        const record = { request_id: row.request_id, user_id: side === 'product' ? row.profile_id : row.user_id, generation: String(row.generation) };
        if (!validDeletionJob(record) || (cursor && record.user_id.toLowerCase() <= cursor.toLowerCase())) {
          throw new Error('Invalid lifecycle replay ordering');
        }
        await applyBoth(record); cursor = record.user_id; result[`${side}Records`] += 1;
      }
      if (batch.rows.length < 100) { exhausted = true; break; }
    }
    if (!exhausted) throw new Error('Lifecycle replay page limit reached; keep services quiesced');
  }
  return result;
}
module.exports = { reconcileAccountLifecycleTombstones, PRODUCT_LIST_SQL, PRODUCT_REPLAY_SQL };
