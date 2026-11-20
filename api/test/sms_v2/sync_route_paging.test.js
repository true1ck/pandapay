'use strict';
// The sync route passes the phone's page size (?limit=) to storage and keeps the page contract: has-more header,
// the cursor storage returned, nothing else changed.
const test = require('node:test');
const assert = require('node:assert/strict');
const storage = require('../../src/sms_v2/storage');
const { createSyncHandler } = require('../../src/sms_v2/sync_route');

async function run(query) {
  const seen = [];
  const headers = {};
  const hooks = {
    security: { verifyAttestation: async () => true, checkRate: async () => true },
    aiResultsSince: async () => [], correctionStatusSince: async () => [], latestBundleVersion: async () => 7,
  };
  const original = storage.readChanges;
  storage.readChanges = async (_c, _p, cursor, hookCursors, opts) => {
    seen.push({ cursor, hookCursors, opts });
    return { cursor: 'next', instruments: [], events: [], ledger: [], facts: [], updatedAt: {}, hasMore: true };
  };
  try {
    let status = 200; let body;
    const res = { set(k, v) { headers[k] = v; return this; }, status(s) { status = s; return this; }, json(b) { body = b; return this; } };
    await createSyncHandler({ withUserClient: async (_i, fn) => fn({}), hooks })({ query, userId: 'u1', get: () => undefined }, res);
    return { seen, headers, status, body };
  } finally { storage.readChanges = original; }
}

test('the phone\'s page size reaches storage; no size means the server default', async () => {
  const asked = await run({ cursor: storage.encodeCursor({}), limit: '100' });
  assert.equal(asked.seen[0].opts.limit, '100');
  const none = await run({ cursor: storage.encodeCursor({}) });
  assert.equal(none.seen[0].opts.limit, undefined);
  assert.equal(none.headers['X-Sms-Sync-Has-More'], '1');
  assert.equal(none.body.cursor, 'next');
  assert.equal(none.body.latestBundleVersion, 7);
});

test('a repeated ?limit= uses the first value, like the cursor', async () => {
  const out = await run({ cursor: storage.encodeCursor({}), limit: ['60', '900'] });
  assert.equal(out.seen[0].opts.limit, '60');
});

test('page sizes are clamped to 1..1000 and default to 250', () => {
  assert.equal(storage.SYNC_PAGE_DEFAULT, 250);
  assert.equal(storage.syncPageSize(undefined), 250);
  assert.equal(storage.syncPageSize('100'), 100);
  assert.equal(storage.syncPageSize(' 40 '), 40);
  assert.equal(storage.syncPageSize('5000'), 1000);
  for (const bad of ['0', '-3', '1.5', 'abc', '', null, 0, 2.5, {}]) assert.equal(storage.syncPageSize(bad), 250, String(bad));
});
