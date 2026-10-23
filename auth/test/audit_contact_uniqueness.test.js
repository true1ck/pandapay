'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  runAudit,
  boundedTimeout,
  CONTACT_METRICS_SQL,
  auditExitCode,
} = require('../scripts/auditContactUniqueness');

const USER_CONTACT_MARKER = 'contact-must-never-appear-in-output@example.invalid';
const HASH_MARKER = 'a'.repeat(64);

test('deployment audit gate rejects active conflicts and undefined lifecycle without requiring a backfill yet', () => {
  const report = { gates: { lifecycle_defined: true, active_uniqueness_clear: false, phone_hashes_complete: false } };
  assert.equal(auditExitCode(report), 0);
  assert.equal(auditExitCode(report, true), 2);
  report.gates.active_uniqueness_clear = true;
  assert.equal(auditExitCode(report, true), 0);
  report.gates.lifecycle_defined = false;
  assert.equal(auditExitCode(report), 2);
});

function fakePool({ lifecycleNull = 0, readOnly = 'on', isolation = 'repeatable read', failOn = null } = {}) {
  const queries = [];
  let released = null;
  const client = {
    async query(sql, params = []) {
      const statement = String(sql).trim();
      queries.push({ statement, params });
      if (statement === 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY') return { rows: [] };
      if (statement.startsWith('SET LOCAL')) return { rows: [] };
      if (statement === 'SHOW transaction_read_only') {
        return { rows: [{ transaction_read_only: readOnly }] };
      }
      if (statement === 'SHOW transaction_isolation') {
        return { rows: [{ transaction_isolation: isolation }] };
      }
      if (statement.startsWith('ROLLBACK')) return { rows: [] };
      if (statement.includes('COUNT(*)::bigint AS total_users')) {
        if (failOn === 'metrics') throw Object.assign(new Error(USER_CONTACT_MARKER), { code: 'XX000' });
        assert.match(statement, /email_malformed_rows/);
        assert.match(statement, /phone_missing_hash_rows/);
        return { rows: [{
          total_users: '8', active_users: '5', deleted_users: '2', null_deleted_users: String(lifecycleNull),
          email_null_rows: '1', email_blank_rows: '1', email_malformed_rows: '1',
          phone_null_rows: '2', phone_blank_storage_rows: '0', phone_present_rows: '6', phone_missing_hash_rows: '1',
          phone_malformed_hash_rows: '0',
        }] };
      }
      if (statement.includes('duplicate_groups')) {
        if (failOn === 'duplicates') throw Object.assign(new Error(USER_CONTACT_MARKER), { code: 'XX000' });
        assert.doesNotMatch(statement, /SELECT .*identity_key.*FROM/i);
        const activeOnly = params[0] === true;
        return { rows: [{
          duplicate_groups: activeOnly ? '1' : '2',
          duplicate_rows: activeOnly ? '2' : '5',
          extra_rows: activeOnly ? '1' : '3',
        }] };
      }
      throw new Error(`Unexpected query in fake pool: ${statement}`);
    },
    release(discard) { released = discard; },
  };
  return {
    pool: { async connect() { return client; } },
    queries,
    get released() { return released; },
  };
}

test('audit is read-only, bounded, and returns only aggregate counts', async () => {
  const fake = fakePool();
  const report = await runAudit(fake.pool, { statementTimeoutMs: 7000 });
  assert.deepEqual(report.lifecycle, { total: 8, active: 5, deleted: 2, null_deleted: 0 });
  assert.deepEqual(report.contact_quality.email, { null_rows: 1, blank_rows: 1, malformed_rows: 1 });
  assert.deepEqual(report.contact_quality.phone, {
    null_rows: 2,
    blank_storage_rows: 0,
    present_rows: 6,
    missing_hash_rows: 1,
    malformed_hash_rows: 0,
  });
  assert.deepEqual(report.duplicates.email_lower.active_only, {
    duplicate_groups: 1, duplicate_rows: 2, extra_rows: 1,
  });
  assert.deepEqual(report.duplicates.phone_lookup_hash.all_rows, {
    duplicate_groups: 2, duplicate_rows: 5, extra_rows: 3,
  });
  assert.equal(report.gates.lifecycle_defined, true);
  assert.equal(report.gates.active_uniqueness_clear, false);

  const emitted = JSON.stringify(report);
  assert.equal(emitted.includes(USER_CONTACT_MARKER), false);
  assert.equal(emitted.includes(HASH_MARKER), false);
  assert.deepEqual(fake.queries[0], {
    statement: 'BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY', params: [],
  });
  assert.ok(fake.queries.some(query => query.statement === "SET LOCAL statement_timeout = '7000ms'"));
  assert.ok(fake.queries.some(query => query.statement === 'SHOW transaction_read_only'));
  assert.ok(fake.queries.some(query => query.statement === 'SHOW transaction_isolation'));
  assert.ok(fake.queries.some(query => query.statement === 'ROLLBACK'));
  assert.ok(fake.queries.filter(query => query.params.length).every(query =>
    query.params.length === 1 && typeof query.params[0] === 'boolean'));
  assert.equal(fake.released, false);
  assert.match(CONTACT_METRICS_SQL, /email_malformed_rows/);
});

test('null lifecycle values are surfaced and hold the lifecycle gate', async () => {
  const report = await runAudit(fakePool({ lifecycleNull: 1 }).pool);
  assert.equal(report.lifecycle.null_deleted, 1);
  assert.equal(report.gates.lifecycle_defined, false);
});

test('audit rejects a transaction that is not read-only and releases it', async () => {
  const fake = fakePool({ readOnly: 'off' });
  await assert.rejects(runAudit(fake.pool), /not read-only/);
  assert.ok(fake.queries.some(query => query.statement === 'ROLLBACK'));
  assert.equal(fake.released, false);
});

test('audit rejects a transaction without repeatable-read isolation', async () => {
  const fake = fakePool({ isolation: 'read committed' });
  await assert.rejects(runAudit(fake.pool), /repeatable-read isolation/);
  assert.ok(fake.queries.some(query => query.statement === 'ROLLBACK'));
  assert.equal(fake.released, false);
});

test('query errors are rethrown without serializing returned contact data', async () => {
  const fake = fakePool({ failOn: 'metrics' });
  await assert.rejects(runAudit(fake.pool), error => {
    assert.equal(error.code, 'XX000');
    assert.equal(error.message, USER_CONTACT_MARKER);
    return true;
  });
  assert.ok(fake.queries.some(query => query.statement === 'ROLLBACK'));
});

test('timeout values are validated and bounded', () => {
  assert.equal(boundedTimeout(undefined, 15000, 'statement', 300000), 15000);
  assert.equal(boundedTimeout('5000', 15000, 'connect', 30000), 5000);
  assert.throws(() => boundedTimeout(999, 15000, 'statement', 300000), /integer from 1000/);
  assert.throws(() => boundedTimeout(30001, 5000, 'connect', 30000), /integer from 1000/);
});
