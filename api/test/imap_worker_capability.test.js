'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { readImapWorkerBatch, MAX_BATCH_SIZE } = require('../src/imap_worker_capability');
const { sealPassword } = require('../src/imap_credentials');

const key = { id: 'k1', bytes: crypto.randomBytes(32) };
const keys = new Map([[key.id, key.bytes]]);
const row = (id, password, profileId = 'p1') => {
  const sealed = sealPassword(password, { profileId, connectionId: id }, key);
  return { id, profile_id: profileId, email: 'a@example.test', app_password_ciphertext: sealed.ciphertext, app_password_key_id: sealed.keyId };
};

test('IMAP worker enumeration is one private capability, max100, and opens credentials in the API', async () => {
  let calls = 0;
  const rows = [row('c1', 'synthetic-secret')];
  const result = await readImapWorkerBatch({ query: async (sql, params) => {
    calls++;
    assert.match(sql, /FROM imap_worker.next_connections\(\$1::integer\)/);
    assert.deepEqual(params, [100]);
    return { rows };
  } }, keys);
  assert.equal(calls, 1);
  assert.equal(MAX_BATCH_SIZE, 100);
  assert.equal(result[0].app_password, 'synthetic-secret');
  assert.equal(result[0].credential_error, false);
  assert.ok(!('app_password_ciphertext' in result[0]));
});
test('an unopenable credential is isolated per row', async () => {
  const good = row('c1', 'one');
  const wrongBinding = { ...row('c2', 'two'), profile_id: 'other-profile' };
  const unknownKey = { ...row('c3', 'three'), app_password_key_id: 'k9' };
  const corrupt = { ...row('c4', 'four'), app_password_ciphertext: Buffer.from('corrupt') };
  const result = await readImapWorkerBatch({ query: async () => ({ rows: [good, wrongBinding, unknownKey, corrupt] }) }, keys);
  assert.deepEqual(result.map((r) => r.credential_error), [false, true, true, true]);
  assert.deepEqual(result.map((r) => r.app_password), ['one', null, null, null]);
});
for (const batchSize of [0, 101, -1, 2.5, null, '100']) {
  test(`IMAP worker rejects invalid batch ${JSON.stringify(batchSize)} before SQL`, async () => {
    await assert.rejects(readImapWorkerBatch({ query: () => { throw new Error('must not query'); } }, keys, { batchSize }), /batch_size_invalid/);
  });
}
for (const ring of [null, new Map(), 'synthetic-key']) {
  test(`IMAP worker rejects an invalid keyring before SQL (${ring === null ? 'null' : typeof ring})`, async () => {
    await assert.rejects(readImapWorkerBatch({ query: () => { throw new Error('must not query'); } }, ring), /keyring_invalid/);
  });
}
test('IMAP worker refuses an oversized capability response', async () => {
  await assert.rejects(readImapWorkerBatch({ query: async () => ({ rows: Array.from({ length: 101 }, () => ({})) }) }, keys), /batch_result_invalid/);
});
