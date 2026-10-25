'use strict';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SYNC_OPS = new Set(['insert', 'update', 'delete']);
const SYNC_REJECTION_DETAILS = Object.freeze({
  '22P02': 'A value has an invalid format.',
  '22003': 'A number is outside the supported range.',
  '23503': 'A referenced record is missing.',
  '23505': 'This change duplicates an existing record.',
  '23514': 'This change violates a data rule.',
  '42501': 'This change is not permitted.',
  SYNC_TRANSACTION_DOMAIN_REQUIRED: 'Use the transaction status route for status changes or deletion.',
  SYNC_SPLIT_TOTAL_CONFLICT: 'amount is less than saved split shares; edit or clear the split first',
});

/** Return only fixed, non-sensitive text for a failed sync item. */
function syncRejectionDetail(err) {
  const code = err?.code;
  return typeof code === 'string' && Object.hasOwn(SYNC_REJECTION_DETAILS, code)
    ? SYNC_REJECTION_DETAILS[code]
    : 'The change could not be applied.';
}

function isRecord(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function error(error, status = 400) {
  return { error, status };
}

function success(value) {
  return { value };
}

function isUuid(value) {
  return typeof value === 'string' && UUID_PATTERN.test(value);
}

function parseQueryInteger(value, name, fallback) {
  if (value === undefined || value === null || value === '') return success(fallback);
  if (typeof value !== 'string' || !/^[+-]?\d+$/.test(value)) {
    return error(`${name} must be an integer`);
  }
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) return error(`${name} is outside the safe integer range`);
  return success(parsed);
}

/**
 * Normalize the intentionally optional registration fields without changing
 * the SQL function's stale-device recovery or its platform-to-web fallback.
 */
function validateSyncRegistration(body) {
  if (body === undefined || body === null) body = {};
  if (!isRecord(body)) return error('request body must be an object');

  const deviceId = typeof body.deviceId === 'string' && body.deviceId.length > 0
    ? body.deviceId
    : null;
  if (deviceId !== null && !isUuid(deviceId)) return error('deviceId must be a UUID');

  return success({
    platform: typeof body.platform === 'string' ? body.platform : 'web',
    label: typeof body.label === 'string' ? body.label : null,
    appVersion: typeof body.appVersion === 'string' ? body.appVersion : null,
    deviceId,
  });
}

function validateSyncPushRequest(body) {
  if (!isRecord(body)) return error('request body must be an object');
  if (!isUuid(body.deviceId)) return error('deviceId is required and must be a UUID');
  if (!Array.isArray(body.changes)) return error('changes must be an array');
  if (body.changes.length > 200) return error('too many changes in one push', 413);
  return success({ deviceId: body.deviceId, changes: body.changes });
}

/**
 * Validate an individual push item while retaining item-level partial
 * success. Unknown entity names are allowed through to SQL, which owns the
 * sync entity allowlist and returns its established `unknown_entity` result.
 */
function validateSyncPushChange(change) {
  if (!isRecord(change)) return error('malformed');

  const { entity, entityId, op } = change;
  if (typeof entity !== 'string' || entity.length === 0 || !isUuid(entityId) || !SYNC_OPS.has(op)) {
    return error('malformed');
  }

  const clientSeq = change.clientSeq;
  if (clientSeq !== undefined && clientSeq !== null &&
      (!Number.isSafeInteger(clientSeq) || clientSeq < 0)) {
    return error('malformed');
  }

  const payload = change.payload == null ? {} : change.payload;
  const fieldClocks = change.fieldClocks == null ? {} : change.fieldClocks;
  if (!isRecord(payload) || !isRecord(fieldClocks)) return error('malformed');
  for (const clock of Object.values(fieldClocks)) {
    if (!Number.isSafeInteger(clock)) return error('malformed');
  }

  return success({
    entity,
    entityId,
    op,
    payload,
    fieldClocks,
    clientSeq: clientSeq ?? null,
  });
}

function validateSyncPullQuery(query) {
  if (!isRecord(query)) return error('query must be an object');
  if (!isUuid(query.deviceId)) return error('deviceId is required and must be a UUID');

  const sinceResult = parseQueryInteger(query.since, 'since', 0);
  if (sinceResult.error) return sinceResult;
  const limitResult = parseQueryInteger(query.limit, 'limit', 500);
  if (limitResult.error) return limitResult;
  // The route historically used `parseInt(value, 10) || 500`, so explicit
  // zero selected the default before SQL applied its 1..1000 clamp.
  const requestedLimit = limitResult.value === 0 ? 500 : limitResult.value;

  return success({
    deviceId: query.deviceId,
    // The SQL function accepts any bigint and selects server_seq > since;
    // negative cursors are safe (they replay from the beginning) and the old
    // parseInt route accepted them, so retain that behavior within JS bounds.
    since: sinceResult.value,
    // SQL clamps the same range. Clamp here too so response hasMore reflects
    // the effective limit and never relies on bigint/int casts to do it.
    limit: Math.min(Math.max(requestedLimit, 1), 1000),
  });
}

function validateSyncAck(body) {
  if (!isRecord(body)) return error('request body must be an object');
  if (!isUuid(body.deviceId)) return error('deviceId and serverSeq are required');
  if (!Number.isSafeInteger(body.serverSeq) || body.serverSeq < 0) {
    return error('deviceId and serverSeq are required');
  }
  return success({ deviceId: body.deviceId, serverSeq: body.serverSeq });
}

function validateSyncConflictId(id) {
  return isUuid(id) ? success(id) : error('id must be a UUID');
}

module.exports = {
  validateSyncRegistration,
  validateSyncPushRequest,
  validateSyncPushChange,
  validateSyncPullQuery,
  validateSyncAck,
  validateSyncConflictId,
  syncRejectionDetail,
};
