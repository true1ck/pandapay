'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const fs = require('node:fs'), os = require('node:os'), path = require('node:path'), crypto = require('node:crypto');
const { inputs, compareLedger, reviewRestoredPrivileges } = require('../scripts/review_restored_privileges');
const { QUERIES, loadPolicy } = require('../scripts/audit_runtime_privileges');
function environment(dir) {
  return { RESTORE_PRODUCT_TARGET_URL: 'postgresql://fixture@127.0.0.1/pprestore_0123456789abcdef0123_p',
    RESTORE_AUTH_TARGET_URL: 'postgresql://fixture@127.0.0.1/pprestore_0123456789abcdef0123_a',
    RESTORE_PRODUCT_EXACT_COMPARISON: 'passed', RESTORE_AUTH_EXACT_COMPARISON: 'passed',
    RESTORE_PRODUCT_RUNTIME_ROLE: 'app_user', RESTORE_AUTH_RUNTIME_ROLE: 'auth_runtime',
    RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION: 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER',
    RESTORE_PRIVILEGE_REVIEW_FILE: path.join(dir, 'review.json.age'), RESTORE_DIAGNOSTIC_RECIPIENTS_FILE: path.join(dir, 'public-recipients.txt'),
    PATH: process.env.PATH, HOME: process.env.HOME, DATABASE_URL: 'postgresql://never-use-private-live-url' };
}
test('requires both exact-copy attestations, generated loopback targets, explicit roles and encrypted output', () => {
  const env = environment(os.tmpdir()); assert.deepEqual(inputs(env), { productRole: 'app_user', authRole: 'auth_runtime' });
  for (const mutate of [
    value => value.RESTORE_PRODUCT_TARGET_URL = 'postgresql://fixture@host.invalid/pprestore_0123456789abcdef0123_p',
    value => value.RESTORE_AUTH_TARGET_URL = 'postgresql://fixture@127.0.0.1/live',
    value => value.RESTORE_AUTH_TARGET_URL = 'postgresql://fixture@127.0.0.1/pprestore_abcdef01234567890123_a',
    value => value.RESTORE_AUTH_TARGET_URL += '?host=remote.invalid',
    value => value.RESTORE_AUTH_EXACT_COMPARISON = 'not_run',
    value => value.RESTORE_PRODUCT_EXACT_COMPARISON = 'not_run',
    value => delete value.RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION,
    value => value.RESTORE_AUTH_RUNTIME_ROLE = 'role;select', value => value.RESTORE_PRODUCT_RUNTIME_ROLE = '',
    value => value.RESTORE_PRIVILEGE_REVIEW_FILE = '/private/tmp/review.json',
    value => value.RESTORE_DIAGNOSTIC_RECIPIENTS_FILE = 'relative.txt',
  ]) { const invalid = { ...env }; mutate(invalid); assert.throws(() => inputs(invalid)); }
});
test('migration comparison retains unknown history, mismatches, missing checksums and duplicates without adopting them', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-ledger-review-'));
  try {
    const file = path.join(dir, '0001_fixture.sql'); fs.writeFileSync(file, 'select 1;');
    const checksum = crypto.createHash('sha256').update('select 1;').digest('hex');
    const verified = compareLedger([{ filename: '0001_fixture.sql', checksum }], [['0001_fixture.sql', file]]);
    assert.equal(verified.history_known, true);
    assert.equal(verified.history_checksums_verified, true);
    const unverified = compareLedger([{ filename: '0001_fixture.sql', checksum: null }], [['0001_fixture.sql', file]]);
    assert.equal(unverified.history_known, true, 'a known filename is separate from verification of applied bytes');
    assert.equal(unverified.history_checksums_verified, false);
    const result = compareLedger([{ filename: 'unknown.sql', checksum: null }, { filename: '0001_fixture.sql', checksum: '0'.repeat(64) }, { filename: '0001_fixture.sql', checksum: null }], [['0001_fixture.sql', file], ['pending.sql', file]]);
    assert.deepEqual(result.unknown, ['unknown.sql']); assert.deepEqual(result.mismatched, ['0001_fixture.sql']);
    assert.deepEqual(result.missingChecksum, ['0001_fixture.sql']); assert.deepEqual(result.duplicate, ['0001_fixture.sql']);
    assert.deepEqual(result.pending, ['pending.sql']); assert.equal(result.history_known, false);
  } finally { fs.rmSync(dir, { recursive: true }); }
});
function pool({ failHistory = false, historyRows, healthyScope } = {}) {
  const policy = healthyScope ? loadPolicy({ scope: healthyScope, runtimeRoles: [healthyScope === 'product' ? 'app_user' : 'auth_runtime'] }) : null;
  const calls = []; let released = 0;
  const client = { release() { released++; }, async query(sql) {
    calls.push(sql);
    const matched = Object.entries(QUERIES).find(([, query]) => sql.endsWith(query));
    if (matched) {
      if (matched[0] === 'metadata') return { rows: [{ server_version_num: 170006, read_only: 'on', isolation: 'repeatable read' }] };
      if (matched[0] === 'roles') return { rows: [{ name: 'app_user', login: true }, { name: 'auth_runtime', login: true }] };
      if (matched[0] === 'effectiveRoutines' && policy) return { rows: policy.requiredRoutineAccess
        .filter(required => ['app_user','auth_runtime'].includes(required.role))
        .map(required => ({ role: required.role, identity: required.identity, execute: true })) };
      return { rows: [] };
    }
    if (sql.includes('to_regclass')) return { rows: [{ present: true }] };
    if (sql.startsWith('SELECT filename,')) {
      if (failHistory) throw new Error('synthetic private diagnostic');
      return { rows: historyRows || [{ filename: 'unknown_fixture.sql', checksum: null }] };
    }
    return { rows: [] };
  } };
  return { connect: async () => client, calls, get released() { return released; } };
}
test('complete review is encrypted, count-only result remains unaccepted, and every database operation is read only', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-private-privilege-'));
  try {
    const env = environment(dir), product = pool(), auth = pool(); let encryptedInput;
    const summary = await reviewRestoredPrivileges({ product, auth, env, encrypt(command, args, options) {
      assert.equal(command, 'age'); assert.deepEqual(args, ['-R', env.RESTORE_DIAGNOSTIC_RECIPIENTS_FILE]);
      assert.equal(Object.hasOwn(options.env, 'DATABASE_URL'), false); encryptedInput = JSON.parse(options.input);
      return { status: 0, stdout: Buffer.from('synthetic-ciphertext-only') };
    } });
    assert.equal(summary.strict_pass, false); assert.equal(summary.history_unknown, 1);
    assert.equal(encryptedInput.reports.product.complete, true); assert.equal(encryptedInput.reports.auth.complete, true);
    assert.equal(encryptedInput.read_only, true); assert.equal(JSON.stringify(encryptedInput).includes('never-use-private-live-url'), false);
    assert.equal(fs.readFileSync(env.RESTORE_PRIVILEGE_REVIEW_FILE, 'utf8'), 'synthetic-ciphertext-only');
    assert.equal(fs.statSync(env.RESTORE_PRIVILEGE_REVIEW_FILE).mode & 0o777, 0o600);
    assert.equal(product.released, 2); assert.equal(auth.released, 1);
    for (const sql of [...product.calls, ...auth.calls]) assert.ok(/^(?:BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY|SET LOCAL |WITH |SELECT |COMMIT)/.test(sql), sql.slice(0, 25));
  } finally { fs.rmSync(dir, { recursive: true }); }
});
test('otherwise clean role audits cannot pass strict review with a checksum-less applied migration', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-private-checksum-'));
  try {
    const filename = '0001_extensions_and_enums.sql';
    const bytes = fs.readFileSync(path.join(__dirname, '../supabase/migrations', filename));
    for (const checksum of [null, crypto.createHash('sha256').update(bytes).digest('hex')]) {
      const env = environment(dir);
      env.RESTORE_PRIVILEGE_REVIEW_FILE = path.join(dir, checksum ? 'verified.json.age' : 'unverified.json.age');
      let protectedReport;
      const summary = await reviewRestoredPrivileges({
        product: pool({ healthyScope: 'product', historyRows: [{ filename, checksum }] }),
        auth: pool({ healthyScope: 'auth' }), env,
        encrypt(_command, _args, options) {
          protectedReport = JSON.parse(options.input);
          return { status: 0, stdout: Buffer.from('synthetic-ciphertext-only') };
        },
      });
      assert.equal(summary.product_blocking, 0);
      assert.equal(summary.auth_blocking, 0);
      assert.equal(summary.history_unknown, 0);
      assert.equal(protectedReport.product_history.history_known, true);
      assert.equal(summary.history_missing_checksum, checksum ? 0 : 1);
      assert.equal(summary.strict_pass, Boolean(checksum));
      assert.equal(protectedReport.product_history.history_checksums_verified, Boolean(checksum));
      assert.equal(protectedReport.product_history.pending.length > 0, true,
        'checksum verification is a history check and does not claim the full candidate upgrade passed');
    }
  } finally { fs.rmSync(dir, { recursive: true }); }
});
test('ledger query failure rolls back and releases; encryption failure emits no plaintext file', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-private-privilege-'));
  try {
    const env = environment(dir), product = pool({ failHistory: true });
    await assert.rejects(reviewRestoredPrivileges({ product, auth: pool(), env, encrypt() { throw new Error('must not encrypt incomplete review'); } }));
    assert.equal(product.calls.at(-1), 'ROLLBACK'); assert.equal(product.released, 2); assert.equal(fs.existsSync(env.RESTORE_PRIVILEGE_REVIEW_FILE), false);
    await assert.rejects(reviewRestoredPrivileges({ product: pool(), auth: pool(), env, encrypt: () => ({ status: 1 }) }), /encryption failed/);
    assert.equal(fs.existsSync(env.RESTORE_PRIVILEGE_REVIEW_FILE), false);
  } finally { fs.rmSync(dir, { recursive: true }); }
});
