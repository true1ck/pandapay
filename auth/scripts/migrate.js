'use strict';

require('dotenv').config();

const fs = require('node:fs');
const path = require('node:path');
const db = require('../src/db');
const { canonicalizePhone, phoneLookupHash } = require('../src/utils/encryptedPhoneSearch');
const { decryptPhoneNumber } = require('../src/utils/fieldEncryption');

const MIGRATIONS_DIR = path.join(__dirname, '..', 'db', 'migrations');

async function backfillPhoneLookupHashes(client) {
  for (const table of ['users', 'otp_requests']) {
    const rows = await client.query(
      `SELECT id, phone_number FROM ${table}
       WHERE phone_number IS NOT NULL AND phone_lookup_hash IS NULL`,
    );
    for (const row of rows.rows) {
      let hash;
      try {
        hash = phoneLookupHash(canonicalizePhone(decryptPhoneNumber(row.phone_number)));
      } catch (_) {
        throw new Error(`Unable to backfill ${table}.phone_lookup_hash; verify the phone encryption and lookup keys`);
      }
      await client.query(
        `UPDATE ${table} SET phone_lookup_hash = $1
         WHERE id = $2 AND phone_lookup_hash IS NULL`,
        [hash, row.id],
      );
    }
  }
}

async function runMigrations(pool, { migrationsDir = MIGRATIONS_DIR } = {}) {
  if (Buffer.byteLength(process.env.PHONE_LOOKUP_HMAC_KEY || '') < 32) {
    throw new Error('PHONE_LOOKUP_HMAC_KEY must be configured with at least 32 bytes');
  }
  const client = await pool.connect();
  try {
    await client.query(`
      CREATE TABLE IF NOT EXISTS auth_schema_migrations (
        version TEXT PRIMARY KEY,
        applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
      )
    `);

    const files = fs.readdirSync(migrationsDir)
      .filter(file => /^\d+_[a-z0-9_-]+\.sql$/i.test(file))
      .sort();
    for (const file of files) {
      const version = file.slice(0, -'.sql'.length);
      const existing = await client.query(
        'SELECT version FROM auth_schema_migrations WHERE version = $1',
        [version],
      );
      if (existing.rows.length) continue;

      const sql = fs.readFileSync(path.join(migrationsDir, file), 'utf8');
      await client.query('BEGIN');
      try {
        await client.query(sql);
        await client.query('INSERT INTO auth_schema_migrations (version) VALUES ($1)', [version]);
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      }
      console.log(`Applied auth migration ${version}`);
    }

    await backfillPhoneLookupHashes(client);
  } finally {
    client.release();
  }
}

async function main() {
  try {
    await runMigrations(await db.getPool());
    console.log('Auth database migrations are current');
  } finally {
    await db.closeDb();
  }
}

if (require.main === module) {
  main().catch(error => {
    console.error('Auth database migration failed:', error.message);
    process.exitCode = 1;
  });
}

module.exports = { runMigrations, backfillPhoneLookupHashes, main };
