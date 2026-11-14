'use strict';

/**
 * Entity -> handler registry for POST /sync/push, plus the per-item pipeline
 * that used to live inline in the route.
 *
 * Why a registry: the route loop must not grow an `if (entity === ...)` branch
 * for every entity that gets a dedicated SQL function. A later package
 * registers, for example, a `user_cards` insert or a `card_overrides` insert
 * handler with `registerSyncPushHandler(...)` and the loop is untouched.
 *
 * Why this file does not import sync_request_validation: that module
 * re-exports these helpers (the route fragments are evaluated in sandboxes
 * that only see its exports), so the dependency has to point one way. The
 * route passes `rejectionDetail` in the context instead.
 *
 * Behaviour contract (unchanged for clients that do not send `strict: true`):
 *   - Each item runs inside its own SAVEPOINT. A failure rolls back only that
 *     item and is reported as one `rejected` result, except transient database
 *     errors (statement timeout, serialization failure, deadlock), which are
 *     reported as `transient` so the client retries instead of parking them.
 *   - Result keys, order and values for a normal item are exactly what the
 *     inline loop produced: clientSeq, entityId, applied, conflicts, reason.
 *
 * Strict mode (`strict: true` in the request body, opt-in) adds, per item:
 *   - `ignoredFields`: payload keys that are not on the SQL allowlist
 *     (pandapay.sync_fields_for). Entities handled by a dedicated SQL function
 *     keep their allowlist inside that function and report `[]`.
 *   - `reason: 'no_syncable_fields'` (applied=false) when an update carries no
 *     allowlisted field at all; nothing is written for that item.
 *   - field clocks more than five minutes ahead of the server clock are
 *     clamped to the server clock (they would otherwise win every later
 *     conflict); the affected field names are returned as `clampedClocks`.
 */

const { isTransientDbError } = require('./http_db_errors');

const SYNC_CLOCK_TOLERANCE_MS = 5 * 60 * 1000;
const SYNC_TRANSIENT_DETAIL = 'The server was busy. This change will be retried.';

function createSyncPushHandlerRegistry() {
  const byEntity = new Map();
  let fallback = null;
  return {
    /**
     * @param {string} entity
     * @param {string|string[]} ops  'insert' | 'update' | 'delete' | '*'
     * @param {(client, item, ctx) => Promise<{out_applied, out_conflicts, out_reason}>} handler
     * @param {{usesFieldAllowlist?: boolean}} [options]
     */
    register(entity, ops, handler, { usesFieldAllowlist = false } = {}) {
      if (typeof entity !== 'string' || entity.length === 0) throw new TypeError('entity must be a string');
      if (typeof handler !== 'function') throw new TypeError('handler must be a function');
      const list = Array.isArray(ops) ? ops : [ops];
      if (!byEntity.has(entity)) byEntity.set(entity, new Map());
      for (const op of list) byEntity.get(entity).set(op, { handler, usesFieldAllowlist });
    },
    registerFallback(handler, { usesFieldAllowlist = false } = {}) {
      if (typeof handler !== 'function') throw new TypeError('handler must be a function');
      fallback = { handler, usesFieldAllowlist };
    },
    resolve(entity, op) {
      const ops = byEntity.get(entity);
      return ops?.get(op) ?? ops?.get('*') ?? fallback;
    },
  };
}

function asRow(row) {
  return {
    out_applied: row.out_applied,
    out_conflicts: row.out_conflicts ?? 0,
    out_reason: row.out_reason ?? null,
  };
}

// ---------------------------------------------------------------------------
// Handlers. Each one is the body of one branch of the previous inline loop.
// ---------------------------------------------------------------------------

async function applyUserCategoryInsert(client, item, ctx) {
  const { entityId, payload, fieldClocks, clientSeq } = item;
  const result = await client.query(
    `SELECT out_applied, out_reason
       FROM pandapay.sync_insert_user_category(
         $1, $2, $3, $4, $5, $6::uuid, $7::uuid, $8::text[], $9::jsonb, $10)`,
    [
      ctx.userId,
      ctx.deviceId,
      entityId,
      typeof payload?.name === 'string' ? payload.name : null,
      typeof payload?.slug === 'string' ? payload.slug : null,
      typeof payload?.parent_category_id === 'string' ? payload.parent_category_id : null,
      typeof payload?.parent_user_category_id === 'string' ? payload.parent_user_category_id : null,
      Array.isArray(payload?.match_terms) ? payload.match_terms.filter((term) => typeof term === 'string') : [],
      JSON.stringify(fieldClocks || {}),
      Number.isFinite(clientSeq) ? clientSeq : 0,
    ],
  );
  const row = result.rows[0];
  return { out_applied: row.out_applied, out_conflicts: 0, out_reason: row.out_reason };
}

function documentHandler(functionName) {
  // functionName is a fixed literal chosen below, never request data.
  return async function applyDocumentChange(client, item, ctx) {
    const { entityId, op, payload, clientSeq } = item;
    const result = await client.query(
      `SELECT out_applied, out_conflicts, out_reason
         FROM pandapay.${functionName}(
           $1, $2, $3, $4, $5::jsonb, $6
         )`,
      [
        ctx.userId,
        ctx.deviceId,
        entityId,
        op,
        JSON.stringify(payload || {}),
        Number.isFinite(clientSeq) ? clientSeq : 0,
      ],
    );
    return asRow(result.rows[0]);
  };
}

/**
 * Generic field-clock writer for transactions, user_cards and card_overrides
 * (legacy raw writer, or the typed v2 writer / transaction domain applier when
 * SYNC_TYPED_WRITES_ENABLED is on).
 */
async function applyGenericChange(client, item, ctx) {
  const { entity, entityId, op, payload, fieldClocks, clientSeq } = item;
  const { userId, deviceId, config } = ctx;
  const args = [
    userId, deviceId, entity, entityId, op,
    JSON.stringify(payload), JSON.stringify(fieldClocks),
    Number.isFinite(clientSeq) ? clientSeq : 0,
  ];
  // card-rewards (WP8, C8 D23d): the typed applier locks the row and
  // reverses/re-applies card state; take the user's ingest lock first.
  if (config.syncTypedWritesEnabled && entity === 'transactions') {
    await client.query(`SELECT pg_advisory_xact_lock(hashtextextended($1::text, 0))`, [
      `transaction-ingest:${userId}`,
    ]);
  }
  const row = config.syncTypedWritesEnabled && entity === 'transactions'
    ? await ctx.applyTransactionSync(client, {
        userId, deviceId, entityId, op, payload, fieldClocks, clientSeq,
      })
    : (await client.query(
        config.syncTypedWritesEnabled
          ? `SELECT out_applied, out_conflicts, out_reason FROM pandapay.sync_apply_change_v2($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8)`
          : `SELECT out_applied, out_conflicts, out_reason FROM pandapay.sync_apply_change($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8)`,
        args,
      )).rows[0];
  // Offline transaction edits use this RPC rather than PATCH. Enforce
  // the same split invariant before accepting the item; a failure
  // rolls back the entire item, including its sync log/reward state.
  if (!config.syncTypedWritesEnabled && row.out_applied && entity === 'transactions' && payload?.amount_inr != null) {
    const splitCheck = await client.query(
      `SELECT t.amount_inr, COALESCE((SELECT SUM(s.amount_inr)
         FROM transaction_splits s WHERE s.transaction_id=t.id), 0) AS split_total
         FROM transactions t WHERE t.id=$1 AND t.profile_id=$2 FOR UPDATE`,
      [entityId, userId],
    );
    const checked = splitCheck.rows[0];
    if (checked && Math.round(Number(checked.split_total) * 100) > Math.round(Number(checked.amount_inr) * 100)) {
      throw Object.assign(new Error('amount is less than saved split shares; edit or clear the split first'), { code: 'SYNC_SPLIT_TOTAL_CONFLICT' });
    }
  }
  return row;
}

const defaultRegistry = createSyncPushHandlerRegistry();
defaultRegistry.register('user_categories', 'insert', applyUserCategoryInsert);
defaultRegistry.register('user_commitments', '*', documentHandler('sync_apply_user_commitment'));
defaultRegistry.register('user_merchant_category_rules', '*', documentHandler('sync_apply_user_merchant_category_rule'));
defaultRegistry.registerFallback(applyGenericChange, { usesFieldAllowlist: true });

/** Register a handler on the registry the /sync/push route uses. */
function registerSyncPushHandler(entity, ops, handler, options) {
  defaultRegistry.register(entity, ops, handler, options);
}

// ---------------------------------------------------------------------------
// Pipeline helpers
// ---------------------------------------------------------------------------

function createSyncPushContext({ userId, deviceId, config, applyTransactionSync, strict, rejectionDetail, registry, now }) {
  return {
    userId,
    deviceId,
    config,
    applyTransactionSync,
    strict: strict === true,
    rejectionDetail,
    registry: registry || defaultRegistry,
    now: typeof now === 'function' ? now : Date.now,
    allowedFieldsCache: new Map(),
  };
}

/** True when the device row exists for this profile (RLS also scopes it). */
async function syncDeviceExists(client, userId, deviceId) {
  const result = await client.query(
    'SELECT 1 FROM user_devices WHERE id = $1 AND profile_id = $2',
    [deviceId, userId],
  );
  return result.rows.length > 0;
}

/**
 * Pull and ack call SQL that raises 42501 for an unregistered device and used
 * to surface as HTTP 500. When that is the cause, answer
 * 409 {error:'device_not_registered'} so the client can re-register. Checked
 * after the failure (not before) so the successful path costs no extra query.
 * Returns true when it answered.
 */
async function respondUnknownSyncDevice({ withUserClient, userId, res, err, deviceId }) {
  if (err?.code !== '42501') return false;
  try {
    if (await withUserClient(userId, (client) => syncDeviceExists(client, userId, deviceId))) return false;
  } catch (_) {
    return false;
  }
  res.status(409).json({ error: 'device_not_registered' });
  return true;
}

/**
 * Clamp every field clock that is more than the tolerance ahead of `nowMs` to
 * `nowMs`. Returns the (possibly new) clocks and the clamped field names.
 */
function clampFieldClocks(fieldClocks, nowMs) {
  const limit = nowMs + SYNC_CLOCK_TOLERANCE_MS;
  const clamped = [];
  let adjusted = null;
  for (const [field, clock] of Object.entries(fieldClocks)) {
    if (clock > limit) {
      adjusted ||= { ...fieldClocks };
      adjusted[field] = nowMs;
      clamped.push(field);
    }
  }
  return { fieldClocks: adjusted || fieldClocks, clamped };
}

async function allowedFieldsFor(client, ctx, entity) {
  if (ctx.allowedFieldsCache.has(entity)) return ctx.allowedFieldsCache.get(entity);
  const result = await client.query('SELECT pandapay.sync_fields_for($1) AS fields', [entity]);
  const fields = result.rows[0]?.fields;
  const value = Array.isArray(fields) ? fields : null;
  ctx.allowedFieldsCache.set(entity, value);
  return value;
}

/**
 * Apply one validated push item inside its own savepoint and return its
 * response entry. Never throws for an item-level failure.
 */
async function processSyncPushItem(client, item, ctx) {
  const { entity, entityId, op, payload, clientSeq } = item;
  const base = { clientSeq: clientSeq ?? null, entityId };
  await client.query('SAVEPOINT sync_item');
  try {
    // Transaction status and deletion require the ordinary domain route,
    // whose reversal work cannot be replaced by a raw sync UPDATE/DELETE.
    if (entity === 'transactions' && (op === 'delete' || Object.hasOwn(payload, 'status'))) {
      throw Object.assign(new Error('Use the transaction status route'), { code: 'SYNC_TRANSACTION_DOMAIN_REQUIRED' });
    }
    const entry = ctx.registry.resolve(entity, op);

    let fieldClocks = item.fieldClocks;
    let clamped = [];
    let ignoredFields;
    if (ctx.strict) {
      ({ fieldClocks, clamped } = clampFieldClocks(fieldClocks, ctx.now()));
      if (entry.usesFieldAllowlist) {
        const allowed = await allowedFieldsFor(client, ctx, entity);
        if (allowed) {
          const keys = Object.keys(payload);
          ignoredFields = keys.filter((key) => !allowed.includes(key));
          if (op === 'update' && ignoredFields.length === keys.length) {
            await client.query('RELEASE SAVEPOINT sync_item');
            return { ...base, applied: false, conflicts: 0, reason: 'no_syncable_fields', ignoredFields };
          }
        }
      } else {
        ignoredFields = [];
      }
    }

    const row = await entry.handler(client, { ...item, fieldClocks }, ctx);
    await client.query('RELEASE SAVEPOINT sync_item');
    const result = {
      ...base,
      applied: row.out_applied,
      conflicts: row.out_conflicts,
      reason: row.out_reason,
    };
    if (ignoredFields !== undefined) result.ignoredFields = ignoredFields;
    if (clamped.length > 0) result.clampedClocks = clamped;
    return result;
  } catch (itemErr) {
    await client.query('ROLLBACK TO SAVEPOINT sync_item');
    if (isTransientDbError(itemErr)) {
      return { ...base, applied: false, reason: 'transient', detail: SYNC_TRANSIENT_DETAIL };
    }
    // Keep per-item rejection semantics while excluding PostgreSQL
    // messages, constraint names and submitted values from the response.
    return { ...base, applied: false, reason: 'rejected', detail: ctx.rejectionDetail(itemErr) };
  }
}

module.exports = {
  SYNC_CLOCK_TOLERANCE_MS,
  SYNC_TRANSIENT_DETAIL,
  createSyncPushHandlerRegistry,
  registerSyncPushHandler,
  createSyncPushContext,
  syncDeviceExists,
  respondUnknownSyncDevice,
  clampFieldClocks,
  processSyncPushItem,
};
