'use strict';

const config = require('./config');
const { pool } = require('./db');

const WORKER_ROLE = 'rewards_worker';
const EVENT_ENDPOINT = '/internal/referral-outbox-event';

function safeErrorCode(error) {
  const candidate = typeof error?.code === 'string'
    ? error.code.toLowerCase()
    : 'worker_error';
  return /^[a-z][a-z0-9_]{0,63}$/.test(candidate) ? candidate : 'worker_error';
}

async function inWorkerRole(databasePool, callback) {
  const client = await databasePool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`SET LOCAL ROLE ${WORKER_ROLE}`);
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  } finally {
    client.release();
  }
}

function createRewardsWorker({
  databasePool,
  apiUrl = config.rewardWorkerApiUrl,
  internalSecret = config.rewardWorkerInternalSecret,
  workerId = config.rewardWorkerId,
  pollIntervalMs = config.rewardWorkerPollIntervalMs,
  batchSize = config.rewardWorkerBatchSize,
  leaseSeconds = config.rewardWorkerLeaseSeconds,
  fetchImpl = globalThis.fetch,
  now = () => Date.now(),
  logger = console,
} = {}) {
  if (!databasePool || typeof databasePool.connect !== 'function') {
    throw new TypeError('databasePool.connect is required');
  }
  if (!apiUrl || !internalSecret || Buffer.byteLength(internalSecret) < 32) {
    throw new Error('reward_worker_configuration_invalid');
  }
  if (typeof fetchImpl !== 'function') throw new TypeError('fetchImpl is required');

  let stopping = false;
  let timer = null;
  let finishDelay = null;
  let cyclePromise = null;
  let loopPromise = null;

  async function postEvent(event) {
    let response;
    let body;
    try {
      response = await fetchImpl(`${apiUrl}${EVENT_ENDPOINT}`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-reward-worker-secret': internalSecret,
        },
        body: JSON.stringify({
          eventKey: event.event_key,
          eventType: event.event_type,
          beneficiaryId: event.beneficiary_id,
          payload: event.payload,
        }),
        signal: AbortSignal.timeout(5_000),
      });
      body = await response.json().catch(() => null);
    } catch (error) {
      return { success: false, errorCode: safeErrorCode(error), permanent: false };
    }

    if (response.ok && body?.accepted === true) {
      return {
        success: true,
        result: {
          status: 'inbox_committed',
          inbox: typeof body.inbox === 'string' ? body.inbox : 'accepted',
        },
      };
    }

    const errorCode = safeErrorCode({ code: body?.error || `http_${response.status}` });
    return {
      success: false,
      errorCode,
      // Invalid event shape or permanently missing recipient cannot recover
      // through retries. Auth/config/5xx failures remain retryable.
      permanent: response.status === 400 || body?.error === 'recipient_unavailable',
    };
  }

  async function finalize(event, outcome) {
    return inWorkerRole(databasePool, async (client) => {
      const result = await client.query(
        `SELECT promotions.finalize_reward_outbox(
           $1::uuid, $2::uuid, $3::boolean, $4::jsonb, $5::text, $6::boolean
         ) AS result`,
        [
          event.id,
          event.lease_token,
          outcome.success,
          outcome.success ? JSON.stringify(outcome.result) : null,
          outcome.success ? null : outcome.errorCode,
          outcome.success ? false : outcome.permanent,
        ],
      );
      return result.rows[0]?.result || { accepted: false, state: 'unknown' };
    });
  }

  async function heartbeat({ claimed = 0, completed = 0, errorCode = null } = {}) {
    try {
      await inWorkerRole(databasePool, (client) => client.query(
        `SELECT promotions.record_reward_worker_heartbeat($1, $2, $3, $4)`,
        [workerId, claimed, completed, errorCode],
      ));
    } catch (error) {
      logger.error('reward worker heartbeat failed', { code: safeErrorCode(error) });
    }
  }

  async function pollOnce() {
    if (cyclePromise) return cyclePromise;
    cyclePromise = (async () => {
      let claimed = [];
      let completed = 0;
      let cycleError = null;
      try {
        await inWorkerRole(databasePool, (client) => client.query(
          'SELECT promotions.expire_referral_reservations($1) AS result',
          [Math.min(batchSize * 10, 500)],
        ));

        const result = await inWorkerRole(databasePool, (client) => client.query(
          'SELECT * FROM promotions.claim_reward_outbox($1, $2, $3)',
          [workerId, batchSize, leaseSeconds],
        ));
        claimed = result.rows;

        for (const event of claimed) {
          const outcome = await postEvent(event);
          const finalized = await finalize(event, outcome);
          if (finalized.accepted === true && finalized.state === 'delivered') completed += 1;
          else logger.warn(finalized.accepted === true
            ? 'reward event deferred or moved to dead letter'
            : 'reward event lease was not finalized', {
            eventType: event.event_type,
            state: finalized.state || 'unknown',
          });
        }
      } catch (error) {
        cycleError = safeErrorCode(error);
        logger.error('reward worker cycle failed', { code: cycleError });
      }
      await heartbeat({ claimed: claimed.length, completed, errorCode: cycleError });
      logger.info('reward worker cycle complete', {
        claimed: claimed.length,
        completed,
        failed: claimed.length - completed,
        at: new Date(now()).toISOString(),
      });
      return { claimed: claimed.length, completed, failed: claimed.length - completed };
    })();

    try {
      return await cyclePromise;
    } finally {
      cyclePromise = null;
    }
  }

  function delay(milliseconds) {
    return new Promise((resolve) => {
      finishDelay = resolve;
      timer = setTimeout(() => {
        timer = null;
        finishDelay = null;
        resolve();
      }, milliseconds);
    });
  }

  async function run() {
    while (!stopping) {
      await pollOnce();
      if (!stopping) await delay(pollIntervalMs);
    }
  }

  function start() {
    if (loopPromise || timer) return;
    stopping = false;
    loopPromise = run().finally(() => {
      loopPromise = null;
    });
    logger.info('reward worker started', { workerId, pollIntervalMs, batchSize });
  }

  async function stop() {
    stopping = true;
    if (timer) {
      clearTimeout(timer);
      timer = null;
      finishDelay?.();
      finishDelay = null;
    }
    const running = loopPromise || cyclePromise;
    if (running) await running.catch(() => {});
  }

  return { start, stop, pollOnce, postEvent };
}

if (require.main === module) {
  if (!config.rewardWorkerEnabled) {
    throw new Error('Set REWARD_WORKER_ENABLED=true to run the reward worker');
  }
  const worker = createRewardsWorker({ databasePool: pool });
  worker.start();
  const shutdown = async (signal) => {
    console.info('reward worker stopping', { signal });
    await worker.stop();
    await pool.end();
    process.exit(0);
  };
  process.once('SIGTERM', () => shutdown('SIGTERM'));
  process.once('SIGINT', () => shutdown('SIGINT'));
}

module.exports = { createRewardsWorker, inWorkerRole, safeErrorCode };
