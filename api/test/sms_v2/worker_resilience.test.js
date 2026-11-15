'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  backoffMs,
  errorLabel,
  availableMbFromMeminfo,
  containerLimitMbFrom,
  guardSettings,
  memoryHeadroom,
  runResilientLoop,
  openPatiently,
} = require('../../src/sms_v2/jobs/worker_resilience');
const { openAiWorkerStore } = require('../../src/sms_v2/ai_worker_store');

const noJitter = () => 0.5; // jitter factor exactly 1

test('the wait after a failure grows 5 s, 10 s, 20 s and stops at 5 minutes', () => {
  const waits = [1, 2, 3, 4, 5, 6, 7, 8, 20].map((n) => backoffMs(n, { random: noJitter }));
  assert.deepEqual(waits, [5000, 10000, 20000, 40000, 80000, 160000, 300000, 300000, 300000]);
  for (let i = 0; i < 50; i += 1) {
    const w = backoffMs(3);
    assert.ok(w >= 15000 && w <= 25000, `jitter stays within 25%: ${w}`);
  }
});

test('an error is described by its code or name, never by its message', () => {
  assert.equal(errorLabel(Object.assign(new Error('password authentication failed for user "x"'), { code: '28P01' })), '28P01');
  assert.equal(errorLabel(new TypeError('secret text')), 'TypeError');
  assert.equal(errorLabel(null), 'Error');
});

test('free memory is read from /proc/meminfo, and the container limit from the cgroup files', () => {
  assert.equal(availableMbFromMeminfo('MemTotal:  977096 kB\nMemAvailable:  266240 kB\n'), 260);
  assert.equal(availableMbFromMeminfo('nothing here'), null);
  assert.equal(containerLimitMbFrom([() => 'max', () => String(192 * 1048576)]), 192);
  assert.equal(containerLimitMbFrom([() => 'max', () => null]), null);
  assert.equal(containerLimitMbFrom([() => String(2 ** 62)]), null, 'an "unlimited" cgroup value is no limit');
});

test('the worker recycles at 75% of its container limit unless told otherwise', () => {
  assert.deepEqual(guardSettings({}, 192), { recycleAtMb: 144, minAvailableMb: 100 });
  assert.deepEqual(guardSettings({}, null), { recycleAtMb: 150, minAvailableMb: 100 });
  assert.deepEqual(guardSettings({ SMS_V2_WORKER_RECYCLE_RSS_MB: '90', SMS_V2_WORKER_MIN_AVAILABLE_MB: '200' }, 192), {
    recycleAtMb: 90,
    minAvailableMb: 200,
  });
  assert.deepEqual(guardSettings({ SMS_V2_WORKER_RECYCLE_RSS_MB: 'abc' }, 192).recycleAtMb, 144, 'a bad value falls back');
});

test('memory decides: recycle near the worker limit, wait when the host is short, otherwise run', () => {
  const s = { recycleAtMb: 144, minAvailableMb: 100 };
  assert.equal(memoryHeadroom({ rssMb: 150, availableMb: 500 }, s).action, 'recycle');
  assert.equal(memoryHeadroom({ rssMb: 40, availableMb: 60 }, s).action, 'wait');
  assert.equal(memoryHeadroom({ rssMb: 40, availableMb: 260 }, s).action, 'run');
  assert.equal(memoryHeadroom({ rssMb: 40, availableMb: null }, s).action, 'run', 'an unreadable host never blocks work');
});

function harness(over = {}) {
  const logs = [];
  const sleeps = [];
  let stopped = false;
  return {
    logs,
    sleeps,
    stop: () => {
      stopped = true;
    },
    opts: {
      isStopped: () => stopped,
      sleep: async (ms) => {
        sleeps.push(ms);
      },
      log: (line) => logs.push(line),
      headroom: () => ({ action: 'run', rssMb: 40 }),
      nextDelayMs: () => 1000,
      ...over,
    },
  };
}

test('a login failure or a timeout in a cycle never ends the worker: it logs the code, waits longer each time, and carries on', async () => {
  const h = harness();
  let calls = 0;
  const outcome = await runResilientLoop({
    ...h.opts,
    runCycle: async () => {
      calls += 1;
      if (calls === 1) throw Object.assign(new Error('password authentication failed for user "sms_ai_worker"'), { code: '28P01' });
      if (calls === 2) throw Object.assign(new Error('canceling statement due to statement timeout'), { code: '57014' });
      if (calls === 3) return { status: 'ready' };
      h.stop();
      return { status: 'idle' };
    },
  });
  assert.equal(outcome, 'stopped');
  assert.equal(calls, 4);
  const errors = h.logs.filter((l) => l.status === 'error');
  assert.deepEqual(errors.map((e) => [e.code, e.inARow]), [['28P01', 1], ['57014', 2]]);
  assert.ok(!JSON.stringify(h.logs).includes('password authentication'), 'no error message reaches the log');
  assert.ok(h.sleeps[0] >= 3750 && h.sleeps[0] <= 6250, 'first failure waits about 5 s');
  assert.ok(h.sleeps[1] >= 7500 && h.sleeps[1] <= 12500, 'second waits about 10 s');
  assert.equal(h.sleeps[2], 1000, 'a good cycle returns to the normal pace');
});

test('a success resets the failure count', async () => {
  const h = harness();
  const script = ['fail', 'ok', 'fail', 'stop'];
  await runResilientLoop({
    ...h.opts,
    runCycle: async () => {
      const step = script.shift();
      if (step === 'fail') throw Object.assign(new Error('x'), { code: '08006' });
      if (step === 'stop') h.stop();
      return { status: 'idle' };
    },
  });
  assert.deepEqual(h.logs.filter((l) => l.status === 'error').map((e) => e.inARow), [1, 1]);
});

test('near its own memory limit the worker leaves cleanly BEFORE taking a job', async () => {
  const h = harness({ headroom: () => ({ action: 'recycle', reason: 'worker_memory', rssMb: 160 }) });
  let ran = false;
  const outcome = await runResilientLoop({ ...h.opts, runCycle: async () => { ran = true; return { status: 'ready' }; } });
  assert.equal(outcome, 'recycle');
  assert.equal(ran, false);
  assert.equal(h.logs[0].status, 'recycle');
});

test('when the host is short of memory the worker takes no job and looks again later', async () => {
  const h = harness();
  let ran = 0;
  let waits = 0;
  await runResilientLoop({
    ...h.opts,
    headroom: () => {
      waits += 1;
      if (waits >= 3) h.stop();
      return { action: 'wait', reason: 'host_memory', rssMb: 40 };
    },
    runCycle: async () => { ran += 1; return { status: 'ready' }; },
  });
  assert.equal(ran, 0, 'no job was claimed while the host was short of memory');
  assert.ok(h.logs.every((l) => l.status === 'capacity'));
});

test('a one-shot run still surfaces its error', async () => {
  const h = harness();
  await assert.rejects(
    runResilientLoop({ ...h.opts, once: true, runCycle: async () => { throw Object.assign(new Error('x'), { code: '28P01' }); } }),
    (e) => e.code === '28P01',
  );
});

test('a housekeeping error is logged and does not stop the loop', async () => {
  const h = harness();
  await runResilientLoop({
    ...h.opts,
    runCycle: async () => ({ status: 'idle' }),
    afterCycle: async () => { h.stop(); throw Object.assign(new Error('cleanup'), { code: '42P01' }); },
  });
  assert.deepEqual(h.logs.filter((l) => l.status === 'housekeeping_error').map((l) => l.code), ['42P01']);
});

test('opening the stores waits out a database login failure instead of exiting', async () => {
  const h = harness();
  let attempts = 0;
  const store = await openPatiently({
    open: async () => {
      attempts += 1;
      if (attempts < 3) throw Object.assign(new Error('password authentication failed'), { code: '28P01' });
      return { ok: true };
    },
    sleep: h.opts.sleep,
    log: h.opts.log,
    isStopped: h.opts.isStopped,
  });
  assert.deepEqual(store, { ok: true });
  assert.equal(attempts, 3);
  assert.deepEqual(h.logs.map((l) => [l.status, l.code, l.inARow]), [['database_unavailable', '28P01', 1], ['database_unavailable', '28P01', 2]]);
  await assert.rejects(
    openPatiently({ open: async () => { throw new Error('x'); }, sleep: h.opts.sleep, log: h.opts.log, isStopped: h.opts.isStopped, once: true }),
    /x/,
  );
});

test('told to stop while waiting for the database, opening the stores gives up quietly', async () => {
  const h = harness();
  const store = await openPatiently({
    open: async () => { throw Object.assign(new Error('x'), { code: 'ECONNREFUSED' }); },
    sleep: async () => { h.stop(); },
    log: h.opts.log,
    isStopped: h.opts.isStopped,
  });
  assert.equal(store, null);
});

test('a dropped idle connection is reported by code only and does not end the process', async () => {
  const handlers = {};
  class FakePool {
    on(event, fn) { handlers[event] = fn; }
    async query() { return { rows: [{ name: 'sms_ai_worker', unsafe: false }] }; }
    async end() {}
  }
  const env = { SMS_AI_WORKER_DATABASE_URL: 'postgresql://fixture@localhost/test', DB_SSL: 'false', NODE_ENV: 'test' };
  await openAiWorkerStore({ env, PoolClass: FakePool });
  assert.equal(typeof handlers.error, 'function', 'the pool has an error listener');
  const seen = [];
  const original = console.error;
  console.error = (...args) => seen.push(args.join(' '));
  try {
    handlers.error(Object.assign(new Error('terminating connection due to administrator command: secret'), { code: '57P01' }));
  } finally {
    console.error = original;
  }
  assert.equal(seen.length, 1);
  assert.match(seen[0], /57P01/);
  assert.ok(!seen[0].includes('secret'), 'the message is never logged');
});
