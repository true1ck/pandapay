#!/usr/bin/env node
'use strict';

// Run explicitly on the recovery machine after a fresh verified restore.
// The backup host does not need (and must not receive) the private age key.
// Neither the manifest plaintext nor the dedicated DB credential is written
// to disk or routine output. This is not an HTTP-accessible operation.
const fs = require('node:fs/promises');
const { constants } = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { promisify } = require('node:util');
const execFile = promisify(require('node:child_process').execFile);
const { resolveDatabaseTls } = require('../../api/src/db_tls');

const MAX_AGE_MS = 48 * 60 * 60 * 1000;
const MAX_FUTURE_MS = 5 * 60 * 1000;
const MAX_DUMP_BYTES = 64 * 1024 ** 3;
const FORMAT = 'pandapay-paired-postgresql-backup-v5';
const PROOF_FORMAT = 'pandapay-paired-postgresql-restore-proof-v1';
const FILES = ['product.dump.age', 'auth.dump.age', 'manifest.json.age'];
const DIGEST_RE = /^[a-f0-9]{64}$/;
const SET_RE = /^[a-f0-9]{32}$/;
const PUBLISH_SQL = `SELECT backup_status.publish_verified_status(
  $1::text,$2::text,$3::timestamptz,$4::bigint,$5::text,
  $6::timestamptz,$7::text,$8::text) AS published`;

function refused() { return new Error('Backup status evidence rejected'); }

function parseMarker(text, allowedKeys) {
  if (typeof text !== 'string' || text.length > 4096) throw refused();
  const values = Object.create(null);
  for (const line of text.trimEnd().split('\n')) {
    const match = /^([a-z][a-z0-9_]*)=([a-zA-Z0-9_.:+-]+)$/.exec(line);
    if (!match || !allowedKeys.includes(match[1]) || Object.hasOwn(values, match[1])) throw refused();
    values[match[1]] = match[2];
  }
  return values;
}

function parseChecksums(text) {
  const values = Object.create(null);
  if (typeof text !== 'string' || text.length > 1024) throw refused();
  for (const line of text.trimEnd().split('\n')) {
    const match = /^([a-f0-9]{64}) {2}(product\.dump\.age|auth\.dump\.age|manifest\.json\.age)$/.exec(line);
    if (!match || Object.hasOwn(values, match[2])) throw refused();
    values[match[2]] = match[1];
  }
  if (FILES.some(name => !Object.hasOwn(values, name))) throw refused();
  return values;
}

function parseTimestamp(value, now) {
  if (typeof value !== 'string' || value.length > 40 || !/Z$|\+00:00$/.test(value)) throw refused();
  const parsed = Date.parse(value);
  if (!Number.isFinite(parsed) || parsed < now - MAX_AGE_MS || parsed > now + MAX_FUTURE_MS) throw refused();
  return parsed;
}

function validateEvidence({ setId, manifest, completion, restore, files }, now = Date.now()) {
  if (!SET_RE.test(setId) || manifest?.format !== FORMAT || manifest.set_id !== setId ||
      !Number.isInteger(manifest.dump_client_major) || manifest.dump_client_major < 12 ||
      completion.set_id !== setId || restore.set_id !== setId ||
      restore.status !== 'database_restore_verified' || restore.proof_format !== PROOF_FORMAT ||
      !['passed', 'not_run'].includes(restore.application_check) ||
      !['passed', 'not_run'].includes(restore.upgrade_check)) throw refused();
  if (!['local_saved', 'offsite_uploaded'].includes(completion.status) ||
      !/^\d{10}$/.test(completion.completed_epoch)) throw refused();
  const completed = Number(completion.completed_epoch) * 1000;
  if (!Number.isSafeInteger(completed) || completed < now - MAX_AGE_MS || completed > now + MAX_FUTURE_MS) throw refused();
  const created = parseTimestamp(manifest.created_at_utc, now);
  const verified = parseTimestamp(restore.verified_at_utc, now);
  if (created > completed + MAX_FUTURE_MS || verified < completed - 1000) throw refused();
  const digestFields = {
    'manifest.json.age': 'manifest_ciphertext_sha256',
    'product.dump.age': 'product_ciphertext_sha256',
    'auth.dump.age': 'auth_ciphertext_sha256',
  };
  for (const filename of FILES) {
    const actual = files[filename];
    if (!actual || !DIGEST_RE.test(actual.sha256) || !Number.isSafeInteger(actual.size_bytes) ||
        actual.size_bytes <= 0 || actual.size_bytes > MAX_DUMP_BYTES ||
        restore[digestFields[filename]] !== actual.sha256) throw refused();
  }
  const archives = manifest.archives;
  if (!archives || Object.keys(archives).sort().join(',') !== 'auth.dump,product.dump') throw refused();
  for (const archive of ['product.dump', 'auth.dump']) {
    const expected = archives[archive];
    const actual = files[`${archive}.age`];
    const database = expected?.database;
    if (expected?.sha256 !== actual.sha256 || expected.size_bytes !== actual.size_bytes ||
        !database || !database.exact_row_counts || Array.isArray(database.exact_row_counts) ||
        !database.canonical_row_sha256 || Array.isArray(database.canonical_row_sha256) ||
        typeof database.canonical_row_sha256 !== 'object' ||
        !Array.isArray(database.parameter_grants)) throw refused();
    const tables = Object.keys(database.exact_row_counts).sort();
    if (!tables.length || tables.join(',') !== Object.keys(database.canonical_row_sha256).sort().join(',') ||
        tables.some(table => !Number.isSafeInteger(database.exact_row_counts[table]) || database.exact_row_counts[table] < 0 ||
          !DIGEST_RE.test(database.canonical_row_sha256[table]))) throw refused();
  }
  if (JSON.stringify(archives['product.dump'].database.parameter_grants) !==
      JSON.stringify(archives['auth.dump'].database.parameter_grants)) throw refused();
  return {
    setId, manifestSha256: files['manifest.json.age'].sha256,
    completedAt: new Date(completed).toISOString(),
    sizeBytes: files['product.dump.age'].size_bytes + files['auth.dump.age'].size_bytes,
    storage: completion.status === 'local_saved' ? 'local' : 'offhost',
    verifiedAt: new Date(verified).toISOString(),
    applicationCheck: restore.application_check, upgradeCheck: restore.upgrade_check,
  };
}

async function readRegular(filename, maximum) {
  const handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size <= 0 || stat.size > maximum) throw refused();
    const buffer = Buffer.alloc(maximum + 1);
    let length = 0;
    while (length < buffer.length) {
      const { bytesRead } = await handle.read(buffer, length, buffer.length - length, length);
      if (!bytesRead) break;
      length += bytesRead;
    }
    const after = await handle.stat();
    if (length !== stat.size || length > maximum || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) throw refused();
    return buffer.subarray(0, length).toString('utf8');
  } finally { await handle.close(); }
}

async function hashRegular(filename, maximum = MAX_DUMP_BYTES) {
  const handle = await fs.open(filename, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = await handle.stat();
    if (!stat.isFile() || stat.size <= 0 || stat.size > maximum) throw refused();
    const hash = crypto.createHash('sha256');
    const deadline = Date.now() + 120000;
    let bytes = 0;
    for await (const block of handle.createReadStream({ autoClose: false })) {
      bytes += block.length;
      if (bytes > maximum || Date.now() > deadline) throw refused();
      hash.update(block);
    }
    const after = await handle.stat();
    if (bytes !== stat.size || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs) throw refused();
    return { sha256: hash.digest('hex'), size_bytes: bytes };
  } finally { await handle.close(); }
}

async function loadEvidence(setDirectory, identityFile, { now = Date.now(), decrypt = execFile } = {}) {
  if (!identityFile) throw refused();
  const directory = path.resolve(setDirectory);
  if (!SET_RE.test(path.basename(directory)) || (await fs.lstat(directory)).isSymbolicLink()) throw refused();
  const checksums = parseChecksums(await readRegular(path.join(directory, 'checksums.sha256'), 1024));
  const files = Object.create(null);
  for (const filename of FILES) {
    files[filename] = await hashRegular(path.join(directory, filename), filename === 'manifest.json.age' ? 64 * 1024 ** 2 : MAX_DUMP_BYTES);
    if (files[filename].sha256 !== checksums[filename]) throw refused();
  }
  let completion;
  try {
    completion = await readRegular(path.join(directory, 'OFFSITE_COMPLETE'), 1024);
    if (!completion.includes('status=offsite_uploaded\n')) throw refused();
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    completion = await readRegular(path.join(directory, 'LOCAL_COMPLETE'), 1024);
    if (!completion.includes('status=local_saved\n')) throw refused();
  }
  const restore = await readRegular(path.join(directory, 'RESTORE_VERIFIED'), 4096);
  const { stdout } = await decrypt('age', ['--decrypt', '--identity', identityFile, path.join(directory, 'manifest.json.age')], {
    encoding: 'utf8', timeout: 60000, maxBuffer: 64 * 1024 ** 2,
  });
  if ((await hashRegular(path.join(directory, 'manifest.json.age'), 64 * 1024 ** 2)).sha256 !== files['manifest.json.age'].sha256) throw refused();
  const manifest = JSON.parse(stdout);
  return validateEvidence({
    setId: path.basename(directory), manifest, files,
    completion: parseMarker(completion, ['set_id', 'status', 'completed_epoch']),
    restore: parseMarker(restore, ['set_id', 'status', 'application_check', 'upgrade_check', 'product_upgrade',
      'contact_upgrade', 'verified_at_utc', 'proof_format', 'manifest_ciphertext_sha256',
      'product_ciphertext_sha256', 'auth_ciphertext_sha256']),
  }, now);
}

function connectionOptions(env) {
  if (!env.BACKUP_STATUS_DATABASE_URL) throw new Error('Backup status publisher configuration is incomplete');
  const tls = resolveDatabaseTls(env.BACKUP_STATUS_DATABASE_URL, {
    NODE_ENV: env.NODE_ENV || 'production', DB_SSL: env.BACKUP_STATUS_DB_SSL || 'true',
    DB_SSL_CA: env.BACKUP_STATUS_DB_SSL_CA, DB_SSL_CA_FILE: env.BACKUP_STATUS_DB_SSL_CA_FILE,
  });
  return { ...tls, connectionTimeoutMillis: 5000, statement_timeout: 10000, application_name: 'pandapay-backup-status-publisher' };
}

async function publishStatus(evidence, env, ClientClass) {
  const options = connectionOptions(env);
  const Client = ClientClass || require('../../api/node_modules/pg').Client;
  const client = new Client(options);
  try {
    await client.connect();
    const role = await client.query(`SELECT r.rolsuper, r.rolbypassrls, r.rolcreaterole, r.rolcreatedb, r.rolreplication,
      pg_has_role(current_user, 'backup_status_writer', 'USAGE') AS publisher,
      has_table_privilege(current_user,'backup_status.attestations','SELECT,INSERT,UPDATE,DELETE') AS raw_access,
      has_schema_privilege(current_user,'backup_status','CREATE') AS schema_create
      FROM pg_roles r WHERE r.rolname = current_user`);
    const capabilities = role.rows[0];
    if (!capabilities || capabilities.rolsuper || capabilities.rolbypassrls || capabilities.rolcreaterole ||
        capabilities.rolcreatedb || capabilities.rolreplication || capabilities.raw_access ||
        capabilities.schema_create || capabilities.publisher !== true) throw refused();
    await client.query(PUBLISH_SQL, [evidence.setId, evidence.manifestSha256, evidence.completedAt,
      evidence.sizeBytes, evidence.storage, evidence.verifiedAt, evidence.applicationCheck, evidence.upgradeCheck]);
  } finally { await client.end(); }
}

async function main(args = process.argv.slice(2), env = process.env) {
  if (args.length !== 2 || args[0] !== '--set-dir' || !env.BACKUP_STATUS_AGE_IDENTITY_FILE) {
    throw new Error('Use --set-dir with dedicated BACKUP_STATUS_DATABASE_URL and BACKUP_STATUS_AGE_IDENTITY_FILE');
  }
  // Validate explicit DB/TLS config before touching recovery evidence.
  connectionOptions(env);
  const evidence = await loadEvidence(args[1], env.BACKUP_STATUS_AGE_IDENTITY_FILE);
  await publishStatus(evidence, env);
  process.stdout.write('BACKUP_STATUS_PUBLICATION=verified\n');
}

if (require.main === module) main().catch(() => {
  process.stderr.write('Backup status publication failed; no verified status was published\n');
  process.exitCode = 1;
});

module.exports = { FORMAT, PROOF_FORMAT, MAX_AGE_MS, MAX_FUTURE_MS, PUBLISH_SQL,
  parseMarker, parseChecksums, validateEvidence, loadEvidence, connectionOptions, publishStatus };
