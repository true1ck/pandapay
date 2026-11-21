"use strict";
// After the AI service was down, a layout that failed only because of it waited 5 min, 30 min, then 24 hours, even when
// the service came back a minute later (owner, 21 Nov 2026: "why tomorrow, make it instant once the service is up").
// The worker now looks every 2 minutes; when such layouts are waiting and the service answers its health check, it
// makes them due at once. At most one release every 10 minutes, so a flapping service cannot burn their tries.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createOutageRecovery } = require("../../src/sms_v2/jobs/outage_recovery");

function rig({ waiting = 2, up = true } = {}) {
  const calls = { count: 0, probe: 0, release: 0 };
  const lines = [];
  const clock = { t: 0 };
  const state = { waiting, up };
  const recovery = createOutageRecovery({
    store: {
      outageDeferredCount: async () => { calls.count += 1; return state.waiting; },
      releaseAfterOutage: async () => { calls.release += 1; const n = state.waiting; state.waiting = 0; return n; },
    },
    probe: async () => { calls.probe += 1; return state.up; },
    now: () => clock.t,
    log: (line) => lines.push(line),
  });
  return { recovery, calls, lines, clock, state };
}

test("waiting layouts are released as soon as the service answers its health check", async () => {
  const { recovery, calls, lines } = rig({ waiting: 2, up: true });
  assert.deepEqual(await recovery.check(), { waiting: 2, released: 2 });
  assert.equal(calls.release, 1);
  assert.deepEqual(lines.at(-1), { event: "sms_v2_ai_recovered", waiting: 2, released: 2 });
});

test("while the service is still down nothing is released and the outage is logged", async () => {
  const { recovery, calls, lines } = rig({ waiting: 3, up: false });
  assert.deepEqual(await recovery.check(), { waiting: 3, released: 0 });
  assert.equal(calls.release, 0);
  assert.deepEqual(lines.at(-1), { event: "sms_v2_ai_outage", waiting: 3, serviceUp: false });
});

test("with nothing waiting the service is not even asked", async () => {
  const { recovery, calls } = rig({ waiting: 0 });
  assert.equal(await recovery.check(), null);
  assert.equal(calls.probe, 0);
  assert.equal(calls.release, 0);
});

test("it looks at most every 2 minutes, and releases at most every 10", async () => {
  const { recovery, calls, clock, state } = rig({ waiting: 1, up: false });
  await recovery.check();
  assert.equal(await recovery.check(), null, "too soon to look again");
  assert.equal(calls.count, 1);
  clock.t += 2 * 60_000;
  state.up = true;
  assert.deepEqual(await recovery.check(), { waiting: 1, released: 1 });
  state.waiting = 4; // the service failed again straight after
  clock.t += 2 * 60_000;
  assert.equal(await recovery.check(), null, "a second release within 10 minutes waits");
  assert.equal(calls.release, 1);
  clock.t += 8 * 60_000;
  assert.deepEqual(await recovery.check(), { waiting: 4, released: 4 });
});

test("a database or network error never stops the worker", async () => {
  const lines = [];
  const recovery = createOutageRecovery({
    store: { outageDeferredCount: async () => { throw Object.assign(new Error("x"), { code: "57P01" }); }, releaseAfterOutage: async () => 0 },
    probe: async () => true,
    now: () => 0,
    log: (line) => lines.push(line),
  });
  assert.equal(await recovery.check(), null);
  assert.deepEqual(lines.at(-1), { event: "sms_v2_ai_outage_check_failed", code: "57P01" });
});

test("a store without the methods (admin login) turns the check off", async () => {
  const recovery = createOutageRecovery({ store: {}, probe: async () => true, now: () => 0, log: () => {} });
  assert.equal(await recovery.check(), null);
});
