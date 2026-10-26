'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');

function load(fetch) {
  const module = { exports: {} };
  const config = { notificationServiceUrl: 'http://synthetic-provider.invalid', notificationServiceApiKey: 'synthetic',
    notificationServiceWorkflowIdentifier: 'fixture', notificationServiceWorkflowName: 'Fixture', notificationServiceTimeoutMs: 1000 };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/notification_service.js'), 'utf8'), {
    module, exports: module.exports, require: name => name === './config' ? config : require(name),
    fetch, AbortController, AbortSignal, URL, setTimeout, clearTimeout,
  });
  return module.exports;
}
function workflow() { return { ok: true, status: 200, json: async () => [{ identifier: 'fixture', steps: [{ template: { title: 'Title', body: 'Body' } }] }] }; }
const payload = signal => ({ subscriberId: 'profile', title: 'Title', body: 'Body', dedupeKey: 'notification:revision', signal });
test('already aborted durable delivery never calls a provider', async () => {
  const service = load(async () => assert.fail('no provider call after cancellation'));
  const c = new AbortController(); c.abort();
  await assert.rejects(service.send(payload(c.signal)), error => error.name === 'AbortError');
});
test('active trigger cancellation reaches the fetch signal and prevents a retry', async () => {
  let calls = 0; let entered; const started = new Promise(r => { entered = r; });
  const service = load(async (url, options) => {
    if (url.endsWith('/workflows')) return workflow();
    calls++;
    assert.equal(options.headers['Idempotency-Key'], 'notification:revision');
    entered();
    return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')), { once: true }));
  });
  const c = new AbortController(); const sending = service.send(payload(c.signal));
  await started; c.abort(); await assert.rejects(sending, error => error.name === 'AbortError');
  assert.equal(calls, 1);
});
test('cancellation while reading the response cannot be recorded as accepted delivery', async () => {
  let entered; const started = new Promise(r => { entered = r; });
  const service = load(async (url, options) => {
    if (url.endsWith('/workflows')) return workflow();
    return { ok: true, status: 200, json: () => { entered(); return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(new Error('aborted body')), { once: true })); } };
  });
  const c = new AbortController(); const sending = service.send(payload(c.signal));
  await started; c.abort(); await assert.rejects(sending, error => error.name === 'AbortError');
});
