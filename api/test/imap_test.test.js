const test = require('node:test');
const assert = require('node:assert/strict');
const { testImapLogin } = require('../src/imap_test');

// Node has no built-in X.509 cert-issuance API and this project adds no new
// npm dependency for tests, so this suite can't spin up a self-signed TLS
// IMAP server to exercise the full greeting/LOGIN/response parse locally.
// It instead verifies the two things that don't need a live TLS peer:
// argument validation, and that network failures resolve ok:false (never
// throw) so a caller can always show the user a message. The full
// handshake path was exercised manually against a real mail provider
// during development (rejected bad credentials cleanly, as expected).

test('testImapLogin throws synchronously on missing host', () => {
  assert.throws(() => {
    testImapLogin({ host: '', email: 'a@b.com', password: 'x' });
  }, /host is required/);
});

test('testImapLogin throws synchronously on missing email', () => {
  assert.throws(() => {
    testImapLogin({ host: 'imap.example.com', email: '', password: 'x' });
  }, /email is required/);
});

test('testImapLogin throws synchronously on missing password', () => {
  assert.throws(() => {
    testImapLogin({ host: 'imap.example.com', email: 'a@b.com', password: '' });
  }, /password is required/);
});

test('testImapLogin resolves ok:false (never throws) when nothing is listening', async () => {
  const result = await testImapLogin({
    host: '127.0.0.1',
    port: 1, // nothing listens on port 1
    email: 'a@b.com',
    password: 'x',
    timeoutMs: 2000,
  });
  assert.equal(result.ok, false);
  assert.equal(typeof result.reason, 'string');
});

test('testImapLogin resolves ok:false on an unresolvable hostname', async () => {
  const result = await testImapLogin({
    host: 'this-host-does-not-exist.invalid',
    port: 993,
    email: 'a@b.com',
    password: 'x',
    timeoutMs: 5000,
  });
  assert.equal(result.ok, false);
  assert.equal(typeof result.reason, 'string');
});
