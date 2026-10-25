'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { safeUrl, requestLogger, errorHandler } = require('../src/observability');
const { EventEmitter } = require('node:events');

test('encoded, nested and unknown query values cannot enter logs', () => {
  for (const query of ['email=synthetic-private@example.com', '%74oken=synthetic-secret', 'x[a]=synthetic-secret&flag', 'lat=18.5&lng=73.8']) {
    assert.equal(safeUrl('/auth/me?' + query), '/auth/me');
  }
});
test('request logs use route templates and error logs exclude exception contents', () => {
  const events = [];
  const out = process.stdout.write, err = process.stderr.write;
  process.stdout.write = line => { events.push(JSON.parse(line)); return true; };
  process.stderr.write = line => { events.push(JSON.parse(line)); return true; };
  try {
    const req = { get: () => null, method: 'POST', baseUrl: '/auth', route: { path: '/device/:id' }, originalUrl: '/auth/device/synthetic-secret?code=1234' };
    const res = new EventEmitter(); res.statusCode = 200; res.setHeader = () => {};
    requestLogger(req, res, () => {}); res.emit('finish');
    res.status = () => res; res.json = () => {};
    errorHandler(new Error('synthetic-private-error'), req, res, () => {});
    assert.equal(events[0].path, '/auth/device/:id');
    assert.equal(JSON.stringify(events).includes('synthetic-'), false);
  } finally { process.stdout.write = out; process.stderr.write = err; }
});

function runLoggerWithRequestId(value) {
  const req = {
    get: () => value,
    method: 'GET',
    route: { path: '/health' },
    baseUrl: '',
  };
  const res = new EventEmitter();
  res.statusCode = 200;
  let responseId;
  res.setHeader = (name, id) => { if (name === 'x-request-id') responseId = id; };
  requestLogger(req, res, () => {});
  res.emit('finish');
  return { reqId: req.requestId, responseId };
}

test('bounded safe request IDs are preserved across logs and response headers', () => {
  const out = process.stdout.write;
  const lines = [];
  process.stdout.write = line => { lines.push(JSON.parse(line)); return true; };
  try {
    const ids = ['trace-01_A.b', 'a'.repeat(128)];
    for (const id of ids) {
      const result = runLoggerWithRequestId(id);
      assert.equal(result.reqId, id);
      assert.equal(result.responseId, id);
      assert.equal(lines.at(-1).requestId, id);
    }
  } finally {
    process.stdout.write = out;
  }
});

test('contact, header injection, arrays and overlong request IDs are replaced', () => {
  for (const value of ['private@example.com', 'secret\r\nvalue', ['safe', 'secret'], 'x'.repeat(129), '']) {
    const result = runLoggerWithRequestId(value);
    assert.match(result.reqId, /^[0-9a-f-]{36}$/);
    assert.equal(result.responseId, result.reqId);
  }
});

test('auth ordinary request logs omit account identifiers', () => {
  const output = process.stdout.write;
  const lines = [];
  process.stdout.write = line => { lines.push(JSON.parse(line)); return true; };
  try {
    const req = { get: () => 'support-case', method: 'GET', route: { path: '/users/me' }, user: { id: 'private-account-uuid' } };
    const res = new EventEmitter();
    res.statusCode = 200; res.setHeader = () => {};
    requestLogger(req, res, () => {}); res.emit('finish');
    assert.equal(lines[0].authenticated, true);
    assert.equal('userId' in lines[0], false);
    assert.equal(JSON.stringify(lines).includes(req.user.id), false);
  } finally { process.stdout.write = output; }
});
