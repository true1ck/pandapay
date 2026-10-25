'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { FORMAT, PROOF_FORMAT, MAX_AGE_MS, PUBLISH_SQL, parseMarker, parseChecksums,
  validateEvidence, loadEvidence, connectionOptions, publishStatus } = require('../../db/scripts/publish_backup_status');
const NOW = Date.parse('2026-10-24T02:00:00Z');
const SET = '1'.repeat(32);
const sha = value => crypto.createHash('sha256').update(value).digest('hex');

function fixture() {
  const files = Object.fromEntries(['product.dump.age', 'auth.dump.age', 'manifest.json.age']
    .map(name => [name, { sha256: sha(name), size_bytes: name.length }]));
  const database = { exact_row_counts: { 'public.synthetic': 1 }, canonical_row_sha256: { 'public.synthetic': 'a'.repeat(64) }, parameter_grants: [] };
  return {
    setId: SET, files,
    manifest: { format: FORMAT, set_id: SET, dump_client_major: 17, created_at_utc: '2026-10-24T00:59:00Z',
      archives: { 'product.dump': { ...files['product.dump.age'], database }, 'auth.dump': { ...files['auth.dump.age'], database } } },
    completion: { set_id: SET, status: 'local_saved', completed_epoch: String(Date.parse('2026-10-24T01:00:00Z') / 1000) },
    restore: { set_id: SET, status: 'database_restore_verified', proof_format: PROOF_FORMAT,
      manifest_ciphertext_sha256: files['manifest.json.age'].sha256,
      product_ciphertext_sha256: files['product.dump.age'].sha256, auth_ciphertext_sha256: files['auth.dump.age'].sha256,
      application_check: 'not_run', upgrade_check: 'passed', verified_at_utc: '2026-10-24T01:30:00Z' },
  };
}

test('v5 same-set hash-bound successful restore evidence becomes only bounded sanitized fields', () => {
  const valid = fixture();
  const result = validateEvidence(valid, NOW);
  assert.deepEqual(result, {
    setId: SET, manifestSha256: valid.files['manifest.json.age'].sha256,
    completedAt: '2026-10-24T01:00:00.000Z', sizeBytes: 29, storage: 'local',
    verifiedAt: '2026-10-24T01:30:00.000Z', applicationCheck: 'not_run', upgradeCheck: 'passed',
  });
  assert.doesNotMatch(JSON.stringify(result), /public.synthetic|database|role|location|error/);
});

test('old weak marker, stale/future/incomplete/mismatched/tampered proof is rejected', () => {
  const mutations = [
    v => { delete v.restore.proof_format; },
    v => { delete v.restore.manifest_ciphertext_sha256; },
    v => { v.restore.product_ciphertext_sha256 = 'b'.repeat(64); },
    v => { v.restore.auth_ciphertext_sha256 = 'b'.repeat(64); },
    v => { v.restore.set_id = '2'.repeat(32); },
    v => { v.manifest.set_id = '2'.repeat(32); },
    v => { v.manifest.format = 'pandapay-paired-postgresql-backup-v4'; },
    v => { v.restore.status = 'failed'; },
    v => { v.restore.application_check = 'failed'; },
    v => { v.restore.verified_at_utc = '2026-10-20T01:30:00Z'; },
    v => { v.restore.verified_at_utc = '2026-10-24T02:06:00Z'; },
    v => { v.restore.verified_at_utc = '2026-10-24T00:30:00Z'; },
    v => { v.completion.completed_epoch = String((NOW - MAX_AGE_MS - 1) / 1000); },
    v => { v.completion.status = 'success'; },
    v => { v.manifest.archives['product.dump'].sha256 = 'b'.repeat(64); },
    v => { v.manifest.archives['auth.dump'].size_bytes += 1; },
    v => { v.manifest.archives['unexpected.dump'] = {}; },
    v => { v.manifest.archives['auth.dump'].database = {}; },
    v => { v.manifest.archives['auth.dump'].database = { ...v.manifest.archives['auth.dump'].database, parameter_grants: [['unsafe']] }; },
  ];
  for (const mutate of mutations) {
    const value = fixture(); mutate(value);
    assert.throws(() => validateEvidence(value, NOW), /evidence rejected/);
  }
});

test('marker/checksum parsers reject duplicate fields, unknown paths and diagnostic payloads', () => {
  for (const text of ['set_id=x\nset_id=y\n', 'set_id=x\nerror_text=secret\n', 'set_id=x\nsecret spaces\n']) {
    assert.throws(() => parseMarker(text, ['set_id']), /evidence rejected/);
  }
  const checksum = Object.entries(fixture().files).map(([name, value]) => `${value.sha256}  ${name}`).join('\n') + '\n';
  assert.equal(Object.keys(parseChecksums(checksum)).length, 3);
  for (const text of [checksum + checksum, checksum.replace('auth.dump.age', '../secret'), checksum.replace('auth.dump.age', 'unknown.dump.age')]) {
    assert.throws(() => parseChecksums(text), /evidence rejected/);
  }
});

test('publisher requires a dedicated URL and verified TLS, with no generic DATABASE_URL fallback', () => {
  assert.throws(() => connectionOptions({ DATABASE_URL: 'postgres://secret' }), /configuration is incomplete/);
  assert.throws(() => connectionOptions({ BACKUP_STATUS_DATABASE_URL: 'postgres://writer:password@host/db', BACKUP_STATUS_DB_SSL: 'false' }), /allowed only/);
  const options = connectionOptions({ BACKUP_STATUS_DATABASE_URL: 'postgres://writer:password@db.example/db' });
  assert.equal(options.ssl.rejectUnauthorized, true);
  assert.equal(options.statement_timeout, 10000);
});

test('dedicated publisher is refused if superuser, bypass-RLS, create-role/db or missing capability', async () => {
  const env = { BACKUP_STATUS_DATABASE_URL: 'postgres://writer:synthetic@localhost/test', NODE_ENV: 'test', BACKUP_STATUS_DB_SSL: 'false' };
  for (const flags of [{ rolsuper: true }, { rolbypassrls: true }, { rolcreaterole: true }, { rolcreatedb: true },
    { rolreplication: true }, { raw_access: true }, { schema_create: true }, { publisher: false }]) {
    const calls = [];
    class Client {
      async connect() {}
      async query(sql) { calls.push(sql); return { rows: [{ rolsuper: false, rolbypassrls: false, rolcreaterole: false, rolcreatedb: false, publisher: true, ...flags }] }; }
      async end() {}
    }
    await assert.rejects(publishStatus(validateEvidence(fixture(), NOW), env, Client), /evidence rejected/);
    assert.equal(calls.length, 1);
  }
});

test('publisher performs one parameterized sanitized write after role checks', async () => {
  const calls = [];
  let ended = false;
  class Client {
    async connect() {}
    async query(sql, params) { calls.push([sql, params]); return { rows: [{ rolsuper: false, rolbypassrls: false, rolcreaterole: false, rolcreatedb: false, publisher: true }] }; }
    async end() { ended = true; }
  }
  const env = { BACKUP_STATUS_DATABASE_URL: 'postgres://writer:synthetic@localhost/test', NODE_ENV: 'test', BACKUP_STATUS_DB_SSL: 'false' };
  await publishStatus(validateEvidence(fixture(), NOW), env, Client);
  assert.equal(ended, true);
  assert.equal(calls[1][0], PUBLISH_SQL);
  assert.equal(calls[1][1].length, 8);
  assert.equal(calls.length, 2);
});

test('file evidence is checked against fixed ciphertext names before private manifest decryption', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pp-status-evidence-'));
  const directory = path.join(root, SET);
  try {
    await fs.mkdir(directory);
    const value = fixture();
    for (const [name, info] of Object.entries(value.files)) await fs.writeFile(path.join(directory, name), name);
    const checksum = Object.entries(value.files).map(([name, info]) => `${info.sha256}  ${name}`).join('\n') + '\n';
    await fs.writeFile(path.join(directory, 'checksums.sha256'), checksum);
    await fs.writeFile(path.join(directory, 'LOCAL_COMPLETE'), Object.entries(value.completion).map(([k,v]) => `${k}=${v}`).join('\n') + '\n');
    await fs.writeFile(path.join(directory, 'RESTORE_VERIFIED'), Object.entries(value.restore).map(([k,v]) => `${k}=${v}`).join('\n') + '\n');
    let decryptions = 0;
    const decrypt = async (binary, args, options) => {
      decryptions += 1; assert.equal(binary, 'age');
      assert.deepEqual(args, ['--decrypt', '--identity', '/synthetic/key', path.join(directory, 'manifest.json.age')]);
      assert.equal(options.timeout, 60000);
      return { stdout: JSON.stringify(value.manifest) };
    };
    assert.equal((await loadEvidence(directory, '/synthetic/key', { now: NOW, decrypt })).storage, 'local');
    await fs.writeFile(path.join(directory, 'auth.dump.age'), 'corrupt');
    await assert.rejects(loadEvidence(directory, '/synthetic/key', { now: NOW, decrypt }), /evidence rejected/);
    assert.equal(decryptions, 1, 'ciphertext corruption must fail before decrypting manifest');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
