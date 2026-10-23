#!/usr/bin/env node
'use strict';

// Source-only product-upgrade proof for an isolated, exact-restore copy.
// The caller must run this after restore verification and provide the explicit
// generated product target plus the reviewed legacy migration baseline.
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createRequire } = require('node:module');
const { spawn } = require('node:child_process');

const ISOLATED_ATTESTATION = 'THIS_IS_AN_ISOLATED_DISPOSABLE_RECOVERY_CLUSTER';
const EXACT_RESTORE_ATTESTATION = 'passed';
const REQUIRED_RUNTIME_ROLES = ['app_user', 'rewards_worker_login'];
const ROLE_NAMES = [...REQUIRED_RUNTIME_ROLES, 'sms_learning_worker'];
const COMMAND_TIMEOUT_MS = 5 * 60 * 1000;
const STATEMENT_TIMEOUT_MS = 120000;
const BATCH_SIZE = 1000;
const REHEARSAL_STAGES = new Set(['preflight', 'apply', 'replay']);
const SAFE_FAILURE_CATEGORIES = new Set([
  'invalid_target', 'restore_attestation_required', 'reviewed_baseline_required',
  'recovery_client_config_required', 'invalid_pgpassfile', 'invalid_recovery_adapter',
  'foreign_table_review_required', 'table_fingerprint_failed', 'table_data_changed',
  'original_column_missing', 'ledger_history_changed', 'runtime_role_unavailable',
  'runtime_role_changed', 'optional_worker_created', 'unknown_migration_history',
  'migration_checksum_missing', 'migration_checksum_drift', 'migration_inventory_unavailable',
  'migration_command_timeout', 'migration_command_failed', 'migration_ledger_checksum',
  'migration_legacy_baseline_review_required', 'migration_unknown_migration_history',
  'migration_role_setup_failed', 'migration_lock_unavailable', 'migration_operation_failed',
  'migration_node_module_not_found', 'migration_spawn_not_found',
  'operation_failed',
]);
const PRODUCT_MIGRATION_CATEGORIES = new Map([
  ['ledger_checksum', 'migration_ledger_checksum'],
  ['legacy_baseline_review_required', 'migration_legacy_baseline_review_required'],
  ['unknown_migration_history', 'migration_unknown_migration_history'],
  ['role_setup_failed', 'migration_role_setup_failed'],
  ['migration_lock_unavailable', 'migration_lock_unavailable'],
  ['operation_failed', 'migration_operation_failed'],
]);

function rehearsalError(code, stage) {
  const error = new Error(code);
  error.rehearsalCode = code;
  if (REHEARSAL_STAGES.has(stage)) error.rehearsalStage = stage;
  return error;
}

function safeFailureCategory(error) {
  return SAFE_FAILURE_CATEGORIES.has(error?.rehearsalCode) ? error.rehearsalCode : 'operation_failed';
}

function safeProductMigrationCategory(stderr) {
  const value = (Buffer.isBuffer(stderr) ? stderr.subarray(0, 8192).toString('utf8') : String(stderr || '').slice(0, 8192));
  const categoryNames = [...PRODUCT_MIGRATION_CATEGORIES.keys()].join('|');
  const inspectDiagnostic = new RegExp(
    `^Product database migration failed:\\s*\\{\\s*code: '(?:[0-9A-Z]{5}|migration_failed)',\\s*(?:migration: '(?:seed:)?\\d+_[A-Za-z0-9_-]{1,120}\\.sql',\\s*)?category: '(${categoryNames})'\\s*\\}`,
    's',
  ).exec(value.trim());
  if (inspectDiagnostic) return PRODUCT_MIGRATION_CATEGORIES.get(inspectDiagnostic[1]);

  // Runtime warnings can precede the canonical CLI diagnostic. Accept only
  // one complete prefixed JSON line, reject extra fields, and never expose
  // the surrounding stderr.
  const prefix = 'Product database migration failed:';
  const lines = value.split(/\r?\n/).filter(line => line.startsWith(prefix));
  if (lines.length !== 1) return null;
  const firstLine = lines[0];
  const payload = firstLine.slice(prefix.length).trim();
  let parsed;
  try { parsed = JSON.parse(payload); }
  catch { return null; }
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return null;
  const keys = Object.keys(parsed);
  if (!keys.every(key => ['code', 'migration', 'category'].includes(key)) ||
      !keys.includes('code') || !keys.includes('category') ||
      keys.some(key => key === 'migration') !== Object.hasOwn(parsed, 'migration') ||
      !/^(?:[0-9A-Z]{5}|migration_failed)$/.test(parsed.code) ||
      (Object.hasOwn(parsed, 'migration') && !/^(?:seed:)?\d+_[A-Za-z0-9_-]{1,120}\.sql$/.test(parsed.migration)) ||
      typeof parsed.category !== 'string' || !PRODUCT_MIGRATION_CATEGORIES.has(parsed.category)) return null;
  return PRODUCT_MIGRATION_CATEGORIES.get(parsed.category);
}

function validateProductTarget(env = process.env) {
  let target;
  try { target = new URL(env.RESTORE_PRODUCT_TARGET_URL); }
  catch { throw rehearsalError('invalid_target'); }
  const allowedConnectionOptions = new Set(['sslmode', 'sslrootcert', 'sslcert', 'sslkey', 'sslpassword']);
  if (!['postgres:', 'postgresql:'].includes(target.protocol) ||
      target.hostname !== '127.0.0.1' ||
      !/^\/pprestore_[a-f0-9]{20}_p$/.test(target.pathname) ||
      target.hash || [...target.searchParams.keys()].some(key => !allowedConnectionOptions.has(key.toLowerCase()))) {
    throw rehearsalError('invalid_target');
  }
  if (env.RESTORE_EXTENSION_BOOTSTRAP_ATTESTATION !== ISOLATED_ATTESTATION ||
      env.RESTORE_PRODUCT_EXACT_COMPARISON !== EXACT_RESTORE_ATTESTATION) {
    throw rehearsalError('restore_attestation_required');
  }
  const baseline = env.PRODUCT_REVIEWED_BASELINE_FILE;
  if (typeof baseline !== 'string' || !baseline.trim()) throw rehearsalError('reviewed_baseline_required');
  try {
    if (!fs.statSync(baseline).isFile()) throw new Error('not_file');
  } catch {
    throw rehearsalError('reviewed_baseline_required');
  }
  return { target, baseline: path.resolve(baseline) };
}

function validateRecoveryClientEnvironment(env) {
  const passFile = env.PGPASSFILE;
  const container = env.PP_RECOVERY_CONTAINER;
  const portValue = env.PP_RECOVERY_HOST_PORT;
  if (typeof passFile !== 'string' || !path.isAbsolute(passFile) ||
      typeof container !== 'string' || !/^pandapay-recovery-[a-f0-9]{16}$/.test(container) ||
      typeof portValue !== 'string' || !/^\d{1,5}$/.test(portValue) ||
      Number(portValue) < 1 || Number(portValue) > 65535) {
    throw rehearsalError('recovery_client_config_required');
  }
  let passStat;
  try { passStat = fs.lstatSync(passFile); }
  catch { throw rehearsalError('invalid_pgpassfile'); }
  if (!passStat.isFile() || passStat.isSymbolicLink() || (passStat.mode & 0o077) !== 0) {
    throw rehearsalError('invalid_pgpassfile');
  }
  return { passFile, container, port: String(Number(portValue)) };
}

function safeChildEnvironment(env, targetUrl, baselineFile, authDir, dbDir, randomBytes = crypto.randomBytes) {
  // Keep only execution and verified-TLS inputs. In particular, no source DB
  // URL, application key, auth secret, or SMS worker credential is inherited.
  const child = {};
  for (const name of [
    'PATH', 'HOME', 'TMPDIR', 'TEMP', 'TMP', 'NODE_ENV',
    'DB_SSL', 'DB_SSL_CA', 'DB_SSL_CA_FILE',
  ]) {
    if (env[name] !== undefined) child[name] = env[name];
  }
  const recovery = validateRecoveryClientEnvironment(env);
  child.PGPASSFILE = recovery.passFile;
  child.PP_RECOVERY_CONTAINER = recovery.container;
  child.PP_RECOVERY_HOST_PORT = recovery.port;
  if (env.PP_RECOVERY_DUMP_IMAGE !== undefined) {
    if (!/^[a-z0-9][a-z0-9._/:@-]{0,240}$/.test(env.PP_RECOVERY_DUMP_IMAGE)) throw rehearsalError('invalid_recovery_adapter');
    child.PP_RECOVERY_DUMP_IMAGE = env.PP_RECOVERY_DUMP_IMAGE;
  }
  child.ADMIN_DATABASE_URL = targetUrl.toString();
  child.DB_DIR = dbDir;
  child.AUTH_APP_DIR = authDir;
  child.MIGRATION_ADOPT_LEGACY_CHECKSUMS = 'true';
  child.MIGRATION_LEGACY_BASELINE_FILE = baselineFile;
  child.SEED_DEMO_DATA = 'false';
  child.APP_USER_PASSWORD = randomBytes(32).toString('base64url');
  child.REWARD_WORKER_DB_PASSWORD = randomBytes(32).toString('base64url');
  // A blank value intentionally prevents setup_app_role.sql from creating or
  // rotating the optional SMS worker role on this disposable copy.
  child.SMS_LEARNING_WORKER_DB_PASSWORD = '';
  return child;
}

function quoteIdentifier(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function tableKey(schemaName, tableName) {
  return `${schemaName}\u0000${tableName}`;
}

async function hashTableRowsWithCursor(client, schemaName, tableName, columns) {
  const selected = columns.map(quoteIdentifier).join(', ');
  const relation = `${quoteIdentifier(schemaName)}.${quoteIdentifier(tableName)}`;
  await client.query(`DECLARE product_upgrade_data_cursor NO SCROLL CURSOR FOR
    SELECT canonical
    FROM (
      SELECT to_jsonb(t)::text AS canonical
      FROM (SELECT ${selected} FROM ${relation}) AS t
    ) AS canonical_rows
    ORDER BY canonical COLLATE "C"`);
  const digest = crypto.createHash('sha256');
  let rows = 0;
  try {
    while (true) {
      const batch = await client.query(`FETCH FORWARD ${BATCH_SIZE} FROM product_upgrade_data_cursor`);
      if (!batch.rows.length) break;
      for (const row of batch.rows) {
        if (typeof row.canonical !== 'string') throw rehearsalError('table_fingerprint_failed');
        digest.update(row.canonical).update('\n');
        rows++;
      }
    }
  } finally {
    await client.query('CLOSE product_upgrade_data_cursor').catch(() => {});
  }
  return { rows, sha256: digest.digest('hex') };
}

async function captureProductState(client, options = {}) {
  const fingerprintTable = options.fingerprintTable || hashTableRowsWithCursor;
  await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  try {
    await client.query(`SET LOCAL statement_timeout = '${STATEMENT_TIMEOUT_MS}ms'`);
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '180000ms'");
    const hasForeignTables = (await client.query(`SELECT EXISTS (
      SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE c.relkind = 'f' AND n.nspname <> 'information_schema' AND left(n.nspname, 3) <> 'pg_'
    ) AS present`)).rows[0]?.present;
    if (hasForeignTables) throw rehearsalError('foreign_table_review_required');
    const inventory = await client.query(`SELECT n.nspname AS schema_name, c.relname AS table_name,
        a.attname AS column_name, a.attnum AS ordinal
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      JOIN pg_attribute a ON a.attrelid = c.oid
      WHERE c.relkind IN ('r', 'p', 'm')
        AND n.nspname <> 'information_schema'
        AND left(n.nspname, 3) <> 'pg_'
        AND a.attnum > 0 AND NOT a.attisdropped
        AND NOT (n.nspname = 'public' AND c.relname = 'schema_migrations')
      ORDER BY n.nspname COLLATE "C", c.relname COLLATE "C", a.attnum`);
    const tables = new Map();
    for (const row of inventory.rows) {
      const key = tableKey(row.schema_name, row.table_name);
      if (!tables.has(key)) tables.set(key, { schema: row.schema_name, name: row.table_name, columns: [] });
      tables.get(key).columns.push(row.column_name);
    }
    const fingerprints = new Map();
    for (const [key, table] of tables) {
      if (options.originalColumns && !options.originalColumns.has(key)) continue;
      const columnsToHash = options.originalColumns?.get(key) || table.columns;
      fingerprints.set(key, await fingerprintTable(client, table.schema, table.name, columnsToHash));
    }

    const ledgerExists = (await client.query("SELECT to_regclass('public.schema_migrations') IS NOT NULL AS present")).rows[0]?.present;
    const ledger = ledgerExists
      ? (await client.query(`SELECT filename::text AS filename, applied_at::text AS applied_at,
            to_jsonb(t)->>'checksum' AS checksum
          FROM public.schema_migrations t
          ORDER BY filename COLLATE "C", applied_at`)).rows.map(row => ({
            filename: row.filename, appliedAt: row.applied_at, checksum: row.checksum,
          }))
      : [];
    const roles = (await client.query(`SELECT rolname, rolcanlogin, rolsuper, rolbypassrls
      FROM pg_roles WHERE rolname = ANY($1::text[]) ORDER BY rolname COLLATE "C"`, [ROLE_NAMES])).rows;
    await client.query('COMMIT');
    return { tables, fingerprints, ledgerExists: Boolean(ledgerExists), ledger, roles };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

function assertOriginalTablesPreserved(before, after) {
  for (const [key, original] of before.tables) {
    const upgraded = after.tables.get(key);
    const oldFingerprint = before.fingerprints.get(key);
    const newFingerprint = after.fingerprints.get(key);
    if (!upgraded || !oldFingerprint || !newFingerprint ||
        !Number.isSafeInteger(oldFingerprint.rows) || !Number.isSafeInteger(newFingerprint.rows) ||
        oldFingerprint.rows !== newFingerprint.rows || oldFingerprint.sha256 !== newFingerprint.sha256) {
      throw rehearsalError('table_data_changed');
    }
    // The post-upgrade fingerprint selects exactly the pre-upgrade column list;
    // added migration columns therefore do not conceal a change to old data.
    if (!original.columns.every(column => upgraded.columns.includes(column))) {
      throw rehearsalError('original_column_missing');
    }
  }
  const remaining = new Map();
  for (const row of after.ledger) {
    const key = `${row.filename}\u0000${row.appliedAt}`;
    remaining.set(key, (remaining.get(key) || 0) + 1);
  }
  for (const row of before.ledger) {
    const key = `${row.filename}\u0000${row.appliedAt}`;
    const count = remaining.get(key) || 0;
    if (count < 1) throw rehearsalError('ledger_history_changed');
    remaining.set(key, count - 1);
  }
}

function assertRuntimeRolesPreserved(beforeRoles, afterRoles) {
  const before = new Map(beforeRoles.map(row => [row.rolname, row]));
  const after = new Map(afterRoles.map(row => [row.rolname, row]));
  for (const name of REQUIRED_RUNTIME_ROLES) {
    const role = after.get(name);
    if (!role || role.rolcanlogin !== true || role.rolsuper !== false || role.rolbypassrls !== false) {
      throw rehearsalError('runtime_role_unavailable');
    }
  }
  for (const [name, original] of before) {
    const current = after.get(name);
    if (!current || current.rolcanlogin !== original.rolcanlogin ||
        current.rolsuper !== original.rolsuper || current.rolbypassrls !== original.rolbypassrls) {
      throw rehearsalError('runtime_role_changed');
    }
  }
  if (!before.has('sms_learning_worker') && after.has('sms_learning_worker')) {
    throw rehearsalError('optional_worker_created');
  }
}

function assertProductLedger(ledger, migrationInventory, dbDir) {
  const inventory = migrationInventory(dbDir);
  const known = new Map(inventory.map(([name, filename]) => [name, filename]));
  const seen = new Set();
  for (const row of ledger) {
    if (typeof row.filename !== 'string' || seen.has(row.filename) || !known.has(row.filename)) {
      throw rehearsalError('unknown_migration_history');
    }
    seen.add(row.filename);
    if (typeof row.checksum !== 'string' || !/^[a-f0-9]{64}$/.test(row.checksum)) {
      throw rehearsalError('migration_checksum_missing');
    }
    const expected = crypto.createHash('sha256').update(fs.readFileSync(known.get(row.filename))).digest('hex');
    if (row.checksum !== expected) throw rehearsalError('migration_checksum_drift');
  }
  return ledger.length;
}

function runBounded(command, args, options = {}) {
  const timeoutMs = options.timeoutMs || COMMAND_TIMEOUT_MS;
  return new Promise((resolve, reject) => {
    let settled = false;
    const launch = options.spawn || spawn;
    const child = launch(command, args, { env: options.env, stdio: ['ignore', 'ignore', 'pipe'] });
    const stderrChunks = [];
    let stderrBytes = 0;
    child.stderr?.on('data', chunk => {
      if (stderrBytes >= 8192) return;
      const bounded = Buffer.from(chunk).subarray(0, 8192 - stderrBytes);
      stderrChunks.push(bounded);
      stderrBytes += bounded.length;
    });
    const fixedMigrationError = (spawnError = null) => {
      const stderr = Buffer.concat(stderrChunks, stderrBytes);
      const categorized = safeProductMigrationCategory(stderr);
      if (categorized) return rehearsalError(categorized, options.phase);
      if (spawnError?.code === 'ENOENT') return rehearsalError('migration_spawn_not_found', options.phase);
      if (/Error: Cannot find module ['"][^'"\r\n]+['"]/.test(stderr.toString('utf8'))) {
        return rehearsalError('migration_node_module_not_found', options.phase);
      }
      const error = rehearsalError('migration_command_failed', options.phase);
      error.rehearsalDiagnostic = { stderr_bytes: stderrBytes,
        canonical_prefix_present: stderr.includes(Buffer.from('Product database migration failed:')) };
      return error;
    };
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      child.kill('SIGTERM');
      const killTimer = setTimeout(() => child.kill('SIGKILL'), 10000);
      killTimer.unref();
      reject(rehearsalError('migration_command_timeout', options.phase));
    }, timeoutMs);
    timer.unref();
    child.once('error', error => {
      if (settled) return;
      settled = true; clearTimeout(timer); reject(fixedMigrationError(error));
    });
    child.once('close', code => {
      if (settled) return;
      settled = true; clearTimeout(timer);
      if (code === 0) resolve(); else reject(fixedMigrationError());
    });
  });
}

async function runProductUpgrade(options = {}) {
  const env = options.env || process.env;
  const { target, baseline } = validateProductTarget(env);
  const dbDir = options.dbDir || path.resolve(__dirname, '..');
  const authDir = options.authDir || env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
  const migrationFile = options.migrationFile || path.join(__dirname, 'product_migrate.js');
  const runner = options.runner || require(migrationFile);
  const migrationInventory = options.migrationInventory || runner.migrationInventory;
  if (typeof migrationInventory !== 'function') throw rehearsalError('migration_inventory_unavailable');

  let client = options.client;
  let ownsClient = false;
  if (!client) {
    const authRequire = createRequire(path.join(authDir, 'package.json'));
    const { Client } = authRequire('pg');
    const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
    client = new Client({ ...resolveDatabaseTls(target.toString(), env), connectionTimeoutMillis: 10000 });
    ownsClient = true;
  }

  const childEnv = safeChildEnvironment(env, target, baseline, authDir, dbDir, options.randomBytes);
  try {
    await client.connect?.();
    const before = await captureProductState(client, { fingerprintTable: options.fingerprintTable });
    const invoke = options.runMigration || (async (command, migrationEnv, phase) => {
      const args = command === '--check' ? [migrationFile, '--check'] : [migrationFile];
      await runBounded(process.execPath, args, { env: migrationEnv, timeoutMs: options.commandTimeoutMs, phase });
    });
    await invoke('--check', childEnv, 'preflight');
    await invoke('apply', childEnv, 'apply');
    await invoke('apply', childEnv, 'replay');

    const originalColumns = new Map([...before.tables].map(([key, table]) => [key, table.columns]));
    const after = await captureProductState(client, { fingerprintTable: options.fingerprintTable, originalColumns });
    assertOriginalTablesPreserved(before, after);
    assertRuntimeRolesPreserved(before.roles, after.roles);
    const ledgerEntriesVerified = assertProductLedger(after.ledger, migrationInventory, dbDir);
    const summary = {
      tablesPreserved: before.tables.size,
      ledgerEntriesVerified,
      runtimeRolesPreserved: REQUIRED_RUNTIME_ROLES.length,
      applyReplay: true,
    };
    options.log?.(`PRODUCT_UPGRADE_STATUS=passed tables_preserved=${summary.tablesPreserved} ledger_entries_verified=${ledgerEntriesVerified} runtime_roles_preserved=${summary.runtimeRolesPreserved} replay=passed`);
    return summary;
  } catch (error) {
    if (SAFE_FAILURE_CATEGORIES.has(error?.rehearsalCode)) throw error;
    throw rehearsalError('operation_failed');
  } finally {
    if (ownsClient) await client.end().catch(() => {});
  }
}

async function main(env = process.env) {
  return runProductUpgrade({ env, log: console.log });
}

if (require.main === module) {
  main().catch(error => {
    console.error(`Product upgrade rehearsal failed (${safeFailureCategory(error)})`);
    process.exitCode = 1;
  });
}

module.exports = {
  ISOLATED_ATTESTATION,
  EXACT_RESTORE_ATTESTATION,
  validateProductTarget,
  validateRecoveryClientEnvironment,
  safeFailureCategory,
  safeProductMigrationCategory,
  safeChildEnvironment,
  quoteIdentifier,
  tableKey,
  hashTableRowsWithCursor,
  captureProductState,
  assertOriginalTablesPreserved,
  assertRuntimeRolesPreserved,
  assertProductLedger,
  runBounded,
  runProductUpgrade,
  main,
};
