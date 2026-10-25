'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
function load(env) {
  const context = { module: { exports: {} }, require, Buffer, process: { env } };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, '../src/utils/fieldEncryption.js'), 'utf8'), context);
  return context.module.exports;
}
const key = crypto.randomBytes(32).toString('base64');
const encryptedEnv = { ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: key };
const aadPrefix = Buffer.from('pandapay-field-encryption-v2\0', 'utf8');
function makeV2(keyId, rawKey, plaintext = '+919876543210', iv = crypto.randomBytes(12)) {
  const cipher = crypto.createCipheriv('aes-256-gcm', rawKey, iv);
  cipher.setAAD(Buffer.concat([aadPrefix, Buffer.from(keyId, 'utf8')]));
  const ciphertext = Buffer.concat([Buffer.isBuffer(plaintext) ? cipher.update(plaintext) : cipher.update(plaintext, 'utf8'), cipher.final()]);
  return ['v2', keyId, iv, cipher.getAuthTag(), ciphertext]
    .map((part, index) => index < 2 ? part : part.toString('base64')).join(':');
}
const readKey = crypto.randomBytes(32);
const readKeyConfig = JSON.stringify([['primary_reader', readKey.toString('base64')]]);
test('existing authenticated ciphertext survives a provider move using the same key', () => {
  const original = load(encryptedEnv);
  const ciphertext = original.encryptPhoneNumber('+919876543210');
  assert.equal(ciphertext.split(':').length, 3);
  assert.equal(load({ ...encryptedEnv, NODE_ENV: 'production' }).decryptPhoneNumber(ciphertext), '+919876543210');
  assert.notEqual(original.encryptPhoneNumber('+919876543210'), ciphertext);
});
test('hosted startup rejects missing, disabled, malformed and short keys', () => {
  for (const NODE_ENV of ['production', 'staging']) {
    for (const env of [{}, { ENCRYPTION_ENABLED: 'false', ENCRYPTION_KEY: key },
      { ENCRYPTION_ENABLED: 'true' }, { ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: 'invalid!' },
      { ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: Buffer.alloc(31).toString('base64') }]) {
      assert.throws(() => load({ ...env, NODE_ENV }), /encryption must be enabled|base64-encoded 32-byte key/);
    }
  }
});
test('wrong keys, tampering and unknown formats cannot become plaintext', () => {
  const encrypted = load(encryptedEnv);
  const ciphertext = encrypted.encryptPhoneNumber('+919876543210');
  const wrong = load({ ...encryptedEnv, ENCRYPTION_KEY: crypto.randomBytes(32).toString('base64') });
  assert.throws(() => wrong.decryptPhoneNumber(ciphertext), /authentication failed/);
  const parts = ciphertext.split(':');
  parts[1] = Buffer.alloc(16).toString('base64');
  for (const value of [parts.join(':'), 'v2:unknown:format:key', 'invalid:tag:payload']) {
    assert.throws(() => encrypted.decryptPhoneNumber(value), /authentication failed/);
  }
  assert.throws(() => load({}).decryptPhoneNumber(ciphertext), /valid encryption key is required/);
  assert.throws(() => encrypted.decryptPhoneNumber(ciphertext.replaceAll(':', '')), /Unrecognized legacy phone/);
});
test('legacy local mode and plaintext reads preserve existing records', () => {
  const local = load({ NODE_ENV: 'development', ENCRYPTION_ENABLED: 'false' });
  assert.equal(local.isEncryptionEnabled(), false);
  assert.equal(local.encryptPhoneNumber('+919876543210'), '+919876543210');
  assert.equal(load(encryptedEnv).decryptPhoneNumber('+919876543210'), '+919876543210');
  assert.equal(load(encryptedEnv).decryptPhoneNumber(null), null);
});

test('v2 reader opens independently manufactured AAD-bound envelopes without changing the writer', () => {
  const env = { ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: readKeyConfig };
  const reader = load(env);
  const envelope = makeV2('primary_reader', readKey);
  assert.equal(reader.decryptPhoneNumber(envelope), '+919876543210');
  const written = reader.encryptPhoneNumber('+919876543210');
  assert.equal(written.split(':').length, 3);
  assert.equal(reader.decryptPhoneNumber(written), '+919876543210');
});

test('read key config accepts empty forms, enforces limits and keeps IDs prototype safe', () => {
  for (const config of [undefined, null, '', '[]']) {
    const env = { ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: config };
    const module = load(env);
    assert.equal(module.decryptPhoneNumber(load(encryptedEnv).encryptPhoneNumber('+919876543210')), '+919876543210');
  }
  const prototypeKey = crypto.randomBytes(32);
  const prototypeReader = load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: JSON.stringify([['__proto__', prototypeKey.toString('base64')]]) });
  assert.equal(prototypeReader.decryptPhoneNumber(makeV2('__proto__', prototypeKey)), '+919876543210');

  const malformedConfigs = [
    JSON.stringify([['dup', readKey.toString('base64')], ['dup', readKey.toString('base64')]]),
    JSON.stringify([['bad id', readKey.toString('base64')]]),
    JSON.stringify([['short', Buffer.alloc(31).toString('base64')]]),
    JSON.stringify([['unpadded', readKey.toString('base64').replace(/=+$/, '')]]),
    JSON.stringify([{ id: 'reader', key: readKey.toString('base64') }]),
    JSON.stringify(Array.from({ length: 9 }, (_, i) => [`r${i}`, readKey.toString('base64')])),
    ' '.repeat(8193),
  ];
  for (const config of malformedConfigs) {
    assert.throws(() => load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: config }), error => error.code === 'FIELD_ENCRYPTION_ERROR');
  }
  assert.throws(() => load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: '{"reader":"key"}' }), error => error.code === 'FIELD_ENCRYPTION_ERROR');
});

test('v2 rejects missing, unknown, wrong and tampered keys or envelope fields safely', () => {
  const envelope = makeV2('primary_reader', readKey);
  const reader = load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  const aliasedReader = load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: JSON.stringify([
    ['primary_reader', readKey.toString('base64')], ['alias_reader', readKey.toString('base64')],
  ]) });
  const wrongReadKey = crypto.randomBytes(32);
  const wrongReader = load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: JSON.stringify([['primary_reader', wrongReadKey.toString('base64')]]) });
  const cases = [
    [load(encryptedEnv), envelope],
    [reader, envelope.replace('primary_reader', 'unknown_reader')],
    [aliasedReader, envelope.replace('primary_reader', 'alias_reader')],
    [wrongReader, envelope],
    [reader, envelope.replace('v2:', 'v3:')],
    [reader, envelope.replace('primary_reader', 'another_reader')],
    [reader, envelope.replace(/:([^:]+)$/, ':AAAA')],
    [reader, `${envelope}:extra`],
    [reader, 'v2:primary_reader:AA==:AA==:AA=='],
    [reader, `v2:primary_reader:${Buffer.alloc(12).toString('base64')}:${Buffer.alloc(16).toString('base64').replace(/=$/, '')}:${Buffer.from('x').toString('base64')}`],
    [reader, `v2:primary_reader:${Buffer.alloc(12).toString('base64')}:${Buffer.alloc(16).toString('base64')}:${Buffer.alloc(5000).toString('base64')}`],
  ];
  for (const [module, value] of cases) {
    assert.throws(() => module.decryptPhoneNumber(value), error => error.code === 'FIELD_ENCRYPTION_ERROR' && !('cause' in error));
  }
  assert.throws(() => reader.decryptPhoneNumber(makeV2('primary_reader', readKey, Buffer.from([0xff]))), error => error.code === 'FIELD_ENCRYPTION_ERROR');
});

test('v2 can be read in explicit local-off mode while hosted mode still requires the original key', () => {
  const local = load({ NODE_ENV: 'development', ENCRYPTION_ENABLED: 'false', ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  const envelope = makeV2('primary_reader', readKey);
  assert.equal(local.isEncryptionEnabled(), false);
  assert.equal(local.encryptPhoneNumber('+919876543210'), '+919876543210');
  assert.equal(local.decryptPhoneNumber(envelope), '+919876543210');
  for (const NODE_ENV of ['production', 'staging']) {
    assert.throws(() => load({ NODE_ENV, ENCRYPTION_ENABLED: 'false', ENCRYPTION_READ_KEYS_JSON: readKeyConfig }), /encryption must be enabled/);
  }
});

test('legacy envelopes never fall back to optional read keys when the original key is wrong', () => {
  const originalKey = crypto.randomBytes(32);
  const legacyWriter = load({ ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: originalKey.toString('base64') });
  const legacyEnvelope = legacyWriter.encryptPhoneNumber('+919876543210');
  const wrongOriginalKey = crypto.randomBytes(32);
  const reader = load({
    ENCRYPTION_ENABLED: 'true',
    ENCRYPTION_KEY: wrongOriginalKey.toString('base64'),
    ENCRYPTION_READ_KEYS_JSON: JSON.stringify([['legacy_key_copy', originalKey.toString('base64')]]),
  });
  assert.throws(() => reader.decryptPhoneNumber(legacyEnvelope), error => error.code === 'FIELD_ENCRYPTION_ERROR');
});
