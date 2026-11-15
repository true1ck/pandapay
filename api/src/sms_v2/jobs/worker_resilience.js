'use strict';

// Keeps a long-running worker alive through database trouble and memory pressure.
//
// Why: the production host is a 1 GB machine. A slow database, a dropped connection or a short login failure
// used to END the worker process (an error escaped the loop), and the kernel killed it whenever a job pushed it
// past its own memory limit. Each restart costs more memory and time on a machine that is already short of both.
//
// No dependencies, so it can be tested without a database. Errors are described by their code or name only:
// a database error message can carry data, and the worker's logs must stay metadata-only.

const BACKOFF = { minMs: 5_000, maxMs: 300_000 };
const DEFAULTS = { recycleRssMb: 150, minAvailableMb: 100 };

/** Wait after the Nth failure in a row: 5 s, 10 s, 20 s ... capped at 5 min, with +-25% jitter. */
function backoffMs(inARow, { minMs = BACKOFF.minMs, maxMs = BACKOFF.maxMs, random = Math.random } = {}) {
  const grown = Math.min(maxMs, minMs * 2 ** Math.min(Math.max(inARow, 1) - 1, 10));
  return Math.round(grown * (0.75 + random() * 0.5));
}

/** A short, safe label for an error (never its message). */
function errorLabel(error) {
  return String((error && (error.code || error.name)) || 'Error').slice(0, 40);
}

/** MemAvailable from the text of /proc/meminfo, in MB; null when it cannot be read. */
function availableMbFromMeminfo(text) {
  const m = /^MemAvailable:\s+(\d+)\s+kB/m.exec(String(text || ''));
  return m ? Math.floor(Number(m[1]) / 1024) : null;
}

/** The container's own memory limit in MB (cgroup v2 then v1); null when there is none. */
function containerLimitMbFrom(readers) {
  for (const read of readers) {
    const raw = String(read() ?? '').trim();
    if (!raw || raw === 'max') continue;
    const bytes = Number(raw);
    if (Number.isFinite(bytes) && bytes > 0 && bytes < 2 ** 40) return Math.floor(bytes / 1048576);
  }
  return null;
}

function number(env, key, fallback) {
  const v = Number(env[key]);
  return Number.isFinite(v) && v > 0 ? v : fallback;
}

/**
 * Settings from the environment. By default the worker recycles at 75% of its container limit (so it leaves
 * cleanly BETWEEN jobs instead of being killed in the middle of one) and waits while the host has under 100 MB
 * of memory available.
 */
function guardSettings(env = process.env, containerLimitMb = null) {
  const fromLimit = containerLimitMb ? Math.floor(containerLimitMb * 0.75) : DEFAULTS.recycleRssMb;
  return {
    recycleAtMb: number(env, 'SMS_V2_WORKER_RECYCLE_RSS_MB', fromLimit),
    minAvailableMb: number(env, 'SMS_V2_WORKER_MIN_AVAILABLE_MB', DEFAULTS.minAvailableMb),
  };
}

/**
 * Decide before taking the next job.
 *  - recycle: this process is near its own limit; leave cleanly so it restarts with a fresh heap.
 *  - wait:    the host is short of memory; take no new work now, look again soon.
 *  - run:     take a job.
 * An unknown host reading never blocks work.
 */
function memoryHeadroom({ rssMb, availableMb }, { recycleAtMb, minAvailableMb }) {
  if (Number.isFinite(rssMb) && rssMb >= recycleAtMb) return { action: 'recycle', reason: 'worker_memory' };
  if (Number.isFinite(availableMb) && availableMb < minAvailableMb) return { action: 'wait', reason: 'host_memory' };
  return { action: 'run', reason: null };
}

/**
 * The worker loop. A cycle that throws never ends the process: it is logged by code, then retried after a growing
 * pause. `once` keeps the old behaviour (one claim, errors surface) for tests and manual runs.
 *
 * Returns 'stopped' or 'recycle'.
 */
async function runResilientLoop({
  runCycle,
  nextDelayMs,
  headroom,
  isStopped,
  sleep,
  log,
  afterCycle,
  once = false,
}) {
  let failures = 0;
  for (;;) {
    if (isStopped()) return 'stopped';
    const room = headroom();
    if (room.action === 'recycle') {
      log({ event: 'sms_v2_template_worker', status: 'recycle', reason: room.reason, rssMb: room.rssMb });
      return 'recycle';
    }
    let result;
    if (room.action === 'wait') {
      result = { status: 'capacity', reason: room.reason };
    } else {
      try {
        result = await runCycle();
        failures = 0;
      } catch (error) {
        if (once) throw error;
        failures += 1;
        log({ event: 'sms_v2_template_worker', status: 'error', code: errorLabel(error), inARow: failures });
        await sleep(backoffMs(failures));
        continue;
      }
    }
    log({ event: 'sms_v2_template_worker', status: result.status, ...(room.rssMb ? { rssMb: room.rssMb } : {}) });
    if (afterCycle) {
      try {
        await afterCycle(result);
      } catch (error) {
        log({ event: 'sms_v2_template_worker', status: 'housekeeping_error', code: errorLabel(error) });
      }
    }
    if (once || isStopped()) return 'stopped';
    await sleep(nextDelayMs(result));
  }
}

/**
 * Opens the stores, retrying while the database login or connection is unavailable (never for a one-shot run).
 * Returns null when the process was told to stop while it was still waiting.
 */
async function openPatiently({ open, sleep, log, isStopped, once = false }) {
  for (let inARow = 1; ; inARow += 1) {
    try {
      return await open();
    } catch (error) {
      if (once) throw error;
      if (isStopped()) return null;
      log({ event: 'sms_v2_template_worker', status: 'database_unavailable', code: errorLabel(error), inARow });
      await sleep(backoffMs(inARow));
      if (isStopped()) return null;
    }
  }
}

module.exports = {
  BACKOFF,
  DEFAULTS,
  backoffMs,
  errorLabel,
  availableMbFromMeminfo,
  containerLimitMbFrom,
  guardSettings,
  memoryHeadroom,
  runResilientLoop,
  openPatiently,
};
