const { fetchRecentMessages } = require('./imap_client');
const { safeErrorCode } = require('./safeErrorCode');
const { readImapWorkerBatch, deferImapWorkerBatch } = require('./imap_worker_capability');

/**
 * The background IMAP poller — the thing `imap_connections` was built for
 * and never had.
 *
 * Migration 0018 stored an encrypted app password and index.js offered a
 * live "test connection", and then nothing ever read a mailbox. Both files
 * said so in their own comments. That left the app storing a decryptable
 * credential purely as a liability, while the user reasonably believed
 * their mail was being read.
 *
 * The poller runs IN THE API PROCESS on an interval rather than as a
 * separate service or a pg_cron job, for two reasons: pg_cron runs SQL and
 * cannot open a TLS socket, and a separate worker would be new
 * infrastructure to deploy, monitor and secure for one job. A Postgres
 * advisory lock keeps exactly one instance polling when the API is scaled
 * out.
 *
 * Everything downstream of "a (sender, body) pair arrived" is the SAME path
 * SMS and forwarded email already take — `importParsedMessage`, injected by
 * the caller — so a transaction discovered by IMAP gets identical
 * parsing, card resolution, categorisation, deduplication and cap/reward
 * treatment. No second implementation to keep in sync.
 */

/**
 * Arbitrary but fixed 64-bit key for `pg_try_advisory_lock`. Any two API
 * instances that pick the same number cooperate; the value itself has no
 * meaning beyond being unlikely to collide with another advisory lock in
 * this database.
 */
const POLL_ADVISORY_LOCK_KEY = 738201947;

/** How far back a first-ever poll looks. */
const INITIAL_LOOKBACK_DAYS = 30;
const MAX_CYCLE_DURATION_MS = 5 * 60 * 1000;

/**
 * Polls one connection and imports whatever parses.
 *
 * `deps` carries everything this module refuses to import itself, so it
 * stays testable without a database, a socket, or index.js's whole
 * dependency graph.
 */
async function pollConnection(connection, deps) {
  const {
    withUserClient,
    parseSmsAgainstPatterns,
    importParsedMessage,
    importSourceKey,
    emailSourceKey,
    parseTransactionDate,
    fetchMessages,
  } = deps;

  const since = connection.last_poll_at
    ? new Date(connection.last_poll_at)
    : new Date(Date.now() - INITIAL_LOOKBACK_DAYS * 86400000);

  const result = await fetchMessages({
    host: connection.imap_host,
    port: connection.imap_port,
    email: connection.email,
    password: connection.app_password,
    since,
    senderFilter: connection.sender_filter,
  });

  if (!result.ok) {
    return { ok: false, reason: result.reason, imported: 0, skipped: 0, unparsed: 0 };
  }

  let imported = 0;
  let skipped = 0;
  let unparsed = 0;
  let needsReview = 0;

  await withUserClient(connection.profile_id, async (client) => {
    const patterns = await client.query(
      `SELECT id, issuer_id, sender_pattern, regex, field_map, version
         FROM parser_patterns WHERE channel = 'email' AND is_active = true ORDER BY version DESC`
    );

    for (const message of result.messages) {
      const parsed = parseSmsAgainstPatterns(patterns.rows, {
        sender: message.sender,
        body: message.body,
      });
      if (!parsed.ok) {
        // Not an error. Most mail in an inbox isn't a transaction alert,
        // and a bank template we haven't matched yet is exactly what
        // `parser_failures` exists to surface — the SMS path takes the same
        // view. Silently skipped here rather than recorded, because unlike
        // SMS this poller sees mail the user never asked us to parse.
        unparsed += 1;
        continue;
      }

      const patternRow = patterns.rows.find((p) => p.id === parsed.patternId);
      const occurred = parseTransactionDate(parsed.fields.date) || new Date();

      const outcome = await importParsedMessage(client, connection.profile_id, {
        parsed,
        patternIssuerId: patternRow ? patternRow.issuer_id : null,
        sender: message.sender,
        rawText: message.body,
        source: 'email',
        occurred,
        // Keyed on the normalized message body, so the same mail fetched
        // again by an overlapping poll window cannot double-count.
        // The overlap is deliberate: `SINCE` has day granularity, so
        // consecutive polls always re-see part of a day.
        sourceKey: emailSourceKey
          ? emailSourceKey(
              connection.profile_id,
              message.sender,
              message.subject,
              message.body,
              `${connection.id}:${message.uid}`,
            )
          : importSourceKey(connection.profile_id, message.sender, message.body, occurred),
        backfill: false,
        observationMetadata: { transport: 'imap', imapUid: String(message.uid) },
      });

      if (outcome.needsReview) needsReview += 1;
      else if (outcome.status === 201) imported += 1;
      else skipped += 1;
    }
  });

  return { ok: true, imported, skipped, unparsed, needsReview, count: result.messages.length };
}

/**
 * One bounded batch of active connections, using the durable worker cursor.
 *
 * Takes an advisory lock first and does nothing if another instance already
 * holds it — two instances polling the same mailbox concurrently would
 * duplicate work and could trip a provider's connection limits. The lock is
 * released in a `finally` so a thrown poll can't wedge the schedule.
 *
 * A failure on one connection never stops the others: one user's expired
 * app password must not stop everyone else's mail being read.
 */
async function runPollCycle(deps) {
  const { pool, workerPool, withUserClient, encryptionKey } = deps;
  if (!encryptionKey) {
    return { skipped: 'no_encryption_key' };
  }
  if (!workerPool) return { skipped: 'no_worker_database' };
  if (workerPool === pool) return { skipped: 'worker_database_pool_not_separate' };
  const maxCycleDurationMs = deps.maxCycleDurationMs ?? MAX_CYCLE_DURATION_MS;
  if (!Number.isInteger(maxCycleDurationMs) || maxCycleDurationMs < 1 || maxCycleDurationMs > MAX_CYCLE_DURATION_MS) {
    throw new Error('imap_poll_cycle_budget_invalid');
  }
  const now = deps.now || Date.now;
  const deadline = now() + maxCycleDurationMs;

  let client;
  let lockResolved = false;
  let lockAcquired = false;
  let result;
  let operationError;
  let unlockError;
  try {
    client = await workerPool.connect();
    const lock = await client.query(
      `SELECT pg_try_advisory_lock($1) AS acquired`,
      [POLL_ADVISORY_LOCK_KEY],
    );
    const acquired = lock.rows[0]?.acquired;
    if (typeof acquired !== 'boolean') {
      throw new Error('imap_poll_lock_result_invalid');
    }
    lockResolved = true;
    lockAcquired = acquired;
    if (!lockAcquired) {
      result = { skipped: 'another_instance_is_polling' };
    } else {
      // A private capability enumerates at most 100 active connections. Its
      // durable keyset cursor survives process/lock-owner changes. Imports and
      // status updates still use ordinary per-user RLS connections.
      const connections = await readImapWorkerBatch(client, encryptionKey);

      const results = [];
      let deferredCount = 0;
      try {
        for (const [index, connection] of connections.entries()) {
          if (now() >= deadline) {
            deferredCount = connections.length - index;
            break;
          }
          let outcome;
          try {
            outcome = connection.credential_error || typeof connection.app_password !== 'string'
              ? { ok: false, reason: 'credential_unavailable', imported: 0, skipped: 0, unparsed: 0 }
              : await pollConnection(connection, deps);
          } catch (_) {
            outcome = { ok: false, reason: 'unexpected_error' };
          } finally {
            // Release this batch's reference as soon as its provider work ends.
            connection.app_password = null;
          }

          const status = outcome.ok
            ? `ok: ${outcome.imported} imported, ${outcome.skipped} already known, ${outcome.unparsed} not transactions`
            : `error: ${outcome.reason}`;

          // last_poll_at advances only on SUCCESS. Advancing it after a failure
          // would silently skip the window that failed, so a transient outage
          // would permanently lose whatever arrived during it.
          try {
            await withUserClient(connection.profile_id, (client) =>
              client.query(
                outcome.ok
                  ? `UPDATE imap_connections SET last_poll_at = now(), last_poll_status = $2 WHERE id = $1`
                  : `UPDATE imap_connections SET last_poll_status = $2 WHERE id = $1`,
                [connection.id, status]
              )
            );
          } catch (_) {
            // The per-user transaction rolls back failed status writes. Keep
            // its old successful poll window and continue this batch so one
            // bad row cannot repeatedly starve every later mailbox.
            outcome = { ...outcome, ok: false, reason: 'status_write_failed' };
          }

          results.push({ connectionId: connection.id, ...outcome });
        }
      } finally {
        // Include unprocessed rows when a cycle is deferred or status I/O
        // fails. Their original last_poll_at survives for a later rotation.
        for (const connection of connections) connection.app_password = null;
      }
      if (deferredCount) {
        // Resume after the last attempted mailbox next tick. This matters
        // even for a short batch: otherwise one slow first mailbox could
        // consume each cycle and starve every later row after cursor wrap.
        await deferImapWorkerBatch(client, results.at(-1)?.connectionId ?? null);
      }
      result = { polled: results.length, results, ...(deferredCount ? { deferredCount } : {}) };
    }
  } catch (err) {
    operationError = err;
  } finally {
    if (client) {
      let discardClient = false;
      if (!lockResolved) {
        // A failed lock query has an uncertain server-side outcome. Destroy
        // this session so a lock acquired without a received response cannot
        // remain attached to a connection returned to the pool.
        discardClient = true;
      }
      if (lockAcquired) {
        try {
          const unlock = await client.query(
            `SELECT pg_advisory_unlock($1) AS released`,
            [POLL_ADVISORY_LOCK_KEY],
          );
          if (unlock.rows[0]?.released !== true) {
            throw new Error('imap_poll_lock_release_failed');
          }
        } catch (err) {
          discardClient = true;
          unlockError = err;
        }
      }
      // pg.PoolClient.release(error) destroys the underlying session. This is
      // required whenever lock ownership could not be confirmed as released.
      client.release(
        discardClient
          ? (unlockError || operationError || new Error('imap_poll_lock_state_uncertain'))
          : undefined,
      );
    }
  }

  if (operationError) throw operationError;
  if (unlockError) throw unlockError;
  return result;
}

/**
 * Starts the interval. Returns a stop function.
 *
 * Off unless `IMAP_POLL_INTERVAL_MINUTES` is set, so the poller never
 * starts by accident in a development or test process — one that opened TLS
 * connections to real mailboxes from a laptop would be a genuinely bad
 * surprise.
 */
function startImapPoller(deps, { intervalMinutes, logger = console } = {}) {
  if (!intervalMinutes || intervalMinutes <= 0) return () => {};

  let running = false;
  const tick = async () => {
    // Skip rather than queue: a poll that runs long (a slow mailbox) must
    // not stack up behind itself.
    if (running) return;
    running = true;
    try {
      const summary = await runPollCycle(deps);
      if (summary.skipped === 'no_worker_database' || summary.skipped === 'worker_database_pool_not_separate') {
        logger.warn('[imap-poller] skipped: configure a separate IMAP worker database capability');
      }
      if (summary.polled) logger.log(`[imap-poller] polled ${summary.polled} connection(s)`);
      if (summary.deferredCount) logger.warn(`[imap-poller] deferred ${summary.deferredCount} connection(s) after cycle deadline`);
    } catch (err) {
      logger.error('[imap-poller] cycle failed', safeErrorCode(err));
    } finally {
      running = false;
    }
  };

  const handle = setInterval(tick, intervalMinutes * 60 * 1000);
  // Never hold the process open for a background timer.
  if (handle.unref) handle.unref();
  return () => clearInterval(handle);
}

module.exports = {
  pollConnection,
  runPollCycle,
  startImapPoller,
  fetchRecentMessages,
  POLL_ADVISORY_LOCK_KEY,
  INITIAL_LOOKBACK_DAYS,
  MAX_CYCLE_DURATION_MS,
};
