'use strict';

// Unit tests with a stubbed query, so they run in `npm test` without a database.
// The same rules against real tables are in device_account_limit_postgres.js.
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createDeviceAccountLimit, isStrongDeviceId, SHARED_PLACEHOLDERS,
} = require('../src/services/deviceAccountLimit');

const IOS = 'k2-3f2a9c1e-7b1d-4c55-9d0e-1a2b3c4d5e6f';
const ANDROID = 'a2-0123456789abcdef0123456789abcdef';
const LEGACY = '3f2a9c1e-7b1d-4c55-9d0e-1a2b3c4d5e6f';

function limiter(options = {}, accounts = 0) {
  const sql = [];
  const events = [];
  const svc = createDeviceAccountLimit({
    query: async (text, params) => { sql.push({ text, params }); return { rows: [{ accounts }] }; },
    audit: async event => { events.push(event); },
    logger: { warn() {} },
    ...options,
  });
  return { svc, sql, events };
}

test('only the phone ids the app now sends count as strong', () => {
  assert.equal(isStrongDeviceId(IOS), true);
  assert.equal(isStrongDeviceId(ANDROID), true);
  for (const weak of [LEGACY, 'app-mobile', 'unknown-device', 'k2-', 'a2-short', 'anon-0123456789abcdef0123456789abcdef', '', null, undefined, 42]) {
    assert.equal(isStrongDeviceId(weak), false, String(weak));
  }
});

test('a phone id that is also in the shared-placeholder list is still not strong', () => {
  for (const placeholder of SHARED_PLACEHOLDERS) assert.equal(isStrongDeviceId(placeholder), false);
});

test('deleted accounts count toward the limit unless asked not to', async () => {
  const counting = limiter({ limit: 2 }, 2);
  await counting.svc.admitNewAccount({ deviceId: IOS });
  assert.doesNotMatch(counting.sql[0].text, /deleted\s*=\s*FALSE/i);

  const liveOnly = limiter({ limit: 2, countDeleted: false }, 2);
  await liveOnly.svc.admitNewAccount({ deviceId: IOS });
  assert.match(liveOnly.sql[0].text, /deleted\s*=\s*FALSE/i);
});

test('enforced: a third account on one phone is refused and recorded', async () => {
  const { svc, events } = limiter({ limit: 2, enforce: true }, 2);
  const result = await svc.admitNewAccount({ deviceId: ANDROID, ip: '203.0.113.9', userAgent: 'ua' });
  assert.deepEqual([result.allowed, result.accounts, result.reason], [false, 2, 'device_account_limit']);
  assert.equal(events.length, 1);
  assert.equal(events[0].status, 'blocked');
  assert.equal(events[0].meta.enforced, true);
});

test('enforced: the second account is still allowed', async () => {
  const { svc, events } = limiter({ limit: 2, enforce: true }, 1);
  assert.deepEqual(await svc.admitNewAccount({ deviceId: IOS }), { allowed: true, accounts: 1 });
  assert.equal(events.length, 0);
});

test('log-only: past the limit it lets the sign-up through and records it', async () => {
  const { svc, events } = limiter({ limit: 2, enforce: false }, 5);
  const result = await svc.admitNewAccount({ deviceId: IOS });
  assert.equal(result.allowed, true);
  assert.equal(events[0].status, 'flagged');
});

test('requiring a phone id: an old build or missing id cannot open a new account once enforced', async () => {
  for (const deviceId of [LEGACY, 'app-mobile', 'unknown-device', undefined]) {
    const { svc, events, sql } = limiter({ limit: 2, enforce: true, requireStrongId: true }, 0);
    const result = await svc.admitNewAccount({ deviceId });
    assert.deepEqual([result.allowed, result.reason], [false, 'weak_device_id'], String(deviceId));
    assert.equal(events[0].status, 'blocked');
    assert.equal(events[0].meta.reason, 'weak_device_id');
    assert.equal(sql.length, 0, 'no count is needed to refuse a weak id');
  }
});

test('requiring a phone id does nothing while enforcement is off', async () => {
  const { svc, events } = limiter({ limit: 2, enforce: false, requireStrongId: true }, 0);
  assert.equal((await svc.admitNewAccount({ deviceId: LEGACY })).allowed, true);
  assert.equal(events.length, 0);
});

test('requiring a phone id still lets a strong id through below the limit', async () => {
  const { svc } = limiter({ limit: 2, enforce: true, requireStrongId: true }, 1);
  assert.equal((await svc.admitNewAccount({ deviceId: ANDROID })).allowed, true);
});

test('limit 0 turns the whole check off, including the phone id requirement', async () => {
  const { svc, sql, events } = limiter({ limit: 0, enforce: true, requireStrongId: true });
  assert.deepEqual(await svc.admitNewAccount({ deviceId: LEGACY }), { allowed: true, accounts: null });
  assert.equal(sql.length + events.length, 0);
});

test('a count that cannot be read never blocks a sign-up', async () => {
  const svc = createDeviceAccountLimit({
    query: async () => { throw new Error('db down'); },
    audit: async () => {}, limit: 2, enforce: true, logger: { warn() {} },
  });
  assert.deepEqual(await svc.admitNewAccount({ deviceId: IOS }), { allowed: true, accounts: null });
});
