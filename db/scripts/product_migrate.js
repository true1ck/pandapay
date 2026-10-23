'use strict';

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { createHash } = require('node:crypto');
const { createRequire } = require('node:module');
const { execFileSync } = require('node:child_process');
const { schemaFingerprint } = require('./schema_fingerprint');

// Split only top-level statements, preserving strings, quoted identifiers,
// nested comments and PL/pgSQL dollar blocks. Historical files may contain
// an outer BEGIN/COMMIT; the runner owns that transaction and the ledger.
function statements(sql) {
  const result = [];
  let start = 0, i = 0, quote = null, dollar = null, comment = 0;
  while (i < sql.length) {
    const c = sql[i], next = sql[i + 1];
    if (comment) {
      if (c === '/' && next === '*') { comment++; i += 2; }
      else if (c === '*' && next === '/') { comment--; i += 2; }
      else i++;
    } else if (dollar) {
      if (sql.startsWith(dollar, i)) { i += dollar.length; dollar = null; } else i++;
    } else if (quote) {
      if (c === quote && next === quote) i += 2;
      else if (c === quote) { quote = null; i++; }
      else i++;
    } else if (c === '-' && next === '-') {
      const end = sql.indexOf('\n', i + 2); i = end < 0 ? sql.length : end + 1;
    } else if (c === '/' && next === '*') { comment = 1; i += 2; }
    else if (c === "'" || c === '"') { quote = c; i++; }
    else if (c === '$' && /^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/.test(sql.slice(i))) {
      dollar = sql.slice(i).match(/^\$(?:[A-Za-z_][A-Za-z0-9_]*)?\$/)[0]; i += dollar.length;
    } else if (c === ';') { result.push(sql.slice(start, ++i)); start = i; }
    else i++;
  }
  if (quote || dollar || comment) throw new Error('Unterminated SQL literal or comment');
  result.push(sql.slice(start));
  return result;
}

function command(sql) {
  let value = sql.trim();
  while (value.startsWith('--') || value.startsWith('/*')) {
    if (value.startsWith('--')) {
      const end = value.indexOf('\n'); value = end < 0 ? '' : value.slice(end + 1).trim();
    } else {
      let depth = 1, i = 2;
      while (i < value.length && depth) {
        if (value.startsWith('/*', i)) { depth++; i += 2; }
        else if (value.startsWith('*/', i)) { depth--; i += 2; } else i++;
      }
      value = value.slice(i).trim();
    }
  }
  return value;
}

function transactionalSql(sql) {
  const parts = statements(sql).filter(part => command(part).replace(/;$/, '').trim());
  if (/^BEGIN(?:\s+(?:WORK|TRANSACTION))?\s*;?$/i.test(command(parts[0] || ''))) {
    if (!/^COMMIT(?:\s+(?:WORK|TRANSACTION))?\s*;?$/i.test(command(parts.at(-1) || ''))) {
      throw new Error('Migration has an unmatched outer transaction');
    }
    parts.shift(); parts.pop();
  }
  for (const part of parts) {
    if (/^(?:BEGIN\b|COMMIT\b|ROLLBACK\b|END\s*;|START\s+TRANSACTION|VACUUM\b|CREATE\s+(?:UNIQUE\s+)?INDEX\s+CONCURRENTLY\b|\\)/i.test(command(part))) {
      throw new Error('Migration requires a separate reviewed transaction/nontransaction job');
    }
  }
  return parts.join('\n');
}

async function runProductMigrations(client, options = {}) {
  const dbDir = options.dbDir || path.resolve(__dirname, '..');
  const log = options.log || (() => {});
  const timeout = options.statementTimeoutMs || 120000;
  await client.query("SELECT set_config('lock_timeout', '10000', false), set_config('statement_timeout', $1, false)", [`${timeout}ms`]);
  const lock = await client.query('SELECT pg_try_advisory_lock(1346457153, 1) AS acquired');
  if (!lock.rows[0]?.acquired) throw new Error('Another product migration is running');
  try {
    await client.query(`CREATE TABLE IF NOT EXISTS schema_migrations (
      filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now(), checksum text)`);
    await client.query('ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS checksum text');
    const applied = new Map((await client.query('SELECT filename, checksum FROM schema_migrations')).rows.map(row => [row.filename, row.checksum]));
    const files = migrationInventory(dbDir);
    const pending = await validateProductHistory(client, files, applied, options);
    await options.runRoleSetup?.();
    for (const { name, checksum, sql } of pending) {
      if (applied.has(name)) {
        if (!applied.get(name)) await client.query('UPDATE schema_migrations SET checksum = $1 WHERE filename = $2 AND checksum IS NULL', [checksum, name]);
        continue;
      }
      await client.query('BEGIN');
      try {
        await client.query(sql);
        // Older execution used a fresh psql connection for every file. A file
        // may SET ROLE to create owned functions; never ledger as that role or
        // carry its search path into the next migration.
        await client.query('RESET ROLE');
        await client.query('RESET search_path');
        await client.query('INSERT INTO schema_migrations (filename, checksum) VALUES ($1, $2)', [name, checksum]);
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        const failure = new Error(`Product migration failed: ${name}`, { cause: error });
        failure.migrationFile = name;
        throw failure;
      }
      log(`Applied product migration ${name}`);
    }
    await options.runRoleSetup?.();
    // This runner must not conceal the need for portable scheduled jobs.
    log('Scheduler migration 0013 requires separately installed and monitored jobs');
  } finally {
    await client.query('SELECT pg_advisory_unlock(1346457153, 1)');
  }
}

async function validateProductHistory(client, files, applied, options = {}) {
  for (const name of applied.keys()) {
    if (!files.some(([known]) => known === name)) throw new Error(`Unknown applied product migration: ${name}`);
  }
  const legacy = [...applied].filter(([, checksum]) => !checksum);
  if (legacy.length) {
    if (!options.adoptLegacyChecksums || !options.legacyBaselineFile) {
      throw new Error('Legacy checksum adoption requires an independently reviewed MIGRATION_LEGACY_BASELINE_FILE and explicit adoption flag');
    }
    const expected = JSON.parse(fs.readFileSync(options.legacyBaselineFile, 'utf8'));
    if (expected?.format !== 'pandapay-reviewed-product-baseline-v2') {
      throw new Error('Legacy baseline format is unsupported; capture and independently review a v2 legacy baseline');
    }
    const actual = await legacyBaseline(client, files, [...applied.keys()], options.snapshot);
    if (JSON.stringify(expected) !== JSON.stringify(actual)) throw new Error('Reviewed legacy baseline differs from current migration history or database schema');
  }
  const pending = [];
  for (const [name, filename] of files) {
    if ((name === '0013_cron_jobs.sql' && !applied.has(name)) || (name.startsWith('seed:') && !options.seedDemoData && !applied.has(name))) continue;
    const sql = fs.readFileSync(filename, 'utf8');
    const checksum = createHash('sha256').update(sql).digest('hex');
    if (applied.has(name)) {
      if (applied.get(name) && applied.get(name) !== checksum) throw new Error(`Applied migration checksum mismatch: ${name}`);
    }
    pending.push({ name, checksum, sql: applied.has(name) ? null : transactionalSql(sql) });
  }
  return pending;
}

async function preflightProductMigrations(client, options = {}) {
  await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  try {
    await client.query("SET LOCAL statement_timeout = '120000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '180000ms'");
    const snapshot = (await client.query('SELECT pg_export_snapshot() AS snapshot')).rows[0]?.snapshot;
    if (typeof snapshot !== 'string' || !/^[0-9A-F]+-[0-9A-F]+-\d+$/i.test(snapshot)) throw new Error('Read-only baseline snapshot is unavailable');
    const exists = (await client.query("SELECT to_regclass('public.schema_migrations') IS NOT NULL AS present")).rows[0]?.present;
    // JSON extraction supports the historical ledger before its checksum column
    // is added. No DDL or ledger adoption happens during this command.
    const rows = exists ? (await client.query("SELECT filename, to_jsonb(t)->>'checksum' AS checksum FROM public.schema_migrations t")).rows : [];
    const applied = new Map(rows.map(row => [row.filename, row.checksum]));
    const files = migrationInventory(options.dbDir || path.resolve(__dirname, '..'));
    const pending = await validateProductHistory(client, files, applied, { ...options, snapshot });
    await client.query('COMMIT');
    return { applied: applied.size, legacy: rows.filter(row => !row.checksum).length, pending: pending.filter(item => item.sql !== null).length };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

function migrationInventory(dbDir) {
  const files = fs.readdirSync(path.join(dbDir, 'supabase/migrations')).filter(name => /^\d+_[A-Za-z0-9_-]+\.sql$/.test(name)).sort()
    .map(name => [name, path.join(dbDir, 'supabase/migrations', name)]);
  if (fs.existsSync(path.join(dbDir, 'seed'))) {
    for (const name of fs.readdirSync(path.join(dbDir, 'seed')).filter(name => /^\d+_[A-Za-z0-9_-]+\.sql$/.test(name)).sort()) {
      files.push([`seed:${name}`, path.join(dbDir, 'seed', name)]);
    }
  }
  return files;
}

async function legacyBaseline(client, files, names, snapshot) {
  // The v2 fingerprint combines no-ACL pg_dump definitions with a semantic
  // catalog owner/ACL inventory, avoiding provider pg_init_privs dump drift.
  if (typeof client.schemaFingerprint !== 'function') throw new Error('Schema fingerprint provider is required for baseline verification');
  let schemaSha256;
  if (snapshot) {
    schemaSha256 = await client.schemaFingerprint(snapshot);
  } else {
    // The apply path also validates legacy checksums. Hold a read-only snapshot
    // across pg_dump and catalog inspection before writing any adopted digest.
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    try {
      await client.query("SET LOCAL statement_timeout = '120000ms'");
      await client.query("SET LOCAL idle_in_transaction_session_timeout = '180000ms'");
      const exported = (await client.query('SELECT pg_export_snapshot() AS snapshot')).rows[0]?.snapshot;
      if (typeof exported !== 'string' || !/^[0-9A-F]+-[0-9A-F]+-\d+$/i.test(exported)) {
        throw new Error('Read-only baseline snapshot is unavailable');
      }
      schemaSha256 = await client.schemaFingerprint(exported);
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK').catch(() => {});
      throw error;
    }
  }
  const ledger = names.slice().sort().map(name => {
    const entry = files.find(([known]) => known === name);
    if (!entry) throw new Error(`Unknown applied product migration: ${name}`);
    return [name, createHash('sha256').update(fs.readFileSync(entry[1])).digest('hex')];
  });
  return { format: 'pandapay-reviewed-product-baseline-v2', ledger, schemaSha256 };
}

async function captureReadOnlyBaseline(client, files) {
  await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
  try {
    await client.query("SET LOCAL statement_timeout = '120000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '180000ms'");
    const snapshot = (await client.query('SELECT pg_export_snapshot() AS snapshot')).rows[0]?.snapshot;
    if (typeof snapshot !== 'string' || !/^[0-9A-F]+-[0-9A-F]+-\d+$/i.test(snapshot)) {
      throw new Error('Read-only baseline snapshot is unavailable');
    }
    const ledger = await client.query('SELECT filename FROM schema_migrations ORDER BY filename');
    const baseline = await legacyBaseline(client, files, ledger.rows.map(row => row.filename), snapshot);
    await client.query('COMMIT');
    return baseline;
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

async function main() {
  const authDir = process.env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
  const authRequire = createRequire(path.join(authDir, 'package.json'));
  const { Pool } = authRequire('pg');
  const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
  const url = process.env.ADMIN_DATABASE_URL;
  if (!url) throw new Error('ADMIN_DATABASE_URL is required');
  const connection = resolveDatabaseTls(url);
  const pool = new Pool({ ...connection, max: 1, connectionTimeoutMillis: 10000 });
  const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-migrate-'));
  let client;
  try {
    const adminUrl = new URL(connection.connectionString);
    const password = decodeURIComponent(adminUrl.password);
    adminUrl.password = '';
    const adminConnection = adminUrl.toString();
    const env = { ...process.env, PGPASSWORD: password, PGSSLMODE: connection.ssl ? 'verify-full' : 'disable' };
    if (connection.ssl) {
      const ca = connection.ssl.ca;
      if (ca) {
        env.PGSSLROOTCERT = path.join(temp, 'ca.pem');
        fs.writeFileSync(env.PGSSLROOTCERT, Array.isArray(ca) ? ca.join('\n') : ca, { mode: 0o600 });
      } else env.PGSSLROOTCERT = 'system';
    }
    const dbDir = process.env.DB_DIR || path.resolve(__dirname, '..');
    client = await pool.connect();
    client.schemaFingerprint = snapshot => {
      const args = ['--dbname', adminConnection, '--schema-only', '--no-acl', '--quote-all-identifiers', '--exclude-table=public.schema_migrations'];
      if (snapshot) args.push('--snapshot', snapshot);
      const schema = execFileSync('pg_dump', args, { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'], timeout: 120000, maxBuffer: 16 * 1024 * 1024 });
      return schemaFingerprint({ client, snapshot, dump: schema });
    };
    if (process.argv[2] === '--write-baseline') {
      if (!process.argv[3]) throw new Error('--write-baseline requires a new output path');
      const baseline = await captureReadOnlyBaseline(client, migrationInventory(dbDir));
      fs.writeFileSync(process.argv[3], JSON.stringify(baseline), { mode: 0o600, flag: 'wx' });
      console.log('Read-only schema/history baseline written; independent review is required before adoption');
      return;
    }
    const options = {
      dbDir, seedDemoData: process.env.SEED_DEMO_DATA === 'true',
      adoptLegacyChecksums: process.env.MIGRATION_ADOPT_LEGACY_CHECKSUMS === 'true',
      legacyBaselineFile: process.env.MIGRATION_LEGACY_BASELINE_FILE,
    };
    if (process.argv[2] === '--check') {
      const summary = await preflightProductMigrations(client, options);
      console.log(`Read-only product migration preflight passed; applied=${summary.applied} legacy=${summary.legacy} pending=${summary.pending}`);
      return;
    }
    if (process.argv.length > 2) throw new Error('Unknown migration command');
    await runProductMigrations(client, {
      ...options,
      log: console.log,
      runRoleSetup() {
        try { execFileSync('psql', ['--dbname', adminConnection, '-X', '-v', 'ON_ERROR_STOP=1', '-q', '-f', path.join(dbDir, 'setup_app_role.sql')], { env, stdio: 'pipe' }); }
        catch (_) { throw new Error('Application role setup failed; review privileges in the isolated migration rehearsal'); }
      },
    });
  } finally {
    client?.release(); await pool.end(); fs.rmSync(temp, { recursive: true, force: true });
  }
}
function safeMigrationDiagnostic(error) {
  const rawCode = error?.code || error?.cause?.code;
  const diagnostic = { code: typeof rawCode === 'string' && /^[0-9A-Z]{5}$/.test(rawCode) ? rawCode : 'migration_failed' };
  if (/^(?:seed:)?\d+_[A-Za-z0-9_-]{1,120}\.sql$/.test(error?.migrationFile || '')) {
    diagnostic.migration = error.migrationFile;
  }
  const message = typeof error?.message === 'string' ? error.message : '';
  const categories = [
    [/checksum mismatch|has no checksum/i, 'ledger_checksum'],
    [/legacy.*baseline|reviewed legacy baseline/i, 'legacy_baseline_review_required'],
    [/unknown.*migration|unknown.*ledger/i, 'unknown_migration_history'],
    [/role setup failed/i, 'role_setup_failed'],
    [/another.*migration|advisory lock/i, 'migration_lock_unavailable'],
  ];
  diagnostic.category = categories.find(([pattern]) => pattern.test(message))?.[1] || 'operation_failed';
  return diagnostic;
}
if (require.main === module) main().catch(error => {
  console.error('Product database migration failed:', JSON.stringify(safeMigrationDiagnostic(error)));
  process.exitCode = 1;
});
module.exports = { statements, transactionalSql, runProductMigrations, migrationInventory, legacyBaseline, captureReadOnlyBaseline, preflightProductMigrations, validateProductHistory, safeMigrationDiagnostic, main };
