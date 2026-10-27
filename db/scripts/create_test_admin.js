#!/usr/bin/env node
'use strict';

// Bootstraps the static test operator used for console QA. Works by data, not
// by a login bypass: it creates the email-only auth user, seeds a bcrypt OTP
// row, grants the admin_users row, then optionally exchanges the OTP for a
// refresh token the console can load from localStorage.
//
// Run with the deployment database URLs, e.g. from the repo root:
//   ADMIN_DATABASE_URL=... AUTH_DATABASE_URL=... \
//     node db/scripts/create_test_admin.js --email pandapayadmin@example.com
//
// Retire the account with --deactivate. Keep the admin_users row afterwards so
// admin_audit_log attribution survives.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { createRequire } = require('module');

const apiRequire = createRequire(path.join(__dirname, '../../api/package.json'));
const authRequire = createRequire(path.join(__dirname, '../../auth/package.json'));
const { Client } = apiRequire('pg');
const bcrypt = authRequire('bcrypt');

const DEFAULT_CODE = '1234';
const DEFAULT_DAYS = 30;

function parseArgs(argv) {
  const args = { email: null, code: DEFAULT_CODE, role: 'operator', days: DEFAULT_DAYS, authUrl: null, deactivate: false, noMint: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--deactivate') args.deactivate = true;
    else if (arg === '--no-mint') args.noMint = true;
    else if (arg === '--email') args.email = argv[++i];
    else if (arg === '--code') args.code = argv[++i];
    else if (arg === '--role') args.role = argv[++i];
    else if (arg === '--days') args.days = Number(argv[++i]);
    else if (arg === '--auth-url') args.authUrl = argv[++i];
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function connect(url) {
  if (!url) return null;
  return new Client({
    connectionString: url,
    ssl: process.env.DB_SSL === 'false' ? undefined : { rejectUnauthorized: false },
  });
}

async function findOrCreateUser(auth, email) {
  const existing = await auth.query(
    `SELECT id FROM users WHERE lower(email) = lower($1) AND deleted = FALSE ORDER BY created_at LIMIT 1`,
    [email],
  );
  if (existing.rows.length > 0) return { id: existing.rows[0].id, created: false };

  const created = await auth.query(
    `INSERT INTO users (email, is_email_verified) VALUES ($1, TRUE) RETURNING id`,
    [email],
  );
  return { id: created.rows[0].id, created: true };
}

async function seedOtp(auth, email, code, days) {
  const hash = await bcrypt.hash(code, 10);
  await auth.query(
    `UPDATE otp_requests SET deleted = TRUE WHERE email = $1 AND deleted = FALSE`,
    [email],
  );
  const inserted = await auth.query(
    `INSERT INTO otp_requests (email, type, otp_hash, expires_at, attempt_count, deleted)
     VALUES ($1, 'email', $2, now() + ($3 || ' days')::interval, 0, FALSE)
     RETURNING expires_at`,
    [email, hash, days],
  );
  return inserted.rows[0].expires_at;
}

async function upsertAdmin(product, email, userId, role, isActive) {
  const clash = await product.query(
    `SELECT id FROM admin_users WHERE lower(email) = lower($1) AND id <> $2`,
    [email, userId],
  );
  if (clash.rows.length > 0) {
    throw new Error(`admin_users already has ${email} under a different id (${clash.rows[0].id})`);
  }
  await product.query(
    `INSERT INTO admin_users (id, email, role, is_active) VALUES ($1, $2, $3, $4)
     ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, role = EXCLUDED.role, is_active = EXCLUDED.is_active`,
    [userId, email, role, isActive],
  );
}

async function mintSession(authUrl, email, code) {
  const response = await fetch(`${authUrl.replace(/\/$/, '')}/auth/verify-email-otp`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, code, device_id: 'console-bootstrap' }),
  });
  const body = await response.json().catch(() => ({}));
  return { status: response.status, body };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const adminUrl = process.env.ADMIN_DATABASE_URL;
  const authUrl = process.env.AUTH_DATABASE_URL;
  const email = String(args.email || '').trim().toLowerCase();

  if (!email) throw new Error('--email is required');
  if (!/^\d{4}$/.test(args.code)) throw new Error('--code must be exactly 4 digits (auth validation)');
  if (!['owner', 'operator', 'reviewer', 'readonly'].includes(args.role)) throw new Error('Invalid --role');
  if (!Number.isInteger(args.days) || args.days < 1) throw new Error('--days must be a positive integer');
  if (!adminUrl || !authUrl) throw new Error('ADMIN_DATABASE_URL and AUTH_DATABASE_URL must be set');

  const auth = connect(authUrl);
  const product = connect(adminUrl);
  await auth.connect();
  await product.connect();

  try {
    const user = await findOrCreateUser(auth, email);

    if (args.deactivate) {
      await upsertAdmin(product, email, user.id, args.role, false);
      await auth.query(`UPDATE otp_requests SET deleted = TRUE WHERE email = $1 AND deleted = FALSE`, [email]);
      console.log(`Deactivated ${email} (user ${user.id}). admin_users row kept for audit attribution.`);
      return;
    }

    const expiresAt = await seedOtp(auth, email, args.code, args.days);
    await upsertAdmin(product, email, user.id, args.role, true);

    console.log(`User:      ${user.id} (${user.created ? 'created' : 'existing'})`);
    console.log(`Admin row: ${email} role=${args.role} is_active=true`);
    console.log(`OTP:       code ${args.code}, expires ${expiresAt.toISOString()} (single use)`);

    if (args.noMint) return;

    const baseUrl = args.authUrl || process.env.AUTH_BASE_URL || 'https://auth.pandapath.site';
    const minted = await mintSession(baseUrl, email, args.code);
    if (minted.status !== 200 || !minted.body.refresh_token) {
      console.error(`Mint failed (${minted.status}): ${minted.body.error || minted.body.message || 'no refresh token'}`);
      process.exitCode = 1;
      return;
    }

    const tokenPath = path.join(os.tmpdir(), 'pandapay-test-admin-session.txt');
    fs.writeFileSync(tokenPath, minted.body.refresh_token, { mode: 0o600 });
    console.log(`Session:   refresh token written to ${tokenPath}`);
    console.log(`Next:      localStorage.setItem('flutter.pandapay_console.refresh_token', <contents of that file>)`);
  } finally {
    await auth.end();
    await product.end();
  }
}

main().catch((err) => {
  console.error(err.message);
  process.exitCode = 1;
});
