'use strict';

function safeErrorCode(error) {
  const code = typeof error?.code === 'string' ? error.code.toLowerCase() : 'notification_error';
  return /^[a-z][a-z0-9_]{0,63}$/.test(code) ? code : 'notification_error';
}

function createNotificationOutboxWorker({ databasePool, workerId = 'notification-worker', batchSize = 1,
  leaseSeconds = 90, pollIntervalMs = 5000, deliveryTimeoutMs = 30000, abortGraceMs = 3000, send, reportStatus = null, logger = console } = {}) {
  if (!databasePool?.connect) throw new TypeError('databasePool.connect is required');
  if (!/^[A-Za-z0-9._:-]{1,120}$/.test(workerId)) throw new TypeError('workerId must be 1-120 safe characters');
  if (!Number.isInteger(batchSize) || batchSize !== 1) throw new RangeError('batchSize must be 1 to keep each claimed lease bounded');
  if (!Number.isInteger(leaseSeconds) || leaseSeconds < 60 || leaseSeconds > 900) throw new RangeError('leaseSeconds must be 60-900');
  if (!Number.isInteger(pollIntervalMs) || pollIntervalMs < 100 || pollIntervalMs > 300000) throw new RangeError('pollIntervalMs must be 100-300000');
  if (!Number.isInteger(deliveryTimeoutMs) || deliveryTimeoutMs < 1000 || deliveryTimeoutMs > 60000 || deliveryTimeoutMs * 2 > leaseSeconds * 1000) {
    throw new RangeError('deliveryTimeoutMs must be 1000-60000 and at most half of the lease');
  }
  if (!Number.isInteger(abortGraceMs) || abortGraceMs < 100 || abortGraceMs > 10000
      || deliveryTimeoutMs + abortGraceMs > leaseSeconds * 1000 * 0.75) {
    throw new RangeError('abortGraceMs must be 100-10000 and leave lease recovery margin');
  }
  if (!send) send = require('./notification_service').send;
  if (typeof send !== 'function') throw new TypeError('send is required');
  if (reportStatus !== null && typeof reportStatus !== 'function') throw new TypeError('reportStatus must be a function');
  const withWorkerRole = async (fn) => {
    const c = await databasePool.connect();
    let discardConnection;
    try {
      await c.query('BEGIN'); await c.query('SET LOCAL ROLE notification_worker');
      await c.query("SET LOCAL statement_timeout = '5s'");
      const value = await fn(c); await c.query('COMMIT'); return value;
    } catch (e) { try { await c.query('ROLLBACK'); } catch (rollbackError) { discardConnection = rollbackError; } throw e; }
    finally { c.release(discardConnection); }
  };
  let cycle = null; let timer = null; let wakeDelay = null; let stopRequested = false; let loop = null;
  let activeController = null; let cancelActiveSend = null; let senderBlocked = false;
  let latestStatus = { available: false, lastPollAt: null, errorCode: 'notification_worker_not_started' };

  async function sendWithDeadline(payload) {
    const controller = new AbortController();
    activeController = controller;
    const sendPromise = Promise.resolve().then(() => send({ ...payload, signal: controller.signal }));
    const settled = sendPromise.then((value) => ({ kind: 'resolved', value }), (error) => ({ kind: 'rejected', error }));
    let deadlineTimer;
    const deadline = new Promise((resolve) => { deadlineTimer = setTimeout(() => resolve({ kind: 'timeout' }), deliveryTimeoutMs); });
    let resolveCancellation;
    const cancellation = new Promise((resolve) => { resolveCancellation = resolve; });
    cancelActiveSend = () => resolveCancellation({ kind: 'timeout' });
    const first = await Promise.race([settled, deadline, cancellation]);
    clearTimeout(deadlineTimer);
    cancelActiveSend = null;
    if (first.kind !== 'timeout') {
      if (activeController === controller) activeController = null;
      if (first.kind === 'rejected') throw first.error;
      return { completed: true, value: first.value };
    }

    controller.abort();
    let graceTimer;
    const grace = new Promise((resolve) => { graceTimer = setTimeout(() => resolve({ kind: 'unresponsive' }), abortGraceMs); });
    const afterAbort = await Promise.race([settled, grace]);
    clearTimeout(graceTimer);
    if (afterAbort.kind === 'unresponsive') {
      // Keep this worker fenced from further sends. The abandoned provider
      // operation is allowed to settle later, but no local cycle can overlap it.
      senderBlocked = true;
      settled.finally(() => { if (activeController === controller) activeController = null; }).catch(() => {});
      return { completed: false, unresponsive: true };
    }
    if (activeController === controller) activeController = null;
    return { completed: false, timedOut: true };
  }

  async function deliver(row) {
    try {
      // Provider identity remains stable across retries. Duplicate external
      // sends are still possible if the provider accepts but its response is lost.
      const sent = await sendWithDeadline({ subscriberId: row.profile_id, title: row.title, body: row.body || '',
        category: row.category, severity: row.severity, deepLink: row.deep_link,
        dedupeKey: `notification:${row.revision_id}` });
      if (sent.unresponsive) return { success: false, permanent: false, code: 'notification_sender_unresponsive', deferFinalization: true };
      if (sent.timedOut) return { success: false, permanent: false, code: 'notification_delivery_timeout' };
      const providerResult = sent.value;
      if (providerResult?.configured === false) return { success: false, permanent: false, code: 'notification_service_unconfigured' };
      return { success: true };
    } catch (e) { const code = safeErrorCode(e); return { success: false, permanent: code === 'notification_no_devices', code }; }
  }
  async function pollOnce() {
    if (cycle) return cycle;
    if (senderBlocked) return { available: false, errorCode: 'notification_sender_unresponsive', claimed: 0, completed: 0, failed: 0 };
    cycle = (async () => {
      const rows = await withWorkerRole((c) => c.query(
        'SELECT * FROM notification_delivery.claim($1,$2,$3)', [workerId, batchSize, leaseSeconds]));
      let completed = 0;
      for (const row of rows.rows) {
        const allowed = await withWorkerRole((c) => c.query(
          'SELECT notification_delivery.allowed($1::uuid,$2::uuid) AS allowed', [row.id, row.lease_token]));
        const result = allowed.rows[0]?.allowed ? await deliver(row) : { success: false, permanent: true, code: 'preference_or_account_disabled' };
        if (result.deferFinalization) {
          logger.error('notification outbox worker blocked by non-cancellable sender', { code: result.code });
          return { available: false, errorCode: result.code, claimed: rows.rowCount, completed, failed: rows.rowCount - completed };
        }
        const finalized = await withWorkerRole((c) => c.query(
          'SELECT notification_delivery.finish($1::uuid,$2::uuid,$3::boolean,$4::text,$5::boolean) AS result',
          [row.id, row.lease_token, result.success, result.success ? null : result.code, result.permanent]));
        if (finalized.rows[0]?.result?.accepted && result.success) completed++;
      }
      return { available: true, claimed: rows.rowCount, completed, failed: rows.rowCount - completed };
    })().catch((e) => { const code = safeErrorCode(e); logger.error('notification outbox cycle unavailable', { code }); return { available: false, errorCode: code, claimed: 0, completed: 0, failed: 0 }; })
      .then(async result => {
        try {
          if (reportStatus) await reportStatus({ ...result, blocked: senderBlocked });
        } catch (error) {
          result = { ...result, available: false, errorCode: 'notification_worker_status_unavailable' };
          logger.error('notification worker status unavailable', { code: safeErrorCode(error) });
        }
        latestStatus = { available: result.available === true, lastPollAt: Date.now(), errorCode: result.errorCode || null };
        return result;
      })
      .finally(() => { cycle = null; });
    return cycle;
  }
  function start() {
    if (loop) return;
    stopRequested = false;
    loop = (async () => { while (!stopRequested) { await pollOnce(); if (!stopRequested) await new Promise((r) => {
      wakeDelay = r; timer = setTimeout(() => { timer = null; wakeDelay = null; r(); }, pollIntervalMs);
    }); } })().finally(() => { loop = null; });
  }
  async function stop() {
    stopRequested = true; activeController?.abort(); cancelActiveSend?.();
    if (timer) clearTimeout(timer); timer = null; wakeDelay?.(); wakeDelay = null;
    if (loop) await loop;
    latestStatus = { available: false, lastPollAt: Date.now(), errorCode: 'notification_worker_stopped' };
    if (reportStatus) {
      try { await reportStatus({ available: false, blocked: senderBlocked, claimed: 0, completed: 0, failed: 0, errorCode: 'notification_worker_stopped' }); }
      catch (error) { logger.error('Notification worker stop status unavailable', { code: safeErrorCode(error) }); }
    }
  }
  return { pollOnce, start, stop, isBlocked: () => senderBlocked,
    getStatus: () => ({ ...latestStatus, blocked: senderBlocked, running: Boolean(loop) }) };
}

module.exports = { createNotificationOutboxWorker, safeErrorCode };
