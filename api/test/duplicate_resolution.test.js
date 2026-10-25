const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
const start = source.indexOf("app.post('/duplicate-candidates/:id/resolve'");
const end = source.indexOf("app.patch('/transactions/:id'", start);
assert.ok(start >= 0 && end > start);
const register = new Function('app', 'requireAuth', 'withUserClient', 'DUPLICATE_RESOLUTIONS',
  'loadUserCardForState', 'applyTransactionState', 'reverseTransactionState', 'transactionTags', 'safeErrorCode',
  source.slice(start, end));
const id = (n) => `00000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
const smsA = id(1), smsB = id(2), statement = id(3), pairA = id(4), pairB = id(5);

function harness({ backfill = false, instrument = 'credit_card', missingCard = false, elsewhere = false, live = false } = {}) {
  const row = (txnId, status) => ({
    id: txnId, status, user_card_id: id(9), amount_inr: '505.00',
    occurred_at: '2026-10-02T17:41:00Z', category_id: null,
    rail: 'unknown', merchant_name: 'FLIPKART', instrument, entry_kind: 'spend',
    state_applied: status === 'active', is_backfill: backfill,
    source: txnId === statement ? 'statement' : live ? 'imported' : 'sms',
    note: status === 'ignored' ? `[pending duplicate of ${statement}] original note` : null,
  });
  let rows = new Map([row(smsA, 'ignored'), row(smsB, 'ignored'), row(statement, 'active')].map((r) => [r.id, r]));
  const pair = (pairId, a, b, suppressed) => ({ id: pairId, txn_a_id: a, txn_b_id: b, suppressed_txn_id: suppressed, state: 'pending' });
  let pairs = new Map([pair(pairA, smsA, statement, smsA), pair(pairB, smsB, statement, smsB)].map((p) => [p.id, p]));
  if (elsewhere) {
    rows.set(id(6), row(id(6), 'active'));
    pairs.set(id(7), pair(id(7), smsB, id(6), smsB));
  }
  let applied = [], reversed = [];
  const client = { query: async (sql, params) => {
    if (sql.includes('pg_advisory_xact_lock')) return { rows: [] };
    if (sql.includes('FROM duplicate_candidates WHERE id')) return { rows: pairs.has(params[0]) ? [{ ...pairs.get(params[0]) }] : [] };
    if (sql.includes('SELECT id, suppressed_txn_id FROM duplicate_candidates')) {
      return { rows: [...pairs.values()].filter((p) => p.state === 'pending' && p.id !== params[1] &&
        [p.txn_a_id, p.txn_b_id].includes(params[2])).map((p) => ({ ...p })) };
    }
    if (sql.includes('FROM transactions t')) {
      assert.match(sql, /FOR UPDATE/);
      assert.match(sql, /NOT \(d\.id = ANY\(\$3::uuid\[\]\)\)/);
      return { rows: params[1].filter((txnId) => rows.has(txnId)).map((txnId) => ({
        ...rows.get(txnId), suppressed_elsewhere: [...pairs.values()].some((p) =>
          p.state === 'pending' && p.suppressed_txn_id === txnId && !params[2].includes(p.id)),
      })) };
    }
    if (sql.includes("UPDATE transactions SET status = 'active'")) {
      Object.assign(rows.get(params[2]), { status: 'active', note: params[0], state_applied: params[1] });
      return { rows: [] };
    }
    if (sql.includes("UPDATE transactions SET status = 'ignored'")) {
      Object.assign(rows.get(params[1]), { status: 'ignored', note: params[0], state_applied: false });
      return { rows: [] };
    }
    if (sql.includes('UPDATE transaction_observations')) return { rows: [] };
    if (sql.includes('UPDATE duplicate_candidates') && sql.includes('ANY($2::uuid[])')) {
      for (const pairId of params[1]) Object.assign(pairs.get(pairId), { state: 'resolved', resolution: 'kept_both', suppressed_txn_id: null });
      return { rows: [] };
    }
    if (sql.includes('UPDATE duplicate_candidates')) {
      const p = pairs.get(params[1]);
      Object.assign(p, { state: 'resolved', resolution: params[0], suppressed_txn_id: null });
      return { rows: [{ ...p }] };
    }
    throw new Error(`Unexpected query: ${sql}`);
  } };
  let handler;
  register({ post: (_path, _auth, fn) => { handler = fn; } }, () => {},
    async (_user, fn) => {
      const before = structuredClone({ rows, pairs, applied, reversed });
      try { return await fn(client); } catch (error) {
        ({ rows, pairs, applied, reversed } = before);
        throw error;
      }
    }, ['merged', 'deleted_one', 'kept_both'],
    async (_client, _user, cardId) => missingCard ? null : { id: cardId },
    async (_client, _user, _card, args) => { applied.push(args.txnId); },
    async (_client, _user, _card, txn) => { reversed.push(txn.id); },
    { mergeTransactionTags: async () => {} }, require('../src/safeErrorCode').safeErrorCode);
  return {
    get rows() { return rows; }, get pairs() { return pairs; },
    get applied() { return applied; }, get reversed() { return reversed; },
    async resolve(resolution, keepTransactionId, candidateId = pairA) {
      const result = { status: 200 };
      await handler({ userId: id(8), params: { id: candidateId }, body: { resolution, keepTransactionId } }, {
        status(code) { result.status = code; return this; },
        json(body) { result.body = body; },
      });
      return result;
    },
  };
}

test('merging overlapping historical or live candidates restores the suppressed neighbor exactly once', async () => {
  for (const live of [false, true]) {
    for (const resolution of ['merged', 'deleted_one']) {
      const h = harness({ live });
      assert.equal((await h.resolve(resolution, smsA)).status, 200);
      assert.equal(h.rows.get(smsA).status, 'active');
      assert.equal(h.rows.get(smsB).status, 'active');
      assert.equal(h.rows.get(smsB).note, 'original note');
      assert.equal(h.rows.get(statement).status, 'ignored');
      assert.deepEqual(h.applied.sort(), [smsA, smsB]);
      assert.deepEqual(h.reversed, [statement]);
      assert.equal(h.pairs.get(pairB).state, 'resolved');
      assert.equal(h.pairs.get(pairB).suppressed_txn_id, null);
      assert.equal((await h.resolve(resolution, smsA)).status, 409);
      assert.equal(h.applied.length, 2);
    }
  }
});

test('keeping the statement or keeping both does not release an unrelated pending suppression', async () => {
  for (const [resolution, kept] of [['merged', statement], ['kept_both', undefined]]) {
    const h = harness();
    assert.equal((await h.resolve(resolution, kept)).status, 200);
    assert.equal(h.rows.get(smsB).status, 'ignored');
    assert.equal(h.pairs.get(pairB).state, 'pending');
  }
});

test('neighbor held by another pending candidate is restored only when the final suppression is resolved', async () => {
  const h = harness({ elsewhere: true });
  assert.equal((await h.resolve('merged', smsA)).status, 200);
  assert.equal(h.rows.get(smsB).status, 'ignored');
  assert.deepEqual(h.applied, [smsA]);
  assert.equal((await h.resolve('kept_both', undefined, id(7))).status, 200);
  assert.equal(h.rows.get(smsB).status, 'active');
  assert.deepEqual(h.applied, [smsA, smsB]);
});

test('backfills and non-credit neighbors reactivate without applying credit-card state', async () => {
  for (const options of [{ backfill: true }, { instrument: 'debit_card' }]) {
    const h = harness(options);
    assert.equal((await h.resolve('merged', smsA)).status, 200);
    assert.equal(h.rows.get(smsB).status, 'active');
    assert.deepEqual(h.applied, []);
  }
});

test('failed reactivation rolls back the decision and retains suppression markers', async () => {
  const h = harness({ missingCard: true });
  assert.equal((await h.resolve('merged', smsA)).status, 500);
  assert.equal(h.rows.get(statement).status, 'active');
  assert.equal(h.rows.get(smsB).status, 'ignored');
  assert.equal(h.pairs.get(pairB).state, 'pending');
  assert.equal(h.pairs.get(pairB).suppressed_txn_id, smsB);
});
