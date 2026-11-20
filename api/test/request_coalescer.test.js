'use strict';
// Identical reads that pile up share work WITHOUT ever answering a request with data read before it arrived: a request
// that comes in while a run is going waits for that run to end, and every such request shares one follow-up run that
// starts after all of them arrived. So a write committed before a request was sent is always in its answer.
const test = require('node:test');
const assert = require('node:assert/strict');
const { createRequestCoalescer } = require('../src/request_coalescer');

function deferred() {
  let resolve; let reject;
  const promise = new Promise((res, rej) => { resolve = res; reject = rej; });
  return { promise, resolve, reject };
}

test('a request that arrives during a run never gets that run\'s older answer', async () => {
  const lanes = createRequestCoalescer();
  let version = 1; // the data
  const first = deferred();
  const reads = [];
  const read = async () => { const seen = version; reads.push(seen); if (reads.length === 1) await first.promise; return seen; };
  const a = lanes.run('u1', read);
  await new Promise((r) => setImmediate(r)); // the first run has read version 1 and is still going
  version = 2; // a write commits, then the phone asks again
  const b = lanes.run('u1', read);
  first.resolve();
  assert.equal(await a, 1);
  assert.equal(await b, 2, 'the later request sees the write');
});

test('requests that arrive during a run share one follow-up run', async () => {
  const lanes = createRequestCoalescer();
  let runs = 0;
  const first = deferred();
  const work = async () => { runs += 1; if (runs === 1) await first.promise; return runs; };
  const a = lanes.run('u1', work);
  const rest = [lanes.run('u1', work), lanes.run('u1', work), lanes.run('u1', work)];
  first.resolve();
  assert.equal(await a, 1);
  assert.deepEqual(await Promise.all(rest), [2, 2, 2]);
  assert.equal(runs, 2, 'four identical requests, two runs');
  assert.equal(lanes.size, 0, 'nothing kept after the burst');
});

test('different keys never wait for each other', async () => {
  const lanes = createRequestCoalescer();
  const slow = deferred();
  const a = lanes.run('u1', () => slow.promise);
  assert.equal(await lanes.run('u2', async () => 'other'), 'other');
  slow.resolve('done');
  assert.equal(await a, 'done');
});

test('a failed run does not block the follow-up, and each failure reaches only its own waiters', async () => {
  const lanes = createRequestCoalescer();
  const first = deferred();
  let runs = 0;
  const work = async () => { runs += 1; if (runs === 1) { await first.promise; throw new Error('boom'); } return 'ok'; };
  const a = lanes.run('k', work);
  const b = lanes.run('k', work);
  first.resolve();
  await assert.rejects(a, /boom/);
  assert.equal(await b, 'ok');
  assert.equal(lanes.size, 0);
});

test('after a burst ends, the next request runs on its own (nothing cached)', async () => {
  const lanes = createRequestCoalescer();
  let runs = 0;
  await lanes.run('k', async () => ++runs);
  assert.equal(await lanes.run('k', async () => ++runs), 2);
});
