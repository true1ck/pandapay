'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { JSON_BODY_LIMIT_BYTES, jsonBodyParser, jsonBodyErrorHandler } = require('../src/middleware/requestLimits');

test('auth retains its 100 KiB JSON contract and returns safe 400/413 responses', async t => {
  const app = express();
  app.use(jsonBodyParser, jsonBodyErrorHandler);
  app.post('/fixture', (req, res) => res.json(req.body));
  const server = await new Promise(resolve => { const value = app.listen(0, '127.0.0.1', () => resolve(value)); });
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const url = `http://127.0.0.1:${server.address().port}/fixture`;
  const send = body => fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
  assert.equal(JSON_BODY_LIMIT_BYTES, 102400);
  const valid = await send('{"phone_number":"+919876543210"}');
  assert.equal(valid.status, 200);
  assert.deepEqual(await valid.json(), { phone_number: '+919876543210' });
  const invalid = await send('{"token":"private",');
  assert.equal(invalid.status, 400);
  assert.deepEqual(await invalid.json(), { error: 'invalid_json' });
  const large = await send(JSON.stringify({ data: 'a'.repeat(JSON_BODY_LIMIT_BYTES) }));
  assert.equal(large.status, 413);
  assert.deepEqual(await large.json(), { error: 'payload_too_large' });
});
