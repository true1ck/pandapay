const test = require('node:test');
const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const { createAdmission, notePoolBusy, classify } = require('../src/admission');

function fakeRes() {
  const res = new EventEmitter();
  Object.assign(res, { headers: {}, locals: {}, headersSent: false, writableEnded: false, statusCode: 200, body: null });
  res.set = (k, v) => { res.headers[k] = v; return res; };
  res.status = (c) => { res.statusCode = c; return res; };
  res.json = (b) => { res.body = b; res.headersSent = true; res.writableEnded = true; res.emit('close'); return res; };
  return res;
}
const finish = (res) => { res.writableEnded = true; res.emit('close'); };
const tick = () => new Promise((r) => setImmediate(r));

// Sends a request through the middleware; `started` flips when it is admitted.
function send(mw, { method = 'GET', path = '/x', userId = null } = {}) {
  const req = { method, path, userId };
  const res = fakeRes();
  const h = { req, res, started: false };
  mw(req, res, () => { h.started = true; });
  return h;
}

test('classify: probes are exempt, push and heavy routes get their own class', () => {
  assert.equal(classify({ method: 'GET', path: '/health' }), null);
  assert.equal(classify({ method: 'GET', path: '/ready' }), null);
  assert.equal(classify({ method: 'POST', path: '/sync/push' }), 'push');
  assert.equal(classify({ method: 'GET', path: '/account-summaries' }), 'heavy');
  assert.equal(classify({ method: 'POST', path: '/user-cards' }), 'default'); // only the GET is heavy
  assert.equal(classify({ method: 'GET', path: '/categories' }), 'default');
});

test('overall cap: extra requests wait and are admitted first-come-first-served', async () => {
  const mw = createAdmission({ maxConcurrent: 2, maxWaitMs: 1000 });
  const a = send(mw), b = send(mw), c = send(mw), d = send(mw);
  await tick();
  assert.deepEqual([a, b, c, d].map((x) => x.started), [true, true, false, false]);
  finish(a.res);
  await tick();
  assert.deepEqual([c.started, d.started], [true, false], 'c is next in line, not d');
  finish(b.res);
  await tick();
  assert.equal(d.started, true);
  [c, d].forEach((x) => finish(x.res));
});

test('waiting too long answers 503 + Retry-After and frees nothing it never held', async () => {
  const mw = createAdmission({ maxConcurrent: 1, maxWaitMs: 30 });
  const a = send(mw);
  const b = send(mw);
  await new Promise((r) => setTimeout(r, 80));
  assert.equal(b.started, false);
  assert.equal(b.res.statusCode, 503);
  assert.deepEqual(b.res.body, { error: 'server_busy', retryable: true });
  assert.match(b.res.headers['Retry-After'], /^\d+$/);
  const secs = Number(b.res.headers['Retry-After']);
  assert.ok(secs >= 5 && secs <= 60, 'whole seconds in the range the app handles well');
  finish(a.res);
  const c = send(mw);
  await tick();
  assert.equal(c.started, true, 'the slot is free again');
  finish(c.res);
});

test('a full line refuses immediately', async () => {
  const mw = createAdmission({ maxConcurrent: 1, maxQueue: 1, maxWaitMs: 1000 });
  const a = send(mw), b = send(mw);
  const c = send(mw);
  await tick();
  assert.equal(c.res.statusCode, 503);
  assert.equal(b.started, false);
  finish(a.res);
  await tick();
  assert.equal(b.started, true);
  finish(b.res);
});

test('a client that hangs up while waiting leaves the line without running', async () => {
  const mw = createAdmission({ maxConcurrent: 1, maxWaitMs: 1000 });
  const a = send(mw), b = send(mw), c = send(mw);
  await tick();
  b.res.emit('close'); // aborted, never finished
  finish(a.res);
  await tick();
  assert.equal(b.started, false);
  assert.equal(c.started, true, 'the next live request is served');
  assert.equal(mw.stats.cancelled, 1);
  finish(c.res);
});

test('/sync/push: one at a time per user, other users and the cap are independent', async () => {
  const mw = createAdmission({ maxConcurrent: 10, pushMax: 2, maxWaitMs: 1000 });
  const u1a = send(mw, { method: 'POST', path: '/sync/push', userId: 'u1' });
  const u1b = send(mw, { method: 'POST', path: '/sync/push', userId: 'u1' });
  const u2 = send(mw, { method: 'POST', path: '/sync/push', userId: 'u2' });
  const u3 = send(mw, { method: 'POST', path: '/sync/push', userId: 'u3' });
  await tick();
  assert.deepEqual([u1a, u1b, u2, u3].map((x) => x.started), [true, false, true, false]);
  finish(u1a.res);
  await tick();
  // u3 reached the class gate before u1b (which was waiting for its own user lane), so u3 is served first.
  assert.deepEqual([u1b.started, u3.started], [false, true], 'class slots go first come, first served');
  finish(u2.res);
  await tick();
  assert.equal(u1b.started, true, 'same user is served once the first push ended and a class slot is free');
  [u1b, u3].forEach((x) => finish(x.res));
  await tick();
  assert.equal(mw._gates.userLanes.size, 0, 'idle per-user lanes are dropped');
});

test('heavy reads are capped so they cannot take every slot', async () => {
  const mw = createAdmission({ maxConcurrent: 10, heavyMax: 2, maxWaitMs: 1000 });
  const h = [1, 2, 3].map(() => send(mw, { path: '/account-summaries' }));
  const light = send(mw, { path: '/categories' });
  await tick();
  assert.deepEqual(h.map((x) => x.started), [true, true, false]);
  assert.equal(light.started, true, 'a light route is not stuck behind the heavy line');
  finish(h[0].res);
  await tick();
  assert.equal(h[2].started, true);
  [h[1], h[2], light].forEach((x) => finish(x.res));
});

test('health and ready are never queued', async () => {
  const mw = createAdmission({ maxConcurrent: 1, maxWaitMs: 1000 });
  const a = send(mw);
  const probe = send(mw, { path: '/health' });
  await tick();
  assert.equal(probe.started, true);
  finish(a.res);
});

test('a route 500 caused by pool starvation is answered 503 + Retry-After', async () => {
  const mw = createAdmission({ maxConcurrent: 5, maxWaitMs: 1000 });
  const a = send(mw);
  await tick();
  // The database layer reports a connect timeout from inside the request's async context.
  const { _als } = require('../src/admission');
  _als.run({ res: a.res }, () => notePoolBusy());
  a.res.status(500).json({ error: 'internal_error' });
  assert.equal(a.res.statusCode, 503);
  assert.ok(a.res.headers['Retry-After']);
  // An ordinary 500 is untouched.
  const b = send(mw);
  await tick();
  b.res.status(500).json({ error: 'internal_error' });
  assert.equal(b.res.statusCode, 500);
});

test('Retry-After is jittered so refused clients do not all return in the same second', async () => {
  const seen = new Set();
  for (let i = 0; i < 40; i += 1) {
    const mw = createAdmission({ maxConcurrent: 1, maxQueue: 0, maxWaitMs: 1000 });
    const a = send(mw);
    const b = send(mw); // the line holds nobody, so it is refused at once
    await tick();
    assert.equal(b.res.statusCode, 503);
    const secs = Number(b.res.headers['Retry-After']);
    assert.ok(Number.isInteger(secs) && secs >= 5 && secs <= 60, `whole seconds in range, got ${secs}`);
    seen.add(secs);
    finish(a.res);
  }
  assert.ok(seen.size >= 2, `expected spread, got ${[...seen]}`);
});

test('snapshot reports how full the line is and how much was refused', async () => {
  const mw = createAdmission({ maxConcurrent: 1, maxQueue: 1, maxWaitMs: 1000 });
  const a = send(mw), b = send(mw), c = send(mw);
  await tick();
  const snap = mw.snapshot();
  assert.deepEqual([snap.active, snap.queued, snap.admitted, snap.refused], [1, 1, 1, 1]);
  finish(a.res); await tick(); finish(b.res); finish(c.res);
});

test('the reporter logs while the line is busy and stays silent when idle', async () => {
  const { startAdmissionReporter } = require('../src/admission');
  const mw = createAdmission({ maxConcurrent: 1, maxWaitMs: 1000 });
  const lines = [];
  const timer = startAdmissionReporter(mw, { log: (level, f) => lines.push(f), pool: { totalCount: 10, idleCount: 2, waitingCount: 3 }, intervalMs: 20 });
  await new Promise((r) => setTimeout(r, 60));
  assert.equal(lines.length, 0, 'silent when nothing happens');
  const a = send(mw); await tick(); finish(a.res);
  await new Promise((r) => setTimeout(r, 60));
  clearInterval(timer);
  assert.equal(lines.length, 1);
  assert.equal(lines[0].msg, 'admission');
  assert.equal(lines[0].admittedInInterval, 1);
  assert.equal(lines[0].poolWaiting, 3);
});
