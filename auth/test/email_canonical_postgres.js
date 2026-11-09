'use strict';

// Coordinator-invoked fixture for a disposable loopback PostgreSQL database.
// Run: EMAIL_CANONICAL_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:PORT/email_canonical_test \
//      node --test test/email_canonical_postgres.js
// Applies the baseline schema, the contact uniqueness migration and 0015/0016 if the
// users table is missing. Refuses any database that is not email_canonical_test on loopback.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { Pool } = require('pg');
const corpus = require('./fixtures/email_canonical_corpus.json');
const { canonicalEmail } = require('../src/utils/emailIdentity');

const url = process.env.EMAIL_CANONICAL_TEST_DATABASE_URL;
if (!url) throw new Error('EMAIL_CANONICAL_TEST_DATABASE_URL is required');
const parsed = new URL(url);
if (!['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname) || parsed.pathname !== '/email_canonical_test') {
  throw new Error('EMAIL_CANONICAL_TEST_DATABASE_URL must name the loopback email_canonical_test database');
}
const root = path.join(__dirname, '..');
const sql = file => fs.readFileSync(path.join(root, file), 'utf8');
const pool = new Pool({ connectionString: url, max: 4 });

test.before(async () => {
  const exists = await pool.query("SELECT to_regclass('public.users') AS t");
  if (!exists.rows[0].t) {
    for (const file of ['db/pandapay-auth/init.sql', 'db/migrations/9001_active_contact_uniqueness.sql',
      'db/migrations/0015_claimed_phone.sql', 'db/migrations/0016_email_canonical.sql']) {
      await pool.query(sql(file));
    }
  }
  await pool.query('TRUNCATE users CASCADE');
});
test.after(async () => { await pool.end(); });

async function insertUser(email) {
  const { rows } = await pool.query('INSERT INTO users (email, is_email_verified) VALUES ($1, TRUE) RETURNING id, email_canonical', [email]);
  return rows[0];
}

test('the SQL function and the JavaScript function agree on every corpus address', async () => {
  for (const [typed, expected] of corpus) {
    const { rows } = await pool.query('SELECT auth_canonical_email($1) AS c', [typed]);
    assert.equal(rows[0].c, expected, `SQL: ${typed}`);
    assert.equal(canonicalEmail(typed), expected, `JS: ${typed}`);
  }
  assert.equal((await pool.query('SELECT auth_canonical_email(NULL) AS c')).rows[0].c, null);
});

test('the trigger fills the mailbox on insert and refreshes it when the email changes', async () => {
  const created = await insertUser('Trig.Ger+one@Gmail.com');
  assert.equal(created.email_canonical, 'trigger@gmail.com');
  await pool.query("UPDATE users SET email = 'someone.else+x@outlook.com' WHERE id = $1", [created.id]);
  const row = (await pool.query('SELECT email_canonical FROM users WHERE id = $1', [created.id])).rows[0];
  assert.equal(row.email_canonical, 'someone.else@outlook.com');
});

test('two live accounts cannot share a mailbox, however the address is written', async () => {
  await insertUser('mailbox@gmail.com');
  for (const alias of ['m.a.i.l.b.o.x@gmail.com', 'mailbox+promo@gmail.com', 'MAILBOX@googlemail.com']) {
    await assert.rejects(insertUser(alias), /uq_users_live_email_canonical/, alias);
  }
});

test('a deleted account frees its mailbox', async () => {
  const first = await insertUser('freed@gmail.com');
  await pool.query('UPDATE users SET deleted = TRUE WHERE id = $1', [first.id]);
  assert.equal((await insertUser('fr.eed+again@gmail.com')).email_canonical, 'freed@gmail.com');
});

test('re-running the migration backfills rows that have no mailbox yet', async () => {
  const row = await insertUser('backfill.me@gmail.com');
  await pool.query('ALTER TABLE users DISABLE TRIGGER trg_users_email_canonical');
  await pool.query('UPDATE users SET email_canonical = NULL WHERE id = $1', [row.id]);
  await pool.query('ALTER TABLE users ENABLE TRIGGER trg_users_email_canonical');
  await pool.query(sql('db/migrations/0016_email_canonical.sql'));
  assert.equal((await pool.query('SELECT email_canonical FROM users WHERE id = $1', [row.id])).rows[0].email_canonical, 'backfillme@gmail.com');
});

test('the migration refuses, count only, when two live accounts already share a mailbox', async () => {
  // A database from before this migration: no mailbox column data, no index.
  await pool.query('DROP INDEX uq_users_live_email_canonical');
  await pool.query('ALTER TABLE users DISABLE TRIGGER trg_users_email_canonical');
  const a = (await pool.query("INSERT INTO users (email, is_email_verified) VALUES ('dupe@gmail.com', TRUE) RETURNING id")).rows[0].id;
  const b = (await pool.query("INSERT INTO users (email, is_email_verified) VALUES ('d.u.p.e@gmail.com', TRUE) RETURNING id")).rows[0].id;
  await pool.query('ALTER TABLE users ENABLE TRIGGER trg_users_email_canonical');
  await assert.rejects(pool.query(sql('db/migrations/0016_email_canonical.sql')), error => {
    assert.match(error.message, /^email canonical preflight blocked \(count-only\): duplicate_groups=1$/);
    assert.doesNotMatch(error.message, /dupe/, 'the message carries counts, never addresses');
    return true;
  });
  await pool.query('DELETE FROM users WHERE id = ANY($1)', [[a, b]]);
  await pool.query(sql('db/migrations/0016_email_canonical.sql'));
  const index = await pool.query("SELECT 1 FROM pg_indexes WHERE indexname = 'uq_users_live_email_canonical'");
  assert.equal(index.rows.length, 1, 'once the duplicate is resolved the migration completes');
});
