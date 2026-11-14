'use strict';

/**
 * Admission control: a bounded first-come-first-served line in front of the database.
 *
 * Why: the pool has a handful of connections. Without a line, a burst makes requests wait on the pool,
 * hit its 5 s connect timeout and answer a bare 500, which the app reads as a possibly-bad change (it
 * parks a change for an hour after repeated 500s on the same row). Here a request waits its turn, and
 * when the wait or the line is too long it is refused fast with 503 + Retry-After, which the app treats
 * as "server busy, try again" and keeps the data.
 *
 * Three limits, checked in this order (all FIFO, one shared deadline):
 *   1. per user: at most one /sync/push at a time (also serialises two devices of one account);
 *   2. per class: a few slots for /sync/push and for heavy report routes, so they cannot starve the rest;
 *   3. overall: total in-flight requests, a small multiple of the pool size.
 * A request whose client has gone away while it waits leaves the line without running.
 *
 * ponytail: in-process only (one API container). With several containers each enforces its own caps;
 * move the per-user lane to Postgres/Redis only if the API is scaled out and needs a global order.
 */

const { AsyncLocalStorage } = require('node:async_hooks');

const als = new AsyncLocalStorage();

const POOL_TIMEOUT_MESSAGE = 'timeout exceeded when trying to connect';
const isPoolTimeout = (err) => err?.message === POOL_TIMEOUT_MESSAGE;

// The database is busy or briefly away (restart, failover, network blip): the same request can succeed shortly, so
// it is answered 503 + Retry-After, never a 500 (the app parks a change for an hour after repeated 500s on one row).
const UNAVAILABLE_NET_CODES = new Set(['ECONNREFUSED', 'ECONNRESET', 'ETIMEDOUT', 'EPIPE', 'ENOTFOUND', 'EAI_AGAIN', 'ECONNABORTED']);
const UNAVAILABLE_MESSAGE = /connection terminated|connection timeout|timeout exceeded when trying to connect|database system is (starting up|shutting down|in recovery)|client has encountered a connection error|cannot use a pool after calling end|query read timeout/i;
function isDbUnavailable(err) {
  const code = typeof err?.code === 'string' ? err.code : '';
  return UNAVAILABLE_NET_CODES.has(code)
    || /^08/.test(code)                 // connection exception class
    || /^57P0[123]$/.test(code)         // admin_shutdown, crash_shutdown, cannot_connect_now
    || UNAVAILABLE_MESSAGE.test(String(err?.message || ''));
}

// Called by the database layer when a request's database work failed. If the failure has a well-known meaning (busy or
// away -> 503, malformed id -> 400, duplicate -> 409, ...) it is remembered on the response, and when the route's own
// catch block then answers a generic 500, that answer is replaced (see the res.status wrapper in the middleware).
// Routes that answer something else for the same error are untouched.
function noteDbError(err) {
  const store = als.getStore();
  if (!store || store.res.locals.dbError) return;
  const mapped = require('./http_db_errors').classifyDbError(err);
  if (mapped) store.res.locals.dbError = mapped;
}

// Pool exhaustion / no connection in time (kept for callers that have no error object).
function notePoolBusy() {
  const store = als.getStore();
  if (store && !store.res.locals.dbError) store.res.locals.dbError = { status: 503, body: { error: 'server_busy', retryable: true } };
}

class Gate {
  constructor(limit, maxQueue) {
    this.limit = limit;
    this.maxQueue = maxQueue;
    this.active = 0;
    this.queue = []; // FIFO of { grant, dead }
  }

  /** Resolves with a release function, or null when the line is full. `ctl.cancelled()` drops a waiter. */
  acquire(ctl) {
    if (this.active < this.limit && this.queue.length === 0) {
      this.active += 1;
      return Promise.resolve(this._releaser());
    }
    if (this.queue.length >= this.maxQueue) return Promise.resolve(null);
    return new Promise((resolve) => {
      const waiter = { resolve, ctl };
      this.queue.push(waiter);
      ctl.onCancel(() => {
        const i = this.queue.indexOf(waiter);
        if (i >= 0) this.queue.splice(i, 1);
        resolve(undefined); // cancelled: neither granted nor refused
      });
    });
  }

  _releaser() {
    let done = false;
    return () => {
      if (done) return;
      done = true;
      this.active -= 1;
      this._drain();
    };
  }

  _drain() {
    while (this.active < this.limit && this.queue.length > 0) {
      const waiter = this.queue.shift();
      this.active += 1;
      waiter.resolve(this._releaser());
    }
  }
}

// Routes measured at 100 ms - 1 s+ per call on a 40k-transaction account (see scripts/bench_http.js).
const HEAVY_GET = new Set(['/account-summaries', '/spend-report', '/monthly-reports', '/recurring', '/user-cards']);

// Long-running requests (imports, exports, backups, bulk uploads) hold their admission slot for their whole duration; they get
// their own small cap so a handful of them cannot take every slot from the ordinary traffic.
const BULK_POST = new Set(['/user-cards/import', '/statement-imports', '/sms-import-batches', '/transactions/category-bulk-apply']);
const BULK_GET = new Set(['/export', '/export/transactions.csv']);
function isBulk(req) {
  const path = req.path;
  if (path.startsWith('/portable-backups') || path.startsWith('/restore-sessions')) return true;
  if (req.method === 'POST' && (BULK_POST.has(path) || (path.startsWith('/sms/v2/') && path.endsWith(':batch')))) return true;
  return req.method === 'GET' && BULK_GET.has(path);
}

function classify(req) {
  const path = req.path;
  if (path === '/health' || path === '/ready') return null; // liveness probes never queue
  if (req.method === 'POST' && path === '/sync/push') return 'push';
  if (isBulk(req)) return 'bulk';
  if (req.method === 'GET' && HEAVY_GET.has(path)) return 'heavy';
  return 'default';
}

function createAdmission({
  maxConcurrent = 20,
  heavyMax = 3,
  pushMax = 3,
  bulkMax = 2,
  maxQueue = 200,
  maxWaitMs = 8000,
} = {}) {
  const overall = new Gate(maxConcurrent, maxQueue);
  const classes = {
    push: new Gate(pushMax, maxQueue),
    heavy: new Gate(heavyMax, maxQueue),
    bulk: new Gate(bulkMax, maxQueue),
  };
  const userLanes = new Map(); // userId -> Gate(1); removed when idle

  const stats = { admitted: 0, refused: 0, cancelled: 0 };

  function retryAfterSeconds() {
    // Rough drain time of the overall line, clamped to what the app handles well (5-60 s is ideal for it), plus up
    // to 50% random jitter: clients refused in the same second must not all come back in the same second.
    const queued = overall.queue.length;
    const base = Math.min(30, Math.max(5, 5 + Math.ceil(queued / Math.max(1, maxConcurrent))));
    return Math.min(60, Math.round(base * (1 + Math.random() * 0.5)));
  }

  function refuse(res) {
    stats.refused += 1;
    if (res.headersSent) return;
    res.set('Retry-After', String(retryAfterSeconds()));
    res.status(503).json({ error: 'server_busy', retryable: true });
  }

  function middleware(req, res, next) {
    const cls = classify(req);
    if (cls === null) return next();

    // A route that fails on a database error with a known meaning answers a generic 500 from its own catch block. Replace
    // that 500 with the right answer (and for 503 a Retry-After), so every route behaves the same way under failure.
    const status = res.status.bind(res);
    res.status = (code) => {
      const mapped = code === 500 ? res.locals.dbError : null;
      if (!mapped) return status(code);
      if (mapped.body.retryable) res.set('Retry-After', String(retryAfterSeconds()));
      const json = res.json.bind(res);
      res.json = () => json(mapped.body);
      return status(mapped.status);
    };

    const cancels = [];
    let cancelled = false;
    let admitted = false;
    const ctl = { onCancel: (fn) => { if (cancelled) fn(); else cancels.push(fn); } };
    const releases = [];
    const releaseAll = () => { while (releases.length) releases.pop()(); };
    const leaveLine = () => {
      if (cancelled) return;
      cancelled = true;
      cancels.splice(0).forEach((fn) => fn());
      releaseAll();
    };
    // 'close' fires after a normal finish too, and when the client hangs up mid-request. A request that is
    // still waiting just leaves the line. One already running keeps its work going (we cannot stop the
    // handler), so its slots are freed here; that can briefly overshoot a cap after an abort.
    res.on('close', () => {
      if (!admitted && !res.writableEnded) { stats.cancelled += 1; leaveLine(); } else releaseAll();
    });

    const deadline = setTimeout(() => {
      if (admitted || cancelled) return;
      leaveLine();
      refuse(res);
    }, maxWaitMs);
    deadline.unref?.();

    (async () => {
      const gates = [];
      if (cls === 'push' && req.userId) {
        let lane = userLanes.get(req.userId);
        if (!lane) { lane = new Gate(1, 4); userLanes.set(req.userId, lane); }
        gates.push({ gate: lane, lane: true });
      }
      if (classes[cls]) gates.push({ gate: classes[cls] });
      gates.push({ gate: overall });

      for (const { gate, lane } of gates) {
        const release = await gate.acquire(ctl);
        if (release === undefined) return; // client left or deadline hit while waiting
        if (release === null) { clearTimeout(deadline); leaveLine(); refuse(res); return; } // line is full
        // Releases run last-pushed-first: the gate is released, then an idle lane is dropped from the map.
        if (lane) releases.push(() => { if (gate.active === 0 && gate.queue.length === 0) userLanes.delete(req.userId); });
        releases.push(release);
        if (cancelled) { releaseAll(); return; }
      }
      clearTimeout(deadline);
      admitted = true;
      stats.admitted += 1;
      als.run({ req, res }, next);
    })().catch(next);
  }

  // Point-in-time view for logs/metrics: how full the line is and how much has been refused so far.
  middleware.snapshot = () => ({
    active: overall.active,
    queued: overall.queue.length,
    pushActive: classes.push.active,
    pushQueued: classes.push.queue.length,
    heavyActive: classes.heavy.active,
    heavyQueued: classes.heavy.queue.length,
    bulkActive: classes.bulk.active,
    bulkQueued: classes.bulk.queue.length,
    pushLanes: userLanes.size,
    admitted: stats.admitted,
    refused: stats.refused,
    cancelled: stats.cancelled,
  });
  middleware.stats = stats;
  middleware._gates = { overall, classes, userLanes };
  return middleware;
}

/**
 * One structured log line per interval while the line is in use (or refusing), so an operator can see queue depth,
 * wait pressure on the pool and the 503 rate without a metrics stack. Silent when idle. The timer never keeps the
 * process alive.
 */
function startAdmissionReporter(admission, { log, pool, intervalMs = 30_000 }) {
  let last = admission.snapshot();
  const timer = setInterval(() => {
    const now = admission.snapshot();
    const moved = now.admitted !== last.admitted || now.refused !== last.refused || now.cancelled !== last.cancelled;
    if (moved || now.queued > 0) {
      log('info', {
        msg: 'admission',
        intervalSeconds: intervalMs / 1000,
        ...now,
        admittedInInterval: now.admitted - last.admitted,
        refusedInInterval: now.refused - last.refused,
        cancelledInInterval: now.cancelled - last.cancelled,
        poolTotal: pool?.totalCount,
        poolIdle: pool?.idleCount,
        poolWaiting: pool?.waitingCount,
      });
    }
    last = now;
  }, intervalMs);
  timer.unref?.();
  return timer;
}

module.exports = { startAdmissionReporter, createAdmission, noteDbError, notePoolBusy, isPoolTimeout, isDbUnavailable, classify, Gate, _als: als };
