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
