'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createAppStatusReader } = require('../src/app_status_cache');
const { classify } = require('../src/admission');

const row = { min_supported_version: '1.0.18', maintenance_mode: false, maintenance_message: null, sms_backup_import_enabled: true };

test('/app-status never waits in the admission line', () => {
  assert.equal(classify({ method: 'GET', path: '/app-status' }), null);
});

test('one database read serves every call inside the ttl', async () => {
  let reads = 0, t = 1000;
  const get = createAppStatusReader({ readRow: async () => { reads++; return row; }, ttlMs: 30000, now: () => t });
  assert.deepEqual(await get(), row);
  t += 29000;
  await get();
  assert.equal(reads, 1);
  t += 2000;
  await get();
  assert.equal(reads, 2);
});

test('concurrent calls share one read', async () => {
  let reads = 0;
  const get = createAppStatusReader({ readRow: async () => { reads++; await new Promise((r) => setTimeout(r, 5)); return row; }, now: () => 0 });
  await Promise.all([get(), get(), get()]);
  assert.equal(reads, 1);
});

test('a failing read serves the last good value, then fails when none is left', async () => {
  let fail = false, t = 0;
  const get = createAppStatusReader({ readRow: async () => { if (fail) throw new Error('db down'); return row; }, ttlMs: 1000, staleMs: 600000, now: () => t });
  await get();
  fail = true; t += 5000;
  assert.deepEqual(await get(), row);
  t += 700000;
  await assert.rejects(get(), /db down/);
});

test('a failing first read is not cached', async () => {
  let n = 0;
  const get = createAppStatusReader({ readRow: async () => { if (n++ === 0) throw new Error('first'); return row; }, now: () => 0 });
  await assert.rejects(get(), /first/);
  assert.deepEqual(await get(), row);
});

test('a missing row is cached as null so the route can fail open', async () => {
  let reads = 0;
  const get = createAppStatusReader({ readRow: async () => { reads++; return undefined; }, now: () => 0 });
  assert.equal(await get(), null);
  await get();
  assert.equal(reads, 1);
});
