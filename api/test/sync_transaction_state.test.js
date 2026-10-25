'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  SYNC_TRANSACTION_RPC_SQL,
  REWARD_INPUT_FIELDS,
  createSyncTransactionApplier,
} = require('../src/sync_transaction_state');

const PROFILE = '10000000-0000-4000-8000-000000000001';
const DEVICE = '20000000-0000-4000-8000-000000000001';
const TXN = '30000000-0000-4000-8000-000000000001';
const CARD_OLD = '40000000-0000-4000-8000-000000000001';
const CARD_NEW = '40000000-0000-4000-8000-000000000002';
const CAT_OLD = '50000000-0000-4000-8000-000000000001';
const CAT_NEW = '50000000-0000-4000-8000-000000000002';
const USER_CAT_OLD = '60000000-0000-4000-8000-000000000001';
const USER_CAT_NEW = '60000000-0000-4000-8000-000000000002';

function row(overrides = {}) {
  return {
    id: TXN,
    profile_id: PROFILE,
    user_card_id: CARD_OLD,
    amount_inr: '100.00',
    occurred_at: new Date('2026-01-01T12:00:00.000Z'),
    category_id: CAT_OLD,
    user_category_id: null,
    merchant_name: 'Store',
    merchant_vpa: null,
    mcc: null,
    rail: 'card',
    status: 'active',
    instrument: 'credit_card',
    entry_kind: 'spend',
    state_applied: true,
    is_backfill: false,
    ...overrides,
  };
}

function fixture({ before = row(), after = row(), rpcRow = { out_applied: true, out_conflicts: 0, out_reason: null }, splitTotal = '0', userCategories = {} } = {}) {
  const calls = [];
  const events = [];
  const client = {
    async query(sql, args = []) {
      calls.push({ sql, args });
      if (sql.includes('FOR UPDATE')) return { rows: before ? [before] : [] };
      if (sql.includes('pandapay.sync_apply_change_v2')) return { rows: rpcRow ? [rpcRow] : [] };
      if (sql.includes('WITH RECURSIVE category_chain')) {
        let id = args[0];
        const seen = new Set();
        for (let depth = 0; depth <= 32; depth += 1) {
          if (seen.has(id)) return { rows: [{ parent_category_id: null, chain_complete: false }] };
          seen.add(id);
          const raw = userCategories[id];
          if (raw === undefined) {
            return depth === 0
              ? { rows: [] }
              : { rows: [{ parent_category_id: null, chain_complete: false }] };
          }
          const node = typeof raw === 'string'
            ? { parent_category_id: raw, parent_user_category_id: null }
            : raw;
          if (node.parent_category_id) {
            return { rows: [{ parent_category_id: node.parent_category_id, chain_complete: true }] };
          }
          if (!node.parent_user_category_id) {
            return { rows: [{ parent_category_id: null, chain_complete: true }] };
          }
          if (depth === 32) return { rows: [{ parent_category_id: null, chain_complete: false }] };
          id = node.parent_user_category_id;
        }
        return { rows: [{ parent_category_id: null, chain_complete: false }] };
      }
      if (sql.includes('FROM transactions') && sql.includes('WHERE id = $1 AND profile_id = $2')) {
        return { rows: after ? [after] : [] };
      }
      if (sql.includes('FROM transaction_splits')) return { rows: [{ split_total: splitTotal }] };
      if (sql.includes('UPDATE transactions SET state_applied = true')) return { rows: [], rowCount: 1 };
      throw new Error(`unexpected query: ${sql}`);
    },
  };
  const applier = createSyncTransactionApplier({
    async loadUserCardForState(_client, userId, userCardId) {
      events.push(['load-card', userId, userCardId]);
      return { id: userCardId };
    },
    async reverseTransactionState(_client, userId, card, txn) {
      events.push(['reverse', userId, card.id, txn.amount_inr, txn.category_id]);
    },
    async applyTransactionState(_client, userId, card, state) {
      events.push(['apply', userId, card.id, state.amount, state.categoryId, state.sign]);
    },
    async userCardMatchesInstrument(_client, userId, userCardId, instrument) {
      events.push(['match-card', userId, userCardId, instrument]);
      return true;
    },
  });
  return { calls, events, client, applier };
}

function input(patch = {}) {
  return {
    userId: PROFILE,
    deviceId: DEVICE,
    entityId: TXN,
    op: 'update',
    payload: { amount_inr: 120 },
    fieldClocks: { amount_inr: 1792920000000 },
    clientSeq: 17,
    ...patch,
  };
}

test('uses only the fixed, fully-qualified typed transaction RPC and preserves its row shape', async () => {
  const f = fixture();
  const result = await f.applier(f.client, input());
  assert.deepEqual(result, { out_applied: true, out_conflicts: 0, out_reason: null });
  const rpc = f.calls.find((call) => call.sql.includes('pandapay.sync_apply_change_v2'));
  assert.equal(rpc.sql, SYNC_TRANSACTION_RPC_SQL);
  assert.deepEqual(rpc.args, [
    PROFILE, DEVICE, 'transactions', TXN, 'update',
    JSON.stringify({ amount_inr: 120 }), JSON.stringify({ amount_inr: 1792920000000 }), 17,
  ]);
  assert.equal(rpc.args[2], 'transactions');
  assert.equal(REWARD_INPUT_FIELDS.includes('amount_inr'), true);
});

test('stale-clock wins, same-value retries, and note-only writes do no reward-state work', async () => {
  const same = row({ amount_inr: '100.00' });
  const f = fixture({ after: same, rpcRow: { out_applied: true, out_conflicts: 1, out_reason: null } });
  await f.applier(f.client, input({ payload: { amount_inr: 80 } }));
  assert.deepEqual(f.events, []);
  assert.equal(f.calls.some((call) => call.sql.includes('transaction_splits')), false);

  const noteOnly = fixture({ after: row({ amount_inr: '100.00' }) });
  await noteOnly.applier(noteOnly.client, input({ payload: { note: 'new note' } }));
  assert.deepEqual(noteOnly.events, []);
});

test('effective financial edit reverses old state and reapplies final stored values', async () => {
  const f = fixture({
    before: row(),
    after: row({ amount_inr: '120.00', category_id: CAT_NEW, user_card_id: CARD_NEW }),
  });
  await f.applier(f.client, input());
  assert.deepEqual(f.events, [
    ['load-card', PROFILE, CARD_OLD],
    ['load-card', PROFILE, CARD_NEW],
    ['match-card', PROFILE, CARD_NEW, 'credit_card'],
    ['reverse', PROFILE, CARD_OLD, '100.00', CAT_OLD],
    ['apply', PROFILE, CARD_NEW, 120, CAT_NEW, 1],
  ]);
  assert.equal(f.calls.at(-1).sql.includes('state_applied = true'), true);
});

test('private category edits calculate rewards from owned public parents without rewriting stored payload values', async () => {
  const before = row({ category_id: null, user_category_id: USER_CAT_OLD });
  const after = row({ amount_inr: '120.00', category_id: null, user_category_id: USER_CAT_NEW });
  const f = fixture({
    before,
    after,
    userCategories: { [USER_CAT_OLD]: CAT_OLD, [USER_CAT_NEW]: CAT_NEW },
  });
  await f.applier(f.client, input({
    payload: { amount_inr: 120, category_id: null, user_category_id: USER_CAT_NEW },
  }));
  const reverse = f.events.find(([kind]) => kind === 'reverse');
  const apply = f.events.find(([kind]) => kind === 'apply');
  assert.equal(reverse[4], CAT_OLD);
  assert.equal(apply[4], CAT_NEW);
  const rpc = f.calls.find((call) => call.sql.includes('pandapay.sync_apply_change_v2'));
  assert.equal(rpc.args[5], JSON.stringify({ amount_inr: 120, category_id: null, user_category_id: USER_CAT_NEW }));
});

test('nested private category resolves through owned ancestors to its public reward category', async () => {
  const nested = '60000000-0000-4000-8000-000000000003';
  const parentPrivate = '60000000-0000-4000-8000-000000000004';
  const after = row({ amount_inr: '120.00', category_id: null, user_category_id: nested });
  const f = fixture({
    after,
    userCategories: {
      [nested]: { parent_category_id: null, parent_user_category_id: parentPrivate },
      [parentPrivate]: CAT_NEW,
    },
  });
  await f.applier(f.client, input({ payload: { amount_inr: 120, user_category_id: nested } }));
  assert.equal(f.events.find(([kind]) => kind === 'apply')[4], CAT_NEW);
});

test('explicit stored public category keeps PATCH precedence over private parent', async () => {
  const after = row({ amount_inr: '120.00', category_id: CAT_NEW, user_category_id: USER_CAT_NEW });
  const f = fixture({ after, userCategories: { [USER_CAT_NEW]: CAT_OLD } });
  await f.applier(f.client, input());
  assert.equal(f.events.find(([kind]) => kind === 'apply')[4], CAT_NEW);
});

test('missing owned user category parent rejects before any state work', async () => {
  const after = row({ amount_inr: '120.00', category_id: null, user_category_id: USER_CAT_NEW });
  const f = fixture({ after });
  await assert.rejects(f.applier(f.client, input()), { code: 'SYNC_TRANSACTION_USER_CATEGORY_UNAVAILABLE' });
  assert.equal(f.events.some(([kind]) => kind === 'reverse' || kind === 'apply'), false);
});

test('cyclic and over-depth private category parent chains reject before state work', async () => {
  const cycleA = '60000000-0000-4000-8000-000000000005';
  const cycleB = '60000000-0000-4000-8000-000000000006';
  const cycleAfter = row({ amount_inr: '120.00', category_id: null, user_category_id: cycleA });
  const cyclic = fixture({
    after: cycleAfter,
    userCategories: {
      [cycleA]: { parent_category_id: null, parent_user_category_id: cycleB },
      [cycleB]: { parent_category_id: null, parent_user_category_id: cycleA },
    },
  });
  await assert.rejects(cyclic.applier(cyclic.client, input()), { code: 'SYNC_TRANSACTION_USER_CATEGORY_UNAVAILABLE' });
  assert.equal(cyclic.events.some(([kind]) => kind === 'reverse' || kind === 'apply'), false);

  const longChain = {};
  for (let index = 0; index <= 32; index += 1) {
    const id = `70000000-0000-4000-8000-${String(index).padStart(12, '0')}`;
    const next = `70000000-0000-4000-8000-${String(index + 1).padStart(12, '0')}`;
    longChain[id] = { parent_category_id: null, parent_user_category_id: next };
  }
  const longStart = '70000000-0000-4000-8000-000000000000';
  const tooDeep = fixture({
    after: row({ amount_inr: '120.00', category_id: null, user_category_id: longStart }),
    userCategories: longChain,
  });
  await assert.rejects(tooDeep.applier(tooDeep.client, input()), { code: 'SYNC_TRANSACTION_USER_CATEGORY_UNAVAILABLE' });
  assert.equal(tooDeep.events.some(([kind]) => kind === 'reverse' || kind === 'apply'), false);
});

test('suppressed old state is not reversed, but a non-backfill final spend is applied', async () => {
  const f = fixture({
    before: row({ state_applied: false }),
    after: row({ amount_inr: '120.00', state_applied: false }),
  });
  await f.applier(f.client, input());
  assert.equal(f.events.some(([kind]) => kind === 'reverse'), false);
  assert.equal(f.events.some(([kind]) => kind === 'apply'), true);
});

test('instrument and entry-kind transition reverses the old card spend without applying a cash transfer', async () => {
  const f = fixture({
    before: row(),
    after: row({ amount_inr: '100.00', instrument: 'cash', entry_kind: 'transfer', user_card_id: null }),
  });
  await f.applier(f.client, input({
    payload: { instrument: 'cash', entry_kind: 'transfer', user_card_id: null },
  }));
  assert.equal(f.events.some(([kind]) => kind === 'reverse'), true);
  assert.equal(f.events.some(([kind]) => kind === 'apply'), false);
  assert.equal(f.calls.at(-1).sql.includes('state_applied = true'), true);
});

test('backfilled edit validates card but leaves derived reward state untouched', async () => {
  const f = fixture({
    before: row({ is_backfill: true, state_applied: false }),
    after: row({ amount_inr: '120.00', is_backfill: true, state_applied: false }),
  });
  await f.applier(f.client, input());
  assert.equal(f.events.some(([kind]) => kind === 'reverse' || kind === 'apply'), false);
  assert.equal(f.calls.some((call) => call.sql.includes('state_applied = true')), false);
});

test('missing transaction is delegated to SQL and preserves not_found', async () => {
  const expected = { out_applied: false, out_conflicts: 0, out_reason: 'not_found' };
  const f = fixture({ before: null, after: null, rpcRow: expected });
  assert.deepEqual(await f.applier(f.client, input()), expected);
  assert.equal(f.calls.filter((call) => call.sql.includes('pandapay.sync_apply_change_v2')).length, 1);
  assert.equal(f.calls.some((call) => call.sql.includes('transaction_splits')), false);
});

test('split guard uses final stored amount and rejects over-allocation before state calls', async () => {
  const f = fixture({ after: row({ amount_inr: '20.00' }), splitTotal: '20.01' });
  await assert.rejects(f.applier(f.client, input()), { code: 'SYNC_SPLIT_TOTAL_CONFLICT' });
  assert.deepEqual(f.events, []);

  // A rejected stale amount did not change the stored amount, so it does not
  // spuriously fail an existing split invariant.
  const stale = fixture({ after: row({ amount_inr: '100.00' }), splitTotal: '100.01' });
  await stale.applier(stale.client, input());
  assert.equal(stale.calls.some((call) => call.sql.includes('transaction_splits')), false);
});

test('invalid card ownership, archive state, type, or missing credit card aborts before reversal', async () => {
  const archived = fixture({ after: row({ amount_inr: '120.00', user_card_id: CARD_NEW }) });
  archived.applier = createSyncTransactionApplier({
    async loadUserCardForState(_client, _userId, cardId) { return cardId === CARD_OLD ? { id: CARD_OLD } : null; },
    async reverseTransactionState() { archived.events.push(['reverse']); },
    async applyTransactionState() { archived.events.push(['apply']); },
    async userCardMatchesInstrument() { return true; },
  });
  await assert.rejects(archived.applier(archived.client, input()), { code: 'SYNC_TRANSACTION_CARD_UNAVAILABLE' });
  assert.deepEqual(archived.events, []);

  const incompatible = fixture({ after: row({ amount_inr: '120.00', user_card_id: CARD_NEW }) });
  incompatible.applier = createSyncTransactionApplier({
    async loadUserCardForState(_client, _userId, id) { return { id }; },
    async reverseTransactionState() { incompatible.events.push(['reverse']); },
    async applyTransactionState() { incompatible.events.push(['apply']); },
    async userCardMatchesInstrument() { return false; },
  });
  await assert.rejects(incompatible.applier(incompatible.client, input()), { code: 'SYNC_TRANSACTION_CARD_INCOMPATIBLE' });
  assert.deepEqual(incompatible.events, []);

  const missing = fixture({ after: row({ amount_inr: '120.00', user_card_id: null }) });
  await assert.rejects(missing.applier(missing.client, input()), { code: 'SYNC_TRANSACTION_CARD_REQUIRED' });
});

test('rejects inactive financial edits, transaction deletes, status writes, and non-card card references', async () => {
  const inactive = fixture({
    before: row({ status: 'ignored' }),
    after: row({ amount_inr: '120.00', status: 'ignored' }),
  });
  await assert.rejects(inactive.applier(inactive.client, input()), { code: 'SYNC_TRANSACTION_NOT_ACTIVE' });
  assert.equal(inactive.events.length, 0);

  const deletion = fixture();
  await assert.rejects(deletion.applier(deletion.client, input({ op: 'delete' })), { code: 'SYNC_TRANSACTION_DELETE_UNSUPPORTED' });
  assert.equal(deletion.calls.length, 0);

  const status = fixture();
  await assert.rejects(status.applier(status.client, input({ payload: { status: 'ignored' } })), { code: 'SYNC_TRANSACTION_STATUS_FORBIDDEN' });
  assert.equal(status.calls.length, 0);

  const noncard = fixture({ after: row({ amount_inr: '120.00', instrument: 'cash' }) });
  await assert.rejects(noncard.applier(noncard.client, input()), { code: 'SYNC_TRANSACTION_CARD_FOR_NONCARD' });
  assert.equal(noncard.events.length, 0);
});

test('propagates state-core failures so the caller can roll back its item savepoint', async () => {
  const f = fixture({ after: row({ amount_inr: '120.00' }) });
  f.applier = createSyncTransactionApplier({
    async loadUserCardForState(_client, _userId, id) { return { id }; },
    async reverseTransactionState() { throw Object.assign(new Error('core failed'), { code: 'TEST_CORE_FAILURE' }); },
    async applyTransactionState() {},
    async userCardMatchesInstrument() { return true; },
  });
  await assert.rejects(f.applier(f.client, input()), { code: 'TEST_CORE_FAILURE' });
});

test('prototype property names cannot select alternate SQL', async () => {
  for (const rpcName of ['toString', '__proto__']) {
    const f = fixture();
    await f.applier(f.client, input({ rpcName }));
    assert.equal(f.calls.find((call) => call.sql.includes('pandapay.sync_apply_change_v2')).sql, SYNC_TRANSACTION_RPC_SQL);
  }
});
