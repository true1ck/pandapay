const test = require('node:test');
const assert = require('node:assert/strict');
const { validateSplits, splitTotalPaise } = require('../src/transaction_splits');
const { splitFingerprint, splitWriteDecision } = require('../src/transaction_splits');
const { registerSplitRoutes } = require('../src/transaction_splits');

function routes() {
  const handlers = {};
  const state = { rows: [], writes: 0, owned: true, queries: [] };
  const client = { async query(sql, args) {
    state.queries.push(sql);
    if (sql.includes('FROM transactions WHERE')) return { rows: state.owned ? [{ id: 't1', amount_inr: '1000' }] : [] };
    if (sql.includes('FROM transaction_splits ts')) return { rows: [...state.rows] };
    if (sql.startsWith('DELETE FROM transaction_splits')) { state.rows = []; state.writes++; return { rows: [] }; }
    if (sql.includes('INSERT INTO transaction_splits')) {
      state.rows.push({ id: String(state.rows.length), user_card_id: args[1], category_id: args[2], amount_inr: args[3], note: args[4] });
      state.writes++; return { rows: [] };
    }
    if (sql.includes('FROM user_cards') || sql.includes('FROM spend_categories')) return { rows: [] };
    throw Error(`Unexpected query: ${sql}`);
  } };
  registerSplitRoutes({
    get(path, auth, fn) { handlers.get = fn; }, put(path, auth, fn) { handlers.put = fn; },
  }, { requireAuth() {}, withUserClient: async (user, fn) => fn(client) });
  return { state, async call(method, body) {
    const res = { code: 200, status(code) { this.code = code; return this; }, json(value) { this.body = value; return this; } };
    await handlers[method]({ params: { id: 't1' }, userId: 'owner', body }, res);
    return res;
  } };
}

test('route contract: read, conditional save, lost-response retry and clear', async () => {
  const r = routes();
  const initial = await r.call('get');
  assert.equal(initial.body.fingerprint, splitFingerprint([]));
  const saved = await r.call('put', { splits: [{ amountInr: 33.34 }], expectedFingerprint: initial.body.fingerprint });
  assert.equal(saved.code, 200);
  assert.ok(r.state.queries.some((q) => q.includes('FOR UPDATE')));
  const writes = r.state.writes;
  const retry = await r.call('put', { splits: [{ amountInr: 33.34 }], expectedFingerprint: initial.body.fingerprint });
  assert.equal(retry.code, 200); assert.equal(r.state.writes, writes);
  const conflict = await r.call('put', { splits: [{ amountInr: 50 }], expectedFingerprint: initial.body.fingerprint });
  assert.equal(conflict.code, 409); assert.equal(r.state.writes, writes);
  const cleared = await r.call('put', { splits: [], expectedFingerprint: saved.body.fingerprint });
  assert.equal(cleared.code, 200); assert.deepEqual(cleared.body.splits, []);
});

test('route contract: rejects ownership, totals and references before replacement', async () => {
  const r = routes();
  r.state.owned = false;
  assert.equal((await r.call('get')).code, 404);
  assert.equal((await r.call('put', { splits: [{ amountInr: 10 }] })).code, 404);
  r.state.owned = true;
  assert.equal((await r.call('put', { splits: [{ amountInr: 1000.01 }] })).code, 400);
  assert.equal((await r.call('put', { splits: [{ amountInr: 10, userCardId: '00000000-0000-0000-0000-000000000001' }] })).code, 400);
  assert.equal(r.state.writes, 0);
});

test('fingerprints ignore row IDs, ordering and display names', () => {
  const stored = [{ id: '1', amount_inr: '12.34', note: 'Priya', category_name: 'Other' },
    { id: '2', amount_inr: '5.00', note: null }];
  const desired = [{ amountInr: 5 }, { amountInr: 12.34, note: 'Priya' }];
  assert.equal(splitFingerprint(stored), splitFingerprint(desired));
  assert.equal(splitWriteDecision(stored, desired, splitFingerprint([])), 'unchanged');
  assert.equal(splitWriteDecision(stored, [], splitFingerprint([])), 'conflict');
  assert.equal(splitWriteDecision(stored, [], splitFingerprint(stored)), 'write');
  assert.equal(splitFingerprint([]), '4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945');
});

test('accepts clearing, partial shares and exact decimal partitions', () => {
  assert.equal(validateSplits([]), null);
  const shares = Array.from({ length: 3 }, () => ({ amountInr: 33.34, note: 'Share' }));
  assert.equal(validateSplits(shares), null);
  assert.equal(splitTotalPaise(shares), 10002);
  assert.equal(validateSplits([{ amountInr: 0.29 }]), null);
});

test('rejects malformed and sub-paise shares before database writes', () => {
  for (const share of [null, [], {}, { amountInr: true }, { amountInr: '10' },
    { amountInr: 0 }, { amountInr: -1 }, { amountInr: NaN },
    { amountInr: 0.001 }, { amountInr: 1.005 }, { amountInr: Infinity },
    { amountInr: 10, userCardId: 'other-card' }, { amountInr: 10, note: 12 }]) {
    assert.ok(validateSplits([share]));
  }
  assert.ok(validateSplits(Array.from({ length: 21 }, () => ({ amountInr: 1 }))));
});
