const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const Module = require('node:module');

process.env.NODE_ENV = 'test';
process.env.PHONE_LOOKUP_HMAC_KEY = 'test-phone-lookup-hmac-key-0123456789abcdef';
process.env.ENCRYPTION_ENABLED = 'true';
process.env.ENCRYPTION_KEY = Buffer.alloc(32, 7).toString('base64');

test('only explicit local plaintext mode can migrate without an encryption key', () => {
  const { validateMigrationConfiguration } = loadRunner();
  const local = { NODE_ENV: 'development', ENCRYPTION_ENABLED: 'false', PHONE_LOOKUP_HMAC_KEY: process.env.PHONE_LOOKUP_HMAC_KEY };
  assert.doesNotThrow(() => validateMigrationConfiguration(local));
  assert.throws(() => validateMigrationConfiguration({ ...local, NODE_ENV: 'production' }), /must be true/);
  assert.throws(() => validateMigrationConfiguration({ ...local, ENCRYPTION_ENABLED: 'typo' }), /must be true/);
});

function loadRunner(dependencies = {}) {
  const filename = path.resolve(__dirname, '../scripts/migrate.js');
  const loaded = new Module(filename, module);
  loaded.filename = filename;
  loaded.paths = Module._nodeModulePaths(path.dirname(filename));
  loaded.require = request => Object.hasOwn(dependencies, request)
    ? dependencies[request] : Module.prototype.require.call(loaded, request);
  loaded._compile(fs.readFileSync(filename, 'utf8'), filename);
  return loaded.exports;
}

test('migration diagnostics redact arbitrary database messages and details', () => {
  const { migrationDiagnostic } = loadRunner();
  const secret = 'contact=+919876543210 email=private@example.test token=credential-value';
  const diagnostic = migrationDiagnostic(Object.assign(new Error(secret), {
    code: 'NOT_A_SAFE_CODE+CONTACT',
    detail: secret,
    cause: new Error(secret),
  }));
  assert.equal(diagnostic, 'database_operation');
  assert.doesNotMatch(diagnostic, /\+91|@example|credential-value|contact=/);
});

test('migration diagnostics expose only exact allowlisted contact preflight counters', () => {
  const { migrationDiagnostic } = loadRunner();
  const counts = 'null_deleted_rows=0 email_lower_duplicate_groups=0 email_trimmed_lower_duplicate_groups=0 phone_hash_duplicate_groups=2 missing_phone_hash_rows=0 malformed_phone_hash_rows=0 orphan_phone_hash_rows=0';
  const diagnostic = migrationDiagnostic(new Error(`active contact uniqueness preflight blocked (count-only): ${counts}`));
  assert.equal(diagnostic, `contact_uniqueness count-only ${counts}`);
  const malformed = migrationDiagnostic(new Error(`active contact uniqueness preflight blocked (count-only): ${counts} phone=+919876543210`));
  assert.equal(malformed, 'database_operation');
  assert.doesNotMatch(malformed, /\+91|phone=/);
});

function makeFakeDb({ baselineSql, migrationSql, initialTables = new Map(), records = {}, columnOverrides = {}, omitIdentityConstraints = false, contactConflictCounts = {} }) {
  const tables = new Map([...initialTables].map(([name, cols]) => [name, new Set(cols)]));
  const indexes = new Set();
  const ledger = new Map();
  const events = [];
  let advisoryHeld = false;
  let released = false;

  const client = {
    async query(sql, args = []) {
      const statement = String(sql).trim();
      events.push({ sql: statement, args });
      if (statement.startsWith('SET statement_timeout') || statement.startsWith('SET lock_timeout')) return { rows: [] };
      if (statement.includes("SELECT 'before-post-backfill'")) return { rows: [{ marker: 'before-post-backfill' }] };
      if (statement.includes('pg_try_advisory_lock')) {
        if (advisoryHeld) return { rows: [{ locked: false }] };
        advisoryHeld = true;
        return { rows: [{ locked: true }] };
      }
      if (statement.includes('pg_advisory_unlock')) {
        advisoryHeld = false;
        return { rows: [{ pg_advisory_unlock: true }] };
      }
      if (statement.includes('SELECT EXISTS') && statement.includes('FROM pg_class')) {
        return { rows: [{ has_relations: tables.size > 0 || ledger.size > 0 }] };
      }
      if (statement.includes('FROM information_schema.columns')) {
        const rows = [];
        for (const [table_name, columns] of tables) {
          for (const column_name of columns) rows.push({
            table_name, column_name,
            data_type: columnOverrides[`${table_name}.${column_name}`] || (column_name === 'id' || column_name.endsWith('_id') ? 'uuid' : 'text'),
            udt_name: columnOverrides[`${table_name}.${column_name}`] || (column_name === 'id' || column_name.endsWith('_id') ? 'uuid' : 'text'),
            character_maximum_length: null,
          });
        }
        if (statement.includes("column_name = 'phone_lookup_hash'")) {
          return { rows: rows.filter(row => row.column_name === 'phone_lookup_hash').map(row => ({
            ...row, data_type: 'character varying', character_maximum_length: 64,
          })) };
        }
        return { rows };
      }
      if (statement.includes('FROM information_schema.table_constraints')) {
        if (omitIdentityConstraints) return { rows: [] };
        const rows = [];
        for (const table_name of ['users', 'otp_requests', 'otp_codes', 'user_devices', 'refresh_tokens', 'auth_audit', 'oauth_accounts']) {
          if (tables.has(table_name)) rows.push({ constraint_type: 'PRIMARY KEY', table_name, column_name: 'id' });
        }
        for (const [table_name, column_name, foreign_table_name, foreign_column_name] of [
          ['user_devices', 'user_id', 'users', 'id'],
          ['refresh_tokens', 'user_id', 'users', 'id'],
          ['refresh_tokens', 'rotated_from_id', 'refresh_tokens', 'id'],
          ['auth_audit', 'user_id', 'users', 'id'],
          ['oauth_accounts', 'user_id', 'users', 'id'],
        ]) {
          if (tables.has(table_name)) rows.push({ constraint_type: 'FOREIGN KEY', table_name, column_name, foreign_table_name, foreign_column_name });
        }
        return { rows };
      }
      if (statement.includes('FROM pg_indexes')) {
        const definitions = {
          idx_users_phone_lookup_hash: 'CREATE INDEX idx_users_phone_lookup_hash ON public.users USING btree (phone_lookup_hash) WHERE (phone_lookup_hash IS NOT NULL)',
          idx_otp_phone_lookup_hash_unconsumed: 'CREATE INDEX idx_otp_phone_lookup_hash_unconsumed ON public.otp_requests USING btree (phone_lookup_hash, created_at DESC) WHERE ((phone_lookup_hash IS NOT NULL) AND (deleted = false) AND (consumed_at IS NULL))',
          uq_users_active_email_lower: 'CREATE UNIQUE INDEX uq_users_active_email_lower ON public.users USING btree (lower(email)) WHERE ((deleted = false) AND (email IS NOT NULL))',
          uq_users_active_phone_lookup_hash: 'CREATE UNIQUE INDEX uq_users_active_phone_lookup_hash ON public.users USING btree (phone_lookup_hash) WHERE ((deleted = false) AND (phone_lookup_hash IS NOT NULL))',
        };
        return { rows: [...indexes].filter(indexname => definitions[indexname]).map(indexname => ({
          indexname, indexdef: definitions[indexname],
        })) };
      }
      if (statement.startsWith('CREATE TABLE IF NOT EXISTS auth_schema_migrations')) return { rows: [] };
      if (statement.startsWith('ALTER TABLE auth_schema_migrations')) return { rows: [] };
      if (statement === 'BEGIN' || statement === 'COMMIT' || statement === 'ROLLBACK') return { rows: [] };
      if (statement === baselineSql.trim()) {
        const expected = loadRunner().parseBaselineTables(baselineSql);
        for (const [table, cols] of expected) tables.set(table, new Set(cols));
        indexes.add('idx_users_phone_lookup_hash');
        indexes.add('idx_otp_phone_lookup_hash_unconsumed');
        return { rows: [] };
      }
      if (statement.includes('ALTER TABLE users') && statement.includes('phone_lookup_hash')) {
        tables.get('users')?.add('phone_lookup_hash');
        tables.get('otp_requests')?.add('phone_lookup_hash');
        indexes.add('idx_users_phone_lookup_hash');
        indexes.add('idx_otp_phone_lookup_hash_unconsumed');
        return { rows: [] };
      }
      if (statement.includes('ALTER TABLE otp_requests') && statement.includes('purpose')) {
        tables.get('otp_requests')?.add('purpose');
        return { rows: [] };
      }
      if (statement.includes('CREATE TABLE contact_resolution_history')) {
        tables.set('contact_resolution_history', new Set([
          'id', 'resolution_id', 'user_id', 'retained_phone_account_id',
          'original_row_age', 'archive_sha256', 'reason', 'created_at',
        ]));
        return { rows: [] };
      }
      if (statement.includes('active_contact_uniqueness_preflight')) {
        if (Object.values(contactConflictCounts).some(value => value > 0)) {
          throw new Error(`active contact uniqueness preflight blocked (count-only): ${JSON.stringify(contactConflictCounts)}`);
        }
        indexes.add('uq_users_active_email_lower');
        indexes.add('uq_users_active_phone_lookup_hash');
        return { rows: [] };
      }
      if (statement.startsWith('SELECT version, checksum FROM auth_schema_migrations')) {
        return { rows: [...ledger].map(([version, checksum]) => ({ version, checksum })) };
      }
      if (statement.startsWith('INSERT INTO auth_schema_migrations')) {
        ledger.set(args[0], args[1]);
        return { rows: [] };
      }
      if (statement.startsWith('UPDATE auth_schema_migrations SET checksum')) {
        if (ledger.get(args[1]) === null) ledger.set(args[1], args[0]);
        return { rows: [] };
      }
      const count = statement.match(/SELECT COUNT\(\*\)::bigint AS remaining[\s\S]*?FROM (users|otp_requests)/i);
      if (count) {
        const remaining = (records[count[1]] || []).filter(row => row.phone_number !== null && row.phone_lookup_hash === null).length;
        return { rows: [{ remaining }] };
      }
      const selectBatch = statement.match(/^SELECT id, phone_number FROM (users|otp_requests)/i);
      if (selectBatch) {
        const table = selectBatch[1];
        const cursor = args[0];
        const limit = args[1];
        const rows = (records[table] || [])
          .filter(row => row.phone_number !== null && row.phone_lookup_hash === null && (!cursor || row.id > cursor))
          .sort((a, b) => a.id.localeCompare(b.id))
          .slice(0, limit)
          .map(({ id, phone_number }) => ({ id, phone_number }));
        return { rows };
      }
      const verifyBatch = statement.match(/^SELECT id, phone_number, phone_lookup_hash FROM (users|otp_requests)/i);
      if (verifyBatch) {
        const table = verifyBatch[1];
        const cursor = args[0];
        return {
          rows: (records[table] || [])
            .filter(row => !cursor || row.id > cursor)
            .sort((a, b) => a.id.localeCompare(b.id))
            .slice(0, args[1])
            .map(({ id, phone_number, phone_lookup_hash }) => ({ id, phone_number, phone_lookup_hash })),
        };
      }
      const updateHash = statement.match(/^UPDATE (users|otp_requests) SET phone_lookup_hash/i);
      if (updateHash) {
        const row = (records[updateHash[1]] || []).find(item => item.id === args[1]);
        if (row && row.phone_lookup_hash === null && row.phone_number === args[2]) {
          row.phone_lookup_hash = args[0];
          return { rows: [{ id: row.id }] };
        }
        return { rows: [] };
      }
      throw new Error(`Unexpected SQL in fake DB: ${statement.slice(0, 100)}`);
    },
    release() { released = true; },
  };
  return {
    client,
    pool: { async connect() { return client; } },
    tables,
    indexes,
    ledger,
    events,
    records,
    get advisoryHeld() { return advisoryHeld; },
    get released() { return released; },
  };
}

function setupMigrationFixture({ includePostBackfill = false } = {}) {
  const root = path.resolve(__dirname, '..');
  const baselineFile = path.join(root, 'db/pandapay-auth/init.sql');
  const migrationsDir = fs.mkdtempSync(path.join(os.tmpdir(), 'pandapay-auth-migrations-'));
  const migrationSql = fs.readFileSync(path.join(root, 'db/migrations/0001_phone_lookup_hashes.sql'), 'utf8');
  fs.writeFileSync(path.join(migrationsDir, '0001_phone_lookup_hashes.sql'), migrationSql);
  if (includePostBackfill) {
    for (const name of ['0002_otp_purpose_binding.sql', '0003_contact_resolution_history.sql', '9001_active_contact_uniqueness.sql']) {
      fs.copyFileSync(path.join(root, 'db/migrations', name), path.join(migrationsDir, name));
    }
  }
  return {
    baselineFile,
    baselineSql: fs.readFileSync(baselineFile, 'utf8'),
    migrationsDir,
    migrationSql,
    cleanup: () => fs.rmSync(migrationsDir, { recursive: true, force: true }),
  };
}

function migrationEnv(overrides = {}) {
  return {
    PHONE_LOOKUP_HMAC_KEY: process.env.PHONE_LOOKUP_HMAC_KEY,
    ENCRYPTION_ENABLED: 'true',
    ENCRYPTION_KEY: Buffer.alloc(32, 7).toString('base64'),
    AUTH_MIGRATION_STATEMENT_TIMEOUT_MS: '5000',
    ...overrides,
  };
}

test('importing migration CLI does not import DB startup module or connect', () => {
  let dbModuleImported = false;
  const dependencies = {};
  Object.defineProperty(dependencies, '../src/db', {
    get() { dbModuleImported = true; return {}; },
  });
  const runner = loadRunner(dependencies);
  assert.equal(typeof runner.main, 'function');
  assert.equal(dbModuleImported, false);
});

test('empty auth database bootstraps validated baseline, checksums migration, and resumes bounded hash backfill', async () => {
  const fixture = setupMigrationFixture();
  try {
    const runner = loadRunner();
    const records = {
      users: [
        { id: '00000000-0000-4000-8000-000000000001', phone_number: '+919876543210', phone_lookup_hash: null },
        { id: '00000000-0000-4000-8000-000000000002', phone_number: '+918765432109', phone_lookup_hash: null },
      ],
      otp_requests: [
        { id: '00000000-0000-4000-8000-000000000003', phone_number: '+917654321098', phone_lookup_hash: null },
      ],
    };
    const fake = makeFakeDb({ ...fixture, records });
    const progress = [];
    await runner.runMigrations(fake.pool, {
      ...fixture,
      env: migrationEnv(),
      batchSize: 1,
      onProgress: entry => progress.push(entry),
    });

    assert.equal(fake.ledger.size, 1);
    const expectedChecksum = crypto.createHash('sha256').update(fixture.migrationSql).digest('hex');
    assert.equal(fake.ledger.get('0001_phone_lookup_hashes'), expectedChecksum);
    assert.equal(records.users.every(row => row.phone_lookup_hash), true);
    assert.equal(records.otp_requests.every(row => row.phone_lookup_hash), true);
    assert.ok(fake.events.some(event => event.sql === 'BEGIN'));
    assert.equal(fake.advisoryHeld, false);
    assert.equal(fake.released, true);
    assert.ok(progress.length >= 3);
    assert.ok(progress.every(({ table, scanned, updated, raced, remaining }) =>
      ['users', 'otp_requests'].includes(table) && [scanned, updated, raced, remaining].every(Number.isFinite)));

    // Re-run is safe and has no rows to backfill or unapplied migration.
    const again = makeFakeDb({ ...fixture, initialTables: fake.tables, records, });
    for (const [version, checksum] of fake.ledger) again.ledger.set(version, checksum);
    await runner.runMigrations(again.pool, { ...fixture, env: migrationEnv(), onProgress: () => {} });
    assert.equal(again.ledger.size, 1);
  } finally {
    fixture.cleanup();
  }
});

test('post-backfill migrations run only after full phone hash verification', async () => {
  const fixture = setupMigrationFixture({ includePostBackfill: true });
  try {
    const runner = loadRunner();
    const records = {
      users: [{ id: '00000000-0000-4000-8000-000000000011', phone_number: '+919876543210', phone_lookup_hash: null }],
      otp_requests: [],
    };
    const fake = makeFakeDb({ ...fixture, records });
    await runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv(), onProgress: () => {} });

    assert.deepEqual(runner.splitMigrationPhases(runner.migrationFiles(fixture.migrationsDir)).preBackfill.map(file => file.version), [
      '0001_phone_lookup_hashes', '0002_otp_purpose_binding', '0003_contact_resolution_history',
    ]);
    assert.deepEqual(runner.splitMigrationPhases(runner.migrationFiles(fixture.migrationsDir)).postBackfill.map(file => file.version), [
      '9001_active_contact_uniqueness',
    ]);
    assert.ok(records.users[0].phone_lookup_hash);
    assert.ok(fake.indexes.has('uq_users_active_email_lower'));
    assert.ok(fake.indexes.has('uq_users_active_phone_lookup_hash'));
    assert.equal(fake.ledger.size, 4);

    const appliedUniquePhase = fake.events.findIndex(event => event.sql.includes('active_contact_uniqueness_preflight'));
    const finalPhoneVerification = fake.events.map((event, index) => ({ event, index }))
      .filter(item => item.event.sql.startsWith('SELECT id, phone_number, phone_lookup_hash FROM'))
      .at(-1)?.index;
    assert.ok(Number.isInteger(finalPhoneVerification));
    assert.ok(appliedUniquePhase > finalPhoneVerification);
  } finally {
    fixture.cleanup();
  }
});

test('approved conflict resolution callback runs under the migration client after hash verification and before 9001', async () => {
  const fixture = setupMigrationFixture({ includePostBackfill: true });
  try {
    const runner = loadRunner();
    const records = {
      users: [{ id: '00000000-0000-4000-8000-000000000051', phone_number: '+919876543210', phone_lookup_hash: null }],
      otp_requests: [],
    };
    const fake = makeFakeDb({ ...fixture, records });
    let callbackClient;
    await runner.runMigrations(fake.pool, {
      ...fixture,
      env: migrationEnv(),
      onProgress: () => {},
      beforePostBackfill: async client => {
        callbackClient = client;
        assert.ok(records.users[0].phone_lookup_hash);
        assert.equal(fake.ledger.has('9001_active_contact_uniqueness'), false);
        await client.query("SELECT 'before-post-backfill' AS marker");
      },
    });
    assert.equal(callbackClient, fake.client);
    const callbackBoundary = fake.events.findIndex(event => event.sql.includes("SELECT 'before-post-backfill'"));
    const uniqueMigrationBoundary = fake.events.findIndex(event => event.sql.includes('active_contact_uniqueness_preflight'));
    assert.ok(callbackBoundary >= 0 && uniqueMigrationBoundary > callbackBoundary);
    assert.ok(fake.ledger.has('9001_active_contact_uniqueness'));
  } finally {
    fixture.cleanup();
  }
});

test('post-backfill contact preflight rejects conflicts without recording 9001 or creating indexes', async () => {
  const fixture = setupMigrationFixture({ includePostBackfill: true });
  try {
    const runner = loadRunner();
    const records = {
      users: [{ id: '00000000-0000-4000-8000-000000000021', phone_number: '+919876543210', phone_lookup_hash: null }],
      otp_requests: [],
    };
    const fake = makeFakeDb({
      ...fixture,
      records,
      contactConflictCounts: { phone_hash_duplicate_groups: 2 },
    });
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv(), onProgress: () => {} }),
      error => {
        assert.match(error.message, /phone_hash_duplicate_groups/);
        assert.match(error.message, /2/);
        assert.doesNotMatch(error.message, /\+919876543210/);
        assert.doesNotMatch(error.message, /00000000-0000/);
        return true;
      },
    );
    assert.ok(records.users[0].phone_lookup_hash, 'hash backfill completes before unique preflight');
    assert.equal(fake.ledger.has('9001_active_contact_uniqueness'), false);
    assert.equal(fake.indexes.has('uq_users_active_email_lower'), false);
    assert.equal(fake.indexes.has('uq_users_active_phone_lookup_hash'), false);
  } finally {
    fixture.cleanup();
  }
});

test('post-backfill checksum drift is detected before regular migration or backfill writes', async () => {
  const fixture = setupMigrationFixture({ includePostBackfill: true });
  try {
    const runner = loadRunner();
    const initialTables = runner.parseBaselineTables(fixture.baselineSql);
    const records = {
      users: [{ id: '00000000-0000-4000-8000-000000000031', phone_number: '+919876543210', phone_lookup_hash: null }],
      otp_requests: [],
    };
    const fake = makeFakeDb({ ...fixture, initialTables, records });
    fake.ledger.set('9001_active_contact_uniqueness', '0'.repeat(64));
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv(), onProgress: () => {} }),
      /Checksum mismatch for applied auth migration 9001_active_contact_uniqueness/,
    );
    assert.equal(records.users[0].phone_lookup_hash, null);
    assert.equal(fake.events.some(event => event.sql.startsWith('UPDATE users SET phone_lookup_hash')), false);
    assert.equal(fake.events.some(event => event.sql === 'BEGIN'), false);
  } finally {
    fixture.cleanup();
  }
});

test('checksum-less post-backfill migration cannot use legacy checksum adoption', async () => {
  const fixture = setupMigrationFixture({ includePostBackfill: true });
  try {
    const runner = loadRunner();
    const initialTables = runner.parseBaselineTables(fixture.baselineSql);
    const records = {
      users: [{ id: '00000000-0000-4000-8000-000000000041', phone_number: '+919876543210', phone_lookup_hash: null }],
      otp_requests: [],
    };
    const fake = makeFakeDb({ ...fixture, initialTables, records });
    fake.ledger.set('9001_active_contact_uniqueness', null);
    await assert.rejects(
      runner.runMigrations(fake.pool, {
        ...fixture,
        env: migrationEnv({ AUTH_MIGRATION_ADOPT_LEGACY_CHECKSUMS: 'true' }),
      }),
      /only the reviewed legacy 0001 migration can be adopted/,
    );
    assert.equal(records.users[0].phone_lookup_hash, null);
    assert.equal(fake.ledger.get('9001_active_contact_uniqueness'), null);
    assert.equal(fake.events.some(event => event.sql.startsWith('UPDATE users SET phone_lookup_hash')), false);
    assert.equal(fake.events.some(event => event.sql === 'BEGIN'), false);
  } finally {
    fixture.cleanup();
  }
});

test('existing partial schema is rejected before creating a migration ledger', async () => {
  const fixture = setupMigrationFixture();
  try {
    const runner = loadRunner();
    const fake = makeFakeDb({
      ...fixture,
      initialTables: new Map([['users', ['id']]]),
    });
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv() }),
      /does not match init\.sql baseline/,
    );
    assert.equal(fake.ledger.size, 0);
    assert.equal(fake.events.some(event => event.sql.startsWith('CREATE TABLE IF NOT EXISTS auth_schema_migrations')), false);
  } finally {
    fixture.cleanup();
  }
});

test('missing or invalid crypto configuration fails before acquiring a connection', async () => {
  const runner = loadRunner();
  let connects = 0;
  const pool = { async connect() { connects++; throw new Error('must not connect'); } };
  await assert.rejects(
    runner.runMigrations(pool, { env: migrationEnv({ PHONE_LOOKUP_HMAC_KEY: '' }) }),
    /PHONE_LOOKUP_HMAC_KEY/,
  );
  await assert.rejects(
    runner.runMigrations(pool, { env: migrationEnv({ ENCRYPTION_KEY: 'not-a-key' }) }),
    /ENCRYPTION_KEY/,
  );
  await assert.rejects(
    runner.runMigrations(pool, { env: migrationEnv({ ENCRYPTION_ENABLED: 'false' }) }),
    /ENCRYPTION_ENABLED/,
  );
  assert.equal(connects, 0);
});

test('migration advisory lock is held on the dedicated client and contention fails before schema work', async () => {
  const fixture = setupMigrationFixture();
  try {
    const runner = loadRunner();
    const fake = makeFakeDb(fixture);
    fake.client.query = async (sql, args = []) => {
      const statement = String(sql).trim();
      fake.events.push({ sql: statement, args });
      if (statement.includes('pg_try_advisory_lock')) return { rows: [{ locked: false }] };
      return { rows: [] };
    };
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv() }),
      /advisory lock/,
    );
    assert.equal(fake.events.some(event => event.sql.includes('FROM information_schema.columns')), false);
    assert.equal(fake.released, true);
  } finally {
    fixture.cleanup();
  }
});

test('applied migration checksum mismatch fails closed', async () => {
  const fixture = setupMigrationFixture();
  try {
    const runner = loadRunner();
    const expectedTables = runner.parseBaselineTables(fixture.baselineSql);
    const fake = makeFakeDb({ ...fixture, initialTables: expectedTables });
    fake.ledger.set('0001_phone_lookup_hashes', '0'.repeat(64));
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv() }),
      /Checksum mismatch/,
    );
  } finally {
    fixture.cleanup();
  }
});

test('legacy checksum adoption requires explicit opt-in and verifies migration effects', async () => {
  const fixture = setupMigrationFixture();
  try {
    const runner = loadRunner();
    const expectedTables = runner.parseBaselineTables(fixture.baselineSql);
    const fake = makeFakeDb({ ...fixture, initialTables: expectedTables });
    fake.indexes.add('idx_users_phone_lookup_hash');
    fake.indexes.add('idx_otp_phone_lookup_hash_unconsumed');
    fake.ledger.set('0001_phone_lookup_hashes', null);
    await assert.rejects(
      runner.runMigrations(fake.pool, { ...fixture, env: migrationEnv() }),
      /has no checksum/,
    );
    await runner.runMigrations(fake.pool, {
      ...fixture,
      env: migrationEnv({ AUTH_MIGRATION_ADOPT_LEGACY_CHECKSUMS: 'true' }),
    });
    const digest = crypto.createHash('sha256').update(fixture.migrationSql).digest('hex');
    assert.equal(fake.ledger.get('0001_phone_lookup_hashes'), digest);
  } finally {
    fixture.cleanup();
  }
});

test('backfill checks original ciphertext before setting digest and restarts after a raced update', async () => {
  const runner = loadRunner({
    '../src/utils/encryptedPhoneSearch': {
      canonicalizePhone: value => value,
      phoneLookupHash: value => `hash:${value}`,
    },
    '../src/utils/fieldEncryption': { decryptPhoneNumber: value => value },
  });
  const row = { id: '00000000-0000-4000-8000-000000000001', phone_number: '+919876543210', phone_lookup_hash: null };
  let updates = 0;
  let selections = 0;
  const client = {
    async query(sql, args = []) {
      if (sql.includes('SELECT COUNT(*)')) return { rows: [{ remaining: row.phone_lookup_hash ? 0 : 1 }] };
      if (sql.includes('SELECT id, phone_number')) {
        selections++;
        if (row.phone_lookup_hash || (args[0] && row.id <= args[0])) return { rows: [] };
        return { rows: [{ id: row.id, phone_number: selections === 1 ? '+919876543210' : row.phone_number }] };
      }
      if (sql.includes('UPDATE users SET phone_lookup_hash')) {
        updates++;
        if (updates === 1) {
          row.phone_number = '+918765432109';
          return { rows: [] };
        }
        if (args[2] === row.phone_number) {
          row.phone_lookup_hash = args[0];
          return { rows: [{ id: row.id }] };
        }
        return { rows: [] };
      }
      if (sql.includes('FROM otp_requests') && sql.includes('COUNT(*)')) return { rows: [{ remaining: 0 }] };
      if (sql.includes('SELECT id, phone_number FROM otp_requests')) return { rows: [] };
      throw new Error(`Unexpected SQL: ${sql}`);
    },
  };
  const results = await runner.backfillPhoneLookupHashes(client, { batchSize: 1, onProgress: () => {} });
  assert.equal(row.phone_lookup_hash, 'hash:+918765432109');
  assert.equal(results[0].updated, 1);
  assert.equal(results[0].raced, 1);
  assert.ok(selections >= 3, 'the second pass should revisit the row after the race');
});

test('backfill bounds batch size and progress output contains counters only', async () => {
  const runner = loadRunner();
  assert.throws(() => runner.boundedBatchSize('1001'), /from 1 to 1000/);
  assert.throws(() => runner.boundedBatchSize('1.5'), /from 1 to 1000/);
  const entries = [];
  const client = {
    async query(sql) {
      if (sql.includes('SELECT COUNT(*)')) return { rows: [{ remaining: 0 }] };
      throw new Error(`Unexpected SQL: ${sql}`);
    },
  };
  await runner.backfillPhoneLookupHashes(client, { batchSize: 10, onProgress: item => entries.push(item) });
  assert.deepEqual(entries, []);
});

test('restart verification detects a changed HMAC key or mismatched stored digest', async () => {
  const runner = loadRunner({
    '../src/utils/encryptedPhoneSearch': {
      canonicalizePhone: value => value,
      phoneLookupHash: value => `expected:${value}`,
    },
    '../src/utils/fieldEncryption': { decryptPhoneNumber: value => value },
  });
  const client = {
    async query(sql) {
      if (sql.includes('SELECT id, phone_number, phone_lookup_hash FROM users')) {
        return { rows: [{ id: '00000000-0000-4000-8000-000000000001', phone_number: '+919876543210', phone_lookup_hash: 'old-key:digest' }] };
      }
      if (sql.includes('SELECT id, phone_number, phone_lookup_hash FROM otp_requests')) return { rows: [] };
      throw new Error(`Unexpected SQL: ${sql}`);
    },
  };
  await assert.rejects(
    runner.verifyPhoneLookupHashes(client, { batchSize: 10, onProgress: () => {} }),
    /verify the stable lookup key/,
  );
});
