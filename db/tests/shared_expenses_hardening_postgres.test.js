'use strict';
// Explicit opt-in only. The shared fixture validates a loopback /postgres URL,
// creates a random wm_* database and drops only the database it created.
// Run with PANDAPAY_WORST_MONEY_PG_URL and the same invocation as the money suites.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { SKIP, createFixture, uuid, hex } = require('./shared_expenses_worst_money_common.test.js');

const transferSql = 'SELECT shared_expenses.transfer_owner($1::uuid,$2::uuid,$3::uuid,$4::text) AS result';
const leaveSql = 'SELECT shared_expenses.leave_context($1::uuid,$2::uuid,$3::text) AS result';
const resultOf = (promise) => promise.then((value) => ({ ok: true, value }), (error) => ({ ok: false, error }));

// Observe the actual PostgreSQL lock wait rather than relying on a fixed sleep.
async function waitForLock(F, client) {
  const pid = client.processID;
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline) {
    const rows = await F.q('SELECT wait_event_type FROM pg_stat_activity WHERE pid=$1', [pid]);
    if (rows[0]?.wait_event_type === 'Lock') return;
    await new Promise((resolve) => setTimeout(resolve, 15));
  }
  assert.fail('the second request did not reach the intended context lock');
}

async function openActor(F, profile) {
  const client = await F.newClient();
  await client.query('BEGIN');
  await client.query("SET LOCAL statement_timeout='10s'; SET LOCAL lock_timeout='8s'; SET LOCAL ROLE app_user");
  await client.query("SELECT set_config('app.user_id',$1,true)", [profile]);
  return client;
}

async function waitingClient(F) {
  const client = await F.newClient();
  await client.query("SET statement_timeout='10s'; SET lock_timeout='8s'");
  return client;
}

describe('shared expense command safety against real PostgreSQL', { skip: SKIP, timeout: 120000 }, () => {
  let F;
  before(async () => { F = await createFixture('hardening'); });
  after(async () => { if (F) await F.close(); });

  it('a recycled phone number can request to join by inbox or link but cannot see the split until the owner confirms', async () => {
    const g = await F.group(1, 'phone reassignment');
    const [owner] = g.p;
    const [oldHolder, newHolder] = await F.profiles(2, 'holder');
    const phone = hex();
    await F.asActor(oldHolder, 'SELECT shared_expenses.register_phone($1,true)', [phone]);
    const invited = [];
    const second = await F.createContext(owner, 'group', 'Second private group');
    for (const contextId of [g.ctx, second.ctx]) {
      const memberId = await F.nameOnly(owner, contextId, 'Original contact');
      const invitationId = uuid(), tokenHash = hex();
      await F.asActor(owner, 'SELECT shared_expenses.create_invitation($1,$2)', [
        { invitationId, contextId, memberId, targetPhoneHash: phone, tokenHash }, hex(),
      ]);
      invited.push({ invitationId, memberId, tokenHash });
    }
    await F.asActor(oldHolder, 'SELECT shared_expenses.register_phone($1,true)', [hex()]);
    await F.asActor(newHolder, 'SELECT shared_expenses.register_phone($1,true)', [phone]);
    const inbox = (await F.asActor(newHolder, 'SELECT shared_expenses.list_my_invitations($1) AS result', [phone])).rows[0].result;
    assert.ok(inbox.items.some((item) => item.invitationId === invited[0].invitationId));
    assert.ok(inbox.items.every((item) => item.contextName === 'Group split'));

    const byId = await F.cmd(newHolder, 'claim_invitation_by_id', invited[0].invitationId, phone, '1234');
    const byLink = await F.cmd(newHolder, 'claim_invitation', invited[1].tokenHash, phone, '1234');
    assert.equal(byId.status, 'awaiting_owner');
    assert.equal(byLink.status, 'awaiting_owner');
    const read = (contextId) => F.asActor(newHolder, 'SELECT shared_expenses._can_read_context($1) AS allowed', [contextId]).then((result) => result.rows[0].allowed);
    assert.equal(await read(g.ctx), false);
    assert.equal(await read(second.ctx), false);
    await assert.rejects(F.cmd(oldHolder, 'respond_invitation', invited[0].invitationId, true), /context_not_authorized/);
    await F.cmd(owner, 'respond_invitation', invited[0].invitationId, true);
    assert.equal(await read(g.ctx), true);
    assert.equal(await read(second.ctx), false);
    assert.deepEqual(await F.pairs(g.ctx), []);
  });

  it('erasing an account removes its private split data and issued links while preserving shared balances', async () => {
    const g = await F.group(2, 'erasure');
    const [owner, survivor] = g.p;
    const [ownerMember, survivorMember] = g.m;
    const phone = hex(), token = hex(), linkToken = hex();
    const member = await F.nameOnly(owner, g.ctx, 'Invitee');
    const invitationId = uuid(), resourceId = uuid();

    await F.cmd(owner, 'rename_member', { contextId: g.ctx, memberId: ownerMember, displayName: 'Erased member' });
    const { accepted } = await F.post(g, 0, 400, { [ownerMember]: 400 }, { [ownerMember]: 200, [survivorMember]: 200 });
    assert.equal(accepted, true);
    const ownerPayment = await F.cmd(owner, 'report_settlement', {
      contextId: g.ctx, settlementId: uuid(), payerMemberId: survivorMember, receiverMemberId: ownerMember,
      amountMinor: '50', currency: 'INR', method: 'bank', paidOn: '2026-11-07', reference: 'PRIVATE-OWNER',
    });
    const survivorPayment = await F.cmd(survivor, 'report_settlement', {
      contextId: g.ctx, settlementId: uuid(), payerMemberId: survivorMember, receiverMemberId: ownerMember,
      amountMinor: '50', currency: 'INR', method: 'bank', paidOn: '2026-11-07', reference: 'PRIVATE-SURVIVOR',
    });
    await F.db.query(
      'INSERT INTO shared_expenses.source_resources(resource_id,owner_profile_id,canonical_transaction_id,source_version,eligible_minor,private_snapshot) VALUES($1,$2,$3,$4,400,$5)',
      [resourceId, owner, uuid(), hex(), { note: 'private' }],
    );
    await F.asActor(owner, 'SELECT shared_expenses.create_invitation($1,$2)', [
      { invitationId, contextId: g.ctx, memberId: member, targetPhoneHash: phone, tokenHash: token }, hex(),
    ]);
    await F.cmd(owner, 'create_group_link', g.ctx, linkToken);
    const pairs = await F.pairs(g.ctx);

    await F.db.query('DELETE FROM public.profiles WHERE id=$1', [owner]);

    assert.deepEqual(await F.pairs(g.ctx), pairs);
    const [former] = await F.q('SELECT profile_id,display_name FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2', [g.ctx, ownerMember]);
    assert.deepEqual(former, { profile_id: null, display_name: null });
    const [issued] = await F.q('SELECT state,target_phone_hash FROM shared_expenses.invitations WHERE invitation_id=$1', [invitationId]);
    assert.deepEqual(issued, { state: 'rejected', target_phone_hash: null });
    assert.deepEqual(await F.q('SELECT 1 FROM shared_expenses.group_links WHERE token_hash=$1', [linkToken]), []);
    assert.deepEqual(await F.q('SELECT 1 FROM shared_expenses.source_resources WHERE resource_id=$1', [resourceId]), []);
    assert.deepEqual(await F.q('SELECT 1 FROM shared_expenses.private_cost_facts WHERE profile_id=$1', [owner]), []);
    const refs = await F.q('SELECT settlement_id FROM shared_expenses.settlement_private_references WHERE settlement_id IN ($1,$2)', [ownerPayment.settlementId, survivorPayment.settlementId]);
    assert.deepEqual(refs, [{ settlement_id: survivorPayment.settlementId }]);
  });

  it('lost-response owner transfer retry returns its original receipt and emits no second event', async () => {
    const g = await F.group(3, 'transfer retry');
    const params = [g.ctx, g.m[1], uuid(), hex()];
    const first = (await F.asActor(g.p[0], transferSql, params)).rows[0].result;
    const replay = (await F.asActor(g.p[0], transferSql, params)).rows[0].result;
    assert.deepEqual(replay, first);
    const owners = await F.q("SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]);
    assert.deepEqual(owners.map((row) => row.member_id), [g.m[1]]);
    const events = await F.q("SELECT 1 FROM shared_expenses.context_events WHERE context_id=$1 AND kind='member.owner_changed'", [g.ctx]);
    assert.equal(events.length, 1);
    assert.deepEqual(await F.invariants(g.ctx), []);
  });

  it('lost-response leave retry returns the original receipt without emitting another leave', async () => {
    const g = await F.group(2, 'leave retry');
    const params = [g.ctx, uuid(), hex()];
    const first = (await F.asActor(g.p[1], leaveSql, params)).rows[0].result;
    const replay = (await F.asActor(g.p[1], leaveSql, params)).rows[0].result;
    assert.deepEqual(replay, first);
    const events = await F.q("SELECT 1 FROM shared_expenses.context_events WHERE context_id=$1 AND kind='membership.left'", [g.ctx]);
    assert.equal(events.length, 1);
  });

  it('a member whose net is zero cannot leave while both pairwise debts still exist', async () => {
    const g = await F.group(3, 'pair debts');
    await F.post(g, 1, 100, { [g.m[1]]: 100n }, { [g.m[2]]: 100n });
    await F.post(g, 0, 100, { [g.m[0]]: 100n }, { [g.m[1]]: 100n });
    assert.equal((await F.balances(g.ctx))[g.m[1]] || 0n, 0n);
    assert.equal((await F.pairs(g.ctx)).length, 2);
    await assert.rejects(F.leave(g.p[1], g.ctx), /settle_first/);
    const member = (await F.q('SELECT state FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2', [g.ctx, g.m[1]]))[0];
    assert.equal(member.state, 'active');
    assert.deepEqual(await F.invariants(g.ctx), []);
  });

  it('a pending settlement blocks leaving even before it changes any balance', async () => {
    const g = await F.group(2, 'pending payment');
    const report = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 50);
    assert.equal((await F.balances(g.ctx))[g.m[1]] || 0n, 0n);
    await assert.rejects(F.leave(g.p[1], g.ctx), /settle_first/);
    const member = (await F.q('SELECT state FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2', [g.ctx, g.m[1]]))[0];
    assert.equal(member.state, 'active');
    assert.equal((await F.q('SELECT 1 FROM shared_expenses.settlement_events WHERE context_id=$1 AND settlement_id=$2', [g.ctx, report.settlementId])).length, 0);
    assert.deepEqual(await F.invariants(g.ctx), []);
  });

  it('rejecting an unaccepted proposal does not prevent an otherwise settled member leaving', async () => {
    const g = await F.group(3, 'rejected proposal');
    const proposal = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [g.m[0]]: 50n, [g.m[1]]: 50n } });
    await F.respond(g.p[1], g.ctx, proposal.expenseId, proposal.revisionId, 'reject');
    assert.equal((await F.leave(g.p[1], g.ctx)).status, 'left');
    const approvals = await F.q('SELECT decision FROM shared_expenses.revision_approvals WHERE context_id=$1 AND revision_id=$2 AND member_id=$3', [g.ctx, proposal.revisionId, g.m[1]]);
    assert.deepEqual(approvals.map((row) => row.decision), ['reject'], 'leaving never changes rejection into consent');
    assert.equal((await F.q('SELECT 1 FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx])).length, 0);
    assert.deepEqual(await F.invariants(g.ctx), []);
  });

  it('an ex-owner transfer queued behind the first transfer is refused after the context lock opens', async () => {
    const g = await F.group(3, 'queued ownership');
    const held = await openActor(F, g.p[0]);
    await held.query(transferSql, [g.ctx, g.m[1], uuid(), hex()]);
    const waiting = await waitingClient(F);
    const second = resultOf(F.cmdOn(waiting, g.p[0], 'transfer_owner', g.ctx, g.m[2]));
    let committed = false;
    try {
      await waitForLock(F, waiting);
      await held.query('COMMIT'); committed = true;
      const result = await second;
      assert.equal(result.ok, false, 'revoked owner authority cannot survive a queued lock wait');
      assert.match(result.error.message, /context_not_authorized/);
      const owners = await F.q("SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]);
      assert.deepEqual(owners.map((row) => row.member_id), [g.m[1]]);
      assert.deepEqual(await F.invariants(g.ctx), []);
    } finally {
      if (!committed) await held.query('ROLLBACK').catch(() => {});
      await second;
    }
  });

  it('a member cannot submit a proposal queued behind that member leaving', async () => {
    const g = await F.group(3, 'queued departure');
    const held = await openActor(F, g.p[1]);
    await held.query(leaveSql, [g.ctx, uuid(), hex()]);
    const waiting = await waitingClient(F);
    const payload = {
      contextId: g.ctx, expenseId: uuid(), revisionId: uuid(), expectedHeadRevisionId: null,
      title: 'Queued proposal', occurredOn: '2026-11-07', sources: [], void: false,
      // Financial participants remain active, so only the departed actor's
      // revoked write authority can reject this otherwise valid proposal.
      snapshot: F.snapshot(100, { [g.m[0]]: 100n }, { [g.m[2]]: 100n }),
    };
    const proposed = resultOf(F.cmdOn(waiting, g.p[1], 'submit_proposal', payload));
    let committed = false;
    try {
      await waitForLock(F, waiting);
      await held.query('COMMIT'); committed = true;
      const result = await proposed;
      assert.equal(result.ok, false, 'departed member cannot submit after the lock opens');
      assert.match(result.error.message, /context_not_authorized|membership_not_authorized/);
      assert.equal((await F.q('SELECT 1 FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2', [g.ctx, payload.expenseId])).length, 0);
      assert.deepEqual(await F.invariants(g.ctx), []);
    } finally {
      if (!committed) await held.query('ROLLBACK').catch(() => {});
      await proposed;
    }
  });

  it('SQL rejects null or numeric snapshot currency before storing an expense', async () => {
    const g = await F.group(2, 'snapshot currency');
    for (const currency of [null, 123]) {
      const snapshot = F.snapshot(100, { [g.m[0]]: 100n }, { [g.m[1]]: 100n });
      snapshot.currency = currency;
      await assert.rejects(F.propose(g.p[0], g.ctx, { snapshot }), /invalid_snapshot/);
    }
    assert.equal((await F.q('SELECT 1 FROM shared_expenses.expense_revisions WHERE context_id=$1', [g.ctx])).length, 0);
  });

  it('SQL rejects null or numeric settlement currency before storing a report', async () => {
    const g = await F.group(2, 'settlement currency');
    for (const currency of [null, 123]) {
      await assert.rejects(F.cmd(g.p[1], 'report_settlement', {
        contextId: g.ctx, settlementId: uuid(), payerMemberId: g.m[1], receiverMemberId: g.m[0],
        amountMinor: '50', currency, method: 'bank', paidOn: '2026-11-07',
      }), /invalid_settlement/);
    }
    assert.equal((await F.q('SELECT 1 FROM shared_expenses.settlement_reports WHERE context_id=$1', [g.ctx])).length, 0);
  });
});
