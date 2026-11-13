'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { JSON_BODY_LIMIT_BYTES, jsonBodyParser, jsonBodyErrorHandler } = require('../src/request_limits');
const { SYNC_PUSH_BODY_LIMIT_BYTES, syncPushBodyParser } = require('../src/sync_push_body');
const fs = require('node:fs');
const helpers = require('../src/sync_request_validation');

const USER = '10000000-0000-4000-8000-000000000001';
const DEVICE = '20000000-0000-4000-8000-000000000001';

// Mirrors the mounting order in index.js: identity, sync parser, global parser.
async function server(t) {
  const app = express();
  app.use((req, _res, next) => { req.userId = req.headers['x-test-user'] || null; next(); });
  app.use('/sync/push', syncPushBodyParser);
  app.use(jsonBodyParser);
  app.use(jsonBodyErrorHandler);
  app.post('/sync/push', (req, res) => {
    const checked = helpers.validateSyncPushRequest(req.body);
    res.status(checked.error ? checked.status : 200).json({ changes: checked.value?.changes.length ?? null, error: checked.error });
  });
  app.post('/other', (req, res) => res.json({ ok: true }));
  const http = await new Promise((resolve) => { const value = app.listen(0, '127.0.0.1', () => resolve(value)); });
  t.after(() => new Promise((resolve) => { http.close(resolve); http.closeAllConnections(); }));
  return `http://127.0.0.1:${http.address().port}`;
}

const post = (url, body, user) => fetch(url, {
  method: 'POST',
  headers: { 'content-type': 'application/json', ...(user ? { 'x-test-user': user } : {}) },
  body: JSON.stringify(body),
});

function bigPush(changeCount, bytesPerChange) {
  return {
    deviceId: DEVICE,
    changes: Array.from({ length: changeCount }, (_, i) => ({
      entity: 'user_commitments',
      entityId: `30000000-0000-4000-8000-${String(i).padStart(12, '0')}`,
      op: 'update',
      payload: { document: 'x'.repeat(bytesPerChange) },
      fieldClocks: {},
      clientSeq: i + 1,
    })),
  };
}

test('limits: global stays 100 KiB, sync push gets 1 MiB', () => {
  assert.equal(JSON_BODY_LIMIT_BYTES, 100 * 1024);
  assert.equal(SYNC_PUSH_BODY_LIMIT_BYTES, 1024 * 1024);
});

test('a 200-change push of about 800 KiB (over the old global limit) is accepted', async (t) => {
  const base = await server(t);
  const small = bigPush(200, 4 * 1024);
  assert.ok(JSON.stringify(small).length > JSON_BODY_LIMIT_BYTES, 'would have hit the old global limit');
  const accepted = await post(`${base}/sync/push`, small, USER);
  assert.equal(accepted.status, 200);
  assert.equal((await accepted.json()).changes, 200);
});

test('a batch over the sync limit is 413 payload_too_large', async (t) => {
  const base = await server(t);
  const tooBig = bigPush(100, 16 * 1024);
  assert.ok(JSON.stringify(tooBig).length > SYNC_PUSH_BODY_LIMIT_BYTES);
  const response = await post(`${base}/sync/push`, tooBig, USER);
  assert.equal(response.status, 413);
  assert.deepEqual(await response.json(), { error: 'payload_too_large' });
});

test('the 200-change count limit is kept', async (t) => {
  const base = await server(t);
  const response = await post(`${base}/sync/push`, bigPush(201, 10), USER);
  assert.equal(response.status, 413);
  assert.match((await response.json()).error, /too many changes/);
});

test('unauthenticated sync push and every other route keep the 100 KiB limit', async (t) => {
  const base = await server(t);
  const mid = bigPush(100, 4 * 1024);
  assert.ok(JSON.stringify(mid).length > JSON_BODY_LIMIT_BYTES);
  assert.equal((await post(`${base}/sync/push`, mid)).status, 413);
  assert.equal((await post(`${base}/other`, mid, USER)).status, 413);
  assert.equal((await post(`${base}/other`, { small: true }, USER)).status, 200);
});

test('index.js mounts the sync parser before the global JSON parser', () => {
  const source = fs.readFileSync(require.resolve('../src/index'), 'utf8').split('\r\n').join('\n');
  const sync = source.indexOf("app.use('/sync/push', syncPushBodyParser);");
  const global = source.indexOf('app.use(jsonBodyParser);');
  assert.ok(sync > 0 && global > 0 && sync < global);
});

test('malformed JSON on the sync route is a 400 invalid_json', async (t) => {
  const base = await server(t);
  const response = await fetch(`${base}/sync/push`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-test-user': USER }, body: '{nope' });
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), { error: 'invalid_json' });
});
