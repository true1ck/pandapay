const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { bestDuplicate, MAX_CROSS_SOURCE_CANDIDATE_MS } = require('../src/transaction_dedup');

// Exercise the history repair block against a transactional query fake. The
// API route wraps this block in withUserClient, so a failed reverse rolls back
// both the review record and the transaction status update.
const source = fs.readFileSync(require.resolve('../src/index.js'), 'utf8');
const start = source.indexOf('  let crossSourceCandidatesCreated = 0;');
const end = source.indexOf('  return {', start);
assert.ok(start >= 0 && end > start);
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const reconcileHistory = new AsyncFunction(
  'client', 'userId', 'reviewCrossSource', 'reviewCardId',
  'bestDuplicate', 'MAX_CROSS_SOURCE_CANDIDATE_MS',
  'loadUserCardForState', 'reverseTransactionState',
  `${source.slice(start, end)}\nreturn crossSourceCandidatesCreated;`,
);

const sms = {
  id: 'sms-row', amount_inr: '505.00',
  occurred_at: '2026-10-02T00:00:00.000Z',
  observed_at: '2026-10-02T17:41:37.000Z',
  merchant_name: null, source: 'sms', user_card_id: 'card-7105',
  instrument: 'credit_card', entry_kind: 'spend',
  source_account_last4: '7105', state_applied: true, is_backfill: false,
};
const statement = {
  id: 'statement-row', amount_inr: '505.00',
  occurred_at: '2026-10-02T17:41:00.000Z',
  merchant_name: 'FLIPKART', source: 'statement', user_card_id: 'card-7105',
  instrument: 'credit_card', entry_kind: 'spend',
  source_account_last4: '7105', state_applied: true, is_backfill: false,
};

function run(rows, { inserted = true, reviewCrossSource = true, reviewCardId = null, pendingIds = [] } = {}) {
  const writes = [];
  const reversals = [];
  const reads = [];
  const client = { query: async (sql, params) => {
    if (sql.includes('pg_advisory_xact_lock')) return { rows: [] };
    if (sql.includes('FROM transactions t') && sql.includes('LIMIT 5000')) {
      assert.match(sql, /ORDER BY t\.occurred_at DESC, t\.id/);
      assert.match(sql, /FOR UPDATE OF t/);
      assert.match(sql, /metadata->>'transactionTimeMillis'\s*=\s*\(extract\(epoch FROM t\.occurred_at\)/);
      assert.match(sql, /NOT EXISTS \([\s\S]*FROM duplicate_candidates d[\s\S]*d\.state = 'pending'[\s\S]*d\.txn_a_id = t\.id OR d\.txn_b_id = t\.id/);
      reads.push(params);
      return { rows: rows.filter((row) => !pendingIds.includes(row.id)) };
    }
    writes.push({ sql, params });
    if (sql.includes('INSERT INTO duplicate_candidates')) {
      return { rowCount: inserted ? 1 : 0, rows: inserted ? [{ id: 'review' }] : [] };
    }
    return { rowCount: 1, rows: [] };
  } };
  return reconcileHistory(
    client, 'profile', reviewCrossSource, reviewCardId,
    bestDuplicate, MAX_CROSS_SOURCE_CANDIDATE_MS,
    async () => ({ id: 'card-7105' }),
    async (...args) => { reversals.push(args); },
  ).then((created) => ({ created, writes, reversals, reads }));
}

test('routine SMS repair skips the account wide duplicate scan', async () => {
  const result = await run([sms, statement], { reviewCrossSource: false });
  assert.equal(result.created, 0);
  assert.equal(result.reads.length, 0);
});

test('card add limits historical review to the card just linked', async () => {
  const result = await run([sms, statement], { reviewCardId: 'card-7105' });
  assert.deepEqual(result.reads, [['profile', 'card-7105']]);
});

test('date-only SMS and same-card statement 37 seconds apart create one review and reverse SMS state', async () => {
  const { created, writes, reversals } = await run([sms, statement]);
  assert.equal(created, 1);
  assert.equal(reversals.length, 1);
  const insert = writes.find(({ sql }) => sql.includes('INSERT INTO duplicate_candidates'));
  assert.equal(insert.params[5], sms.id);
  assert.ok(writes.some(({ sql }) => sql.includes("SET status = 'ignored'")));
});

test('rerunning a reviewed pair preserves the earlier decision and card state', async () => {
  const { created, writes, reversals } = await run([sms, statement], { inserted: false });
  assert.equal(created, 0);
  assert.equal(reversals.length, 0);
  assert.equal(writes.length, 1);
  assert.match(writes[0].sql, /ON CONFLICT .* DO NOTHING/);
});

test('date-only SMS without a usable observation time cannot match a distant statement', async () => {
  const { created, writes } = await run([{ ...sms, observed_at: null }, statement]);
  assert.equal(created, 0);
  assert.equal(writes.length, 0);
});

test('missing SMS observation time falls back to a nearby stored transaction time', async () => {
  const { created } = await run([{
    ...sms, occurred_at: statement.occurred_at, observed_at: null,
  }, statement]);
  assert.equal(created, 1);
});

test('explicit swipe time can match despite delayed SMS delivery', async () => {
  const preciseSms = {
    ...sms, occurred_at: '2026-10-02T17:41:37.000Z',
    observed_at: '2026-10-02T18:30:00.000Z', transaction_time_precise: true,
    merchant_name: 'FLIPKART PA',
  };
  const { created } = await run([preciseSms, statement]);
  assert.equal(created, 1);
});

test('historical backfills create a review without reversing unapplied card state', async () => {
  const { created, reversals } = await run([{ ...sms, is_backfill: true, state_applied: null }, statement]);
  assert.equal(created, 1);
  assert.equal(reversals.length, 0);
});

test('historical matching reserves each statement for at most one SMS', async () => {
  const secondSms = { ...sms, id: 'second-sms', observed_at: '2026-10-02T17:45:00Z' };
  const result = await run([sms, secondSms, statement]);
  assert.equal(result.created, 1);
  assert.equal(result.reversals.length, 1);
  assert.equal(result.writes.filter(({ sql }) => sql.includes("SET status = 'ignored'")).length, 1);

  const twoStatements = await run([sms, secondSms, statement, { ...statement, id: 'second-statement' }]);
  assert.equal(twoStatements.created, 2);
  const pairs = twoStatements.writes.filter(({ sql }) => sql.includes('INSERT INTO duplicate_candidates'));
  assert.equal(new Set(pairs.flatMap(({ params }) => params.slice(1, 3))).size, 4);
});

test('historical reruns cannot reuse a row reserved by an existing pending candidate', async () => {
  const result = await run([sms, statement], { pendingIds: [statement.id] });
  assert.equal(result.created, 0);
  assert.equal(result.reversals.length, 0);
});
