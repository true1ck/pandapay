#!/usr/bin/env node
'use strict';

// Explicitly approved, audited contact resolution for the reviewed test
// account proposal. Importing this module has no database or filesystem side
// effects; the CLI is the only entry point that opens a database connection.
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { createRequire } = require('node:module');

const MAX_PLAN_BYTES = 8 * 1024 * 1024;
const MAX_GROUPS = 50;
const MAX_ACCOUNTS = 500;
const APPROVAL = 'I_APPROVE_THE_REVIEWED_TEST_ACCOUNT_PROPOSAL';
const WRITERS_FENCED = 'ALL_AUTH_API_AND_BACKGROUND_WRITERS_ARE_STOPPED';
const REASON = 'approved_test_phone_conflict';
const SELECT_FIELDS = ['id', 'email', 'phone_number', 'phone_lookup_hash', 'created_at',
  'is_phone_verified', 'is_email_verified', 'deleted'];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function safeError(message) { return new Error(message); }
function sha256(value) { return crypto.createHash('sha256').update(value).digest('hex'); }
function stateDigest(row) { return sha256(JSON.stringify(row)); }

function resolutionId(planSha256) {
  const bytes = crypto.createHash('sha256').update(`pandapay-contact-resolution-v1:${planSha256}`).digest().subarray(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = bytes.toString('hex');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

function validateProposal(proposal) {
  if (!proposal || proposal.format !== 'pandapay-contact-conflict-proposal-v1' ||
      proposal.status !== 'proposal_only_no_changes_applied' || !Array.isArray(proposal.groups) ||
      proposal.groups.length === 0 || proposal.groups.length > MAX_GROUPS) {
    throw safeError('Proposal format or bounds are invalid');
  }
  const allIds = new Set();
  const groupHashes = new Set();
  let total = 0;
  const groups = [];
  for (const group of proposal.groups) {
    if (!group || !Array.isArray(group.accounts) || group.accounts.length < 2 ||
        !UUID_RE.test(group.proposed_phone_account_id || '')) throw safeError('Proposal group is invalid');
    total += group.accounts.length;
    if (total > MAX_ACCOUNTS) throw safeError('Proposal exceeds account bound');
    const rows = [];
    const groupIds = new Set();
    let keeperCount = 0;
    let phoneHash;
    for (const row of group.accounts) {
      if (!row || !UUID_RE.test(row.id || '') || allIds.has(row.id) || groupIds.has(row.id) ||
          !/^[0-9a-f]{64}$/i.test(row.phone_lookup_hash || '') || row.deleted !== false ||
          !/^[0-9a-f]{64}$/i.test(row.state_sha256 || '') || typeof row.phone_number !== 'string' ||
          row.phone_number.length === 0 || typeof row.created_at !== 'string' ||
          !Number.isFinite(new Date(row.created_at).getTime()) ||
          typeof row.is_phone_verified !== 'boolean' || typeof row.is_email_verified !== 'boolean') {
        throw safeError('Proposal account is invalid');
      }
      if (phoneHash !== undefined && row.phone_lookup_hash !== phoneHash) throw safeError('Proposal group hash mismatch');
      phoneHash = row.phone_lookup_hash;
      if (row.proposed_action === 'retain_phone') {
        keeperCount += 1;
        if (row.id !== group.proposed_phone_account_id) throw safeError('Proposal keeper mismatch');
      } else if (row.proposed_action !== 'archive_original_phone_and_make_email_only') {
        throw safeError('Proposal action is invalid');
      }
      if (stateDigest(projectRow(row)) !== row.state_sha256) throw safeError('Proposal state digest is invalid');
      if (row.proposed_action !== 'retain_phone' &&
          (row.is_email_verified !== true || !validEmail(row.email))) throw safeError('Secondary account has no verified email login');
      groupIds.add(row.id); allIds.add(row.id); rows.push(row);
    }
    if (keeperCount !== 1 || !groupIds.has(group.proposed_phone_account_id)) throw safeError('Proposal must have one keeper per group');
    const orderedAccounts = [...rows].sort((a, b) =>
      Number(b.is_phone_verified) - Number(a.is_phone_verified) ||
      new Date(a.created_at).getTime() - new Date(b.created_at).getTime() ||
      String(a.id).localeCompare(String(b.id)));
    if (orderedAccounts[0].id !== group.proposed_phone_account_id) {
      throw safeError('Proposal keeper does not match the planner selection rule');
    }
    if (groupHashes.has(phoneHash)) throw safeError('Proposal contains a duplicate phone group');
    groupHashes.add(phoneHash);
    groups.push({ phoneHash, keeperId: group.proposed_phone_account_id, rows });
  }
  return { groups, accountCount: total };
}

function validEmail(value) {
  return typeof value === 'string' && value.length <= 320 && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
}

// Match the planner's SELECT object exactly. PostgreSQL returns timestamps as
// Date instances; JSON.stringify serializes them to the same ISO string.
function projectRow(row) {
  const projected = {};
  for (const field of SELECT_FIELDS) projected[field] = row[field];
  return projected;
}

function assertCurrentSnapshot(proposal, rows) {
  const checked = validateProposal(proposal);
  const actual = new Map(rows.map(row => [row.id, projectRow(row)]));
  if (actual.size !== checked.accountCount || rows.length !== checked.accountCount) throw safeError('Current conflict membership differs from proposal');
  for (const group of checked.groups) {
    const groupRows = [...actual.values()].filter(row => row.phone_lookup_hash === group.phoneHash && row.deleted === false);
    if (groupRows.length !== group.rows.length) throw safeError('Current conflict membership differs from proposal');
    for (const proposed of group.rows) {
      const row = actual.get(proposed.id);
      if (!row || row.phone_lookup_hash !== group.phoneHash || stateDigest(row) !== proposed.state_sha256) {
        throw safeError('Current account state differs from proposal');
      }
    }
  }
  return checked;
}

function sameReplayState(current, expected, keeper) {
  const row = projectRow(current);
  if (keeper) return stateDigest(row) === expected.state_sha256;
  if (row.phone_number !== null || row.phone_lookup_hash !== null || row.is_phone_verified !== false) return false;
  const original = projectRow(expected);
  original.phone_number = null; original.phone_lookup_hash = null; original.is_phone_verified = false;
  return JSON.stringify(row) === JSON.stringify(original);
}

function checkApproval(env, planSha256, suppliedHash) {
  if (env.CONTACT_RESOLUTION_APPROVAL !== APPROVAL || env.CONTACT_RESOLUTION_WRITERS_FENCED !== WRITERS_FENCED ||
      !/^[0-9a-f]{64}$/i.test(suppliedHash || '') || suppliedHash.toLowerCase() !== planSha256) {
    throw safeError('Explicit proposal approval, writer fence, and matching proposal digest are required');
  }
}

function ageEncrypt(publicRecipientsFile, plaintext, spawn = spawnSync) {
  const result = spawn('age', ['-R', publicRecipientsFile], { input: plaintext, maxBuffer: MAX_PLAN_BYTES,
    timeout: 15000, killSignal: 'SIGKILL', encoding: null });
  if (result.error || result.status !== 0 || !Buffer.isBuffer(result.stdout) || result.stdout.length === 0 || result.stdout.length > MAX_PLAN_BYTES) {
    throw safeError('Encrypted archive creation failed');
  }
  return result.stdout;
}

function ageDecrypt(identityFile, ciphertext, spawn = spawnSync) {
  const result = spawn('age', ['--decrypt', '-i', identityFile], { input: ciphertext, maxBuffer: MAX_PLAN_BYTES,
    timeout: 15000, killSignal: 'SIGKILL', encoding: null });
  if (result.error || result.status !== 0 || !Buffer.isBuffer(result.stdout) || result.stdout.length === 0 || result.stdout.length > MAX_PLAN_BYTES) {
    throw safeError('Encrypted proposal could not be opened');
  }
  return result.stdout;
}

function validateCurrentRows(proposal, resultRows) { return assertCurrentSnapshot(proposal, resultRows); }

async function resolveInMigrationTransaction(client, { proposal, planSha256, recipientsFile, encrypt = ageEncrypt, decrypt = null, identityFile = null }) {
  const checked = validateProposal(proposal);
  const rid = resolutionId(planSha256);
  await client.query('BEGIN');
  try {
    await client.query("SET LOCAL idle_in_transaction_session_timeout = '30000ms'");
    await client.query('LOCK TABLE public.users IN SHARE ROW EXCLUSIVE MODE');
    const hashes = checked.groups.map(group => group.phoneHash);
    const currentResult = await client.query(`SELECT id::text AS id,email,phone_number,phone_lookup_hash,
      created_at,is_phone_verified,is_email_verified,deleted FROM public.users
      WHERE deleted=FALSE AND (phone_lookup_hash = ANY($1::varchar[]) OR id = ANY($2::uuid[]))
      ORDER BY phone_lookup_hash,created_at,id FOR UPDATE`, [hashes, checked.groups.flatMap(group => group.rows.map(row => row.id))]);
    const history = await client.query(`SELECT resolution_id::text AS resolution_id,user_id::text AS user_id,
      retained_phone_account_id::text AS retained_phone_account_id,original_row_age,archive_sha256,reason
      FROM public.contact_resolution_history WHERE resolution_id=$1::uuid ORDER BY user_id`, [rid]);
    if (history.rows.length) {
      await validateReplay(client, checked, currentResult.rows, history.rows, { rid, planSha256, decrypt, identityFile });
      await client.query('COMMIT');
      return { status: 'already_applied', groups: checked.groups.length, accounts: checked.accountCount };
    }
    assertCurrentSnapshot(proposal, currentResult.rows);
    for (const group of checked.groups) {
      for (const row of group.rows) {
        if (row.id === group.keeperId) continue;
        const originalJson = Buffer.from(JSON.stringify(projectRow(row)), 'utf8');
        let archive;
        try { archive = encrypt(recipientsFile, originalJson); }
        catch (_) { throw safeError('Encrypted archive creation failed'); }
        if (!Buffer.isBuffer(archive) || archive.length === 0 || archive.length > MAX_PLAN_BYTES) throw safeError('Encrypted archive creation failed');
        const archiveHash = sha256(archive);
        await client.query(`INSERT INTO public.contact_resolution_history
          (resolution_id,user_id,retained_phone_account_id,original_row_age,archive_sha256,reason)
          VALUES ($1::uuid,$2::uuid,$3::uuid,$4,$5,$6)`, [rid, row.id, group.keeperId, archive, archiveHash, REASON]);
        const changed = await client.query(`UPDATE public.users SET phone_number=NULL,phone_lookup_hash=NULL,is_phone_verified=FALSE
          WHERE id=$1::uuid AND deleted=FALSE AND phone_lookup_hash=$2 AND phone_number=$3
            AND is_phone_verified=$4 AND is_email_verified=TRUE`,
        [row.id, row.phone_lookup_hash, row.phone_number, row.is_phone_verified]);
        if (changed.rowCount !== 1) throw safeError('Secondary account changed during resolution');
      }
    }
    await client.query('COMMIT');
    return { status: 'applied', groups: checked.groups.length, accounts: checked.accountCount };
  } catch (error) {
    await client.query('ROLLBACK').catch(() => {});
    throw error;
  }
}

async function validateReplay(client, checked, currentRows, historyRows, { rid, planSha256, decrypt, identityFile }) {
  if (typeof decrypt !== 'function' || !identityFile) throw safeError('Replay verification requires the supplied identity');
  const expected = new Map();
  for (const group of checked.groups) for (const row of group.rows) if (row.id !== group.keeperId) expected.set(row.id, group);
  if (historyRows.length !== expected.size) throw safeError('Resolution history is partial or inconsistent');
  const historyByUser = new Map(historyRows.map(row => [row.user_id, row]));
  const current = new Map(currentRows.map(row => [row.id, row]));
  for (const [userId, group] of expected) {
    const record = historyByUser.get(userId);
    const original = group.rows.find(row => row.id === userId);
    const keeper = group.keeperId;
    if (!record || record.resolution_id !== rid || record.retained_phone_account_id !== keeper || record.reason !== REASON ||
        !Buffer.isBuffer(record.original_row_age) || sha256(record.original_row_age) !== String(record.archive_sha256).trim()) {
      throw safeError('Resolution history is inconsistent');
    }
    let archived;
    try { archived = JSON.parse(decrypt(identityFile, record.original_row_age).toString('utf8')); }
    catch (_) { throw safeError('Resolution archive could not be verified'); }
    if (stateDigest(projectRow(archived)) !== original.state_sha256 ||
        JSON.stringify(projectRow(archived)) !== JSON.stringify(projectRow(original))) throw safeError('Resolution archive does not match proposal');
    const row = current.get(userId);
    if (!row || !sameReplayState(row, original, false)) throw safeError('Resolved account state is inconsistent');
    const keeperRow = current.get(keeper);
    const keeperOriginal = group.rows.find(row => row.id === keeper);
    if (!keeperRow || !sameReplayState(keeperRow, keeperOriginal, true)) throw safeError('Keeper account state is inconsistent');
  }
  for (const group of checked.groups) {
    const activeGroup = currentRows.filter(row => row.deleted === false && row.phone_lookup_hash === group.phoneHash);
    if (activeGroup.length !== 1 || activeGroup[0].id !== group.keeperId) throw safeError('Resolved conflict membership is inconsistent');
    const row = current.get(group.keeperId);
    const expectedKeeper = group.rows.find(account => account.id === group.keeperId);
    if (!row || !sameReplayState(row, expectedKeeper, true)) throw safeError('Keeper account state is inconsistent');
  }
}

function parseArgs(argv) {
  const result = { apply: false };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--apply') result.apply = true;
    else if (['--plan', '--identity', '--recipients', '--approved-proposal-sha256'].includes(arg)) {
      if (!argv[i + 1] || argv[i + 1].startsWith('--')) throw safeError('Required command option is missing a value');
      result[arg.slice(2).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = argv[++i];
    } else throw safeError('Unknown command option');
  }
  if (!result.plan || !result.identity || !result.recipients || (result.apply && !result.approvedProposalSha256)) {
    throw safeError('Plan, identity, recipient file, and apply digest options are required');
  }
  return result;
}

function readBounded(file) {
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size <= 0 || stat.size > MAX_PLAN_BYTES) throw safeError('Input file is invalid or exceeds size bound');
  return fs.readFileSync(file);
}

async function main(argv = process.argv.slice(2), env = process.env, dependencies = {}) {
  const args = parseArgs(argv);
  const encryptedPlan = readBounded(args.plan);
  const planSha256 = sha256(encryptedPlan);
  if (args.apply) checkApproval(env, planSha256, args.approvedProposalSha256);
  const planBytes = (dependencies.decrypt || ageDecrypt)(args.identity, encryptedPlan, dependencies.spawn || spawnSync);
  let proposal;
  try { proposal = JSON.parse(planBytes.toString('utf8')); } catch (_) { throw safeError('Encrypted proposal is invalid'); }
  const checked = validateProposal(proposal);
  const connectionString = env.AUTH_MIGRATION_DATABASE_URL || env.AUTH_DATABASE_URL;
  if (!connectionString) throw safeError('An explicit auth migration database connection is required');
  const authDir = env.AUTH_APP_DIR || path.resolve(__dirname, '../../auth');
  const authRequire = createRequire(path.join(authDir, 'package.json'));
  const { Pool } = authRequire('pg');
  const { resolveDatabaseTls } = require(path.join(authDir, 'src/utils/dbTls'));
  const pool = new Pool({ ...resolveDatabaseTls(connectionString, env), max: 1, connectionTimeoutMillis: 5000 });
  let status = 'validated';
  try {
    if (args.apply) {
      const { runMigrations } = require(path.join(authDir, 'scripts/migrate'));
      let callbackResult;
      await runMigrations(pool, { beforePostBackfill: async client => {
        callbackResult = await resolveInMigrationTransaction(client, { proposal, planSha256,
          recipientsFile: args.recipients, encrypt: dependencies.encrypt || ageEncrypt,
          decrypt: dependencies.archiveDecrypt || ((identity, data) => ageDecrypt(identity, data, dependencies.spawn || spawnSync)),
          identityFile: args.identity });
      } });
      status = callbackResult?.status || 'validated';
    } else {
      const client = await pool.connect();
      let inTransaction = false;
      let discardClient = false;
      try {
        await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
        inTransaction = true;
        await client.query("SET LOCAL statement_timeout = '15000ms'");
        await client.query("SET LOCAL idle_in_transaction_session_timeout = '30000ms'");
        const hashes = checked.groups.map(group => group.phoneHash);
        const rows = await client.query(`SELECT id::text AS id,email,phone_number,phone_lookup_hash,
          created_at,is_phone_verified,is_email_verified,deleted FROM public.users
          WHERE deleted=FALSE AND phone_lookup_hash = ANY($1::varchar[])
          ORDER BY phone_lookup_hash,created_at,id`, [hashes]);
        assertCurrentSnapshot(proposal, rows.rows);
      } finally {
        if (inTransaction) {
          try { await client.query('ROLLBACK'); }
          catch (_) { discardClient = true; }
        }
        client.release(discardClient);
      }
    }
  } finally { await pool.end(); }
  console.log(`Contact resolution ${status}; groups=${checked.groups.length} accounts=${checked.accountCount} changed=${status === 'applied' ? checked.accountCount - checked.groups.length : 0}`);
}

if (require.main === module) main().catch(() => {
  console.error('Contact resolution failed; no contact values or database details are available in this message');
  process.exitCode = 1;
});

module.exports = { MAX_GROUPS, MAX_ACCOUNTS, APPROVAL, WRITERS_FENCED, REASON, SELECT_FIELDS,
  sha256, stateDigest, resolutionId, validateProposal, projectRow, assertCurrentSnapshot,
  sameReplayState, checkApproval, ageEncrypt, ageDecrypt, validateReplay,
  resolveInMigrationTransaction, parseArgs, main };
