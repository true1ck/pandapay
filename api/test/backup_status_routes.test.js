'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  READ_BACKUP_STATUS_SQL, READ_CONFLICTS_SQL, createBackupStatusHandlers,
  sanitizeStatus, unavailableStatus,
} = require('../src/backup_status_routes');

const PROFILE = '10000000-0000-4000-8000-000000000001';
const proof = () => ({
  latestBackup: { ran_at: '2026-10-24T01:00:00.000Z', status: 'success', size_bytes: '12345', location: '/private/recovery/secret' },
  latestRestoreDrill: { ran_at: '2026-10-24T02:00:00.000Z', restored_ok: true, notes: 'private notes' },
  backupAvailability: 'available',
  backupVerification: { protocol: 'paired_v5', databaseRestoreVerified: true, applicationCheck: 'not_run',
    upgradeCheck: 'passed', storage: 'local', publishedAt: '2026-10-24T02:01:00.000Z', manifest: 'private' },
  error_text: 'private provider diagnostic',
});
const response = () => ({ statusCode: 200, body: null,
  status(code) { this.statusCode = code; return this; }, json(value) { this.body = value; return this; } });
const request = { userId: PROFILE, query: { profileId: 'foreign' }, body: { profileId: 'foreign' } };

test('projection retains the existing app fields and removes operational metadata', () => {
  const result = sanitizeStatus(proof());
  assert.deepEqual(result.latestBackup, { ran_at: '2026-10-24T01:00:00.000Z', status: 'success', size_bytes: 12345 });
  assert.deepEqual(result.latestRestoreDrill, { ran_at: '2026-10-24T02:00:00.000Z', restored_ok: true });
  assert.equal(result.backupVerification.applicationCheck, 'not_run');
  assert.equal(result.backupVerification.storage, 'local');
  assert.doesNotMatch(JSON.stringify(result), /private|location|error_text|notes|manifest/);
});

test('legacy success, missing proof and unrecognized proof cannot appear as verified backup', () => {
  for (const value of [null, {}, { latestBackup: { status: 'success' } },
    { ...proof(), backupVerification: { ...proof().backupVerification, protocol: 'legacy' } },
    { ...proof(), latestRestoreDrill: { ran_at: '2026-10-24T02:00:00Z', restored_ok: false } },
    { ...proof(), latestBackup: { ...proof().latestBackup, size_bytes: -1 } },
    { ...proof(), backupAvailability: 'invented' }]) {
    assert.deepEqual(sanitizeStatus(value), unavailableStatus());
  }
});

test('stale evidence never presents a current success', () => {
  const result = sanitizeStatus({ ...proof(), backupAvailability: 'stale' });
  assert.equal(result.latestBackup.status, 'stale');
  assert.equal(result.backupStatusReason, 'verified_status_stale');
});

test('GET binds only the verified caller and reads explicitly selected caller conflict fields', async () => {
  const calls = [];
  const conflict = { id: 'conflict', entity: 'transactions', field: 'amount', strategy: 'last_write_wins',
    user_acknowledged: false, created_at: '2026-10-24T00:00:00Z', local_value: 10, server_value: 11, chosen_value: 11,
    profile_id: PROFILE, device_id: 'private device', diagnostics: 'private notes' };
  const handlers = createBackupStatusHandlers({ withUserClient: async (id, callback) => {
    assert.equal(id, PROFILE);
    return callback({ query: async (sql, params) => {
      calls.push([sql, params]);
      return { rows: sql === READ_BACKUP_STATUS_SQL ? [{ status: proof() }] : [conflict] };
    } });
  } });
  const res = response();
  await handlers.getBackupStatus(request, res);
  assert.equal(res.statusCode, 200);
  assert.equal(res.body.conflicts[0].local_value, 10);
  assert.doesNotMatch(JSON.stringify(res.body), /profile_id|device_id|diagnostics|private/);
  assert.deepEqual(calls, [[READ_BACKUP_STATUS_SQL, [PROFILE]], [READ_CONFLICTS_SQL, [PROFILE]]]);
  assert.match(READ_CONFLICTS_SQL, /WHERE profile_id = \$1/);
  assert.match(READ_CONFLICTS_SQL, /LIMIT 50/);
  assert.doesNotMatch(READ_CONFLICTS_SQL, /SELECT\s+\*/i);
});

test('GET and POST reject missing or malformed identity without a database query', async () => {
  const handlers = createBackupStatusHandlers({ withUserClient() { assert.fail('must not query'); } });
  for (const handler of Object.values(handlers)) {
    for (const userId of [undefined, null, '', 'not-uuid']) {
      const res = response();
      await handler({ userId }, res);
      assert.equal(res.statusCode, 401);
      assert.deepEqual(res.body, { error: 'session_invalid' });
    }
  }
});

test('database/missing migration failures are explicit unavailable with no exception leak', async () => {
  const logs = [];
  const handlers = createBackupStatusHandlers({
    withUserClient: async () => { throw new Error('postgres://secret SQL /backup/path token'); },
    logger: { error(...args) { logs.push(args); } },
  });
  const get = response();
  await handlers.getBackupStatus(request, get);
  assert.equal(get.statusCode, 503);
  assert.deepEqual(get.body, { ...unavailableStatus('status_service_unavailable'), conflicts: [], conflictAvailability: 'unavailable' });
  const post = response();
  await handlers.postBackupRuns(request, post);
  assert.equal(post.statusCode, 409);
  assert.equal(post.body.lastSuccessfulBackup, null);
  assert.equal(post.body.backupAvailability, 'unavailable');
  assert.deepEqual(logs, [['Backup status projection unavailable'], ['Backup status projection unavailable']]);
  assert.doesNotMatch(JSON.stringify([get.body, post.body, logs]), /postgres|secret|token|SQL/);
});

test('POST always returns the existing 409 and never inserts a backup record', async () => {
  for (const status of [proof(), { ...proof(), backupAvailability: 'stale' }, unavailableStatus()]) {
    const calls = [];
    const handlers = createBackupStatusHandlers({ withUserClient: async (_id, cb) => cb({
      query: async (sql) => { calls.push(sql); return { rows: [{ status }] }; },
    }) });
    const res = response();
    await handlers.postBackupRuns(request, res);
    assert.equal(res.statusCode, 409);
    assert.equal(res.body.error, 'manual_backup_not_supported');
    assert.equal(Boolean(res.body.lastSuccessfulBackup), status.backupAvailability === 'available');
    assert.deepEqual(calls, [READ_BACKUP_STATUS_SQL]);
  }
});
