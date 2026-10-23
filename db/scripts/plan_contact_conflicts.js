#!/usr/bin/env node
'use strict';

// Read-only proposal. This command never changes contacts or account data.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { createRequire } = require('node:module');
const { spawnSync } = require('node:child_process');

function maskEmail(value) {
  const [local, domain] = String(value || '').split('@');
  return domain ? `${local.slice(0, 1)}…@${domain}` : '[unavailable]';
}

function makeProposal(rows, now = new Date()) {
  const grouped = new Map();
  for (const row of rows) {
    if (!/^[0-9a-f]{64}$/i.test(row.phone_lookup_hash || '') || row.deleted !== false) {
      throw new Error('Invalid conflict inventory');
    }
    if (!grouped.has(row.phone_lookup_hash)) grouped.set(row.phone_lookup_hash, []);
    grouped.get(row.phone_lookup_hash).push(row);
  }
  const groups = [];
  for (const accounts of grouped.values()) {
    if (accounts.length < 2) throw new Error('Incomplete conflict group');
    const ordered = [...accounts].sort((a, b) =>
      Number(b.is_phone_verified === true) - Number(a.is_phone_verified === true) ||
      new Date(a.created_at).getTime() - new Date(b.created_at).getTime() ||
      String(a.id).localeCompare(String(b.id)));
    groups.push({
      group: groups.length + 1,
      proposed_phone_account_id: ordered[0].id,
      selection_rule: 'oldest verified phone account, then oldest account; requires owner review',
      accounts: ordered.map((row, index) => ({
        ...row,
        proposed_action: index === 0 ? 'retain_phone' : 'archive_original_phone_and_make_email_only',
        requires_email_verification_before_change: index !== 0 && row.is_email_verified !== true,
        state_sha256: crypto.createHash('sha256').update(JSON.stringify(row)).digest('hex'),
      })),
    });
  }
  return { format: 'pandapay-contact-conflict-proposal-v1', generated_at_utc: now.toISOString(),
    status: 'proposal_only_no_changes_applied', deleted_contact_policy: 'reuse_allowed', groups };
}

function markdown(proposal) {
  const lines = ['# Test-account phone conflict proposal', '',
    `Generated: ${proposal.generated_at_utc}`, '',
    '**Proposal only. No account or contact has been changed.**', '',
    'The proposed phone account is the oldest account with a verified phone in each group. Review the account IDs before any change.', '',
    'Every account, UUID, profile, session and history is retained. A secondary account can become email-only only after email access is verified and its original encrypted phone and lookup hash are preserved in a dedicated history record. That change requires separate approval.', ''];
  for (const group of proposal.groups) {
    lines.push(`## Group ${group.group}`, '', '| Account ID | Email hint | Phone verified | Email verified | Proposed action |',
      '|---|---|---|---|---|');
    for (const row of group.accounts) {
      const hint = maskEmail(row.email).replace(/[|`\r\n]/g, '');
      lines.push(`| ${row.id} | \`${hint}\` | ${row.is_phone_verified === true} | ${row.is_email_verified === true} | ${row.proposed_action === 'retain_phone' ? 'Keep phone login' : 'Keep account; email login after verified resolution'} |`);
    }
    lines.push('');
  }
  if (!proposal.groups.length) lines.push('No active phone conflicts were found.', '');
  return lines.join('\n');
}

function assertOutsideRepository(folder) {
  let current = fs.realpathSync(folder);
  while (true) {
    if (fs.existsSync(path.join(current, '.git'))) throw new Error('Proposal output must be outside a Git checkout');
    const parent = path.dirname(current);
    if (parent === current) return;
    current = parent;
  }
}

function privateWrite(folder, filename, contents) {
  const temporary = path.join(folder, '.proposal-' + crypto.randomBytes(12).toString('hex'));
  try {
    fs.writeFileSync(temporary, contents, { flag: 'wx', mode: 0o600 });
    fs.renameSync(temporary, path.join(folder, filename));
  } finally {
    fs.rmSync(temporary, { force: true });
  }
}

async function main() {
  const [folderArgument, recipients] = process.argv.slice(2);
  if (!folderArgument || !recipients || !process.env.AUTH_DATABASE_URL) {
    throw new Error('Provide a private output directory, public recipient file and explicit auth connection');
  }
  process.umask(0o077);
  const folder = path.resolve(folderArgument);
  fs.mkdirSync(folder, { recursive: true, mode: 0o700 });
  assertOutsideRepository(folder);
  if ((fs.statSync(folder).mode & 0o077) !== 0) throw new Error('Proposal output directory must be owner-only');
  const authDir = process.env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
  const authRequire = createRequire(path.join(authDir, 'package.json'));
  const { Client } = authRequire('pg');
  const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
  const client = new Client({ ...resolveDatabaseTls(process.env.AUTH_DATABASE_URL), connectionTimeoutMillis: 10000 });
  await client.connect();
  let proposal;
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    await client.query("SET LOCAL statement_timeout = '15000ms'");
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '30000ms'");
    const result = await client.query(`SELECT id::text,email,phone_number,phone_lookup_hash,
      created_at,is_phone_verified,is_email_verified,deleted FROM public.users
      WHERE deleted=FALSE AND phone_lookup_hash IN (
        SELECT phone_lookup_hash FROM public.users WHERE deleted=FALSE AND phone_lookup_hash IS NOT NULL
        GROUP BY phone_lookup_hash HAVING COUNT(*)>1)
      ORDER BY phone_lookup_hash,created_at,id LIMIT 501`);
    if (result.rows.length > 500) throw new Error('Conflict inventory exceeds the reviewed report bound');
    proposal = makeProposal(result.rows);
  } finally {
    await client.query('ROLLBACK').catch(() => {});
    await client.end();
  }
  // Original ciphertext, keyed hashes and unmasked emails stay encrypted.
  const encrypted = spawnSync('age', ['-R', recipients], {
    input: JSON.stringify(proposal), maxBuffer: 8 * 1024 * 1024,
  });
  if (encrypted.status !== 0) throw new Error('Proposal encryption failed');
  privateWrite(folder, 'contact-conflict-proposal.json.age', encrypted.stdout);
  privateWrite(folder, 'contact-conflict-proposal.md', markdown(proposal));
  console.log(`Read-only proposal saved; groups=${proposal.groups.length} accounts=${proposal.groups.reduce((sum, group) => sum + group.accounts.length, 0)} changes_applied=0`);
}

if (require.main === module) main().catch(() => {
  console.error('Contact conflict proposal failed; no database changes were applied');
  process.exitCode = 1;
});
module.exports = { makeProposal, markdown, assertOutsideRepository };
