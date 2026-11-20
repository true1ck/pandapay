'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

process.env.NODE_ENV = 'test';
process.env.API_DATABASE_URL = 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET = 'worker-test-jwt-secret';

const { createRewardsWorker, safeErrorCode } = require('../src/rewards_worker');

const event = {
  id: '8e8a2f46-e817-487f-ab55-8bbccb064d59',
  event_key: 'referral:joined:1f5ad9c2-1da3-4fb1-91fd-711971454a31:4edcbf35-b9f3-45dc-9fc4-fc3f7fd66d5e',
  event_type: 'referral.joined',
  beneficiary_id: '4edcbf35-b9f3-45dc-9fc4-fc3f7fd66d5e',
  payload: { attributionId: '1f5ad9c2-1da3-4fb1-91fd-711971454a31' },
  attempt_number: 1,
  lease_token: 'a0a92f46-e817-487f-ab55-8bbccb064d59',
};

function fakePool({ events = [event], finalization = { accepted: true, state: 'delivered' } } = {}) {
  const calls = [];
  const pool = {
    calls,
    async connect() {
      return {
        async query(sql, params = []) {
          calls.push({ sql, params });
          if (sql.includes('claim_reward_outbox')) return { rows: events };
          if (sql.includes('finalize_reward_outbox')) {
            return { rows: [{ result: finalization }] };
          }
          return { rows: [{ result: { processed: 0, releasedPaise: '0' } }] };
        },
        release() {},
      };
    },
  };
  return pool;
}

test('worker claims as the restricted DB role and commits inbox-accepted events once', async () => {
  const databasePool = fakePool();
  const requests = [];
  const worker = createRewardsWorker({
    databasePool,
    apiUrl: 'http://api.test',
    internalSecret: 'w'.repeat(40),
    workerId: 'test-worker',
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return { ok: true, async json() { return { accepted: true, inbox: 'created' }; } };
    },
    logger: { info() {}, warn() {}, error() {} },
  });

  assert.deepEqual(await worker.pollOnce(), { claimed: 1, completed: 1, failed: 0 });
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, 'http://api.test/internal/referral-outbox-event');
  assert.equal(requests[0].init.headers['x-reward-worker-secret'], 'w'.repeat(40));
  const calls = databasePool.calls;
  assert.ok(calls.some(({ sql }) => sql === 'SET LOCAL ROLE rewards_worker'));
  assert.ok(calls.some(({ sql }) => sql.includes('expire_referral_reservations')));
  const finalization = calls.find(({ sql }) => sql.includes('finalize_reward_outbox'));
  assert.equal(finalization.params[2], true);
  assert.deepEqual(JSON.parse(finalization.params[3]), {
    status: 'inbox_committed',
    inbox: 'created',
  });
  assert.ok(calls.some(({ sql }) => sql.includes('record_reward_worker_heartbeat')));
});
test('transient API errors are finalized for retry, never reported as delivered', async () => {
  const databasePool = fakePool({
    finalization: { accepted: true, state: 'pending', retryAfterSeconds: 30 },
  });
  const worker = createRewardsWorker({
    databasePool,
    apiUrl: 'http://api.test',
    internalSecret: 'w'.repeat(40),
    workerId: 'test-worker',
    fetchImpl: async () => ({
      ok: false,
      status: 503,
      async json() { return { error: 'notification_storage_unavailable' }; },
    }),
    logger: { info() {}, warn() {}, error() {} },
  });

  assert.deepEqual(await worker.pollOnce(), { claimed: 1, completed: 0, failed: 1 });
  const finalization = databasePool.calls.find(({ sql }) => sql.includes('finalize_reward_outbox'));
  assert.equal(finalization.params[2], false);
  assert.equal(finalization.params[4], 'notification_storage_unavailable');
  assert.equal(finalization.params[5], false);
});

test('API validation failures are marked permanent while worker misconfiguration fails closed', async () => {
  const databasePool = fakePool();
  const worker = createRewardsWorker({
    databasePool,
    apiUrl: 'http://api.test',
    internalSecret: 'w'.repeat(40),
    fetchImpl: async () => ({
      ok: false,
      status: 400,
      async json() { return { error: 'invalid_worker_event' }; },
    }),
    logger: { info() {}, warn() {}, error() {} },
  });
  const outcome = await worker.postEvent(event);
  assert.deepEqual(outcome, {
    success: false,
    errorCode: 'invalid_worker_event',
    permanent: true,
  });
  assert.throws(() => createRewardsWorker({ databasePool, internalSecret: 'short' }),
    /configuration_invalid/);
  assert.equal(safeErrorCode({ code: 'HTTP 500' }), 'worker_error');
});

// Measured 21 Nov 2026: 989 cycles in a row found nothing to do, and each made 12 database round trips (three
// transactions) plus a log line, every 5 s. The cadence stays 5 s; an idle cycle is now one transaction.
function idleWorker({ databasePool, clock, lines }) {
  return createRewardsWorker({
    databasePool,
    apiUrl: 'http://api.test',
    internalSecret: 'w'.repeat(40),
    workerId: 'test-worker',
    fetchImpl: async () => { throw new Error('nothing to deliver'); },
    now: () => clock.t,
    logger: { info: (m, f) => lines.push([m, f]), warn() {}, error: (m, f) => lines.push([m, f]) },
  });
}

test('an idle cycle expires, claims and records its heartbeat in one transaction', async () => {
  const databasePool = fakePool({ events: [] });
  const worker = idleWorker({ databasePool, clock: { t: 0 }, lines: [] });
  assert.deepEqual(await worker.pollOnce(), { claimed: 0, completed: 0, failed: 0 });
  const sqls = databasePool.calls.map(({ sql }) => sql);
  assert.equal(sqls.filter((s) => s === 'BEGIN').length, 1, 'one transaction');
  assert.equal(sqls.length, 6, 'BEGIN, role, expire, claim, heartbeat, COMMIT');
  assert.equal(sqls[1], 'SET LOCAL ROLE rewards_worker');
  assert.ok(sqls[2].includes('expire_referral_reservations'));
  assert.ok(sqls[3].includes('claim_reward_outbox'));
  assert.ok(sqls[4].includes('record_reward_worker_heartbeat'));
  assert.deepEqual(databasePool.calls[4].params, ['test-worker', 0, 0, null]);
  assert.equal(sqls[5], 'COMMIT');
});

test('a cycle with work still records its heartbeat after the events are finalised', async () => {
  const databasePool = fakePool();
  const worker = idleWorker({ databasePool, clock: { t: 0 }, lines: [] });
  await worker.pollOnce();
  const sqls = databasePool.calls.map(({ sql }) => sql);
  const finalised = sqls.findIndex((s) => s.includes('finalize_reward_outbox'));
  const beat = sqls.findIndex((s) => s.includes('record_reward_worker_heartbeat'));
  assert.ok(finalised >= 0 && beat > finalised, 'heartbeat after finalising');
  assert.equal(sqls.filter((s) => s.includes('record_reward_worker_heartbeat')).length, 1);
});

test('idle cycles log once a minute; cycles with work or errors always log', async () => {
  const lines = [];
  const clock = { t: 0 };
  const worker = idleWorker({ databasePool: fakePool({ events: [] }), clock, lines });
  for (let i = 0; i < 12; i++) { await worker.pollOnce(); clock.t += 5000; } // one minute of idle cycles
  await worker.pollOnce();
  assert.equal(lines.filter(([m]) => m === 'reward worker cycle complete').length, 2, 'first idle cycle, then one a minute later');
  const busyLines = [];
  const busyWorker = createRewardsWorker({ databasePool: fakePool(), apiUrl: 'http://api.test', internalSecret: 'w'.repeat(40), workerId: 'w',
    fetchImpl: async () => ({ ok: true, async json() { return { accepted: true, inbox: 'created' }; } }), now: () => 0,
    logger: { info: (m, f) => busyLines.push([m, f]), warn() {}, error() {} } });
  await busyWorker.pollOnce(); await busyWorker.pollOnce();
  assert.equal(busyLines.filter(([m]) => m === 'reward worker cycle complete').length, 2, 'every cycle with work is logged');
});
