'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { enqueueNotification } = require('../src/notification_outbox');
const { createNotificationOutboxWorker, safeErrorCode } = require('../src/notification_outbox_worker');

function mockPool(handler) {
  return { connect: async () => ({
    query: async (sql, args = []) => handler(sql.trim(), args),
    release() {},
  }) };
}
const row = (token) => ({ id: 'o1', notification_id: 'n1', revision_id: 'r1', profile_id: 'p1', lease_token: token, title: 'Title', body: 'Body' });
test('failed rollback discards a connection instead of returning an unknown role/transaction state', async () => {
  let discarded;
  const rollbackError = new Error('synthetic rollback failure');
  const databasePool = { connect: async () => ({ query: async statement => {
    if (statement === 'ROLLBACK') throw rollbackError;
    if (statement.includes('notification_delivery.claim')) throw new Error('synthetic query failure');
    return { rows: [] };
  }, release(error) { discarded = error; } }) };
  const worker = createNotificationOutboxWorker({ databasePool, send: async () => assert.fail('no provider call'), logger: { error() {} } });
  assert.equal((await worker.pollOnce()).available, false); assert.equal(discarded, rollbackError);
});

test('enqueue uses only the supplied user transaction and inbox row identity', async () => {
  const calls = [];
  const result = await enqueueNotification({ query: async (...args) => { calls.push(args); return { rows: [{ enqueued: true }] }; } }, 'n-1');
  assert.equal(result, true);
  assert.deepEqual(calls, [['SELECT notification_delivery.enqueue($1::uuid) AS enqueued', ['n-1']]]);
});

test('worker claims one row, rechecks authorization and uses stable revision identity', async () => {
  const sql = []; const sends = [];
  const databasePool = mockPool((statement, args) => {
    sql.push(statement);
    if (statement.includes('notification_delivery.claim')) return { rows: [row('t1')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { assert.deepEqual(args.slice(0, 3), ['o1', 't1', true]); return { rows: [{ result: { accepted: true, state: 'delivered' } }] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, send: async (payload) => sends.push(payload), logger: { error() {} } });
  assert.deepEqual(await worker.pollOnce(), { available: true, claimed: 1, completed: 1, failed: 0 });
  assert.equal(sends.length, 1);
  assert.equal(sends[0].dedupeKey, 'notification:r1');
  assert.equal(sql.filter((s) => s === 'SET LOCAL ROLE notification_worker').length, 3);
});

test('worker does not send if fresh preference/account validation rejects the lease', async () => {
  let sends = 0; let finishArgs;
  const databasePool = mockPool((statement, args) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row('old-token')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: false }] };
    if (statement.includes('notification_delivery.finish')) { finishArgs = args; return { rows: [{ result: { accepted: false, state: 'lease_lost' } }] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, send: async () => { sends += 1; }, logger: { error() {} } });
  const result = await worker.pollOnce();
  assert.equal(sends, 0);
  assert.equal(finishArgs[3], 'preference_or_account_disabled');
  assert.equal(result.completed, 0);
});

test('transient provider failure retries with the same provider event key', async () => {
  let claims = 0; const keys = []; const results = [];
  const databasePool = mockPool((statement, args) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row(`lease-${++claims}`)], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { results.push(args); return { rows: [{ result: { accepted: true, state: args[2] ? 'delivered' : 'pending' } }] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, send: async ({ dedupeKey }) => {
    keys.push(dedupeKey); if (keys.length === 1) { const e = new Error('network'); e.code = 'notification_service_timeout'; throw e; }
  }, logger: { error() {} } });
  assert.equal((await worker.pollOnce()).completed, 0);
  assert.equal((await worker.pollOnce()).completed, 1);
  assert.deepEqual(keys, ['notification:r1', 'notification:r1']);
  assert.equal(results[0][3], 'notification_service_timeout');
  assert.deepEqual(results.map((args) => args[1]), ['lease-1', 'lease-2']);
});

test('uncertain provider acceptance is retried, never reported as completed', async () => {
  let finishArgs; let sendCount = 0;
  const databasePool = mockPool((statement, args) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row('lease')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { finishArgs = args; return { rows: [{ result: { accepted: true, state: 'pending' } }] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, send: async () => { sendCount++; throw Object.assign(new Error('accepted but response lost'), { code: 'notification_service_timeout' }); }, logger: { error() {} } });
  const result = await worker.pollOnce();
  assert.equal(sendCount, 1);
  assert.equal(finishArgs[2], false);
  assert.equal(result.completed, 0);
  assert.equal(result.failed, 1);
});

test('provider timeout aborts and settles before another send can start', async () => {
  let claims = 0; let active = 0; let maxActive = 0; let finishCount = 0;
  const databasePool = mockPool((statement) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row(`lease-${++claims}`)], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { finishCount++; return { rows: [{ result: { accepted: true, state: 'pending' } }] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, deliveryTimeoutMs: 1000, abortGraceMs: 100,
    send: ({ signal }) => new Promise((resolve, reject) => {
      active++; maxActive = Math.max(maxActive, active);
      signal.addEventListener('abort', () => { active--; reject(Object.assign(new Error('aborted'), { code: 'AbortError' })); }, { once: true });
    }), logger: { error() {} } });
  const first = await worker.pollOnce();
  assert.equal(first.failed, 1);
  const second = await worker.pollOnce();
  assert.equal(second.failed, 1);
  assert.equal(maxActive, 1);
  assert.equal(active, 0);
  assert.equal(finishCount, 2);
});

test('sender that ignores abort blocks this worker and leaves the lease unacknowledged', async () => {
  let sends = 0; let finishes = 0;
  const databasePool = mockPool((statement) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row('lease')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { finishes++; return { rows: [] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, deliveryTimeoutMs: 1000, abortGraceMs: 100,
    send: () => { sends++; return new Promise(() => {}); }, logger: { error() {} } });
  const first = await worker.pollOnce();
  const second = await worker.pollOnce();
  assert.equal(first.available, false);
  assert.equal(first.errorCode, 'notification_sender_unresponsive');
  assert.equal(second.available, false);
  assert.equal(sends, 1);
  assert.equal(finishes, 0);
  await worker.stop();
});

test('stale lease completion is not counted as successful acknowledgment', async () => {
  const databasePool = mockPool((statement) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row('stale')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) return { rows: [{ result: { accepted: false, state: 'lease_lost' } }] };
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, send: async () => {}, logger: { error() {} } });
  assert.deepEqual(await worker.pollOnce(), { available: true, claimed: 1, completed: 0, failed: 1 });
});

test('worker reports database failures as unavailable', async () => {
  const worker = createNotificationOutboxWorker({ databasePool: mockPool(() => { throw Object.assign(new Error('db down'), { code: '08006' }); }), send: async () => {}, logger: { error() {} } });
  assert.deepEqual(await worker.pollOnce(), { available: false, errorCode: 'notification_error', claimed: 0, completed: 0, failed: 0 });
});

test('stop wakes a sleeping poll loop promptly', async () => {
  const databasePool = mockPool(() => ({ rows: [], rowCount: 0 }));
  const worker = createNotificationOutboxWorker({ databasePool, pollIntervalMs: 60000, send: async () => {}, logger: { error() {} } });
  worker.start();
  await new Promise((resolve) => setImmediate(resolve));
  const started = Date.now();
  await worker.stop();
  assert.ok(Date.now() - started < 1000);
});

test('stop aborts an active provider call and returns bounded when sender ignores abort', async () => {
  let notifySendStarted; let finishes = 0;
  const sendStarted = new Promise((resolve) => { notifySendStarted = resolve; });
  const databasePool = mockPool((statement) => {
    if (statement.includes('notification_delivery.claim')) return { rows: [row('lease')], rowCount: 1 };
    if (statement.includes('notification_delivery.allowed')) return { rows: [{ allowed: true }] };
    if (statement.includes('notification_delivery.finish')) { finishes++; return { rows: [] }; }
    return { rows: [] };
  });
  const worker = createNotificationOutboxWorker({ databasePool, leaseSeconds: 120, deliveryTimeoutMs: 50000, abortGraceMs: 100,
    send: () => { notifySendStarted(); return new Promise(() => {}); }, logger: { error() {} } });
  worker.start();
  await sendStarted;
  const started = Date.now();
  await worker.stop();
  assert.ok(Date.now() - started < 1000);
  assert.equal(finishes, 0);
  assert.equal((await worker.pollOnce()).available, false);
});

test('worker bounds configuration and factory construction stays dormant', () => {
  let calls = 0;
  const databasePool = mockPool(() => { calls++; return { rows: [], rowCount: 0 }; });
  assert.throws(() => createNotificationOutboxWorker({ databasePool, batchSize: 2, send: async () => {} }), /batchSize/);
  assert.throws(() => createNotificationOutboxWorker({ databasePool, leaseSeconds: 30, send: async () => {} }), /leaseSeconds/);
  createNotificationOutboxWorker({ databasePool, send: async () => {} });
  assert.equal(calls, 0);
});

test('safe error codes never expose provider text', () => {
  assert.equal(safeErrorCode({ code: 'HTTP_429' }), 'http_429');
  assert.equal(safeErrorCode({ code: 'secret token: abc' }), 'notification_error');
});
