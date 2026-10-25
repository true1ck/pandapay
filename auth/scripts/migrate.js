'use strict';

// This CLI deliberately does not import ../src/db or load .env. Importing it is
// safe in tests and the deployment job must pass its connection/key material
// through its own secret/configuration channel.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { safeErrorCode } = require('../src/utils/safeErrorCode');
const { configureAuthRuntimeRole, isDbAccessLoggingEnabled } = require('./runtimePermissions');
const { configureConsoleSessionLogin } = require('./consoleSessionPermissions');
const {configureAuthLifecycleLogin}=require('./authLifecyclePermissions');
const { canonicalizePhone, phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const { decryptPhoneNumber } = require('../src/utils/fieldEncryption');

const ROOT = path.join(__dirname, '..');
const MIGRATIONS_DIR = path.join(ROOT, 'db', 'migrations');
const BASELINE_FILE = path.join(ROOT, 'db', 'pandapay-auth', 'init.sql');
const DEFAULT_BATCH_SIZE = 100;
const MAX_BATCH_SIZE = 1000;
const MAX_NO_PROGRESS_PASSES = 3;
const ADVISORY_LOCK_NAMESPACE = 0x50414e44; // "PAND"
const ADVISORY_LOCK_ID = 1;
const CONTACT_PREFLIGHT_FIELDS = [
  'null_deleted_rows',
  'email_lower_duplicate_groups',
  'email_trimmed_lower_duplicate_groups',
  'phone_hash_duplicate_groups',
  'missing_phone_hash_rows',
  'malformed_phone_hash_rows',
  'orphan_phone_hash_rows',
];

function sha256(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function migrationDiagnostic(error) {
  const message = typeof error?.message === 'string' ? error.message : '';
  const countPattern = new RegExp(
    '^active contact uniqueness preflight blocked \\(count-only\\): ' +
      CONTACT_PREFLIGHT_FIELDS.map(field => `${field}=(\\d+)`).join(' ') + '$',
  );
  const counts = message.match(countPattern);
  if (counts) {
    const summary = CONTACT_PREFLIGHT_FIELDS
      .map((field, index) => `${field}=${counts[index + 1]}`)
      .join(' ');
    return `contact_uniqueness count-only ${summary}`;
  }

  if (/^(PHONE_LOOKUP_HMAC_KEY|ENCRYPTION_ENABLED|ENCRYPTION_KEY|AUTH_PHONE_HASH_BATCH_SIZE|AUTH_MIGRATION_STATEMENT_TIMEOUT_MS|AUTH_MIGRATION_DATABASE_URL|batchSize must)/.test(message)) {
    return 'configuration_or_key';
  }
  if (/^(Auth baseline|Existing auth schema)/.test(message)) return 'baseline_verification';
  if (/^(Auth migration ledger|Applied auth migration|Checksum mismatch|Cannot adopt legacy checksum|Another auth migration job)/.test(message)) {
    return 'migration_ledger_or_checksum';
  }
  if (/^(Unable to backfill|Unable to verify|Phone hash backfill|Phone hash verification)/.test(message)) {
    return 'phone_hash_backfill_or_verification';
  }
  return 'database_operation';
}

function migrationFiles(migrationsDir) {
  const names = fs.readdirSync(migrationsDir)
    .filter(file => /^\d+_[a-z0-9_-]+\.sql$/i.test(file))
    .sort();
  // Auth has no historical duplicate prefixes. Check the packaged inventory
  // before connecting or starting any schema work.
  const prefixes = new Set();
  for (const name of names) {
    const prefix = BigInt(name.split('_', 1)[0]).toString();
    if (prefixes.has(prefix)) throw new Error('Unreviewed auth migration version-prefix collision');
    prefixes.add(prefix);
  }
  return names.map(file => {
      const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
      return { file, version: file.slice(0, -'.sql'.length), sql, checksum: sha256(sql) };
    });
}

function splitMigrationPhases(files) {
  const isPostBackfill = file => Number(file.version.split('_', 1)[0]) >= 9000;
  return {
    preBackfill: files.filter(file => !isPostBackfill(file)),
    postBackfill: files.filter(isPostBackfill),
  };
}

function parseBaselineTables(sql) {
  const tables = new Map();
  const tablePattern = /CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+([a-z_][a-z0-9_]*)\s*\(([\s\S]*?)\n\);/gi;
  for (const match of sql.matchAll(tablePattern)) {
    const [, tableName, body] = match;
    const columns = [];
    for (const line of body.split('\n')) {
      const column = line.match(/^\s{4}([a-z_][a-z0-9_]*)\s+/i);
      if (column && !['constraint', 'unique', 'check', 'primary', 'foreign'].includes(column[1].toLowerCase())) {
        columns.push(column[1].toLowerCase());
      }
    }
    if (columns.length === 0) throw new Error(`Auth baseline table ${tableName} has no parsed columns`);
    tables.set(tableName.toLowerCase(), columns);
  }
  if (tables.size === 0) throw new Error('Auth baseline contains no parseable CREATE TABLE statements');
  return tables;
}

function validateMigrationConfiguration(env = process.env) {
  const hmacKey = env.PHONE_LOOKUP_HMAC_KEY;
  if (!hmacKey || Buffer.byteLength(hmacKey) < 32) {
    throw new Error('PHONE_LOOKUP_HMAC_KEY must be configured with at least 32 bytes');
  }

  // Local/test installs historically permit plaintext phone values. Keep that
  // contract only for explicit non-hosted environments; hosted/unknown modes
  // must supply the original key so encrypted legacy values can be checked.
  const encryptionEnabled = env.ENCRYPTION_ENABLED === 'true' || env.ENCRYPTION_ENABLED === '1';
  if (env.ENCRYPTION_ENABLED === 'false' && ['development', 'test'].includes(env.NODE_ENV)) return;
  if (!encryptionEnabled) throw new Error('ENCRYPTION_ENABLED must be true for auth migrations outside development/test');
  const encoded = env.ENCRYPTION_KEY;
  const decoded = typeof encoded === 'string' ? Buffer.from(encoded, 'base64') : Buffer.alloc(0);
  if (!encoded || decoded.length !== 32 || decoded.toString('base64').replace(/=+$/, '') !== encoded.replace(/=+$/, '')) {
    throw new Error('ENCRYPTION_KEY must be the valid 32-byte base64 key used for existing auth ciphertext');
  }
}

async function verifyBaseline(client, baselineSql, { allowPhoneHashColumnsMissing = false } = {}) {
  const expected = parseBaselineTables(baselineSql);
  const rows = await client.query(
    `SELECT table_name, column_name, data_type, udt_name, character_maximum_length
       FROM information_schema.columns
      WHERE table_schema = 'public'
      ORDER BY table_name, ordinal_position`,
  );
  const actual = new Map();
  for (const row of rows.rows) {
    const table = String(row.table_name).toLowerCase();
    if (!actual.has(table)) actual.set(table, new Map());
    actual.get(table).set(String(row.column_name).toLowerCase(), row);
  }

  const missing = [];
  for (const [table, columns] of expected) {
    const actualColumns = actual.get(table);
    if (!actualColumns) {
      missing.push(`${table} (table)`);
      continue;
    }
    for (const column of columns) {
      // This is the sole column introduced by the current versioned auth
      // migration. Its absence is expected until that migration runs.
      if (allowPhoneHashColumnsMissing &&
          ((table === 'users' && column === 'phone_lookup_hash') ||
           (table === 'otp_requests' && column === 'phone_lookup_hash'))) continue;
      if (!actualColumns.has(column)) missing.push(`${table}.${column}`);
    }
  }
  if (missing.length) {
    throw new Error(`Existing auth schema does not match init.sql baseline; missing ${missing.slice(0, 12).join(', ')}${missing.length > 12 ? ` and ${missing.length - 12} more` : ''}`);
  }

  // The identity UUID is shared across service and product databases. Name-only
  // checks could otherwise accept a text ID or lose referential integrity.
  const expectedUuidColumns = [
    ['users', 'id'], ['otp_requests', 'id'], ['otp_codes', 'id'], ['user_devices', 'id'],
    ['user_devices', 'user_id'], ['refresh_tokens', 'id'], ['refresh_tokens', 'user_id'],
    ['refresh_tokens', 'token_id'], ['refresh_tokens', 'rotated_from_id'],
    ['auth_audit', 'id'], ['auth_audit', 'user_id'], ['oauth_accounts', 'id'], ['oauth_accounts', 'user_id'],
  ];
  for (const [table, column] of expectedUuidColumns) {
    if (allowPhoneHashColumnsMissing && !actual.has(table)) continue;
    const row = actual.get(table)?.get(column);
    if (row && row.udt_name !== 'uuid') {
      throw new Error(`Existing auth schema has incompatible type for ${table}.${column}; expected uuid`);
    }
  }
  const keys = await client.query(
    `SELECT tc.constraint_type, tc.table_name, kcu.column_name,
            ccu.table_name AS foreign_table_name, ccu.column_name AS foreign_column_name
       FROM information_schema.table_constraints tc
       JOIN information_schema.key_column_usage kcu
         ON tc.constraint_catalog = kcu.constraint_catalog
        AND tc.constraint_schema = kcu.constraint_schema
        AND tc.constraint_name = kcu.constraint_name
        AND tc.table_name = kcu.table_name
       LEFT JOIN information_schema.constraint_column_usage ccu
         ON tc.constraint_catalog = ccu.constraint_catalog
        AND tc.constraint_schema = ccu.constraint_schema
        AND tc.constraint_name = ccu.constraint_name
      WHERE tc.constraint_schema = 'public'
        AND tc.constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY')`,
  );
  const primaryKeys = new Set(keys.rows.filter(row => row.constraint_type === 'PRIMARY KEY')
    .map(row => `${row.table_name}.${row.column_name}`));
  const foreignKeys = new Set(keys.rows.filter(row => row.constraint_type === 'FOREIGN KEY')
    .map(row => `${row.table_name}.${row.column_name}->${row.foreign_table_name}.${row.foreign_column_name}`));
  const requiredPrimaryKeys = ['users.id', 'otp_requests.id', 'otp_codes.id', 'user_devices.id', 'refresh_tokens.id', 'auth_audit.id', 'oauth_accounts.id'];
  const requiredForeignKeys = [
    'user_devices.user_id->users.id', 'refresh_tokens.user_id->users.id',
    'refresh_tokens.rotated_from_id->refresh_tokens.id', 'auth_audit.user_id->users.id',
    'oauth_accounts.user_id->users.id',
  ];
  const missingKeys = [
    ...requiredPrimaryKeys.filter(key => !primaryKeys.has(key)),
    ...requiredForeignKeys.filter(key => !foreignKeys.has(key)),
  ];
  if (missingKeys.length) {
    throw new Error(`Existing auth schema has incompatible identity constraints; missing ${missingKeys.join(', ')}`);
  }
  return { tableCount: expected.size, columnCount: [...expected.values()].reduce((n, columns) => n + columns.length, 0) };
}

async function isEmptyAuthDatabase(client) {
  const result = await client.query(
    `SELECT EXISTS (
       SELECT 1 FROM pg_class c
       JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
         AND n.nspname NOT LIKE 'pg_toast%'
         AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
         AND NOT EXISTS (SELECT 1 FROM pg_depend dep
                         WHERE dep.classid = 'pg_class'::regclass
                           AND dep.objid = c.oid AND dep.deptype = 'e')
     ) AS has_relations`,
  );
  return result.rows[0]?.has_relations !== true;
}

async function initializeEmptyDatabase(client, baselineSql) {
  await client.query('BEGIN');
  try {
    await client.query(baselineSql);
    const result = await verifyBaseline(client, baselineSql);
    await client.query('COMMIT');
    console.log(`Initialized empty auth database baseline (${result.tableCount} tables, ${result.columnCount} columns)`);
  } catch (error) {
    await client.query('ROLLBACK');
    throw error;
  }
}

async function ensureLedger(client) {
  await client.query(`
    CREATE TABLE IF NOT EXISTS auth_schema_migrations (
      version TEXT PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      checksum TEXT
    )
  `);
  // Upgrade the historical ledger shape without pretending any old version
  // has a checksum. Adoption is explicit and separately verified below.
  await client.query('ALTER TABLE auth_schema_migrations ADD COLUMN IF NOT EXISTS checksum TEXT');
}

async function verifyMigrationEffects(client, version) {
  if (version === '0001_phone_lookup_hashes') {
    const result = await client.query(
      `SELECT table_name, column_name, data_type, character_maximum_length
         FROM information_schema.columns
        WHERE table_schema = 'public'
          AND ((table_name = 'users' AND column_name = 'phone_lookup_hash')
            OR (table_name = 'otp_requests' AND column_name = 'phone_lookup_hash'))`,
    );
    const found = new Map(result.rows.map(row => [`${row.table_name}.${row.column_name}`, row]));
    if (!found.has('users.phone_lookup_hash') || !found.has('otp_requests.phone_lookup_hash') ||
        [...found.values()].some(row => row.data_type !== 'character varying' || row.character_maximum_length !== 64)) {
      throw new Error(`Cannot adopt legacy checksum for ${version}: migration columns are missing`);
    }
    const indexes = await client.query(
      `SELECT indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public'
          AND indexname IN ('idx_users_phone_lookup_hash', 'idx_otp_phone_lookup_hash_unconsumed')`,
    );
    const definitions = new Map(indexes.rows.map(row => [row.indexname, String(row.indexdef || '').toLowerCase()]));
    const userIndex = definitions.get('idx_users_phone_lookup_hash') || '';
    const otpIndex = definitions.get('idx_otp_phone_lookup_hash_unconsumed') || '';
    if (!userIndex.includes('on public.users using btree (phone_lookup_hash)') ||
        !userIndex.includes('where (phone_lookup_hash is not null)') ||
        !otpIndex.includes('on public.otp_requests using btree (phone_lookup_hash, created_at desc)') ||
        !otpIndex.includes('phone_lookup_hash is not null') ||
        !otpIndex.includes('deleted = false') ||
        !otpIndex.includes('consumed_at is null')) {
      throw new Error(`Cannot adopt legacy checksum for ${version}: migration indexes are missing`);
    }
    return;
  }
  throw new Error(`Cannot adopt legacy checksum for unknown migration ${version}`);
}

async function validateMigrationLedger(client, files, { adoptLegacyChecksums = false } = {}) {
  const knownVersions = new Set(files.map(file => file.version));
  const ledger = await client.query('SELECT version, checksum FROM auth_schema_migrations ORDER BY version');
  for (const row of ledger.rows) {
    if (!knownVersions.has(row.version)) {
      throw new Error(`Auth migration ledger contains unknown version ${row.version}; preserve and reconcile it before continuing`);
    }
  }

  const adoptions = [];
  for (const migration of files) {
    const existing = ledger.rows.find(row => row.version === migration.version);
    if (!existing) continue;
    if (existing.checksum && existing.checksum !== migration.checksum) {
      throw new Error(`Checksum mismatch for applied auth migration ${migration.version}`);
    }
    if (!existing.checksum) {
      // Only 0001 predates checksummed auth migrations and has a reviewed
      // effects-verification path. New migrations must never be adopted from
      // a checksum-less ledger row, even if their schema effects look present.
      if (migration.version !== '0001_phone_lookup_hashes') {
        throw new Error(`Applied auth migration ${migration.version} has no checksum; only the reviewed legacy 0001 migration can be adopted`);
      }
      if (!adoptLegacyChecksums) {
        throw new Error(`Applied auth migration ${migration.version} has no checksum; verify its effects, then rerun with AUTH_MIGRATION_ADOPT_LEGACY_CHECKSUMS=true`);
      }
      await verifyMigrationEffects(client, migration.version);
      adoptions.push(migration);
    }
  }

  // Only update checksum-less historical entries after validating every
  // version and checksum across both migration phases.
  for (const migration of adoptions) {
    await client.query(
      'UPDATE auth_schema_migrations SET checksum = $1 WHERE version = $2 AND checksum IS NULL',
      [migration.checksum, migration.version],
    );
    console.log(`Adopted reviewed checksum for existing auth migration ${migration.version}`);
  }
}

async function applyMigrationBatch(client, files) {
  const ledger = await client.query('SELECT version, checksum FROM auth_schema_migrations ORDER BY version');
  for (const migration of files) {
    const existing = ledger.rows.find(row => row.version === migration.version);
    if (existing) {
      if (!existing.checksum) throw new Error(`Auth migration ${migration.version} checksum was not validated before application`);
      if (existing.checksum !== migration.checksum) throw new Error(`Checksum mismatch for applied auth migration ${migration.version}`);
      continue;
    }
    await client.query('BEGIN');
    try {
      await client.query(migration.sql);
      await client.query(
        'INSERT INTO auth_schema_migrations (version, checksum) VALUES ($1, $2)',
        [migration.version, migration.checksum],
      );
      await client.query('COMMIT');
    } catch (error) {
      await client.query('ROLLBACK');
      throw error;
    }
    console.log(`Applied auth migration ${migration.version}`);
  }
}

async function applyMigrations(client, files, options = {}) {
  await validateMigrationLedger(client, files, options);
  await applyMigrationBatch(client, files);
}

function boundedBatchSize(value = process.env.AUTH_PHONE_HASH_BATCH_SIZE) {
  const parsed = value === undefined ? DEFAULT_BATCH_SIZE : Number(value);
  if (!Number.isInteger(parsed) || parsed < 1 || parsed > MAX_BATCH_SIZE) {
    throw new Error(`AUTH_PHONE_HASH_BATCH_SIZE must be an integer from 1 to ${MAX_BATCH_SIZE}`);
  }
  return parsed;
}

async function remainingPhoneHashes(client, table) {
  const result = await client.query(
    `SELECT COUNT(*)::bigint AS remaining
       FROM ${table}
      WHERE phone_number IS NOT NULL AND phone_lookup_hash IS NULL`,
  );
  return Number(result.rows[0]?.remaining || 0);
}

async function backfillTablePhoneHashes(client, table, { batchSize, onProgress }) {
  let updatedTotal = 0;
  let racedTotal = 0;
  let noProgressPasses = 0;
  let remaining = await remainingPhoneHashes(client, table);

  while (remaining > 0) {
    let cursor = null;
    let updatedInPass = 0;
    let scannedInPass = 0;

    while (true) {
      const batch = await client.query(
        `SELECT id, phone_number FROM ${table}
          WHERE phone_number IS NOT NULL AND phone_lookup_hash IS NULL
            AND ($1::uuid IS NULL OR id > $1::uuid)
          ORDER BY id
          LIMIT $2`,
        [cursor, batchSize],
      );
      if (batch.rows.length === 0) break;

      for (const row of batch.rows) {
        cursor = row.id;
        scannedInPass += 1;
        let digest;
        try {
          digest = phoneLookupHash(canonicalizePhone(decryptPhoneNumber(row.phone_number)));
        } catch (_) {
          throw new Error(`Unable to backfill ${table} phone hashes; verify the encryption and lookup keys and resolve invalid legacy contacts`);
        }
        const result = await client.query(
          `UPDATE ${table} SET phone_lookup_hash = $1
            WHERE id = $2 AND phone_lookup_hash IS NULL
              AND phone_number IS NOT DISTINCT FROM $3
          RETURNING id`,
          [digest, row.id, row.phone_number],
        );
        if (result.rows.length === 1) {
          updatedInPass += 1;
          updatedTotal += 1;
        } else {
          // The contact or index changed after selection. Restart from the
          // beginning after this pass; never attach a stale digest.
          racedTotal += 1;
        }
      }

      remaining = await remainingPhoneHashes(client, table);
      if (typeof onProgress === 'function') {
        onProgress({ table, scanned: scannedInPass, updated: updatedTotal, raced: racedTotal, remaining });
      }
    }

    remaining = await remainingPhoneHashes(client, table);
    if (remaining > 0 && updatedInPass === 0) {
      noProgressPasses += 1;
      if (noProgressPasses >= MAX_NO_PROGRESS_PASSES) {
        throw new Error(`Phone hash backfill for ${table} made no progress with ${remaining} rows remaining; check concurrent writers or legacy data`);
      }
    } else {
      noProgressPasses = 0;
    }
  }

  return { table, updated: updatedTotal, raced: racedTotal, remaining };
}

async function backfillPhoneLookupHashes(client, {
  batchSize = boundedBatchSize(),
  onProgress = progress => console.log(`Phone hash backfill ${progress.table}: scanned=${progress.scanned} updated=${progress.updated} raced=${progress.raced} remaining=${progress.remaining}`),
} = {}) {
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > MAX_BATCH_SIZE) {
    throw new Error(`batchSize must be an integer from 1 to ${MAX_BATCH_SIZE}`);
  }
  const results = [];
  for (const table of ['users', 'otp_requests']) {
    results.push(await backfillTablePhoneHashes(client, table, { batchSize, onProgress }));
  }
  return results;
}

async function verifyPhoneLookupHashes(client, {
  batchSize = boundedBatchSize(),
  allowMissing = false,
  onProgress = progress => console.log(`Phone hash verification ${progress.table}: checked=${progress.checked} matched=${progress.matched}`),
} = {}) {
  if (!Number.isInteger(batchSize) || batchSize < 1 || batchSize > MAX_BATCH_SIZE) {
    throw new Error(`batchSize must be an integer from 1 to ${MAX_BATCH_SIZE}`);
  }
  const results = [];
  for (const table of ['users', 'otp_requests']) {
    let cursor = null;
    let checked = 0;
    let matched = 0;
    while (true) {
      const batch = await client.query(
        `SELECT id, phone_number, phone_lookup_hash FROM ${table}
          WHERE ($1::uuid IS NULL OR id > $1::uuid)
          ORDER BY id
          LIMIT $2`,
        [cursor, batchSize],
      );
      if (batch.rows.length === 0) break;
      for (const row of batch.rows) {
        cursor = row.id;
        checked += 1;
        if (row.phone_number === null) {
          if (row.phone_lookup_hash !== null) {
            throw new Error(`Phone hash verification found a digest without a phone in ${table}; resolve the inconsistent row before continuing`);
          }
          matched += 1;
          continue;
        }
        let expected;
        try {
          expected = phoneLookupHash(canonicalizePhone(decryptPhoneNumber(row.phone_number)));
        } catch (_) {
          throw new Error(`Unable to verify ${table} phone hashes; verify the encryption and lookup keys and resolve invalid legacy contacts`);
        }
        if (allowMissing && !row.phone_lookup_hash) continue;
        if (!row.phone_lookup_hash || row.phone_lookup_hash !== expected) {
          throw new Error(`Phone hash verification failed for ${table}; verify the stable lookup key and repair the affected records before continuing`);
        }
        matched += 1;
      }
      if (typeof onProgress === 'function') {
      onProgress({ table, checked, matched });
      }
    }
    results.push({ table, checked, matched });
  }
  return results;
}

async function runMigrations(pool, {
  migrationsDir = MIGRATIONS_DIR,
  baselineFile = BASELINE_FILE,
  env = process.env,
  adoptLegacyChecksums = env.AUTH_MIGRATION_ADOPT_LEGACY_CHECKSUMS === 'true' ||
    env.MIGRATION_ADOPT_LEGACY_CHECKSUMS === 'true',
  batchSize = boundedBatchSize(env.AUTH_PHONE_HASH_BATCH_SIZE),
  onProgress,
  beforePostBackfill,
} = {}) {
  validateMigrationConfiguration(env);
  const baselineSql = fs.readFileSync(baselineFile, 'utf8');
  // Parse before connecting so a damaged/mispackaged baseline cannot mutate a DB.
  parseBaselineTables(baselineSql);
  const files = migrationFiles(migrationsDir);
  const client = await pool.connect();
  let lockAcquired = false;
  try {
    const timeoutMs = Number(env.AUTH_MIGRATION_STATEMENT_TIMEOUT_MS || 15000);
    if (!Number.isInteger(timeoutMs) || timeoutMs < 1000 || timeoutMs > 300000) {
      throw new Error('AUTH_MIGRATION_STATEMENT_TIMEOUT_MS must be an integer from 1000 to 300000');
    }
    await client.query(`SET statement_timeout = '${timeoutMs}ms'`);
    await client.query("SET lock_timeout = '5s'");
    const lock = await client.query('SELECT pg_try_advisory_lock($1, $2) AS locked', [
      ADVISORY_LOCK_NAMESPACE,
      ADVISORY_LOCK_ID,
    ]);
    lockAcquired = lock.rows[0]?.locked === true;
    if (!lockAcquired) throw new Error('Another auth migration job holds the migration advisory lock');

    if (await isEmptyAuthDatabase(client)) {
      await initializeEmptyDatabase(client, baselineSql);
    } else {
      await verifyBaseline(client, baselineSql, { allowPhoneHashColumnsMissing: true });
      console.log('Verified existing auth schema against init.sql baseline');
    }

    await ensureLedger(client);
    // Validate the complete ledger before either migration phase mutates it.
    // Versions 9000+ are reserved for migrations that must run after the
    // keyed phone-hash verification/backfill phase.
    await validateMigrationLedger(client, files, { adoptLegacyChecksums });
    const { preBackfill, postBackfill } = splitMigrationPhases(files);
    await applyMigrationBatch(client, preBackfill);
    await verifyBaseline(client, baselineSql);
    // Detect wrong existing lookup keys before writing any missing hashes.
    await verifyPhoneLookupHashes(client, { batchSize, allowMissing: true });
    await backfillPhoneLookupHashes(client, { batchSize, onProgress });
    await verifyPhoneLookupHashes(client, { batchSize });
    if (postBackfill.length > 0 && typeof beforePostBackfill === 'function') {
      await beforePostBackfill(client);
    }
    await applyMigrationBatch(client, postBackfill);
    await configureAuthRuntimeRole(client, { files, runtimeRole: env.AUTH_RUNTIME_ROLE,
      dbAccessLoggingEnabled: isDbAccessLoggingEnabled(env),
      securityDashboardEnabled: ['true', '1'].includes(env.ENABLE_ADMIN_DASHBOARD) });
    await configureConsoleSessionLogin(client, env);
    await configureAuthLifecycleLogin(client, env);
    console.log('Auth migrations and phone hash backfill complete');
  } finally {
    let discardConnection = false;
    if (lockAcquired) {
      try {
        await client.query('SELECT pg_advisory_unlock($1, $2)', [ADVISORY_LOCK_NAMESPACE, ADVISORY_LOCK_ID]);
      } catch (error) {
        discardConnection = true;
        console.error(`Could not confirm auth migration lock release (${safeErrorCode(error)}); closing connection releases the session lock`);
      }
    }
    client.release(discardConnection);
  }
}

async function main() {
  const connectionString = process.env.AUTH_MIGRATION_DATABASE_URL || process.env.AUTH_DATABASE_URL;
  if (!connectionString) throw new Error('AUTH_MIGRATION_DATABASE_URL (or AUTH_DATABASE_URL for compatibility) must be set');
  // Lazy load the driver and pool only for CLI execution. No database is
  // contacted by importing this module or by calling the helpers with fakes.
  const { Pool } = require('pg');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const tls = resolveDatabaseTls(connectionString, process.env);
  const pool = new Pool({ ...tls, max: 1, connectionTimeoutMillis: 5000 });
  try {
    await runMigrations(pool);
  } finally {
    await pool.end();
  }
}

if (require.main === module) {
  main().catch(error => {
    console.error(`Auth database migration failed [${safeErrorCode(error)}]: ${migrationDiagnostic(error)}`);
    process.exitCode = 1;
  });
}

module.exports = {
  applyMigrations,
  backfillPhoneLookupHashes,
  boundedBatchSize,
  initializeEmptyDatabase,
  isEmptyAuthDatabase,
  main,
  migrationFiles,
  migrationDiagnostic,
  splitMigrationPhases,
  parseBaselineTables,
  runMigrations,
  validateMigrationConfiguration,
  verifyBaseline,
  verifyPhoneLookupHashes,
  validateMigrationLedger,
};
