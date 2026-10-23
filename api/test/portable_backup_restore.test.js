'use strict';

const assert = require('node:assert/strict');
const test = require('node:test');
const {
  PORTABLE_SECTIONS,
  canonicalJson,
} = require('../src/portable_backup');
const {
  PortableRestoreError,
  assertNoConflicts,
  commitRestore,
  createRestoreSession,
  insertRecordQuery,
  parseSectionNdjson,
  validateManifest,
} = require('../src/portable_backup/restore');
const { registerPortableBackupRestoreRoutes } = require('../src/portable_backup/restore_routes');

const PROFILE_ID = '11111111-1111-4111-8111-111111111111';
const BACKUP_ID = '22222222-2222-4222-8222-222222222222';

function sectionManifest() {
  const sections = PORTABLE_SECTIONS.map((section) => ({ name: section.name, path: `sections/${section.name}.ndjson`, record_count: 0, byte_length: 0, required: true, sha256: 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855' }));
  return {
    format_version: 1,
    schema_version: 'portable-v1',
    backup_id: BACKUP_ID,
    account_binding: PROFILE_ID,
    server_revision: '42',
    snapshot_at: '2026-10-23T00:00:00.000Z',
    complete: true,
    sections,
  };
}

test('section parser accepts transport envelopes and hashes canonical record plaintext', () => {
  const line = JSON.stringify({
    type: 'record',
    section: 'transactions',
    record: { profile_id: PROFILE_ID, id: '33333333-3333-4333-8333-333333333333', amount_inr: 12.5, push_token: 'discard' },
  });
  const parsed = parseSectionNdjson(`${line}\n`, 'transactions', PROFILE_ID);
  const expectedRecord = { amount_inr: '12.5', id: '33333333-3333-4333-8333-333333333333', profile_id: PROFILE_ID };
  assert.deepEqual(parsed.records[0].record, expectedRecord);
  assert.equal(parsed.bytes, Buffer.byteLength(`${canonicalJson(expectedRecord)}\n`));
  assert.equal(parsed.count, 1);
});

test('section parser rejects duplicate IDs and cross-account records', () => {
  const row = { id: '33333333-3333-4333-8333-333333333333', profile_id: PROFILE_ID };
  assert.throws(() => parseSectionNdjson(`${JSON.stringify(row)}\n${JSON.stringify(row)}\n`, 'transactions', PROFILE_ID), (error) => error.code === 'duplicate_record_id');
  assert.throws(() => parseSectionNdjson(`${JSON.stringify({ ...row, profile_id: BACKUP_ID })}\n`, 'transactions', PROFILE_ID), (error) => error.code === 'record_ownership_mismatch');
});

test('settings section uses profile_id as its stable key', () => {
  const parsed = parseSectionNdjson(`${JSON.stringify({ profile_id: PROFILE_ID, settings: { theme: 'dark' } })}\n`, 'settings', PROFILE_ID);
  assert.equal(parsed.records[0].stableId, PROFILE_ID);
});

test('manifest validation requires complete same-account v1 metadata and every server section', () => {
  const manifest = sectionManifest();
  assert.deepEqual(validateManifest({ manifest, backupId: BACKUP_ID, profileId: PROFILE_ID }), {
    formatVersion: 1,
    schemaVersion: 'portable-v1',
    snapshotRevision: '42',
    snapshotAt: '2026-10-23T00:00:00.000Z',
  });
  assert.throws(() => validateManifest({ manifest: { ...manifest, account_binding: BACKUP_ID }, backupId: BACKUP_ID, profileId: PROFILE_ID }), (error) => error.code === 'account_mismatch');
  assert.throws(() => validateManifest({ manifest: { ...manifest, complete: false }, backupId: BACKUP_ID, profileId: PROFILE_ID }), (error) => error.code === 'backup_incomplete');
});

test('insert query uses static table names and parameterized record values', () => {
  const query = insertRecordQuery('transactions', {
    id: '33333333-3333-4333-8333-333333333333',
    profile_id: PROFILE_ID,
    merchant_name: "O'Reilly; DROP TABLE transactions;",
  });
  assert.match(query.text, /^INSERT INTO public\.transactions \(/);
  assert.doesNotMatch(query.text, /O'Reilly|DROP TABLE/);
  assert.deepEqual(query.values, ['33333333-3333-4333-8333-333333333333', "O'Reilly; DROP TABLE transactions;", PROFILE_ID]);
});

test('create session is idempotent for the same profile, backup, and key', async () => {
  const calls = [];
  const client = {
    async query(query) {
      calls.push(query);
      if (query === 'BEGIN' || query === 'COMMIT' || query === 'ROLLBACK') return { rows: [] };
      if (typeof query === 'string' && query.includes('set_config')) return { rows: [] };
      if ((typeof query === 'object' && query.text.includes('FROM portable_restore_sessions'))
        || (typeof query === 'string' && query.includes('FROM portable_restore_sessions'))) {
        return { rows: [{ id: '44444444-4444-4444-8444-444444444444', profile_id: PROFILE_ID, backup_id: BACKUP_ID, idempotency_key: 'retry-1', state: 'staging', expires_at: '2026-10-24T00:00:00.000Z' }] };
      }
      throw new Error(`unexpected query: ${typeof query === 'string' ? query : query.text}`);
    },
    release() { this.released = true; },
  };
  const pool = { async connect() { return client; } };
  const result = await createRestoreSession({ pool, profileId: PROFILE_ID, input: { backup_id: BACKUP_ID, idempotency_key: 'retry-1', manifest: sectionManifest() } });
  assert.equal(result.resumed, true);
  assert.equal(result.state, 'staging');
  assert.equal(client.released, true);
  assert.equal(calls.filter((query) => query === 'COMMIT').length, 1);
});

test('restore route registration exposes the six authenticated endpoints', () => {
  const routes = [];
  const app = {};
  for (const method of ['post', 'put', 'get', 'delete']) app[method] = (path, auth, handler) => routes.push({ method, path, auth, handler });
  const requireAuth = () => {};
  registerPortableBackupRestoreRoutes(app, { requireAuth, pool: { connect() {} } });
  assert.equal(routes.length, 6);
  assert.ok(routes.every((route) => route.auth === requireAuth));
  assert.ok(routes.some((route) => route.path.endsWith('/preview')));
  assert.ok(routes.some((route) => route.path.endsWith('/commit')));
  assert.ok(routes.some((route) => route.method === 'delete'));
});

test('restore errors carry stable codes and HTTP status for conflicts', () => {
  const error = new PortableRestoreError('restore_conflict', 409, { conflicts: [] });
  assert.equal(error.code, 'restore_conflict');
  assert.equal(error.status, 409);
  assert.deepEqual(error.details, { conflicts: [] });
});

test('commit conflict plan is blocking and a committed ledger retry is idempotent', async () => {
  assert.throws(() => assertNoConflicts({ missingSections: [], conflicts: [{ section: 'transactions', id: 'tx-1' }] }), (error) => error.code === 'restore_conflict');
  const client = {
    async query(query) {
      if (query === 'BEGIN' || query === 'COMMIT' || query === 'ROLLBACK') return { rows: [] };
      if (typeof query === 'string' && query.includes('set_config')) return { rows: [] };
      if (typeof query === 'string' && query.includes('FROM portable_restore_sessions')) return {
        rows: [{ id: '44444444-4444-4444-8444-444444444444', backup_id: BACKUP_ID, state: 'committed', expires_at: '2026-10-24T00:00:00.000Z' }],
      };
      if (typeof query === 'string' && query.includes('FROM portable_backup_ledger')) return {
        rows: [{ result: { inserted: 2 }, committed_at: '2026-10-23T00:00:00.000Z' }],
      };
      throw new Error(`unexpected query: ${typeof query === 'string' ? query : query.text}`);
    },
    release() {},
  };
  const result = await commitRestore({
    pool: { async connect() { return client; } },
    profileId: PROFILE_ID,
    sessionId: '44444444-4444-4444-8444-444444444444',
    previewRevision: '42',
  });
  assert.equal(result.idempotent, true);
  assert.deepEqual(result.result, { inserted: 2 });
});
