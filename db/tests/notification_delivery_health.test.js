'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { probe } = require('../scripts/notification_delivery_health');
const healthy = { enabled: null, queued: 0, retained: 0, max_queued: 10000, max_retained: 10000,
  oldest_pending_seconds: null, expired_leased: 0, dead: 0, new_terminal_24h: 0, worker_rows: 0,
  heartbeat_age_seconds: null, missing_worker: true, blocked_workers: 0, unavailable_workers: 0 };
const safe = { bounded: true, can_read: true, direct_private: false, can_create: false, unsafe_capability: false, unsafe_membership: false };
function fixture(role = safe, health = healthy) {
  const outputs = []; let ended = false;
  class Pool {
    constructor(options) { assert.equal(options.max, 1); assert.equal(options.statement_timeout, 2000); }
    on() {}
    async query(sql) { return sql.includes('AS bounded') ? { rows: [role] } : { rows: [{ health }] }; }
    async end() { ended = true; }
  }
  return { outputs, Pool, ended: () => ended };
}
const env = { NOTIFICATION_MONITOR_DATABASE_URL: 'postgresql://synthetic:private-placeholder@127.0.0.1/synthetic', DB_SSL: 'false', NODE_ENV: 'test' };
test('operator probe emits only validated aggregate fields and always closes its bounded pool', async () => {
  const f = fixture();
  assert.equal(await probe({ env, PoolClass: f.Pool, write: value => f.outputs.push(value) }), 0);
  assert.deepEqual(JSON.parse(f.outputs[0]), { available: true, health: healthy }); assert.equal(f.ended(), true);
  assert.equal(f.outputs.join('').includes('private-placeholder'), false);
});
test('operator probe refuses elevated or broad monitor roles and never falls back to other saved URLs', async () => {
  await assert.rejects(probe({ env: { DATABASE_URL: env.NOTIFICATION_MONITOR_DATABASE_URL }, PoolClass: class { constructor() { assert.fail(); } } }), /NOTIFICATION_MONITOR_DATABASE_URL/);
  for (const key of Object.keys(safe)) {
    const f = fixture({ ...safe, [key]: !safe[key] });
    await assert.rejects(probe({ env, PoolClass: f.Pool, write: value => f.outputs.push(value) }), /Unsafe/);
    assert.equal(f.outputs.length, 0); assert.equal(f.ended(), true);
  }
});
test('operator probe rejects an unreviewed health shape without printing private database fields', async () => {
  const f = fixture(safe, { ...healthy, private_payload: 'sensitive-placeholder' });
  assert.equal(await probe({ env, PoolClass: f.Pool, write: value => f.outputs.push(value) }), 2);
  assert.equal(f.outputs.join('').includes('sensitive-placeholder'), false);
});
