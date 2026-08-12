const test = require('node:test');
const assert = require('node:assert');

const { safeUrl } = require('../src/observability');

// Plan Phase 0.4. Redaction is the only part of the logger with real
// consequences: a log line is a copy of data that outlives the request and
// gets shipped to a third-party platform. These assert that the values which
// actually appear in this service's query strings — OTP codes, tokens,
// affiliate click tokens, webhook signatures — never make it into one.

test('a plain path is unchanged', () => {
  assert.strictEqual(safeUrl('/user-cards'), '/user-cards');
});

test('non-sensitive query values survive, because they are what makes a log useful', () => {
  assert.strictEqual(safeUrl('/export?scope=all&format=csv'), '/export?scope=all&format=csv');
});

test('an OTP code is redacted', () => {
  assert.strictEqual(safeUrl('/auth/verify?code=482913'), '/auth/verify?code=[redacted]');
});

test('tokens are redacted in every spelling used in this codebase', () => {
  assert.strictEqual(safeUrl('/x?token=abc'), '/x?token=[redacted]');
  assert.strictEqual(safeUrl('/x?access_token=abc'), '/x?access_token=[redacted]');
  assert.strictEqual(safeUrl('/x?refresh_token=abc'), '/x?refresh_token=[redacted]');
});

test('an affiliate click token is redacted', () => {
  // `subid` is the default token_param in migration 0030 — a click token in a
  // log is an attribution record tied to a specific user's outbound tap.
  assert.strictEqual(safeUrl('/go?subid=deadbeef'), '/go?subid=[redacted]');
});

test('redaction is case-insensitive on the key', () => {
  assert.strictEqual(safeUrl('/x?Token=abc&OTP=1234'), '/x?Token=[redacted]&OTP=[redacted]');
});

test('a sensitive key mixed with safe ones redacts only the sensitive one', () => {
  assert.strictEqual(
    safeUrl('/x?scope=all&secret=hunter2&format=json'),
    '/x?scope=all&secret=[redacted]&format=json'
  );
});

test('a valueless query key does not crash the logger', () => {
  // Telemetry must never be the thing that takes a request down.
  assert.strictEqual(safeUrl('/x?flag'), '/x?flag');
});

test('path parameters are deliberately left intact', () => {
  // Ids are what make a log line answerable for support; they are not secrets.
  assert.strictEqual(safeUrl('/user-cards/abc-123/archive'), '/user-cards/abc-123/archive');
});
