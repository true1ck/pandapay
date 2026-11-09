'use strict';

// Operator-only support tool for account recovery. Never loads .env. It needs its
// own database URL, AUTH_SUPPORT_DATABASE_URL, for a role that can read and update
// users and recovery_attempts. It prints masked emails and never a token, a hash, a
// code or a phone number.
//
//   node auth/scripts/recovery_support.js list [--state pending_hold] [--limit 20]
//   node auth/scripts/recovery_support.js show --user-id <uuid> | --email <address>
//   node auth/scripts/recovery_support.js cancel --attempt-id <uuid> --actor <name> --reason <text>
//   node auth/scripts/recovery_support.js restore --user-id <uuid> --actor <name> --reason <text>
//   node auth/scripts/recovery_support.js release-phone --user-id <uuid> --actor <name> --reason <text>
//
// cancel   stops a recovery that is still waiting out its 24 hours.
// restore  unfreezes an account that a "this was not me" link froze, once support
//          has checked the person. They sign in again with their email code.
// release-phone  frees a number held by an account, so its real owner can use it.
// Every change needs a named actor and a written reason, and leaves an audit row.

const { maskEmail } = require('../src/utils/recoveryContacts');
const { releaseClaimedPhone } = require('../src/services/phoneClaim');

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const STATES = ['started', 'proven', 'new_email_sent', 'ready', 'pending_hold', 'completed', 'cancelled', 'undone', 'failed'];

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};
  for (let i = 0; i < rest.length; i += 2) {
    const key = rest[i];
    if (!/^--[a-z-]+$/.test(key || '') || rest[i + 1] === undefined || rest[i + 1].startsWith('--')) throw new Error(`Bad option near "${key || ''}"`);
    options[key.slice(2)] = rest[i + 1];
  }
  return { command, options };
}

function requireWho(options) {
  const actor = (options.actor || '').trim();
  const reason = (options.reason || '').trim();
  if (actor.length < 2 || actor.length > 120) throw new Error('--actor must name who is doing this');
  if (reason.length < 8 || reason.length > 500) throw new Error('--reason must be at least 8 characters');
  return { actor, reason };
}

const requireUuid = (value, name) => {
  if (!UUID.test(value || '')) throw new Error(`${name} must be a UUID`);
  return value.toLowerCase();
};

const iso = value => (value ? new Date(value).toISOString() : null);

function attemptRow(row) {
  return {
    attempt_id: row.id, state: row.state, matched: row.matched, path: row.path,
    account: row.email ? maskEmail(row.email) : null, user_id: row.user_id,
    created_at: iso(row.created_at), hold_until: iso(row.hold_until), stop_until: iso(row.stop_until),
    completed_at: iso(row.completed_at), stopped_at: iso(row.stopped_at),
    new_email: row.new_email ? maskEmail(row.new_email) : null,
  };
}

async function audit(client, userId, action, who, extra = {}) {
  await client.query(
    `INSERT INTO auth_audit (user_id, action, status, meta) VALUES ($1, $2, 'success', $3)`,
    [userId, action, JSON.stringify({ actor: who.actor, reason: who.reason, ...extra })],
  );
}

async function inTransaction(pool, work) {
  const client = await pool.connect();
  let began = false;
  let releaseError;
  try {
    await client.query('BEGIN');
    began = true;
    const result = await work(client);
    await client.query('COMMIT');
    began = false;
    return result;
  } catch (error) {
    if (began) { try { await client.query('ROLLBACK'); } catch (rollbackError) { releaseError = rollbackError; } }
    throw error;
  } finally {
    client.release(releaseError);
  }
}

async function run({ pool, argv, write = value => console.log(value) }) {
  const { command, options } = parseArgs(argv);
  const print = value => write(JSON.stringify(value, null, 2));

  if (command === 'list') {
    const state = options.state;
    if (state !== undefined && !STATES.includes(state)) throw new Error(`--state must be one of ${STATES.join(', ')}`);
    const limit = options.limit === undefined ? 20 : Number(options.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw new Error('--limit must be 1 to 200');
    const { rows } = await pool.query(
      `SELECT r.*, u.email FROM recovery_attempts r LEFT JOIN users u ON u.id = r.user_id
        WHERE r.matched = TRUE AND ($1::text IS NULL OR r.state = $1)
        ORDER BY r.created_at DESC LIMIT $2`, [state || null, limit]);
    return print(rows.map(attemptRow));
  }

  if (command === 'show') {
    let userId;
    if (options['user-id']) userId = requireUuid(options['user-id'], '--user-id');
    else if (options.email) {
      const found = await pool.query('SELECT id FROM users WHERE email_canonical = auth_canonical_email($1) AND deleted = FALSE LIMIT 1', [options.email]);
      userId = found.rows[0]?.id;
      if (!userId) return print({ found: false });
    } else throw new Error('show needs --user-id or --email');
    const account = await pool.query(
      `SELECT id, email, is_active, deleted, recovery_email IS NOT NULL AS has_recovery_email,
              claimed_phone_hash IS NOT NULL AS has_claimed_phone FROM users WHERE id = $1`, [userId]);
    if (!account.rows[0]) return print({ found: false });
    const attempts = await pool.query(
      `SELECT r.*, u.email FROM recovery_attempts r LEFT JOIN users u ON u.id = r.user_id
        WHERE r.user_id = $1 ORDER BY r.created_at DESC LIMIT 20`, [userId]);
    const a = account.rows[0];
    return print({
      found: true, user_id: a.id, account: maskEmail(a.email), is_active: a.is_active, deleted: a.deleted,
      has_recovery_email: a.has_recovery_email, has_claimed_phone: a.has_claimed_phone, attempts: attempts.rows.map(attemptRow),
    });
  }

  if (command === 'cancel') {
    const attemptId = requireUuid(options['attempt-id'], '--attempt-id');
    const who = requireWho(options);
    const result = await inTransaction(pool, async client => {
      const { rows } = await client.query(
        `UPDATE recovery_attempts SET state = 'cancelled', stopped_at = NOW()
          WHERE id = $1 AND state = 'pending_hold' RETURNING user_id`, [attemptId]);
      if (!rows[0]) return { cancelled: false };
      await audit(client, rows[0].user_id, 'recovery_cancelled_by_support', who, { attempt_id: attemptId });
      return { cancelled: true };
    });
    return print(result);
  }

  if (command === 'restore') {
    const userId = requireUuid(options['user-id'], '--user-id');
    const who = requireWho(options);
    const result = await inTransaction(pool, async client => {
      // Only an account that a recovery freeze put to sleep is restorable here, so this
      // cannot reopen an account that was closed for another reason.
      const frozen = await client.query(
        `SELECT 1 FROM recovery_attempts WHERE user_id = $1 AND state = 'undone'
          AND stopped_at = (SELECT MAX(stopped_at) FROM recovery_attempts WHERE user_id = $1 AND state = 'undone') LIMIT 1`, [userId]);
      if (!frozen.rows[0]) return { restored: false, reason: 'no_recovery_freeze' };
      const { rows } = await client.query(
        `UPDATE users SET is_active = TRUE, token_version = COALESCE(token_version, 1) + 1, updated_at = NOW()
          WHERE id = $1 AND deleted = FALSE AND is_active = FALSE RETURNING id`, [userId]);
      if (!rows[0]) return { restored: false, reason: 'not_frozen' };
      await audit(client, userId, 'recovery_freeze_lifted', who);
      return { restored: true };
    });
    return print(result);
  }

  if (command === 'release-phone') {
    const userId = requireUuid(options['user-id'], '--user-id');
    const who = requireWho(options);
    return print(await releaseClaimedPhone({ pool, userId, ...who }));
  }

  throw new Error('Usage: recovery_support.js list | show | cancel | restore | release-phone (see the header of this file)');
}

async function main({ argv = process.argv.slice(2), env = process.env, write } = {}) {
  if (!env.AUTH_SUPPORT_DATABASE_URL) throw new Error('AUTH_SUPPORT_DATABASE_URL is required');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const resolved = resolveDatabaseTls(env.AUTH_SUPPORT_DATABASE_URL, env);
  const { Pool } = require('pg');
  const pool = new Pool({
    connectionString: resolved.connectionString, ssl: resolved.ssl, max: 1,
    connectionTimeoutMillis: 5000, statement_timeout: 10000, application_name: 'pandapay-auth-recovery-support',
  });
  try { await run({ pool, argv, write }); } finally { await pool.end(); }
}

if (require.main === module) {
  main().catch(error => { console.error(error && /^(Usage|Bad option|--|show needs|AUTH_SUPPORT|.* must)/.test(error.message) ? error.message : 'Recovery support command failed'); process.exitCode = 1; });
}
module.exports = { run, main, parseArgs };
