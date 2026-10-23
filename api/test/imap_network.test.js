'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  createPinnedImapResolution,
  createPinnedTlsOptions,
  isPublicAddress,
  isValidImapHost,
  resolvePublicImapHost,
} = require('../src/imap_network');

test('public destination classifier allows global addresses and blocks special-use ranges', () => {
  assert.equal(isPublicAddress('8.8.8.8', 4), true);
  assert.equal(isPublicAddress('2001:4860:4860::8888', 6), true);
  for (const address of [
    '0.1.2.3', '10.0.0.1', '100.64.0.1', '127.0.0.1', '169.254.169.254',
    '172.16.0.1', '168.63.129.16', '192.0.2.1', '192.168.1.2', '198.18.0.1', '203.0.113.1',
    '224.0.0.1', '240.0.0.1',
  ]) assert.equal(isPublicAddress(address, 4), false, address);
  for (const address of [
    '::', '::1', 'fc00::1', 'fe80::1', 'ff02::1', '::ffff:8.8.8.8',
    '64:ff9b::808:808', '2001::1', '2002:0808:0808::1', '2001:db8::1', '3ffe::1', '3fff::1',
  ]) assert.equal(isPublicAddress(address, 6), false, address);
});

test('hostname syntax rejects URL, numeric shorthand, and control-character forms', () => {
  assert.equal(isValidImapHost('imap.example.com'), true);
  assert.equal(isValidImapHost('mail.example.com.'), true);
  assert.equal(isValidImapHost('8.8.8.8'), true);
  assert.equal(isValidImapHost('http://127.0.0.1'), false);
  assert.equal(isValidImapHost('2130706433'), false);
  assert.equal(isValidImapHost('imap.example.com\r\nNOOP'), false);
});

test('resolver validates every answer and pins the validated set in lookup callbacks', async () => {
  let lookupCalls = 0;
  const resolved = await resolvePublicImapHost('imap.example.com', {
    lookupAll: async (host, options) => {
      lookupCalls += 1;
      assert.equal(host, 'imap.example.com');
      assert.deepEqual(options, { all: true, order: 'verbatim' });
      return [
        { address: '8.8.8.8', family: 4 },
        { address: '2001:4860:4860::8888', family: 6 },
      ];
    },
  });
  assert.equal(lookupCalls, 1);
  resolved.lookup('imap.example.com', { all: true }, (error, addresses) => {
    assert.equal(error, null);
    assert.deepEqual(addresses, [
      { address: '8.8.8.8', family: 4 },
      { address: '2001:4860:4860::8888', family: 6 },
    ]);
  });
  resolved.lookup('imap.example.com', { family: 6 }, (error, address, family) => {
    assert.equal(error, null);
    assert.equal(address, '2001:4860:4860::8888');
    assert.equal(family, 6);
  });
});

test('resolver rejects unsafe mixed DNS answers instead of selecting a public subset', async () => {
  await assert.rejects(
    resolvePublicImapHost('imap.example.com', {
      lookupAll: async () => [
        { address: '8.8.8.8', family: 4 },
        { address: '169.254.169.254', family: 4 },
      ],
    }),
    { code: 'imap_host_not_public' },
  );
});

test('IP literals are validated without DNS and TLS options retain name verification', () => {
  const resolution = createPinnedImapResolution('imap.example.com', [
    { address: '8.8.8.8', family: 4 },
  ]);
  const options = createPinnedTlsOptions(resolution, 1993);
  assert.equal(options.host, 'imap.example.com');
  assert.equal(options.port, 1993);
  assert.equal(options.servername, 'imap.example.com');
  assert.equal(options.rejectUnauthorized, true);
  assert.equal(typeof options.lookup, 'function');
  assert.equal(typeof options.checkServerIdentity, 'function');
  assert.equal(
    options.checkServerIdentity('8.8.8.8', { subjectaltname: 'DNS:other.example' }).host,
    'imap.example.com',
  );
});

test('public IP literal resolution does not consult DNS', async () => {
  let called = false;
  const resolved = await resolvePublicImapHost('8.8.8.8', {
    lookupAll: async () => { called = true; return []; },
  });
  assert.equal(called, false);
  assert.deepEqual(resolved.addresses, [{ address: '8.8.8.8', family: 4 }]);
  await assert.rejects(resolvePublicImapHost('127.0.0.1', {
    lookupAll: async () => { called = true; return []; },
  }), { code: 'imap_host_not_public' });
  assert.equal(called, false);
});
