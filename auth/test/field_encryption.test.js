'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
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
  assert.equal(original.getWriteFormat(), 'legacy');
  assert.equal(original.getWriteKeyId(), null);
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

test('v2 writer is explicit opt-in and legacy format remains the default with configured read keys', () => {
  const readerOnly = load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  assert.equal(readerOnly.getWriteFormat(), 'legacy');
  assert.equal(readerOnly.getWriteKeyId(), null);
  assert.equal(readerOnly.encryptPhoneNumber('+919876543210').split(':').length, 3);

  const explicitlyLegacy = load({ ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'false',
    ENCRYPTION_WRITE_KEY_ID: 'unused-preprovisioned-id', ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  assert.equal(explicitlyLegacy.getWriteFormat(), 'legacy');
  assert.equal(explicitlyLegacy.encryptPhoneNumber('+919876543210').split(':').length, 3);
});

test('v2 writer requires strict flag, legacy key retention, and an already configured read key ID', () => {
  const valid = { ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: readKeyConfig,
    ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'primary_reader' };
  const writer = load(valid);
  assert.equal(writer.getWriteFormat(), 'v2');
  assert.equal(writer.getWriteKeyId(), 'primary_reader');
  for (const flag of ['', '1', 'yes', 'TRUE']) {
    assert.throws(() => load({ ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: flag }),
      error => error.code === 'FIELD_ENCRYPTION_ERROR');
  }
  for (const env of [
    { ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_READ_KEYS_JSON: readKeyConfig },
    { ENCRYPTION_ENABLED: 'false', ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'primary_reader', ENCRYPTION_READ_KEYS_JSON: readKeyConfig },
    { ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'missing', ENCRYPTION_READ_KEYS_JSON: readKeyConfig },
    { ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'bad id', ENCRYPTION_READ_KEYS_JSON: readKeyConfig },
  ]) {
    assert.throws(() => load(env), error => error.code === 'FIELD_ENCRYPTION_ERROR');
  }
});

test('v2 writer emits reader-compatible canonical envelopes with fresh random IVs', () => {
  const writer = load({ ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'true',
    ENCRYPTION_WRITE_KEY_ID: 'primary_reader', ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  const first = writer.encryptPhoneNumber('+919876543210');
  const second = writer.encryptPhoneNumber('+919876543210');
  assert.match(first, /^v2:primary_reader:/);
  assert.notEqual(first, second);
  assert.notEqual(first.split(':')[2], second.split(':')[2]);
  assert.ok(Buffer.byteLength(first, 'utf8') <= 4096);
  assert.equal(writer.decryptPhoneNumber(first), '+919876543210');
  assert.equal(load({ ...encryptedEnv, ENCRYPTION_READ_KEYS_JSON: readKeyConfig }).decryptPhoneNumber(first), '+919876543210');
  assert.throws(() => writer.encryptField('x'.repeat(4000)), error => error.code === 'FIELD_ENCRYPTION_ERROR');
});

test('v2 writer preserves mixed legacy, v2 and plaintext phone reads plus the original legacy restore key', () => {
  const legacyKey = crypto.randomBytes(32);
  const legacy = load({ ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: legacyKey.toString('base64') });
  const legacyCiphertext = legacy.encryptPhoneNumber('+919876543210');
  const writer = load({ ...encryptedEnv, ENCRYPTION_KEY: legacyKey.toString('base64'),
    ENCRYPTION_V2_WRITES_ENABLED: 'true', ENCRYPTION_WRITE_KEY_ID: 'primary_reader',
    ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
  const v2 = writer.encryptPhoneNumber('+918765432109');
  assert.equal(writer.decryptPhoneNumber(legacyCiphertext), '+919876543210');
  assert.equal(writer.decryptPhoneNumber(v2), '+918765432109');
  assert.equal(writer.decryptPhoneNumber('9876543210'), '9876543210');
  const restoreWithOriginal = load({ ENCRYPTION_ENABLED: 'true', ENCRYPTION_KEY: legacyKey.toString('base64') });
  assert.equal(restoreWithOriginal.decryptPhoneNumber(legacyCiphertext), '+919876543210');
});

test('v2 phone writes leave stable HMAC lookup identity unchanged', () => {
  const previous = process.env.PHONE_LOOKUP_HMAC_KEY;
  const hmacKey = 'synthetic-phone-lookup-key-for-v2-writer';
  process.env.PHONE_LOOKUP_HMAC_KEY = hmacKey;
  try {
    const expected = crypto.createHmac('sha256', hmacKey)
      .update('pandapay-phone-lookup:v1:+919876543210').digest('hex');
    const legacy = load(encryptedEnv);
    const versioned = load({ ...encryptedEnv, ENCRYPTION_V2_WRITES_ENABLED: 'true',
      ENCRYPTION_WRITE_KEY_ID: 'primary_reader', ENCRYPTION_READ_KEYS_JSON: readKeyConfig });
    assert.equal(phoneLookupHash('+919876543210'), expected);
    assert.equal(phoneLookupHash('+91 98765 43210'), expected);
    assert.equal(legacy.getWriteFormat(), 'legacy');
    assert.equal(versioned.getWriteFormat(), 'v2');
    assert.equal(phoneLookupHash('+919876543210'), expected);
  } finally {
    if (previous === undefined) delete process.env.PHONE_LOOKUP_HMAC_KEY;
    else process.env.PHONE_LOOKUP_HMAC_KEY = previous;
  }
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
