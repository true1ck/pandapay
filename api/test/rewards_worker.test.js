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
