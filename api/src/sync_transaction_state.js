'use strict';

const SYNC_TRANSACTION_RPC_SQL = `SELECT out_applied, out_conflicts, out_reason
  FROM pandapay.sync_apply_change_v2($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb, $8)`;

const REWARD_INPUT_FIELDS = Object.freeze([
  'amount_inr',
  'occurred_at',
  'user_card_id',
  'category_id',
  'user_category_id',
  'merchant_name',
  'rail',
  'instrument',
  'entry_kind',
]);

function taggedError(code) {
  return Object.assign(new Error('sync transaction change rejected'), { code });
}

function sameUuid(left, right) {
  if (left == null || right == null) return left == null && right == null;
  return String(left).toLowerCase() === String(right).toLowerCase();
}

function amountCents(value) {
  const text = String(value);
  const match = /^(-?)(\d+)(?:\.(\d{1,2}))?$/.exec(text);
  if (!match) throw taggedError('SYNC_TRANSACTION_AMOUNT_INVALID');
  const cents = BigInt(match[2]) * 100n + BigInt((match[3] || '').padEnd(2, '0') || '0');
  return match[1] === '-' ? -cents : cents;
}

function timestampMillis(value) {
  if (value == null) return null;
  const millis = value instanceof Date ? value.getTime() : new Date(value).getTime();
  if (!Number.isFinite(millis)) throw taggedError('SYNC_TRANSACTION_DATE_INVALID');
  return millis;
}

function sameField(field, left, right) {
  if (field === 'amount_inr') return amountCents(left) === amountCents(right);
  if (field === 'occurred_at') return timestampMillis(left) === timestampMillis(right);
  if (field === 'user_card_id' || field === 'category_id' || field === 'user_category_id') {
    return sameUuid(left, right);
  }
  return left === right;
}

function changedRewardInputs(before, after) {
  const changed = new Set();
  for (const field of REWARD_INPUT_FIELDS) {
    if (!sameField(field, before[field], after[field])) changed.add(field);
  }
  return changed;
}

function movesCardState(row) {
  return row.instrument === 'credit_card' && row.entry_kind === 'spend' && Boolean(row.user_card_id);
}

function normalizeClientSeq(value) {
  return Number.isSafeInteger(value) && value >= 0 ? value : 0;
}

function isCardInstrument(instrument) {
  return instrument === 'credit_card' || instrument === 'debit_card';
}

function createSyncTransactionApplier({
  loadUserCardForState,
  reverseTransactionState,
  applyTransactionState,
  userCardMatchesInstrument,
}) {
  for (const [name, fn] of Object.entries({
    loadUserCardForState,
    reverseTransactionState,
    applyTransactionState,
    userCardMatchesInstrument,
  })) {
    if (typeof fn !== 'function') throw new TypeError(`${name} must be a function`);
  }

  return async function apply(client, {
    userId,
    deviceId,
    entityId,
    op,
    payload,
    fieldClocks,
    clientSeq,
  }) {
    if (op === 'delete') throw taggedError('SYNC_TRANSACTION_DELETE_UNSUPPORTED');
    if (payload && Object.prototype.hasOwnProperty.call(payload, 'status')) {
      throw taggedError('SYNC_TRANSACTION_STATUS_FORBIDDEN');
    }

    const beforeResult = await client.query(
      `SELECT id, profile_id, user_card_id, amount_inr, occurred_at,
              category_id, user_category_id, merchant_name, merchant_vpa,
              mcc, rail, status, instrument, entry_kind, state_applied,
              is_backfill
         FROM transactions
        WHERE id = $1 AND profile_id = $2
        FOR UPDATE`,
      [entityId, userId],
    );
    const before = beforeResult.rows[0] || null;

    // A missing row is deliberately delegated to the RPC so callers retain
    // its established {out_applied, out_conflicts, out_reason} result.
    const rpcResult = await client.query(SYNC_TRANSACTION_RPC_SQL, [
      userId,
      deviceId,
      'transactions',
      entityId,
      op,
      JSON.stringify(payload || {}),
      JSON.stringify(fieldClocks || {}),
      normalizeClientSeq(clientSeq),
    ]);
    const result = rpcResult.rows[0];
    if (!result || !result.out_applied || !before) return result;

    const afterResult = await client.query(
      `SELECT id, profile_id, user_card_id, amount_inr, occurred_at,
              category_id, user_category_id, merchant_name, merchant_vpa,
              mcc, rail, status, instrument, entry_kind, state_applied,
              is_backfill
         FROM transactions
        WHERE id = $1 AND profile_id = $2`,
      [entityId, userId],
    );
    const after = afterResult.rows[0];
    if (!after) throw taggedError('SYNC_TRANSACTION_ROW_MISSING');

    const changed = changedRewardInputs(before, after);
    if (changed.size === 0) return result;

    if (before.status !== 'active' || after.status !== 'active') {
      throw taggedError('SYNC_TRANSACTION_NOT_ACTIVE');
    }

    if (changed.has('amount_inr')) {
      const sharesResult = await client.query(
        `SELECT COALESCE(SUM(amount_inr), 0) AS split_total
           FROM transaction_splits
          WHERE transaction_id = $1`,
        [entityId],
      );
      const splitTotal = sharesResult.rows[0]?.split_total ?? '0';
      if (amountCents(splitTotal) > amountCents(after.amount_inr)) {
        throw taggedError('SYNC_SPLIT_TOTAL_CONFLICT');
      }
    }

    const beforeCategory = await effectiveRewardCategory(client, userId, before);
    const afterCategory = await effectiveRewardCategory(client, userId, after);
    // Match PATCH /transactions/:id's precedence: an explicit public
    // category_id wins; otherwise use the owned private category's public
    // parent. This is computation-only so the typed RPC's accepted payload,
    // stored category_id, and field-clock history remain untouched.
    const beforeForState = beforeCategory === before.category_id
      ? before
      : { ...before, category_id: beforeCategory };
    const afterForState = afterCategory === after.category_id
      ? after
      : { ...after, category_id: afterCategory };

    if (after.instrument === 'credit_card' && !after.user_card_id) {
      throw taggedError('SYNC_TRANSACTION_CARD_REQUIRED');
    }
    if (!isCardInstrument(after.instrument) && after.user_card_id) {
      throw taggedError('SYNC_TRANSACTION_CARD_FOR_NONCARD');
    }

    let oldCard = null;
    if (movesCardState(before) && before.state_applied !== false) {
      oldCard = await loadUserCardForState(client, userId, before.user_card_id);
      if (!oldCard) throw taggedError('SYNC_TRANSACTION_OLD_CARD_UNAVAILABLE');
    }

    let newCard = null;
    if (after.user_card_id) {
      newCard = await loadUserCardForState(client, userId, after.user_card_id);
      if (!newCard) throw taggedError('SYNC_TRANSACTION_CARD_UNAVAILABLE');
      if (isCardInstrument(after.instrument) &&
          !(await userCardMatchesInstrument(client, userId, after.user_card_id, after.instrument))) {
        throw taggedError('SYNC_TRANSACTION_CARD_INCOMPATIBLE');
      }
    }

    if (oldCard) await reverseTransactionState(client, userId, oldCard, beforeForState);

    if (!after.is_backfill && movesCardState(after)) {
      if (!newCard) throw taggedError('SYNC_TRANSACTION_CARD_REQUIRED');
      await applyTransactionState(client, userId, newCard, {
        txnId: after.id,
        userCardId: after.user_card_id,
        amount: Number(after.amount_inr),
        occurred: after.occurred_at,
        categoryId: afterForState.category_id,
        merchantName: after.merchant_name,
        rail: after.rail,
        sign: 1,
      });
    }

    if (!after.is_backfill) {
      await client.query(
        `UPDATE transactions SET state_applied = true
          WHERE id = $1 AND profile_id = $2`,
        [entityId, userId],
      );
    }

    return result;
  };
}

async function effectiveRewardCategory(client, userId, row) {
  if (!row.user_category_id) return row.category_id ?? null;
  const parentResult = await client.query(
    `WITH RECURSIVE category_chain AS (
       SELECT id, parent_category_id, parent_user_category_id,
              ARRAY[id]::uuid[] AS path, 0 AS depth
         FROM user_categories
        WHERE id = $1 AND profile_id = $2
       UNION ALL
       SELECT parent.id, parent.parent_category_id, parent.parent_user_category_id,
              child.path || parent.id, child.depth + 1
         FROM category_chain child
         JOIN user_categories parent
           ON parent.id = child.parent_user_category_id
          AND parent.profile_id = $2
        WHERE child.parent_user_category_id IS NOT NULL
          AND child.depth < 32
          AND NOT (parent.id = ANY(child.path))
     )
     SELECT
       (SELECT parent_category_id
          FROM category_chain
         WHERE parent_category_id IS NOT NULL
         ORDER BY depth
         LIMIT 1) AS parent_category_id,
       (SELECT parent_user_category_id IS NULL
          FROM category_chain
         ORDER BY depth DESC
         LIMIT 1) AS chain_complete`,
    [row.user_category_id, userId],
  );
  if (parentResult.rows.length === 0 || parentResult.rows[0].chain_complete !== true) {
    throw taggedError('SYNC_TRANSACTION_USER_CATEGORY_UNAVAILABLE');
  }
  return row.category_id || parentResult.rows[0].parent_category_id || null;
}

module.exports = {
  SYNC_TRANSACTION_RPC_SQL,
  REWARD_INPUT_FIELDS,
  createSyncTransactionApplier,
};
