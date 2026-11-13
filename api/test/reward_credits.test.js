'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { creditRewardFacts, CREDIT_SQL, ISSUER_CREDIT_REASON } = require('../src/reward_credits');

function fakeClient({ failOn = null, rowCount = 1 } = {}) {
  const calls = [];
  return {
    calls,
    async query(sql, params) {
      calls.push({ sql, params });
      if (failOn && sql.includes(failOn)) {
        const err = new Error('boom');
        err.code = '42P01';
        throw err;
      }
      return { rowCount, rows: [] };
    },
  };
}

test('an empty fact list writes nothing and runs no query', async () => {
  const client = fakeClient();
  assert.equal(await creditRewardFacts(client, 'p1', { factIds: [] }), 0);
  assert.equal(client.calls.length, 0);
});

test('credits are written confirmed, once per fact, from the fact id', () => {
  assert.match(CREDIT_SQL, /'confirmed'/);
  assert.match(CREDIT_SQL, /md5\('reward-credit:' \|\| f\.source_key \|\| ':' \|\| \(a\.value->>'minor'\)\)::uuid/, 'key = SMS identity + amount, so a re-read under a new rule id never doubles it');
  assert.doesNotMatch(CREDIT_SQL, /md5\([^)]*fact_id/, 'never keyed by the fact id');
  assert.match(CREDIT_SQL, /ON CONFLICT \(profile_id, client_mutation_id\) WHERE client_mutation_id IS NOT NULL DO NOTHING/);
  assert.match(CREDIT_SQL, /i\.user_card_id IS NOT NULL/, 'only for a linked card');
  assert.match(CREDIT_SQL, /a\.value->>'role' = 'points_earned'/);
  assert.match(CREDIT_SQL, /CASE WHEN \(a\.value->>'minor'\) ~ '\^\[0-9\]\+\$' THEN/, 'the numeric check and the cast are in one CASE: SQL does not promise AND order');
});

test('passes the profile, the fact ids, the reason and the optional card', async () => {
  const client = fakeClient({ rowCount: 2 });
  const added = await creditRewardFacts(client, 'p1', { factIds: ['f1', 'f2'], userCardId: 'c1' });
  assert.equal(added, 2);
  const run = client.calls.find((c) => c.sql.includes('INSERT INTO points_ledger'));
  assert.deepEqual(run.params, ['p1', ['f1', 'f2'], ISSUER_CREDIT_REASON, 'c1']);
  assert.equal(client.calls[0].sql, 'SAVEPOINT reward_credits');
  assert.equal(client.calls[client.calls.length - 1].sql, 'RELEASE SAVEPOINT reward_credits');
});

test('no fact ids means a sweep of the profile (null filter), narrowed to one card when given', async () => {
  const client = fakeClient();
  await creditRewardFacts(client, 'p1', { userCardId: 'c9' });
  const run = client.calls.find((c) => c.sql.includes('INSERT INTO points_ledger'));
  assert.deepEqual(run.params, ['p1', null, ISSUER_CREDIT_REASON, 'c9']);
});

test('a failure rolls back to the savepoint and never throws', async () => {
  const client = fakeClient({ failOn: 'INSERT INTO points_ledger' });
  const added = await creditRewardFacts(client, 'p1', { factIds: ['f1'] });
  assert.equal(added, 0);
  assert.ok(client.calls.some((c) => c.sql === 'ROLLBACK TO SAVEPOINT reward_credits'));
  assert.equal(client.calls[client.calls.length - 1].sql, 'RELEASE SAVEPOINT reward_credits');
});
