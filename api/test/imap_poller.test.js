const test = require('node:test');
const assert = require('node:assert');
const { pollConnection, runPollCycle, INITIAL_LOOKBACK_DAYS, POLL_ADVISORY_LOCK_KEY } = require('../src/imap_poller');
const { parseFetchResponse, quoted, imapDate } = require('../src/imap_client');

/**
 * The poller, exercised without a socket or a database.
 *
 * The behaviours worth locking down are the ones whose failure is silent:
 * mail that isn't a transaction must be skipped rather than treated as an
 * error, the same mail seen twice must not double-count, and a first-ever
 * poll must look back far enough to find anything at all.
 */
function fakeDeps({ messages = [], onImport = null, patterns = [{ id: 'p1', issuer_id: 'i1' }] } = {}) {
  const imported = [];
  return {
    imported,
    deps: {
      withUserClient: async (_userId, fn) =>
        fn({ query: async () => ({ rows: patterns }) }),
      parseSmsAgainstPatterns: (_patterns, { body }) =>
        body.includes('spent')
          ? { ok: true, patternId: 'p1', fields: { amountInr: 450, merchant: 'Swiggy', date: null } }
          : { ok: false, reason: 'no_regex_match' },
      importParsedMessage: async (_client, _userId, args) => {
        imported.push(args);
        return onImport ? onImport(args) : { status: 201, transaction: { id: 't1' } };
      },
      importSourceKey: (userId, sender, body) => `${userId}|${sender}|${body}`,
      parseTransactionDate: () => null,
      fetchMessages: async (opts) => {
        imported.fetchOpts = opts;
        return { ok: true, messages, highestUid: 10 };
      },
    },
  };
}

const CONNECTION = {
  id: 'c1',
  profile_id: 'u1',
  email: 'me@example.com',
  imap_host: 'imap.example.com',
  imap_port: 993,
  sender_filter: 'alerts@bank.com',
  last_poll_at: null,
  app_password: 'secret',
};

function pollCycleDeps({ lock = true, connections = [], queryError = null, unlock = true } = {}) {
  const calls = [];
  let releasedWith;
  const client = {
    async query(sql, params) {
      calls.push({ sql, params });
      if (queryError && sql.includes('FROM imap_worker.next_connections')) throw queryError;
      if (sql.includes('pg_try_advisory_lock')) return { rows: [{ acquired: lock }] };
      if (sql.includes('pg_advisory_unlock')) return { rows: [{ released: unlock }] };
      return { rows: connections };
    },
    release(error) {
      releasedWith = error;
    },
  };
  return {
    calls,
    client,
    get releasedWith() { return releasedWith; },
    deps: {
      workerPool: { options: { max: 1 }, connect: async () => client },
      encryptionKey: 'synthetic-key',
      withUserClient: async (_userId, fn) => fn({ query: async () => ({ rows: [] }) }),
      parseSmsAgainstPatterns: () => ({ ok: false }),
      importParsedMessage: async () => ({ status: 201 }),
      importSourceKey: () => 'synthetic-source',
      parseTransactionDate: () => null,
      fetchMessages: async () => ({ ok: true, messages: [] }),
    },
  };
}

test('poll cycle holds one checked-out client for lock, work, and unlock', async () => {
  const fake = pollCycleDeps();
  const result = await runPollCycle(fake.deps);

  assert.deepStrictEqual(result, { polled: 0, results: [] });
  assert.strictEqual(fake.calls.length, 3);
  assert.match(fake.calls[0].sql, /pg_try_advisory_lock/);
  assert.match(fake.calls[1].sql, /FROM imap_worker.next_connections/);
  assert.match(fake.calls[2].sql, /pg_advisory_unlock/);
  assert.deepStrictEqual(fake.calls[0].params, [POLL_ADVISORY_LOCK_KEY]);
  assert.deepStrictEqual(fake.calls[2].params, [POLL_ADVISORY_LOCK_KEY]);
  assert.strictEqual(fake.releasedWith, undefined);
});

test('a busy poll lock skips work and returns the checked-out client normally', async () => {
  const fake = pollCycleDeps({ lock: false });
  const result = await runPollCycle(fake.deps);

  assert.deepStrictEqual(result, { skipped: 'another_instance_is_polling' });
  assert.strictEqual(fake.calls.length, 1);
  assert.strictEqual(fake.releasedWith, undefined);
});

test('a failed lock query destroys the client because lock ownership is uncertain', async () => {
  const fake = pollCycleDeps();
  const failure = new Error('synthetic lock query failure');
  fake.client.query = async (sql) => {
    fake.calls.push({ sql });
    throw failure;
  };

  await assert.rejects(runPollCycle(fake.deps), /synthetic lock query failure/);
  assert.strictEqual(fake.calls.length, 1);
  assert.strictEqual(fake.releasedWith, failure);
});

test('an unlock response that says the lock is still held destroys the client', async () => {
  const fake = pollCycleDeps({ unlock: false });

  await assert.rejects(runPollCycle(fake.deps), /imap_poll_lock_release_failed/);
  assert.strictEqual(fake.calls.length, 3);
  assert.ok(fake.releasedWith instanceof Error);
});

test('an unlock query failure destroys the client rather than returning a locked session', async () => {
  const fake = pollCycleDeps();
  fake.client.query = async (sql, params) => {
    fake.calls.push({ sql, params });
    if (sql.includes('pg_advisory_unlock')) throw new Error('synthetic unlock failure');
    if (sql.includes('pg_try_advisory_lock')) return { rows: [{ acquired: true }] };
    return { rows: [] };
  };

  await assert.rejects(runPollCycle(fake.deps), /synthetic unlock failure/);
  assert.strictEqual(fake.calls.length, 3);
  assert.match(fake.calls[2].sql, /pg_advisory_unlock/);
  assert.match(fake.releasedWith.message, /synthetic unlock failure/);
});

test('a poll query failure still attempts unlock and returns the client only after confirmed unlock', async () => {
  const failure = new Error('synthetic poll query failure');
  const fake = pollCycleDeps({ queryError: failure });

  await assert.rejects(runPollCycle(fake.deps), /synthetic poll query failure/);
  assert.strictEqual(fake.calls.length, 3);
  assert.match(fake.calls[2].sql, /pg_advisory_unlock/);
  assert.strictEqual(fake.releasedWith, undefined);
});

test('missing encryption key does not check out a database client', async () => {
  let connections = 0;
  const result = await runPollCycle({
    pool: { connect: async () => { connections += 1; } },
    encryptionKey: null,
  });

  assert.deepStrictEqual(result, { skipped: 'no_encryption_key' });
  assert.strictEqual(connections, 0);
});

test('missing worker capability never falls back to the ordinary application pool', async () => {
  let connections = 0;
  const result = await runPollCycle({
    pool: { options: { max: 10 }, connect: async () => { connections += 1; } },
    encryptionKey: 'synthetic-key',
  });
  assert.deepStrictEqual(result, { skipped: 'no_worker_database' });
  assert.strictEqual(connections, 0);
});

test('the worker and ordinary application pool must be separate', async () => {
  const pool = { options: { max: 1 }, connect: async () => { throw new Error('must not connect'); } };
  assert.deepStrictEqual(await runPollCycle({ pool, workerPool: pool, encryptionKey: 'synthetic-key' }), {
    skipped: 'worker_database_pool_not_separate',
  });
});

test('separate one-connection pools can enumerate and perform per-user work in series', async () => {
  const fake = pollCycleDeps({ connections: [{ ...CONNECTION }] });
  fake.deps.pool = { options: { max: 1 } };
  let perUserCalls = 0;
  fake.deps.withUserClient = async (userId, work) => {
    assert.strictEqual(userId, CONNECTION.profile_id); perUserCalls++;
    return work({ query: async () => ({ rows: [] }) });
  };
  const result = await runPollCycle(fake.deps);
  assert.strictEqual(result.polled, 1);
  assert.strictEqual(perUserCalls, 2);
  assert.deepStrictEqual(fake.calls[1].params, ['synthetic-key', 100]);
  assert.strictEqual(fake.releasedWith, undefined);
});

test('credential failures never contact providers, expose passwords, or advance last_poll_at', async () => {
  const connection = { ...CONNECTION, app_password: null, credential_error: true };
  const fake = pollCycleDeps({ connections: [connection] });
  fake.deps.fetchMessages = async () => { throw new Error('must not contact provider'); };
  const updates = [];
  fake.deps.withUserClient = async (userId, work) => work({ query: async (sql, args) => { updates.push({ sql, args, userId }); return { rows: [] }; } });
  const result = await runPollCycle(fake.deps);
  assert.strictEqual(result.results[0].reason, 'credential_unavailable');
  assert.ok(!('app_password' in result.results[0]));
  assert.strictEqual(updates.length, 1);
  assert.strictEqual(updates[0].userId, CONNECTION.profile_id);
  assert.ok(!updates[0].sql.includes('last_poll_at ='));
  assert.strictEqual(connection.app_password, null);
});

test('cycle deadline defers unprocessed connections and clears all batch credentials', async () => {
  const connections = [{ ...CONNECTION }, { ...CONNECTION, id: 'c2' }, { ...CONNECTION, id: 'c3' }];
  const fake = pollCycleDeps({ connections });
  let now = 1000;
  let providerCalls = 0;
  fake.deps.now = () => now;
  fake.deps.maxCycleDurationMs = 10;
  fake.deps.fetchMessages = async () => { providerCalls++; now += 10; return { ok: true, messages: [] }; };
  const result = await runPollCycle(fake.deps);
  assert.strictEqual(result.polled, 1);
  assert.strictEqual(result.deferredCount, 2);
  assert.strictEqual(providerCalls, 1);
  assert.ok(connections.every(connection => connection.app_password === null));
  assert.match(fake.calls.at(-2).sql, /imap_worker.defer_connections/);
  assert.deepStrictEqual(fake.calls.at(-2).params, ['c1']);
  assert.match(fake.calls.at(-1).sql, /pg_advisory_unlock/);
});

test('a repeated first-row status failure does not starve later rows in a short batch', async () => {
  const connections = [{ ...CONNECTION }, { ...CONNECTION, id: 'c2', email: 'second@example.test' }, { ...CONNECTION, id: 'c3', email: 'third@example.test' }];
  const fake = pollCycleDeps({ connections });
  const originalQuery = fake.client.query.bind(fake.client);
  fake.client.query = async (sql, params) => sql.includes('FROM imap_worker.next_connections')
    ? { rows: connections.map(connection => ({ ...connection })) }
    : originalQuery(sql, params);
  const fetches = [];
  const lastPollAt = new Map(connections.map(connection => [connection.id, 'retained-window']));
  fake.deps.fetchMessages = async options => { fetches.push(options.email); return { ok: true, messages: [] }; };
  fake.deps.withUserClient = async (userId, work) => work({ query: async (sql, args) => {
    if (sql.startsWith('UPDATE imap_connections')) {
      if (args[0] === 'c1') throw new Error('SENSITIVE_DATABASE_ERROR');
      lastPollAt.set(args[0], 'advanced');
    }
    return { rows: [] };
  } });
  for (let cycle = 0; cycle < 2; cycle++) {
    const result = await runPollCycle(fake.deps);
    assert.strictEqual(result.polled, 3);
    assert.strictEqual(result.results[0].ok, false);
    assert.strictEqual(result.results[0].reason, 'status_write_failed');
    assert.strictEqual(result.results[1].ok, true);
    assert.strictEqual(result.results[2].ok, true);
    assert.ok(!JSON.stringify(result).includes('SENSITIVE_DATABASE_ERROR'));
    assert.strictEqual(lastPollAt.get('c1'), 'retained-window');
    assert.strictEqual(lastPollAt.get('c2'), 'advanced');
    assert.strictEqual(lastPollAt.get('c3'), 'advanced');
  }
  assert.strictEqual(fetches.length, 6);
  assert.strictEqual(fetches.filter(email => email === 'third@example.test').length, 2);
});

test('status failures still count as attempted rows for deadline deferral', async () => {
  const fake = pollCycleDeps({ connections: [{ ...CONNECTION }, { ...CONNECTION, id: 'c2' }] });
  let now = 0;
  fake.deps.now = () => now;
  fake.deps.maxCycleDurationMs = 10;
  fake.deps.withUserClient = async (_userId, work) => work({ query: async sql => {
    if (sql.startsWith('UPDATE imap_connections')) { now = 10; throw new Error('sensitive status failure'); }
    return { rows: [] };
  } });
  const result = await runPollCycle(fake.deps);
  assert.strictEqual(result.polled, 1);
  assert.strictEqual(result.deferredCount, 1);
  assert.strictEqual(result.results[0].reason, 'status_write_failed');
  assert.deepStrictEqual(fake.calls.at(-2).params, ['c1']);
  assert.match(fake.calls.at(-1).sql, /pg_advisory_unlock/);
});

test('cycle budget cannot be disabled or extended beyond five minutes', async () => {
  for (const duration of [0, -1, 300001, Infinity, '300000']) {
    const fake = pollCycleDeps();
    fake.deps.maxCycleDurationMs = duration;
    await assert.rejects(runPollCycle(fake.deps), /cycle_budget_invalid/);
    assert.strictEqual(fake.calls.length, 0);
  }
});

test('interval warns for missing worker capability and stays quiet when another poll owns the lock', async () => {
  const originalSetInterval = global.setInterval;
  const originalClearInterval = global.clearInterval;
  let scheduledTick;
  global.setInterval = (callback) => {
    scheduledTick = callback;
    return { unref() {} };
  };
  global.clearInterval = () => {};

  try {
    const warnings = [];
    const errors = [];
    const underSizedStop = require('../src/imap_poller').startImapPoller({
      pool: { options: { max: 1 }, connect: async () => { throw new Error('must not connect'); } },
      encryptionKey: 'synthetic-key',
    }, {
      intervalMinutes: 1,
      logger: { warn: (message) => warnings.push(message), error: (message) => errors.push(message) },
    });
    await scheduledTick();
    underSizedStop();

    assert.deepStrictEqual(warnings, [
      '[imap-poller] skipped: configure a separate IMAP worker database capability',
    ]);
    assert.deepStrictEqual(errors, []);

    warnings.length = 0;
    const busy = pollCycleDeps({ lock: false });
    const busyStop = require('../src/imap_poller').startImapPoller(busy.deps, {
      intervalMinutes: 1,
      logger: { warn: (message) => warnings.push(message), error: (message) => errors.push(message) },
    });
    await scheduledTick();
    busyStop();
    assert.deepStrictEqual(warnings, []);
  } finally {
    global.setInterval = originalSetInterval;
    global.clearInterval = originalClearInterval;
  }
});

test('a parsed bank mail is imported through the shared path', async () => {
  const { imported, deps } = fakeDeps({
    messages: [{ uid: 1, sender: 'alerts@bank.com', subject: 'Alert', body: 'You spent Rs.450' }],
  });
  const result = await pollConnection(CONNECTION, deps);

  assert.strictEqual(result.imported, 1);
  assert.strictEqual(imported.length, 1);
  assert.strictEqual(imported[0].source, 'email');
  assert.strictEqual(imported[0].patternIssuerId, 'i1');
});

test('mail that is not a transaction is skipped, not reported as an error', async () => {
  // Most mail in an inbox isn't a bank alert. Treating that as failure
  // would make every poll look broken.
  const { imported, deps } = fakeDeps({
    messages: [{ uid: 1, sender: 'friend@example.com', subject: 'Hi', body: 'lunch tomorrow?' }],
  });
  const result = await pollConnection(CONNECTION, deps);

  assert.strictEqual(result.ok, true);
  assert.strictEqual(result.unparsed, 1);
  assert.strictEqual(result.imported, 0);
  assert.strictEqual(imported.length, 0);
});

test('every import carries a source key, so an overlapping poll cannot double-count', async () => {
  // SINCE has day granularity, so consecutive polls always re-see part of a
  // day. The source key is the only thing preventing that from doubling
  // every transaction.
  const { imported, deps } = fakeDeps({
    messages: [{ uid: 1, sender: 'alerts@bank.com', subject: 'Alert', body: 'You spent Rs.450' }],
  });
  await pollConnection(CONNECTION, deps);
  assert.ok(imported[0].sourceKey, 'a source key is required for re-poll safety');
  assert.ok(imported[0].sourceKey.includes('You spent Rs.450'));
});

test('a message whose card cannot be resolved counts as needing review, not as imported', async () => {
  const { deps } = fakeDeps({
    messages: [{ uid: 1, sender: 'alerts@bank.com', subject: 'Alert', body: 'You spent Rs.450' }],
    onImport: () => ({ status: 200, needsReview: true, needsReviewItemId: 'n1' }),
  });
  const result = await pollConnection(CONNECTION, deps);
  assert.strictEqual(result.needsReview, 1);
  assert.strictEqual(result.imported, 0);
});

test('an already-known message counts as skipped', async () => {
  const { deps } = fakeDeps({
    messages: [{ uid: 1, sender: 'alerts@bank.com', subject: 'Alert', body: 'You spent Rs.450' }],
    onImport: () => ({ status: 200, duplicate: true }),
  });
  const result = await pollConnection(CONNECTION, deps);
  assert.strictEqual(result.skipped, 1);
});

test('a first-ever poll looks back far enough to find something', async () => {
  const { imported, deps } = fakeDeps({ messages: [] });
  await pollConnection({ ...CONNECTION, last_poll_at: null }, deps);

  const since = imported.fetchOpts.since;
  const daysBack = Math.round((Date.now() - since.getTime()) / 86400000);
  assert.strictEqual(daysBack, INITIAL_LOOKBACK_DAYS);
});

test('a later poll resumes from the last successful one', async () => {
  const { imported, deps } = fakeDeps({ messages: [] });
  const last = new Date('2026-08-20T00:00:00Z');
  await pollConnection({ ...CONNECTION, last_poll_at: last.toISOString() }, deps);
  assert.strictEqual(imported.fetchOpts.since.getTime(), last.getTime());
});

test('the sender filter is passed through so only bank mail crosses the wire', async () => {
  // A privacy property, not an optimisation: the poller should never pull
  // personal correspondence into this process at all.
  const { imported, deps } = fakeDeps({ messages: [] });
  await pollConnection(CONNECTION, deps);
  assert.strictEqual(imported.fetchOpts.senderFilter, 'alerts@bank.com');
});

test('a connection error is reported, not thrown', async () => {
  const { deps } = fakeDeps({ messages: [] });
  deps.fetchMessages = async () => ({ ok: false, reason: 'authentication_failed' });
  const result = await pollConnection(CONNECTION, deps);
  assert.strictEqual(result.ok, false);
  assert.strictEqual(result.reason, 'authentication_failed');
});

test('IMAP quoting neutralises characters that would end the argument early', () => {
  // An app password containing a quote would otherwise terminate the
  // LOGIN argument and turn the rest of the value into commands.
  assert.strictEqual(quoted('pa"ss'), '"pa\\"ss"');
  assert.strictEqual(quoted('back\\slash'), '"back\\\\slash"');
  assert.throws(() => quoted('bank@example.com\r\nNOOP'), /invalid_imap_argument/);
});

test('IMAP dates are formatted the way the protocol requires', () => {
  assert.strictEqual(imapDate(new Date(2026, 7, 25)), '25-Aug-2026');
});

test('a FETCH response is parsed into sender, subject and body', () => {
  const raw = [
    '* 1 FETCH (UID 42 BODY[] {120}',
    'From: alerts@bank.com',
    'Subject: Transaction alert',
    '',
    'You spent Rs.450 at Swiggy.',
    ')',
  ].join('\r\n');

  const messages = parseFetchResponse(raw);
  assert.strictEqual(messages.length, 1);
  assert.strictEqual(messages[0].uid, 42);
  assert.strictEqual(messages[0].sender, 'alerts@bank.com');
  assert.strictEqual(messages[0].subject, 'Transaction alert');
  assert.match(messages[0].body, /You spent Rs\.450 at Swiggy\./);
});

test('a folded header is unfolded before matching', () => {
  // Long headers wrap onto continuation lines; a naive line-based match
  // would truncate the subject at the fold.
  const raw = [
    '* 1 FETCH (UID 7 BODY[] {90}',
    'From: alerts@bank.com',
    'Subject: A very long transaction',
    '  alert subject line',
    '',
    'You spent Rs.100',
    ')',
  ].join('\r\n');

  const messages = parseFetchResponse(raw);
  assert.strictEqual(messages[0].subject, 'A very long transaction alert subject line');
});
