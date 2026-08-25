const { fetchRecentMessages } = require('./imap_client');

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

/**
 * Polls one connection and imports whatever parses.
 *
 * `deps` carries everything this module refuses to import itself, so it
 * stays testable without a database, a socket, or index.js's whole
 * dependency graph.
 */
async function pollConnection(connection, deps) {
  const { withUserClient, parseSmsAgainstPatterns, importParsedMessage, importSourceKey, parseTransactionDate, fetchMessages } = deps;

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
      `SELECT id, issuer_id, sender_pattern, regex, field_map
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
        // Keyed on the message body and its own date, so the same mail
        // fetched again by an overlapping poll window cannot double-count.
        // The overlap is deliberate: `SINCE` has day granularity, so
        // consecutive polls always re-see part of a day.
        sourceKey: importSourceKey(connection.profile_id, message.sender, message.body, occurred),
        backfill: false,
      });

      if (outcome.needsReview) needsReview += 1;
      else if (outcome.status === 201) imported += 1;
      else skipped += 1;
    }
  });

  return { ok: true, imported, skipped, unparsed, needsReview, count: result.messages.length };
}

/**
 * One pass over every active connection.
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
  const { pool, withUserClient, encryptionKey } = deps;
  if (!encryptionKey) {
    return { skipped: 'no_encryption_key' };
  }

  const lock = await pool.query(`SELECT pg_try_advisory_lock($1) AS acquired`, [POLL_ADVISORY_LOCK_KEY]);
  if (!lock.rows[0].acquired) return { skipped: 'another_instance_is_polling' };

  try {
    // Decrypted here, in one query, rather than per-connection: the
    // password is in memory for the shortest window that still lets the
    // poll run, and it never leaves this function's scope.
    const connections = await pool.query(
      `SELECT id, profile_id, email, imap_host, imap_port, sender_filter, last_poll_at,
              pgp_sym_decrypt(app_password_encrypted, $1) AS app_password
         FROM imap_connections
        WHERE is_active`,
      [encryptionKey]
    );

    const results = [];
    for (const connection of connections.rows) {
      let outcome;
      try {
        outcome = await pollConnection(connection, deps);
      } catch (err) {
        outcome = { ok: false, reason: `unexpected: ${err.message}` };
      }

      const status = outcome.ok
        ? `ok: ${outcome.imported} imported, ${outcome.skipped} already known, ${outcome.unparsed} not transactions`
        : `error: ${outcome.reason}`;

      // last_poll_at advances only on SUCCESS. Advancing it after a failure
      // would silently skip the window that failed, so a transient outage
      // would permanently lose whatever arrived during it.
      await withUserClient(connection.profile_id, (client) =>
        client.query(
          outcome.ok
            ? `UPDATE imap_connections SET last_poll_at = now(), last_poll_status = $2 WHERE id = $1`
            : `UPDATE imap_connections SET last_poll_status = $2 WHERE id = $1`,
          [connection.id, status]
        )
      );

      results.push({ connectionId: connection.id, ...outcome });
    }
    return { polled: results.length, results };
  } finally {
    await pool.query(`SELECT pg_advisory_unlock($1)`, [POLL_ADVISORY_LOCK_KEY]);
  }
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
      if (summary.polled) logger.log(`[imap-poller] polled ${summary.polled} connection(s)`);
    } catch (err) {
      logger.error('[imap-poller] cycle failed', err);
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
};
