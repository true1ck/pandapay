'use strict';

/**
 * One-off backfill of shared_expenses.phone_directory for people who signed up
 * before (or never triggered) the lazy registration in
 * api/src/shared_expenses/invitations.js, so "Add friend" finds them.
 *
 * Mirrors the API exactly: same number choice (verified phone first, else the
 * claimed one), same normalisation, same keyed hash
 * (HMAC-SHA256 with SHARED_EXPENSE_INVITE_SECRET over 'pandapay:split-phone:v1:'+E164),
 * same effect as shared_expenses.register_phone (display name from profiles,
 * the existing `discoverable` choice is never changed, new rows default to true).
 *
 * Dry run by default: prints counts only, never numbers or hashes.
 *   node scripts/backfillSplitDirectory.js            # report
 *   node scripts/backfillSplitDirectory.js --apply    # write
 * Env: ADMIN_DATABASE_URL, AUTH_MIGRATION_DATABASE_URL (or AUTH_DATABASE_URL), SHARED_EXPENSE_INVITE_SECRET, ENCRYPTION_KEY (+ the
 * usual ENCRYPTION_* and DB_SSL* settings). Safe to re-run.
 *
 * A number held by more than one active account is skipped and counted: there
 * is no way to tell which one is the real owner, and the API's own lazy write
 * (newest verifier wins) settles it the next time either person opens the app.
 */

const crypto = require('node:crypto');

// Same rule as api/src/shared_expenses/invitations.js normalizePhone.
function normalizePhone(value) {
  if (typeof value !== 'string' || value.length > 40 || !/^[+0-9 ()-]+$/.test(value)) return null;
  let phone = value.replace(/[ ()-]/g, '');
  if (/^[6-9][0-9]{9}$/.test(phone)) phone = `+91${phone}`;
  return /^\+[1-9][0-9]{6,14}$/.test(phone) ? phone : null;
}

function phoneHash(secret, phone) {
  return crypto.createHmac('sha256', secret).update(`pandapay:split-phone:v1:${phone}`).digest('hex');
}

/**
 * rows: [{ id, displayName, phones: [string|null, ...] }] with phones in
 * priority order (verified, then claimed). existing: Map profileId -> hash.
 */
function planBackfill(rows, secret, existing = new Map()) {
  const usable = [];
  const stats = { considered: rows.length, no_usable_number: 0, duplicate_number_skipped: 0, already_registered: 0, to_write: 0 };
  for (const row of rows) {
    let phone = null;
    for (const candidate of row.phones) {
      const normalized = normalizePhone(candidate);
      if (normalized) { phone = normalized; break; }
    }
    if (!phone) { stats.no_usable_number += 1; continue; }
    usable.push({ id: row.id, displayName: row.displayName, hash: phoneHash(secret, phone) });
  }
  const owners = new Map();
  for (const item of usable) owners.set(item.hash, (owners.get(item.hash) || 0) + 1);
  const writes = [];
  for (const item of usable) {
    if (owners.get(item.hash) > 1) { stats.duplicate_number_skipped += 1; continue; }
    if (existing.get(item.id) === item.hash) { stats.already_registered += 1; continue; }
    writes.push(item);
  }
  stats.to_write = writes.length;
  return { writes, stats };
}

async function main(argv = process.argv.slice(2)) {
  if (argv.some(a => a !== '--apply') || argv.length > 1) throw new Error('Unknown option (only --apply)');
  const apply = argv.includes('--apply');
  const url = process.env.ADMIN_DATABASE_URL;
  const secret = process.env.SHARED_EXPENSE_INVITE_SECRET;
  if (!url) throw new Error('ADMIN_DATABASE_URL is required');
  if (typeof secret !== 'string' || secret.length < 32) throw new Error('SHARED_EXPENSE_INVITE_SECRET is required (32+ chars)');

  const authUrl = process.env.AUTH_MIGRATION_DATABASE_URL || process.env.AUTH_DATABASE_URL || url;
  const { Pool } = require('pg');
  const { resolveDatabaseTls } = require('../src/utils/dbTls');
  const { decryptPhoneNumber } = require('../src/utils/fieldEncryption');
  const mkPool = (u) => new Pool({ ...resolveDatabaseTls(u, process.env), max: 1, connectionTimeoutMillis: 10000 });
  const authPool = mkPool(authUrl);
  const pool = mkPool(url);
  const client = await pool.connect();
  try {
    // Accounts live in the auth database; profiles and the directory in the product
    // database. They may be the same database or two, so each is read on its own.
    const { rows: users } = await authPool.query(
      `SELECT id, phone_number, claimed_phone_enc FROM users
        WHERE is_active IS TRUE AND deleted IS FALSE
          AND (phone_number IS NOT NULL OR claimed_phone_enc IS NOT NULL)`);
    const { rows: profiles } = await client.query(
      "SELECT id, NULLIF(btrim(display_name), '') AS display_name FROM public.profiles WHERE id = ANY($1::uuid[])",
      [users.map(u => u.id)]);
    const names = new Map(profiles.map(p => [p.id, p.display_name]));
    let undecryptable = 0;
    const safeDecrypt = (value) => {
      if (!value) return null;
      try { return decryptPhoneNumber(value); } catch (_) { undecryptable += 1; return null; }
    };
    // The directory references profiles, so an account without one cannot be listed.
    const withProfile = users.filter(u => names.has(u.id));
    const rows = withProfile.map(u => ({
      id: u.id,
      displayName: names.get(u.id) ? names.get(u.id).slice(0, 255) : null,
      phones: [safeDecrypt(u.phone_number), safeDecrypt(u.claimed_phone_enc)],
    }));
    const { rows: dir } = await client.query('SELECT profile_id, phone_hash FROM shared_expenses.phone_directory');
    const existing = new Map(dir.map(r => [r.profile_id, r.phone_hash]));
    const { writes, stats } = planBackfill(rows, secret, existing);
    stats.undecryptable_values = undecryptable;
    stats.no_profile_skipped = users.length - withProfile.length;
    stats.directory_rows_before = dir.length;

    if (apply && writes.length) {
      await client.query('BEGIN');
      try {
        for (const w of writes) {
          // Same as register_phone: the newest owner of a number takes its entry.
          await client.query('DELETE FROM shared_expenses.phone_directory WHERE phone_hash = $1 AND profile_id <> $2', [w.hash, w.id]);
          await client.query(
            `INSERT INTO shared_expenses.phone_directory (profile_id, phone_hash, display_name, discoverable)
             VALUES ($1, $2, $3, true)
             ON CONFLICT (profile_id) DO UPDATE
               SET phone_hash = EXCLUDED.phone_hash, display_name = EXCLUDED.display_name, updated_at = clock_timestamp()`,
            [w.id, w.hash, w.displayName]);
        }
        await client.query('COMMIT');
      } catch (error) {
        await client.query('ROLLBACK');
        throw error;
      }
      const { rows: after } = await client.query('SELECT count(*)::int AS n FROM shared_expenses.phone_directory');
      stats.directory_rows_after = after[0].n;
    }
    process.stdout.write(`${JSON.stringify({ mode: apply ? 'apply' : 'dry-run', ...stats })}\n`);
  } finally {
    client.release();
    await pool.end();
    await authPool.end();
  }
}

if (require.main === module) {
  main().catch((error) => {
    process.stderr.write(`Split directory backfill failed: ${error && error.message ? error.message : 'error'}\n`);
    process.exitCode = 1;
  });
}

module.exports = { normalizePhone, phoneHash, planBackfill };
