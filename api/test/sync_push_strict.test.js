'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const helpers = require('../src/sync_request_validation');
const handlers = require('../src/sync_push_handlers');

// Same technique as sync_transport_routes.test.js: run the real route
// registrations from index.js in a sandbox, with a scripted database client.
const source = fs.readFileSync(require.resolve('../src/index'), 'utf8').replace(/\r\n/g, '\n');
const user = '10000000-0000-4000-8000-000000000001';
const device = '20000000-0000-4000-8000-000000000001';
const entityId = '30000000-0000-4000-8000-000000000001';
const sections = [
  ["app.post('/sync/push'", '/**\n * GET /sync/pull?'],
  ["app.get('/sync/pull'", '/** POST /sync/ack'],
  ["app.post('/sync/ack'", '/** POST /sync/conflicts'],
];

function fixture(query, { typed = false } = {}) {
  const routes = new Map();
  const calls = [];
  const context = {
    ...helpers,
    config: { syncTypedWritesEnabled: typed },
    applyTransactionSync: undefined,
    console: { error() {} },
    safeErrorCode: () => 'safe_code',
    requireAuth() {},
    withUserClient: async (id, callback) => {
      assert.equal(id, user);
      return callback({
        query: async (sql, args) => {
          calls.push({ sql, args: args === undefined ? undefined : Array.from(args) });
          return query(sql, args);
        },
      });
    },
    app: Object.fromEntries(['post', 'get'].map((method) => [method, (url, _auth, handler) => routes.set(`${method} ${url}`, handler)])),
  };
  for (const [begin, end] of sections) {
    const start = source.indexOf(begin);
    const stop = source.indexOf(end, start);
    assert.ok(start >= 0 && stop > start);
    vm.runInNewContext(source.slice(start, stop), context);
  }
  return {
    calls,
    async invoke(method, url, request = {}) {
      const res = {
        code: 200,
        status(n) { this.code = n; return this; },
        json(body) { this.body = JSON.parse(JSON.stringify(body)); return this; },
      };
      await routes.get(`${method} ${url}`)({ userId: user, body: {}, query: {}, params: {}, ...request }, res);
      return res;
    },
  };
}

const TRANSACTION_FIELDS = ['user_card_id', 'amount_inr', 'occurred_at', 'merchant_name', 'merchant_vpa', 'mcc',
  'category_id', 'user_category_id', 'rail', 'instrument', 'entry_kind', 'status', 'note'];
const CARD_FIELDS = ['nickname', 'is_default', 'is_archived', 'sort_order', 'credit_limit_inr', 'statement_day',
  'due_day', 'anniversary_on', 'opened_on', 'autopay_mode', 'statement_day_source', 'due_day_source', 'last4',
  'annual_fee_override_inr'];

/** Scripted database: registered device, allowlist lookups and an RPC stub. */
function database({ deviceKnown = true, rpc = () => ({ out_applied: true, out_conflicts: 0, out_reason: null }) } = {}) {
  return async (sql, args) => {
    if (sql.startsWith('SELECT 1 FROM user_devices')) return { rows: deviceKnown ? [{ '?column?': 1 }] : [] };
    if (sql.startsWith('SELECT pandapay.sync_fields_for')) {
      const fields = { transactions: TRANSACTION_FIELDS, user_cards: CARD_FIELDS }[args[0]] || null;
      return { rows: [{ fields }] };
    }
    if (sql.startsWith('SELECT out_applied')) return { rows: [rpc(sql, args)] };
    return { rows: [] };
  };
}

const change = (clientSeq, patch = {}) => ({
  entity: 'user_cards', entityId, op: 'update', payload: { nickname: 'Synthetic' }, fieldClocks: { nickname: 1000 }, clientSeq, ...patch,
});
const push = (f, changes, extra = {}) => f.invoke('post', '/sync/push', { body: { deviceId: device, changes, ...extra } });

test('non-strict push is unchanged: same keys, no extra queries, no strict-only fields', async () => {
  const f = fixture(database());
  const response = await push(f, [change(1, { payload: { nickname: 'a', not_a_column: 1 } })]);
  assert.equal(response.code, 200);
  assert.equal(JSON.stringify(response.body), JSON.stringify({
    results: [{ clientSeq: 1, entityId, applied: true, conflicts: 0, reason: null }],
    appliedCount: 1,
  }));
  assert.deepEqual(f.calls.map((c) => c.sql.split(/\s+/).slice(0, 2).join(' ')), ['SAVEPOINT sync_item', 'SELECT out_applied,', 'RELEASE SAVEPOINT']);
});

test('strict: ignoredFields lists payload keys outside the allowlist and the rest still applies', async () => {
  const f = fixture(database());
  const response = await push(f, [change(1, { payload: { nickname: 'a', bogus: 1, last4: '1234', payment_method: 'cash' }, fieldClocks: {} })], { strict: true });
  assert.equal(response.code, 200);
  assert.deepEqual(response.body.results[0], {
    clientSeq: 1, entityId, applied: true, conflicts: 0, reason: null, ignoredFields: ['bogus', 'payment_method'],
  });
  assert.equal(f.calls.some((c) => c.sql.startsWith('SELECT out_applied')), true);
});

test('strict: an update with nothing syncable is applied:false no_syncable_fields and writes nothing', async () => {
  const f = fixture(database());
  const response = await push(f, [
    change(1, { payload: { bogus: 1, other: 2 } }),
    change(2, { payload: {} }),
    change(3),
  ], { strict: true });
  assert.deepEqual(response.body.results.map((r) => [r.clientSeq, r.applied, r.reason]), [
    [1, false, 'no_syncable_fields'], [2, false, 'no_syncable_fields'], [3, true, null],
  ]);
  assert.deepEqual(response.body.results[0].ignoredFields, ['bogus', 'other']);
  assert.equal(response.body.appliedCount, 1);
  assert.equal(f.calls.filter((c) => c.sql.startsWith('SELECT out_applied')).length, 1);
});

test('strict: deletes and unknown entities are not mistaken for empty payloads', async () => {
  const f = fixture(database({ rpc: (_sql, args) => (args[2] === 'future_entity'
    ? { out_applied: false, out_conflicts: 0, out_reason: 'unknown_entity' }
    : { out_applied: true, out_conflicts: 0, out_reason: null }) }));
  const response = await push(f, [
    change(1, { op: 'delete', payload: {}, fieldClocks: {} }),
    change(2, { entity: 'future_entity', payload: { x: 1 } }),
  ], { strict: true });
  assert.deepEqual(response.body.results.map((r) => [r.clientSeq, r.applied, r.reason]), [[1, true, null], [2, false, 'unknown_entity']]);
  assert.equal('ignoredFields' in response.body.results[1], false);
});

test('strict: entities with a dedicated SQL function are passed through and report no ignored fields', async () => {
  const f = fixture(database({ rpc: () => ({ out_applied: true, out_conflicts: 0, out_reason: null }) }));
  const response = await push(f, [change(1, { entity: 'user_commitments', payload: { anything: 1 } })], { strict: true });
  assert.deepEqual(response.body.results[0], { clientSeq: 1, entityId, applied: true, conflicts: 0, reason: null, ignoredFields: [] });
  assert.equal(f.calls.some((c) => c.sql.includes('sync_apply_user_commitment')), true);
});

test('strict: status is still refused for transactions before any allowlist logic', async () => {
  const f = fixture(database());
  const response = await push(f, [change(1, { entity: 'transactions', payload: { status: 'ignored' } })], { strict: true });
  assert.deepEqual(response.body.results[0].reason, 'rejected');
  assert.equal(f.calls.some((c) => c.sql.startsWith('SELECT pandapay.sync_fields_for')), false);
});

test('unknown device: strict push answers 409 before applying anything', async () => {
  const f = fixture(database({ deviceKnown: false }));
  const response = await push(f, [change(1), change(2)], { strict: true });
  assert.equal(response.code, 409);
  assert.deepEqual(response.body, { error: 'device_not_registered' });
  assert.equal(f.calls.some((c) => c.sql.startsWith('SAVEPOINT')), false);
  assert.equal(f.calls.some((c) => c.sql.startsWith('SELECT out_applied')), false);
});

test('unknown device: a push that did not opt in keeps the old per-item behaviour', async () => {
  const f = fixture(database({
    deviceKnown: false,
    rpc: () => { throw Object.assign(new Error('Sync access denied'), { code: '42501' }); },
  }));
  const response = await push(f, [change(1)]);
  assert.equal(response.code, 200);
  assert.deepEqual(response.body.results.map((r) => [r.clientSeq, r.applied, r.reason]), [[1, false, 'rejected']]);
  assert.equal(f.calls.some((c) => c.sql.startsWith('SELECT 1 FROM user_devices')), false);
});

test('unknown device: pull and ack answer 409 instead of 500; other 42501 causes stay 500', async () => {
  const denied = () => { throw Object.assign(new Error('Sync access denied'), { code: '42501' }); };
  for (const known of [false, true]) {
    const f = fixture(async (sql) => {
      if (sql.startsWith('SELECT 1 FROM user_devices')) return { rows: known ? [{}] : [] };
      return denied();
    });
    const pull = await f.invoke('get', '/sync/pull', { query: { deviceId: device, since: '0' } });
    const ack = await f.invoke('post', '/sync/ack', { body: { deviceId: device, serverSeq: 1 } });
    for (const response of [pull, ack]) {
      assert.equal(response.code, known ? 500 : 409);
      assert.deepEqual(response.body, known ? { error: 'internal_error' } : { error: 'device_not_registered' });
    }
  }
});

test('pull and ack map transient database errors to a retryable 503', async () => {
  const f = fixture(async () => { throw Object.assign(new Error('deadlock'), { code: '40P01' }); });
  const pull = await f.invoke('get', '/sync/pull', { query: { deviceId: device, since: '0' } });
  assert.equal(pull.code, 503);
  assert.deepEqual(pull.body, { error: 'transient_db_error', retryable: true });
});

test('clock guard: strict clamps clocks more than five minutes ahead and reports them', async () => {
  const seen = [];
  const f = fixture(database({ rpc: (_sql, args) => { seen.push(JSON.parse(args[6])); return { out_applied: true, out_conflicts: 0, out_reason: null }; } }));
  const before = Date.now();
  const far = before + 3 * 3600 * 1000;
  const nearFuture = before + 60 * 1000;
  const response = await push(f, [change(1, { payload: { nickname: 'a', last4: '1' }, fieldClocks: { nickname: far, last4: nearFuture } })], { strict: true });
  const after = Date.now();
  assert.equal(response.code, 200);
  assert.deepEqual(response.body.results[0].clampedClocks, ['nickname']);
  assert.ok(seen[0].nickname >= before && seen[0].nickname <= after, 'clamped to the server clock');
  assert.equal(seen[0].last4, nearFuture, 'within five minutes is left alone');
});

test('clock guard: non-strict pushes keep their clocks untouched', async () => {
  const seen = [];
  const f = fixture(database({ rpc: (_sql, args) => { seen.push(JSON.parse(args[6])); return { out_applied: true, out_conflicts: 0, out_reason: null }; } }));
  const far = Date.now() + 3 * 3600 * 1000;
  const response = await push(f, [change(1, { fieldClocks: { nickname: far } })]);
  assert.deepEqual(seen[0], { nickname: far });
  assert.equal('clampedClocks' in response.body.results[0], false);
});

test('clampFieldClocks boundary: exactly five minutes ahead is allowed', () => {
  const now = 1_000_000_000_000;
  assert.deepEqual(handlers.clampFieldClocks({ a: now + handlers.SYNC_CLOCK_TOLERANCE_MS }, now), {
    fieldClocks: { a: now + handlers.SYNC_CLOCK_TOLERANCE_MS }, clamped: [],
  });
  assert.deepEqual(handlers.clampFieldClocks({ a: now + handlers.SYNC_CLOCK_TOLERANCE_MS + 1, b: 5 }, now), {
    fieldClocks: { a: now, b: 5 }, clamped: ['a'],
  });
});

test('transient database errors inside an item are reported as transient, not rejected', async () => {
  for (const code of ['57014', '40001', '40P01']) {
    const f = fixture(database({
      rpc: (_sql, args) => {
        if (JSON.parse(args[5]).nickname === 'boom') throw Object.assign(new Error('private customer@example.invalid'), { code });
        return { out_applied: true, out_conflicts: 0, out_reason: null };
      },
    }));
    const response = await push(f, [
      change(1, { payload: { nickname: 'boom' } }),
      change(2, { payload: { nickname: 'fine' } }),
    ]);
    assert.deepEqual(response.body.results.map((r) => [r.clientSeq, r.applied, r.reason]), [[1, false, 'transient'], [2, true, null]]);
    assert.equal(JSON.stringify(response.body).includes('private'), false);
    assert.ok(f.calls.some((c) => c.sql === 'ROLLBACK TO SAVEPOINT sync_item'));
  }
});

test('permanent errors are still rejected; a last4 identity collision gets a fixed explanation', async () => {
  const f = fixture(database({
    rpc: (_sql, args) => {
      const nickname = JSON.parse(args[5]).nickname;
      if (nickname === 'dup') throw Object.assign(new Error('private'), { code: '23505', constraint: 'uq_user_cards_active_identity', detail: 'Key (profile_id)=(private)' });
      if (nickname === 'other') throw Object.assign(new Error('private'), { code: '23505', constraint: 'some_other_index' });
      return { out_applied: true, out_conflicts: 0, out_reason: null };
    },
  }));
  const response = await push(f, [
    change(1, { payload: { nickname: 'dup' } }),
    change(2, { payload: { nickname: 'other' } }),
  ]);
  assert.deepEqual(response.body.results.map((r) => [r.reason, r.detail]), [
    ['rejected', helpers.SYNC_CARD_IDENTITY_DETAIL],
    ['rejected', 'This change duplicates an existing record.'],
  ]);
  assert.equal(JSON.stringify(response.body).includes('private'), false);
});

test('request-level database errors on push use the shared mapper', async () => {
  const f = fixture(async () => { throw Object.assign(new Error('x'), { code: '40001' }); });
  const response = await push(f, [change(1)]);
  assert.equal(response.code, 503);
  assert.deepEqual(response.body, { error: 'transient_db_error', retryable: true });
});

test('validation: strict is only present in the validated request when it is exactly true', () => {
  const base = { deviceId: device, changes: [] };
  assert.deepEqual(helpers.validateSyncPushRequest(base), { value: base });
  assert.deepEqual(helpers.validateSyncPushRequest({ ...base, strict: false }), { value: base });
  assert.deepEqual(helpers.validateSyncPushRequest({ ...base, strict: 'true' }), { value: base });
  assert.deepEqual(helpers.validateSyncPushRequest({ ...base, strict: true }), { value: { ...base, strict: true } });
});

test('registry: a registered handler receives its entity and op without touching the loop', async () => {
  const registry = handlers.createSyncPushHandlerRegistry();
  const seen = [];
  registry.register('user_cards', 'insert', async (_client, item, ctx) => {
    seen.push([item.entity, item.op, ctx.userId]);
    return { out_applied: true, out_conflicts: 0, out_reason: 'created' };
  });
  registry.registerFallback(async () => ({ out_applied: false, out_conflicts: 0, out_reason: 'fallback' }), { usesFieldAllowlist: false });
  const client = { query: async () => ({ rows: [] }) };
  const ctx = handlers.createSyncPushContext({ userId: user, deviceId: device, config: {}, registry, rejectionDetail: () => 'x' });
  const item = (op) => ({ entity: 'user_cards', entityId, op, payload: {}, fieldClocks: {}, clientSeq: 1 });
  assert.equal((await handlers.processSyncPushItem(client, item('insert'), ctx)).reason, 'created');
  assert.equal((await handlers.processSyncPushItem(client, item('update'), ctx)).reason, 'fallback');
  assert.deepEqual(seen, [['user_cards', 'insert', user]]);
  assert.throws(() => registry.register('', 'insert', () => {}), TypeError);
  assert.throws(() => registry.register('x', 'insert', null), TypeError);
});

test('registry: handler failures are isolated to their item', async () => {
  const registry = handlers.createSyncPushHandlerRegistry();
  registry.registerFallback(async (_client, item) => {
    if (item.clientSeq === 1) throw Object.assign(new Error('x'), { code: '23503' });
    return { out_applied: true, out_conflicts: 0, out_reason: null };
  });
  const calls = [];
  const client = { query: async (sql) => { calls.push(sql); return { rows: [] }; } };
  const ctx = handlers.createSyncPushContext({ userId: user, deviceId: device, config: {}, registry, rejectionDetail: helpers.syncRejectionDetail });
  const bad = await handlers.processSyncPushItem(client, { entity: 'e', entityId, op: 'update', payload: {}, fieldClocks: {}, clientSeq: 1 }, ctx);
  const good = await handlers.processSyncPushItem(client, { entity: 'e', entityId, op: 'update', payload: {}, fieldClocks: {}, clientSeq: 2 }, ctx);
  assert.deepEqual([bad.reason, bad.detail], ['rejected', 'A referenced record is missing.']);
  assert.equal(good.applied, true);
  assert.deepEqual(calls, ['SAVEPOINT sync_item', 'ROLLBACK TO SAVEPOINT sync_item', 'SAVEPOINT sync_item', 'RELEASE SAVEPOINT sync_item']);
});
