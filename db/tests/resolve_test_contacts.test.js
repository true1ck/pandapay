'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const {
  APPROVAL, WRITERS_FENCED, REASON, sha256, stateDigest, resolutionId,
  validateProposal, assertCurrentSnapshot, checkApproval, validateReplay,
  resolveInMigrationTransaction,
} = require('../scripts/resolve_test_contacts');

const ids = ['10000000-0000-4000-8000-000000000001', '10000000-0000-4000-8000-000000000002'];
const hash = 'a'.repeat(64);
const fields = ['id','email','phone_number','phone_lookup_hash','created_at','is_phone_verified','is_email_verified','deleted'];
const digestRow = value => stateDigest(Object.fromEntries(fields.map(field => [field, value[field]])));
function row(id, created, phoneHash = hash) {
  return { id, email: `${id.slice(-1)}@example.invalid`, phone_number: `ciphertext-${id.slice(-1)}`,
    phone_lookup_hash: phoneHash, created_at: created, is_phone_verified: true,
    is_email_verified: true, deleted: false };
}
function proposal() {
  const accounts = [row(ids[0], '2026-01-01T00:00:00.000Z'), row(ids[1], '2026-01-02T00:00:00.000Z')];
  return { format: 'pandapay-contact-conflict-proposal-v1', status: 'proposal_only_no_changes_applied', groups: [{
    group: 1, proposed_phone_account_id: ids[0], accounts: accounts.map((account, i) => ({ ...account,
      proposed_action: i === 0 ? 'retain_phone' : 'archive_original_phone_and_make_email_only',
      requires_email_verification_before_change: false, state_sha256: digestRow(account) })) }]
  };
}

test('validates reviewed proposal shape, keeper, state digest, and verified secondary email', () => {
  const p = proposal();
  assert.equal(validateProposal(p).accountCount, 2);
  const badKeeper = structuredClone(p); badKeeper.groups[0].proposed_phone_account_id = ids[1];
  assert.throws(() => validateProposal(badKeeper), /keeper/);
  const newerKeeper = structuredClone(p);
  newerKeeper.groups[0].proposed_phone_account_id = ids[1];
  newerKeeper.groups[0].accounts[0].proposed_action = 'archive_original_phone_and_make_email_only';
  newerKeeper.groups[0].accounts[1].proposed_action = 'retain_phone';
  assert.throws(() => validateProposal(newerKeeper), /planner selection rule/);
  const unverifiedKeeper = structuredClone(p);
  unverifiedKeeper.groups[0].accounts[0].is_phone_verified = false;
  unverifiedKeeper.groups[0].accounts[0].state_sha256 = digestRow(unverifiedKeeper.groups[0].accounts[0]);
  assert.throws(() => validateProposal(unverifiedKeeper), /planner selection rule/);
  const fallback = structuredClone(p);
  for (const account of fallback.groups[0].accounts) {
    account.is_phone_verified = false;
    account.state_sha256 = digestRow(account);
  }
  assert.equal(validateProposal(fallback).groups[0].keeperId, ids[0]);
  fallback.groups[0].proposed_phone_account_id = ids[1];
  fallback.groups[0].accounts[0].proposed_action = 'archive_original_phone_and_make_email_only';
  fallback.groups[0].accounts[1].proposed_action = 'retain_phone';
  assert.throws(() => validateProposal(fallback), /planner selection rule/);
  const badState = structuredClone(p); badState.groups[0].accounts[1].email = 'changed@example.invalid';
  assert.throws(() => validateProposal(badState), /digest/);
  const unverified = structuredClone(p); unverified.groups[0].accounts[1].is_email_verified = false;
  unverified.groups[0].accounts[1].state_sha256 = digestRow(unverified.groups[0].accounts[1]);
  assert.throws(() => validateProposal(unverified), /verified email/);
});

test('rejects stale inventory and any extra current active account in a shared phone group', () => {
  const p = proposal();
  assertCurrentSnapshot(p, p.groups[0].accounts);
  assert.throws(() => assertCurrentSnapshot(p, [p.groups[0].accounts[0]]), /membership/);
  const extra = { ...row('10000000-0000-4000-8000-000000000003', '2026-01-03T00:00:00.000Z') };
  assert.throws(() => assertCurrentSnapshot(p, [...p.groups[0].accounts, extra]), /membership/);
  const stale = p.groups[0].accounts.map(value => ({ ...value })); stale[1].phone_number = 'changed';
  assert.throws(() => assertCurrentSnapshot(p, stale), /state/);
});

test('approval binds the exact encrypted plan digest and deterministic resolution ID', () => {
  const digest = sha256(Buffer.from('synthetic encrypted plan'));
  checkApproval({ CONTACT_RESOLUTION_APPROVAL: APPROVAL, CONTACT_RESOLUTION_WRITERS_FENCED: WRITERS_FENCED }, digest, digest);
  assert.throws(() => checkApproval({}, digest, digest), /approval/);
  assert.notEqual(resolutionId(digest), resolutionId(sha256(Buffer.from('other plan'))));
  assert.equal(resolutionId(digest), resolutionId(digest));
});

test('replay accepts only complete, checksummed encrypted history and exact resolved state', async () => {
  const p = proposal();
  const planHash = 'b'.repeat(64);
  const rid = resolutionId(planHash);
  const keeper = p.groups[0].accounts[0];
  const secondary = p.groups[0].accounts[1];
  const archive = Buffer.from(JSON.stringify(Object.fromEntries(Object.entries(secondary).filter(([key]) =>
    ['id','email','phone_number','phone_lookup_hash','created_at','is_phone_verified','is_email_verified','deleted'].includes(key)))));
  const resolved = { ...secondary, phone_number: null, phone_lookup_hash: null, is_phone_verified: false };
  const history = [{ resolution_id: rid, user_id: secondary.id, retained_phone_account_id: keeper.id,
    original_row_age: archive, archive_sha256: sha256(archive), reason: REASON }];
  await validateReplay({}, validateProposal(p), [keeper, resolved], history, {
    rid, planSha256: planHash, identityFile: 'synthetic', decrypt: () => archive,
  });
  const reassigned = { ...resolved, phone_number: 'new-phone-ciphertext', phone_lookup_hash: 'e'.repeat(64), is_phone_verified: true };
  await assert.rejects(() => validateReplay({}, validateProposal(p), [keeper, reassigned], history, {
    rid, planSha256: planHash, identityFile: 'synthetic', decrypt: () => archive,
  }), /inconsistent/);
  await assert.rejects(() => validateReplay({}, validateProposal(p), [keeper, resolved], [], {
    rid, planSha256: planHash, identityFile: 'synthetic', decrypt: () => archive,
  }), /partial/);
  const corrupt = [{ ...history[0], archive_sha256: '0'.repeat(64) }];
  await assert.rejects(() => validateReplay({}, validateProposal(p), [keeper, resolved], corrupt, {
    rid, planSha256: planHash, identityFile: 'synthetic', decrypt: () => archive,
  }), /inconsistent/);
});

test('apply transaction archives before clearing only secondary phone fields and commits atomically', async () => {
  const p = proposal();
  const planHash = 'c'.repeat(64);
  const operations = [];
  const client = { query: async (sql, params) => {
    operations.push({ sql, params });
    if (sql.includes('SELECT id::text AS id,email')) return { rows: p.groups[0].accounts, rowCount: 2 };
    if (sql.includes('FROM public.contact_resolution_history')) return { rows: [], rowCount: 0 };
    if (sql.startsWith('UPDATE public.users')) return { rows: [], rowCount: 1 };
    return { rows: [], rowCount: 0 };
  } };
  const outcome = await resolveInMigrationTransaction(client, { proposal: p, planSha256: planHash,
    recipientsFile: 'public-recipient.txt', encrypt: (_file, bytes) => Buffer.concat([Buffer.from('age-test:'), bytes]) });
  assert.equal(outcome.status, 'applied');
  assert.equal(operations.filter(item => item.sql.startsWith('INSERT INTO public.contact_resolution_history')).length, 1);
  const update = operations.find(item => item.sql.startsWith('UPDATE public.users'));
  assert.match(update.sql, /phone_number=NULL,phone_lookup_hash=NULL,is_phone_verified=FALSE/);
  assert.ok(!/\bDELETE\b|UPDATE public\.users SET id|session/i.test(update.sql));
  assert.equal(operations.at(-1).sql, 'COMMIT');
  assert.deepEqual(operations.filter(item => item.sql.startsWith('INSERT INTO')).map(item => item.params[5]), [REASON]);
});

test('archive failure rolls back the whole group and exposes no data through safe error', async () => {
  const p = proposal();
  const operations = [];
  const client = { query: async sql => {
    operations.push(sql);
    if (String(sql).includes('SELECT id::text AS id,email')) return { rows: p.groups[0].accounts, rowCount: 2 };
    if (String(sql).includes('FROM public.contact_resolution_history')) return { rows: [], rowCount: 0 };
    return { rows: [], rowCount: 0 };
  } };
  await assert.rejects(() => resolveInMigrationTransaction(client, { proposal: p, planSha256: 'd'.repeat(64),
    recipientsFile: 'unused', encrypt: () => { throw new Error('private phone/contact detail'); } }), /Encrypted archive creation failed/);
  assert.equal(operations.at(-1), 'ROLLBACK');
});
