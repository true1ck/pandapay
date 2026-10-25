'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { readImapWorkerBatch, MAX_BATCH_SIZE } = require('../src/imap_worker_capability');

test('IMAP worker enumeration is one private capability with bound key and max100', async () => {
  let calls = 0;
  const rows = [{ id: 'synthetic-id', app_password: 'synthetic-secret' }];
  const result = await readImapWorkerBatch({ query: async (sql, params) => {
    calls++;
    assert.match(sql, /FROM imap_worker.next_connections\(\$1::text, \$2::integer\)/);
    assert.ok(!sql.includes('synthetic-secret'));
    assert.deepEqual(params, ['synthetic-secret', 100]);
    return { rows };
  } }, 'synthetic-secret');
  assert.equal(calls, 1);
  assert.equal(MAX_BATCH_SIZE, 100);
  assert.equal(result, rows);
});
for (const batchSize of [0, 101, -1, 2.5, null, '100']) {
  test(`IMAP worker rejects invalid batch ${JSON.stringify(batchSize)} before SQL`, async () => {
    await assert.rejects(readImapWorkerBatch({ query: () => { throw new Error('must not query'); } }, 'synthetic-key', { batchSize }), /batch_size_invalid/);
  });
}
for (const key of ['', null, 'x'.repeat(4097), 'key\0withnul']) {
  test(`IMAP worker rejects invalid key shape before SQL (length ${key?.length ?? 'null'})`, async () => {
    await assert.rejects(readImapWorkerBatch({ query: () => { throw new Error('must not query'); } }, key), /encryption_key_invalid/);
  });
}
test('IMAP worker refuses an oversized capability response', async () => {
  await assert.rejects(readImapWorkerBatch({ query: async () => ({ rows: Array.from({ length: 101 }, () => ({})) }) }, 'synthetic-key'), /batch_result_invalid/);
});
