'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createNotificationPostHandler } = require('../src/notification_routes');

function fixture(options = {}) {
  const calls = []; const sends = []; let committed = false;
  const notification = { id: 'synthetic-notification', title: 'Title', body: 'Body', category: 'caps', severity: 'info', dedupe_key: 'stable' };
  const client = { query: async (sql, args) => {
    calls.push([sql, args]);
    return sql.includes('notification_preferences') ? { rowCount: 0, rows: [] } : { rowCount: 1, rows: [notification] };
  } };
  const res = { statusCode: 200, status(v) { this.statusCode = v; return this; }, json(v) { this.body = v; return this; }, end() { return this; } };
  const handler = createNotificationPostHandler({
    withUserClient: async (id, fn) => { assert.equal(id, 'profile'); const result = await fn(client); committed = true; return result; },
    notificationService: { isConfigured: () => true, send: async payload => { assert.equal(committed, true); sends.push(payload); } },
    logger: { error() {} }, ...options,
  });
  return { handler, res, calls, sends, client, notification, isCommitted: () => committed };
}
const request = extra => ({ userId: 'profile', body: { category: 'caps', title: 'Title', sendRemote: true, ...extra } });

test('disabled outbox retains the existing inbox response and post-commit best-effort delivery', async () => {
  const f = fixture({ enqueue: async () => assert.fail('disabled feature cannot enqueue') });
  await f.handler(request(), f.res);
  assert.equal(f.res.statusCode, 201); assert.deepEqual(f.res.body, { notification: f.notification });
  assert.equal(f.sends.length, 1); assert.equal(f.calls.length, 2);
});
test('enabled outbox enqueues inside the same user transaction and never double-sends directly', async () => {
  let f; let queued = 0;
  f = fixture({ outboxEnabled: true, enqueue: async (client, id) => {
    assert.equal(client, f.client); assert.equal(id, f.notification.id); assert.equal(f.isCommitted(), false); queued++;
  } });
  await f.handler(request(), f.res);
  assert.equal(queued, 1); assert.equal(f.res.statusCode, 201); assert.equal(f.sends.length, 0);
});
test('muted categories create neither inbox nor durable remote intent', async () => {
  const f = fixture({ outboxEnabled: true, enqueue: async () => assert.fail('muted notification cannot enqueue') });
  f.client.query = async () => ({ rowCount: 1, rows: [{ enabled: false }] });
  await f.handler(request(), f.res);
  assert.equal(f.res.statusCode, 204); assert.equal(f.sends.length, 0);
});
test('enqueue failure prevents the surrounding transaction from completing and direct remote delivery', async () => {
  const f = fixture({ outboxEnabled: true, enqueue: async () => { throw Object.assign(new Error('private database payload'), { code: '54000' }); } });
  await f.handler(request(), f.res);
  assert.equal(f.isCommitted(), false); assert.equal(f.res.statusCode, 500); assert.equal(f.sends.length, 0);
  assert.deepEqual(f.res.body, { error: 'internal_error' });
});
test('enabled remote payload is byte bounded before any database write', async () => {
  for (const extra of [{ title: 'x'.repeat(513) }, { body: 'x'.repeat(4097) }, { title: '😀'.repeat(129) }, { deepLink: {} }, { category: {} }]) {
    const f = fixture({ outboxEnabled: true }); await f.handler(request(extra), f.res);
    assert.equal(f.res.statusCode, 400); assert.equal(f.calls.length, 0);
  }
});
test('inbox-only writes remain available without remote queue admission', async () => {
  const f = fixture({ outboxEnabled: true, enqueue: async () => assert.fail('inbox only') });
  await f.handler(request({ sendRemote: false }), f.res);
  assert.equal(f.res.statusCode, 201); assert.equal(f.sends.length, 0);
});
test('prototype property names cannot select an invented SQL preference column', async () => {
  const f = fixture(); await f.handler(request({ category: 'constructor' }), f.res);
  assert.equal(f.calls.length, 1); assert.equal(f.calls[0][0].startsWith('INSERT'), true);
});
