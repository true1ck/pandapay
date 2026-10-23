'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { fetchRecentMessages } = require('../src/imap_client');
const { createPinnedImapResolution } = require('../src/imap_network');

function fakeSocket() {
  const socket = new EventEmitter();
  socket.end = () => {};
  socket.destroy = () => {};
  socket.setEncoding = () => {};
  socket.write = (command) => {
    if (command.startsWith('a1 LOGIN ')) {
      setImmediate(() => socket.emit('data', 'a1 NO user=member@example.com password=private-secret\r\n'));
    }
  };
  return socket;
}

function fetchWithSocket(socket) {
  const promise = fetchRecentMessages({
    host: 'imap.example.com',
    port: 993,
    email: 'member@example.com',
    password: 'private-secret',
    since: new Date('2026-08-20T00:00:00Z'),
    tlsConnect: () => socket,
    resolveHost: async (host) => createPinnedImapResolution(host, [
      { address: '8.8.8.8', family: 4 },
    ]),
  });
  return promise;
}

test('poller reports authentication failure as a stable code without reflecting server text', async () => {
  const socket = fakeSocket();
  const resultPromise = fetchWithSocket(socket);
  setImmediate(() => socket.emit('secureConnect'));
  const result = await resultPromise;
  assert.deepEqual(result, { ok: false, reason: 'authentication_failed' });
  assert.doesNotMatch(result.reason, /member@example\.com|private-secret/);
});

test('poller socket errors do not reflect credential-bearing exception messages', async () => {
  const socket = fakeSocket();
  const resultPromise = fetchWithSocket(socket);
  const error = new Error('password=private-secret bearer=token-value');
  error.code = 'ECONNRESET';
  setImmediate(() => socket.emit('error', error));

  const result = await resultPromise;
  assert.deepEqual(result, { ok: false, reason: 'socket_error' });
  assert.doesNotMatch(result.reason, /private-secret|token-value/);
});

test('poller closed sessions use a stable reason code', async () => {
  const socket = fakeSocket();
  const resultPromise = fetchWithSocket(socket);
  setImmediate(() => socket.emit('end'));

  assert.deepEqual(await resultPromise, { ok: false, reason: 'connection_closed' });
});

test('poller rejects command controls before resolving a host or opening TLS', async () => {
  let touched = false;
  const result = await fetchRecentMessages({
    host: 'imap.example.com',
    email: 'member@example.com',
    password: 'safe-password',
    since: new Date('2026-08-20T00:00:00Z'),
    senderFilter: 'alerts@example.com\r\nNOOP',
    resolveHost: async () => { touched = true; throw new Error('must not resolve'); },
    tlsConnect: () => { touched = true; throw new Error('must not connect'); },
  });
  assert.deepEqual(result, { ok: false, reason: 'invalid_imap_argument' });
  assert.equal(touched, false);
});

test('poller TLS connection uses pinned DNS and preserves verified custom-host TLS', async () => {
  const socket = fakeSocket();
  let options;
  const resultPromise = fetchRecentMessages({
    host: 'imap.example.com',
    port: 2993,
    email: 'member@example.com',
    password: 'safe-password',
    since: new Date('2026-08-20T00:00:00Z'),
    tlsConnect: (tlsOptions) => { options = tlsOptions; return socket; },
    resolveHost: async (host) => createPinnedImapResolution(host, [
      { address: '8.8.8.8', family: 4 },
    ]),
  });
  setImmediate(() => socket.emit('error', new Error('synthetic connect failure')));

  assert.deepEqual(await resultPromise, { ok: false, reason: 'socket_error' });
  assert.equal(options.host, 'imap.example.com');
  assert.equal(options.port, 2993);
  assert.equal(options.servername, 'imap.example.com');
  assert.equal(options.rejectUnauthorized, true);
  assert.equal(typeof options.lookup, 'function');
  assert.equal(typeof options.checkServerIdentity, 'function');
  options.lookup('imap.example.com', { all: true }, (error, addresses) => {
    assert.equal(error, null);
    assert.deepEqual(addresses, [{ address: '8.8.8.8', family: 4 }]);
  });
});

test('poller response cap counts UTF-8 bytes and destroys the socket', async () => {
  const socket = fakeSocket();
  let destroyed = false;
  socket.destroy = () => { destroyed = true; };
  const resultPromise = fetchWithSocket(socket);
  setImmediate(() => socket.emit('data', '€'.repeat(3 * 1024 * 1024)));

  assert.deepEqual(await resultPromise, { ok: false, reason: 'response_too_large' });
  assert.equal(destroyed, true);
});
