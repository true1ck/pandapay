const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { testImapLogin } = require('../src/imap_test');
const { createPinnedImapResolution } = require('../src/imap_network');

function resolvePublicTestHost(host) {
  return Promise.resolve(createPinnedImapResolution(host, [
    { address: '8.8.8.8', family: 4 },
  ]));
}

// Every connection in this suite uses a synthetic resolver and, where needed,
// an EventEmitter socket. Tests do not reach a real mail provider or open a
// network connection.

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

test('testImapLogin resolves ok:false when public-network policy rejects a loopback host', async () => {
  const result = await testImapLogin({
    host: '127.0.0.1',
    port: 1, // nothing listens on port 1
    email: 'a@b.com',
    password: 'x',
    timeoutMs: 2000,
    resolveHost: async () => { throw Object.assign(new Error('synthetic'), { code: 'imap_host_not_public' }); },
  });
  assert.equal(result.ok, false);
  assert.equal(typeof result.reason, 'string');
});

test('testImapLogin resolves ok:false on DNS failure', async () => {
  const result = await testImapLogin({
    host: 'this-host-does-not-exist.invalid',
    port: 993,
    email: 'a@b.com',
    password: 'x',
    timeoutMs: 5000,
    resolveHost: async () => { throw Object.assign(new Error('synthetic'), { code: 'imap_dns_failed' }); },
  });
  assert.equal(result.ok, false);
  assert.equal(typeof result.reason, 'string');
});

test('testImapLogin timeout prevents a late DNS result from opening TLS', async () => {
  let resolveLookup;
  let tlsCalls = 0;
  const resultPromise = testImapLogin({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'safe-password',
    timeoutMs: 5,
    resolveHost: () => new Promise((resolve) => { resolveLookup = resolve; }),
    tlsConnect: () => { tlsCalls += 1; throw new Error('must not connect'); },
  });

  assert.deepEqual(await resultPromise, { ok: false, reason: 'Connection timed out.' });
  resolveLookup(createPinnedImapResolution('imap.example.com', [
    { address: '8.8.8.8', family: 4 },
  ]));
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(tlsCalls, 0);
});

test('testImapLogin does not reflect a credential-bearing IMAP BAD response', async () => {
  const socket = new EventEmitter();
  socket.end = () => {};
  socket.write = () => {};
  const resultPromise = testImapLogin({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'mail-password-secret',
    timeoutMs: 1000,
    tlsConnect: () => socket,
    resolveHost: resolvePublicTestHost,
  });
  queueMicrotask(() => {
    socket.emit('secureConnect');
    socket.emit('data', Buffer.from('* OK ready\r\n'));
    socket.emit('data', Buffer.from('a1 BAD bearer-token-secret member@example.com\r\n'));
  });

  const result = await resultPromise;
  assert.deepEqual(result, {
    ok: false,
    reason: 'IMAP server could not complete the login request.',
  });
  assert.equal(result.reason.includes('bearer-token-secret'), false);
  assert.equal(result.reason.includes('member@example.com'), false);
});

test('testImapLogin maps TLS socket errors to a static helpful reason', async () => {
  const socket = new EventEmitter();
  socket.end = () => {};
  socket.write = () => {};
  const resultPromise = testImapLogin({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'mail-password-secret',
    timeoutMs: 1000,
    tlsConnect: () => socket,
    resolveHost: resolvePublicTestHost,
  });
  queueMicrotask(() => {
    const error = new Error('password=mail-password-secret token=bearer-token-secret');
    error.code = 'ERR_TLS_CERT_ALTNAME_INVALID';
    socket.emit('error', error);
  });

  const result = await resultPromise;
  assert.equal(result.ok, false);
  assert.equal(result.reason, 'Secure IMAP connection failed; check the server certificate and hostname.');
  assert.equal(result.reason.includes('mail-password-secret'), false);
  assert.equal(result.reason.includes('bearer-token-secret'), false);
});

test('testImapLogin pins TLS to validated lookup and retains hostname verification', async () => {
  const socket = new EventEmitter();
  socket.end = () => {};
  socket.destroy = () => {};
  socket.write = () => setImmediate(() => socket.emit('data', 'a1 OK logged in\r\n'));
  let options;
  const resultPromise = testImapLogin({
    host: 'imap.example.com',
    port: 1993,
    email: 'member@example.com',
    password: 'safe-password',
    timeoutMs: 1000,
    tlsConnect: (tlsOptions) => { options = tlsOptions; return socket; },
    resolveHost: resolvePublicTestHost,
  });
  setImmediate(() => {
    socket.emit('secureConnect');
    socket.emit('data', '* OK ready\r\n');
  });

  assert.deepEqual(await resultPromise, { ok: true });
  assert.equal(options.host, 'imap.example.com');
  assert.equal(options.port, 1993);
  assert.equal(options.servername, 'imap.example.com');
  assert.equal(options.rejectUnauthorized, true);
  assert.equal(typeof options.lookup, 'function');
  assert.equal(typeof options.checkServerIdentity, 'function');
  options.lookup('imap.example.com', { all: true }, (error, addresses) => {
    assert.equal(error, null);
    assert.deepEqual(addresses, [{ address: '8.8.8.8', family: 4 }]);
  });
});

test('testImapLogin rejects control characters before DNS or socket access', async () => {
  let resolved = false;
  const result = await testImapLogin({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'safe\r\nNOOP',
    resolveHost: async () => { resolved = true; return resolvePublicTestHost('imap.example.com'); },
    tlsConnect: () => { throw new Error('must not connect'); },
  });
  assert.deepEqual(result, { ok: false, reason: 'IMAP settings contain unsupported control characters.' });
  assert.equal(resolved, false);
});

test('testImapLogin applies a cumulative 64 KiB response limit', async () => {
  const socket = new EventEmitter();
  socket.end = () => {};
  let destroyed = false;
  socket.destroy = () => { destroyed = true; };
  socket.write = () => {};
  const resultPromise = testImapLogin({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'safe-password',
    timeoutMs: 1000,
    tlsConnect: () => socket,
    resolveHost: resolvePublicTestHost,
  });
  setImmediate(() => {
    socket.emit('data', 'x'.repeat(40 * 1024));
    socket.emit('data', `y${'z'.repeat(25 * 1024 - 1)} credential-secret@example.com`);
  });
  const result = await resultPromise;
  assert.deepEqual(result, { ok: false, reason: 'IMAP server response was too large.' });
  assert.equal(destroyed, true);
  assert.equal(result.reason.includes('credential-secret@example.com'), false);
});
