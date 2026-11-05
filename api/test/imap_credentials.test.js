const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { sealPassword, openPassword, normalizeSenderFilter, loadImapKeyring } = require('../src/imap_credentials');

const key = { id: 'k1', bytes: crypto.randomBytes(32) };

test('password round-trips and is bound to its connection', () => {
  const sealed = sealPassword('app-pass-123', { profileId: 'p1', connectionId: 'c1' }, key);
  assert.equal(openPassword(sealed, { profileId: 'p1', connectionId: 'c1' }, new Map([['k1', key.bytes]])), 'app-pass-123');
  assert.throws(() => openPassword(sealed, { profileId: 'p2', connectionId: 'c1' }, new Map([['k1', key.bytes]])));
  assert.throws(() => openPassword(sealed, { profileId: 'p1', connectionId: 'c2' }, new Map([['k1', key.bytes]])));
});

test('sealed value never contains the password', () => {
  const sealed = sealPassword('app-pass-123', { profileId: 'p1', connectionId: 'c1' }, key);
  assert.ok(!sealed.ciphertext.toString('latin1').includes('app-pass-123'));
  assert.equal(sealed.keyId, 'k1');
});

test('a sealed value does not open under another key id or tampered ciphertext', () => {
  const binding = { profileId: 'p1', connectionId: 'c1' };
  const sealed = sealPassword('app-pass-123', binding, key);
  assert.throws(() => openPassword({ ...sealed, keyId: 'k2' }, binding, new Map([['k2', key.bytes]])));
  assert.throws(() => openPassword(sealed, binding, new Map()), /imap_key_unavailable/);
  const tampered = Buffer.from(sealed.ciphertext);
  tampered[tampered.length - 1] ^= 1;
  assert.throws(() => openPassword({ ...sealed, ciphertext: tampered }, binding, new Map([['k1', key.bytes]])));
});

test('a sender filter is required and limited to bank sender domains', () => {
  assert.throws(() => normalizeSenderFilter(''), /sender_filter_required/);
  assert.throws(() => normalizeSenderFilter('*'), /sender_filter_required/);
  assert.throws(() => normalizeSenderFilter(null), /sender_filter_required/);
  assert.deepEqual(normalizeSenderFilter(' alerts@hdfcbank.net, CreditCards@icicibank.com '),
    ['alerts@hdfcbank.net', 'creditcards@icicibank.com']);
  assert.deepEqual(normalizeSenderFilter('a@hdfcbank.net,a@hdfcbank.net'), ['a@hdfcbank.net']);
});

test('keyring needs a 32-byte base64 key and a safe key id', () => {
  const b64 = crypto.randomBytes(32).toString('base64');
  assert.equal(loadImapKeyring({}), null);
  const ring = loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64, IMAP_ENCRYPTION_KEY_ID: 'k7' });
  assert.equal(ring.current.id, 'k7');
  assert.equal(ring.current.bytes.length, 32);
  assert.equal(ring.byId.get('k7'), ring.current.bytes);
  assert.equal(loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64 }).current.id, 'k1');
  assert.throws(() => loadImapKeyring({ IMAP_ENCRYPTION_KEY: 'dev_imap_key_change_me_32_bytes_ok' }), /IMAP_ENCRYPTION_KEY/);
  assert.throws(() => loadImapKeyring({ IMAP_ENCRYPTION_KEY: crypto.randomBytes(16).toString('base64') }), /IMAP_ENCRYPTION_KEY/);
  assert.throws(() => loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64, IMAP_ENCRYPTION_KEY_ID: 'bad id!' }), /IMAP_ENCRYPTION_KEY_ID/);
  const old = crypto.randomBytes(32);
  const withOld = loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64, IMAP_ENCRYPTION_PREVIOUS_KEYS: JSON.stringify({ k0: old.toString('base64') }) });
  assert.ok(withOld.byId.get('k0').equals(old));
  assert.throws(() => loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64, IMAP_ENCRYPTION_PREVIOUS_KEYS: JSON.stringify({ k1: b64 }) }), /PREVIOUS_KEYS/);
});
