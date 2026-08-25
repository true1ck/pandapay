const test = require('node:test');
const assert = require('node:assert');
const { pollConnection, INITIAL_LOOKBACK_DAYS } = require('../src/imap_poller');
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
  deps.fetchMessages = async () => ({ ok: false, reason: 'imap_error: NO invalid credentials' });
  const result = await pollConnection(CONNECTION, deps);
  assert.strictEqual(result.ok, false);
  assert.match(result.reason, /invalid credentials/);
});

test('IMAP quoting neutralises characters that would end the argument early', () => {
  // An app password containing a quote would otherwise terminate the
  // LOGIN argument and turn the rest of the value into commands.
  assert.strictEqual(quoted('pa"ss'), '"pa\\"ss"');
  assert.strictEqual(quoted('back\\slash'), '"back\\\\slash"');
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
