const test = require('node:test');
const assert = require('node:assert');
const { EventEmitter } = require('node:events');

const { safeUrl, requestLogger } = require('../src/observability');

// Plan Phase 0.4. Redaction is the only part of the logger with real
// consequences: a log line is a copy of data that outlives the request and
// gets shipped to a third-party platform. These assert that the values which
// actually appear in this service's query strings — OTP codes, tokens,
// affiliate click tokens, webhook signatures — never make it into one.

test('a plain path is unchanged', () => {
  assert.strictEqual(safeUrl('/user-cards'), '/user-cards');
});

test('all query values are excluded, including currently harmless export options', () => {
  assert.strictEqual(safeUrl('/export?scope=all&format=csv'), '/export');
});

test('an OTP code is redacted', () => {
  assert.strictEqual(safeUrl('/auth/verify?code=482913'), '/auth/verify');
});

test('tokens are redacted in every spelling used in this codebase', () => {
  assert.strictEqual(safeUrl('/x?token=abc'), '/x');
  assert.strictEqual(safeUrl('/x?access_token=abc'), '/x');
  assert.strictEqual(safeUrl('/x?refresh_token=abc'), '/x');
});

test('an affiliate click token is redacted', () => {
  // `subid` is the default token_param in migration 0030 — a click token in a
  // log is an attribution record tied to a specific user's outbound tap.
  assert.strictEqual(safeUrl('/go?subid=deadbeef'), '/go');
});

test('redaction is case-insensitive on the key', () => {
  assert.strictEqual(safeUrl('/x?Token=abc&OTP=1234'), '/x');
});

test('a sensitive key mixed with safe ones redacts only the sensitive one', () => {
  assert.strictEqual(
    safeUrl('/x?scope=all&secret=hunter2&format=json'),
    '/x'
  );
});

test('a valueless query key does not crash the logger', () => {
  // Telemetry must never be the thing that takes a request down.
  assert.strictEqual(safeUrl('/x?flag'), '/x');
});

test('path parameters are deliberately left intact', () => {
  // Ids are what make a log line answerable for support; they are not secrets.
  assert.strictEqual(safeUrl('/user-cards/abc-123/archive'), '/user-cards/abc-123/archive');
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
      assert.strictEqual(result.reqId, id);
      assert.strictEqual(result.responseId, id);
      assert.strictEqual(lines.at(-1).requestId, id);
    }
  } finally {
    process.stdout.write = out;
  }
});

test('ordinary request logs omit persistent account identifiers', () => {
  const output = process.stdout.write;
  const lines = [];
  process.stdout.write = line => { lines.push(JSON.parse(line)); return true; };
  try {
    const req = { get: () => 'support-case', method: 'GET', route: { path: '/profile' }, userId: 'private-account-uuid' };
    const res = new EventEmitter();
    res.statusCode = 200;
    res.setHeader = () => {};
    requestLogger(req, res, () => {});
    res.emit('finish');
    assert.equal(lines[0].authenticated, true);
    assert.equal('userId' in lines[0], false);
    assert.equal(JSON.stringify(lines).includes(req.userId), false);
  } finally { process.stdout.write = output; }
});

test('contact, header injection, arrays and overlong request IDs are replaced', () => {
  for (const value of ['private@example.com', 'secret\r\nvalue', ['safe', 'secret'], 'x'.repeat(129), '']) {
    const result = runLoggerWithRequestId(value);
    assert.match(result.reqId, /^[0-9a-f-]{36}$/);
    assert.strictEqual(result.responseId, result.reqId);
  }
});
