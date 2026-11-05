'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerNotificationDeviceRoutes } = require('../src/notification_devices_route');

async function withServer(notificationService, fn) {
  const app = express();
  app.use(express.json());
  registerNotificationDeviceRoutes(app, {
    requireAuth: (req, _res, next) => { req.userId = 'u1'; next(); },
    notificationService,
    logger: { error() {} },
  });
  const server = app.listen(0);
  try {
    const { port } = server.address();
    return await fn(`http://127.0.0.1:${port}/notification-devices`);
  } finally {
    server.close();
  }
}

const del = (url, body) => fetch(url, {
  method: 'DELETE',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

test('DELETE /notification-devices removes only this phone token', async () => {
  const calls = [];
  await withServer({ unregisterDevice: async (args) => { calls.push(args); } }, async (url) => {
    const res = await del(url, { token: 'x'.repeat(20) });
    assert.equal(res.status, 204);
  });
  assert.deepEqual(calls, [{ subscriberId: 'u1', token: 'x'.repeat(20) }]);
});

test('DELETE /notification-devices rejects a missing or oversized token', async () => {
  const calls = [];
  await withServer({ unregisterDevice: async (args) => { calls.push(args); } }, async (url) => {
    assert.equal((await del(url, {})).status, 400);
    assert.equal((await del(url, { token: 'short' })).status, 400);
    assert.equal((await del(url, { token: 'x'.repeat(4097) })).status, 400);
  });
  assert.deepEqual(calls, []);
});

test('DELETE /notification-devices reports a provider failure without leaking details', async () => {
  await withServer({ unregisterDevice: async () => { throw new Error('secret provider detail'); } }, async (url) => {
    const res = await del(url, { token: 'x'.repeat(20) });
    assert.equal(res.status, 502);
    assert.deepEqual(await res.json(), { error: 'notification_provider_unavailable' });
  });
});
