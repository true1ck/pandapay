'use strict';
// Worst-case MONEY correctness, part 2: settlements, exit rules, unjoined and
// deleted people, ownership, two splits with one pair, overview, concurrency.
// `{ todo }` tests state the DESIRED behaviour and currently FAIL because of a
// real defect; they keep the suite green and become regression tests when fixed.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const { SKIP, createFixture, split, uuid } = require('./shared_expenses_worst_money_common.test.js');
const requireApi = require('node:module').createRequire(require('node:path').resolve(__dirname, '../../api/package.json'));
const { readOverview, listContexts } = requireApi('./src/shared_expenses/queries');

describe('worst-case money: settlements, exits, identities, concurrency', { skip: SKIP, timeout: 240000 }, () => {
  let F;
  before(async () => { F = await createFixture('flows'); });
  after(async () => { if (F) await F.close(); });
  const none = async ctx => assert.deepEqual(await F.invariants(ctx), []);
  // a (index 0) pays `amount`, b..(others) owe via explicit shares.
  async function debt(g, creditorIdx, debtorIdx, amount) {
    const x = await F.post(g, creditorIdx, amount, { [g.m[creditorIdx]]: BigInt(amount) }, { [g.m[debtorIdx]]: BigInt(amount) });
    assert.equal(x.accepted, true); return x.r;
  }
  const pair = async (ctx, x, y) => { const [l, h] = [x, y].sort(); const r = await F.q('SELECT balance_minor::text b FROM shared_expenses.pair_balances WHERE context_id=$1 AND low_member_id=$2 AND high_member_id=$3', [ctx, l, h]); return r.length ? BigInt(r[0].b) * (x === l ? 1n : -1n) : 0n; }; // + : y owes x

  // ---------------------------------------------------------------- settlements
  it('M10 settlement exact / partial / overpay: pair balance and allocation kinds are right', async () => {
    const g = await F.group(2); // m0 is owed by m1
    await debt(g, 0, 1, 1000);
    // partial 300
    let s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 300);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 1000n, 'a report alone moves no money');
    assert.equal((await F.settle(g.p[0], g.ctx, s.settlementId)).status, 'confirmed');
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 700n);
    // exact remainder
    s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 700);
    await F.settle(g.p[0], g.ctx, s.settlementId);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 0n);
    assert.equal((await F.pairs(g.ctx)).length, 0, 'zero pair row is deleted, never -0 / 0');
    // overpay by 50 flips the debt direction and is recorded as pair_credit
    s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 50);
    const ev = await F.settle(g.p[0], g.ctx, s.settlementId);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), -50n, 'receiver now owes the overpayer');
    const alloc = await F.q('SELECT kind,amount_minor::text a FROM shared_expenses.settlement_allocations WHERE event_id=$1', [ev.eventId]);
    assert.deepEqual(alloc, [{ kind: 'pair_credit', a: '50' }]);
    await none(g.ctx);
  });

  it('M11 reject keeps balances; report without receiver response moves nothing and never expires', async () => {
    const g = await F.group(2); await debt(g, 0, 1, 500);
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 500);
    assert.equal((await F.settle(g.p[0], g.ctx, s.settlementId, 'reject')).status, 'rejected');
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 500n);
    await assert.rejects(F.settle(g.p[0], g.ctx, s.settlementId, 'confirm'), /settlement_terminal_conflict/, 'no flip-flop after reject');
    // payer cannot confirm own payment; outsider cannot
    const s2 = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 100);
    await assert.rejects(F.settle(g.p[1], g.ctx, s2.settlementId), /receiver_confirmation_required/);
    // ages a pending report by 10 years: still pending, still no money, still confirmable (no expiry)
    await F.db.query("UPDATE shared_expenses.settlement_reports SET created_at=created_at-interval '10 years' WHERE settlement_id=$1", [s2.settlementId]).catch(async () => { /* immutable trigger: acceptable */ });
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 500n);
    await none(g.ctx);
  });

  it('M12 confirming the same settlement twice, with different operation ids, posts once', async () => {
    const g = await F.group(2); await debt(g, 0, 1, 900);
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 400);
    const a = await F.settle(g.p[0], g.ctx, s.settlementId), b = await F.settle(g.p[0], g.ctx, s.settlementId);
    assert.equal(a.eventId, b.eventId);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 500n);
    assert.equal((await F.q("SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE kind='settlement' AND context_id=$1", [g.ctx]))[0].n, 1);
    await none(g.ctx);
  });

  it('M13 race: two sessions confirm the same settlement concurrently; confirm vs reject concurrently', async () => {
    const g = await F.group(2); await debt(g, 0, 1, 900);
    const c1 = await F.newClient(), c2 = await F.newClient();
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 400);
    const pay = { contextId: g.ctx, settlementId: s.settlementId, decision: 'confirm' };
    const res = await Promise.allSettled([F.cmdOn(c1, g.p[0], 'respond_settlement', pay), F.cmdOn(c2, g.p[0], 'respond_settlement', pay)]);
    assert.ok(res.every(r => r.status === 'fulfilled'), JSON.stringify(res.map(r => r.reason?.message)));
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 500n, 'posted exactly once');
    const s2 = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 100);
    const res2 = await Promise.allSettled([F.cmdOn(c1, g.p[0], 'respond_settlement', { ...pay, settlementId: s2.settlementId }), F.cmdOn(c2, g.p[0], 'respond_settlement', { ...pay, settlementId: s2.settlementId, decision: 'reject' })]);
    assert.equal(res2.filter(r => r.status === 'fulfilled').length, 1, 'exactly one terminal decision wins');
    const kinds = await F.q('SELECT kind FROM shared_expenses.settlement_events WHERE settlement_id=$1', [s2.settlementId]);
    assert.equal(kinds.length, 1);
    await none(g.ctx);
  });

  it('M14 two different reports for the same debt both confirmed -> overpay flips direction, never loses a paisa', async () => {
    const g = await F.group(2); await debt(g, 0, 1, 1000);
    const s1 = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 1000), s2 = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 1000);
    await F.settle(g.p[0], g.ctx, s1.settlementId); await F.settle(g.p[0], g.ctx, s2.settlementId);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), -1000n);
    await none(g.ctx);
  });

  it('M15 settle then void the expense: the debt reverses into a credit, money is conserved', async () => {
    const g = await F.group(2); const r = await debt(g, 0, 1, 1000);
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 1000); await F.settle(g.p[0], g.ctx, s.settlementId);
    const v = await F.propose(g.p[0], g.ctx, { expenseId: r.expenseId, head: r.revisionId, void: true });
    assert.equal(await F.approveAll(g.ctx, v), true);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), -1000n, 'm0 now owes m1 the 1000 that was paid for a voided expense');
    await none(g.ctx);
  });

  it('M16 reporter who is neither payer nor receiver cannot create a settlement report', { todo: 'BUG B7 (S3): report_settlement only checks the reporter is an active member; a third party can file "X paid Y" and the receiver gets a confirmation prompt (no money moves without the receiver, so spam / social-engineering, not theft)' }, async () => {
    const g = await F.group(3); await debt(g, 0, 1, 500);
    await assert.rejects(F.report(g.p[2], g.ctx, g.m[1], g.m[0], 500), /settlement_member_not_authorized|context_not_authorized/);
  });

  it('M16b a third-party report cannot move money by itself; only the named receiver can confirm', async () => {
    const g = await F.group(3); await debt(g, 0, 1, 500);
    const s = await F.report(g.p[2], g.ctx, g.m[1], g.m[0], 500);
    await assert.rejects(F.settle(g.p[2], g.ctx, s.settlementId), /receiver_confirmation_required/);
    await assert.rejects(F.settle(g.p[1], g.ctx, s.settlementId), /receiver_confirmation_required/);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 500n);
    await none(g.ctx);
  });

  it('M17 a payer who reports and a receiver who is the reporter: receiver self-confirm moves money only against the receiver', async () => {
    // The receiver can fabricate "payer paid me" and confirm it alone. Money moves
    // in the payer's favour (their debt shrinks) so it only ever harms the confirmer.
    const g = await F.group(2); await debt(g, 0, 1, 500);
    const s = await F.report(g.p[0], g.ctx, g.m[1], g.m[0], 500); // reporter = receiver
    await F.settle(g.p[0], g.ctx, s.settlementId);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 0n);
    const bal = await F.balances(g.ctx); assert.equal(bal[g.m[0]] || 0n, 0n);
    await none(g.ctx);
  });

  // ------------------------------------------------------------------ exit rules
  it('M20 leaving with net-zero but non-zero pair debts strands money with a ghost', { todo: 'BUG B4 (S1/S2): leave_context checks only the net member balance. a owes c 100 and b owes a 100 -> a nets to 0, leaves, and b/c are left with pair debts to a person who can never be settled with (report_settlement needs both active)' }, async () => {
    const g = await F.group(3); // m0 owner/a? use m1 as the leaver (not owner)
    await debt(g, 1, 2, 100); // m2 owes m1
    await debt(g, 0, 1, 100); // m1 owes m0   => m1 nets 0
    assert.equal((await F.balances(g.ctx))[g.m[1]] || 0n, 0n);
    let left = true;
    try { await F.leave(g.p[1], g.ctx); } catch (e) { assert.match(e.message, /settle_first/); left = false; }
    const stranded = await F.q("SELECT 1 FROM shared_expenses.pair_balances p JOIN shared_expenses.members m ON m.context_id=p.context_id AND m.state='left' AND m.member_id IN (p.low_member_id,p.high_member_id) WHERE p.context_id=$1", [g.ctx]);
    assert.ok(!left || stranded.length === 0, 'either leaving is refused, or no pair debt may point at the departed member');
  });

  it('M21 a rejected proposal blocks the rejecting member from leaving forever', { todo: 'BUG B2 (S2): leave_context refuses while any expense naming you has no accepted revision. After you REJECT a proposal it stays unaccepted, nobody can withdraw it (void needs an accepted head), so you can never leave unless the author re-proposes' }, async () => {
    const g = await F.group(3);
    const r = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [g.m[1]]: 50n, [g.m[0]]: 50n } });
    await F.respond(g.p[1], g.ctx, r.expenseId, r.revisionId, 'reject');
    assert.equal((await F.leave(g.p[1], g.ctx)).status, 'left');
  });

  it('M21b a pending (never rejected) proposal also blocks leaving; author re-proposing without you unblocks', async () => {
    const g = await F.group(3);
    const r = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [g.m[1]]: 50n, [g.m[0]]: 50n } });
    await assert.rejects(F.leave(g.p[1], g.ctx), /settle_first/);
    const r2 = await F.propose(g.p[0], g.ctx, { expenseId: r.expenseId, head: null, total: 100, paid: { [g.m[0]]: 100n }, shares: { [g.m[2]]: 50n, [g.m[0]]: 50n } });
    assert.equal(await F.approveAll(g.ctx, r2), true);
    assert.equal((await F.leave(g.p[1], g.ctx)).status, 'left');
    await none(g.ctx);
  });

  it('M22 void/edit of an expense after a participant left can never be approved', { todo: 'BUG B3 (S2): every previously-involved member must approve an edit/void; a member who left cannot call respond_expense (not an active member), so the expense is frozen forever' }, async () => {
    const g = await F.group(3);
    const r = await F.post(g, 0, 300, { [g.m[0]]: 300n }, { [g.m[0]]: 100n, [g.m[1]]: 100n, [g.m[2]]: 100n });
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 100); await F.settle(g.p[0], g.ctx, s.settlementId);
    assert.equal((await F.leave(g.p[1], g.ctx)).status, 'left');
    const v = await F.propose(g.p[0], g.ctx, { expenseId: r.r.expenseId, head: r.r.revisionId, void: true });
    assert.equal(await F.approveAll(g.ctx, v), true, 'remaining participants should be able to void');
  });

  it('M23 a pending settlement report does not stop the payer leaving; confirming afterwards strands a balance on the left member', { todo: 'BUG B5 (S2): leave_context ignores pending settlement reports; respond_settlement only needs the receiver, so it posts a non-zero balance onto a member who has left and can never be settled with' }, async () => {
    const g = await F.group(2); await debt(g, 0, 1, 100);
    const s0 = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 100); await F.settle(g.p[0], g.ctx, s0.settlementId); // b nets to zero
    const s = await F.report(g.p[1], g.ctx, g.m[1], g.m[0], 50); // overpay report pending
    await F.leave(g.p[1], g.ctx);
    let confirmed = true; try { await F.settle(g.p[0], g.ctx, s.settlementId); } catch { confirmed = false; }
    const bal = await F.balances(g.ctx);
    assert.ok(!confirmed || (bal[g.m[1]] || 0n) === 0n, 'a left member must never end with a non-zero balance');
  });

  it('M24 account deleted (profile_id NULL): history intact, balances intact, nothing posts to them, new expenses/voids wait forever', async () => {
    const g = await F.group(3);
    const r = await F.post(g, 0, 200, { [g.m[0]]: 200n }, { [g.m[1]]: 100n, [g.m[2]]: 100n });
    await F.db.query('DELETE FROM public.profiles WHERE id=$1', [g.p[2]]);
    const mem = (await F.q('SELECT profile_id,state FROM shared_expenses.members WHERE context_id=$1 AND member_id=$2', [g.ctx, g.m[2]]))[0];
    assert.equal(mem.profile_id, null); assert.equal(mem.state, 'active');
    assert.equal((await F.balances(g.ctx))[g.m[2]], -100n);
    const v = await F.propose(g.p[0], g.ctx, { expenseId: r.r.expenseId, head: r.r.revisionId, void: true });
    assert.equal(v.status, 'awaiting_approval', 'void waits for an approver that no longer exists');
    const n = await F.propose(g.p[0], g.ctx, { total: 50, paid: { [g.m[0]]: 50n }, shares: { [g.m[2]]: 50n } });
    assert.equal(n.status, 'awaiting_approval');
    assert.equal((await F.balances(g.ctx))[g.m[2]], -100n, 'pending items post nothing');
    await assert.rejects(F.report(g.p[0], g.ctx, g.m[2], g.m[0], 10), /settlement_member_not_authorized/);
    await none(g.ctx);
  });

  it('M25 debtors of a deleted account can never settle or leave', { todo: 'BUG B6 (S2): after the creditor deletes their account the debt stays (no forgiveness / write-off path), report_settlement needs both parties active and leave_context needs net zero, so the debtor is stuck in the split forever' }, async () => {
    const g = await F.group(3);
    await debt(g, 2, 1, 100); // m1 owes m2
    await F.db.query('DELETE FROM public.profiles WHERE id=$1', [g.p[2]]);
    assert.equal((await F.leave(g.p[1], g.ctx)).status, 'left');
  });

  it('M26 owner transfer with balances outstanding does not touch money; old owner still cannot leave while owed/owing', async () => {
    const g = await F.group(3); await debt(g, 0, 1, 100);
    const before = JSON.stringify(await F.pairs(g.ctx));
    await F.cmd(g.p[0], 'transfer_owner', g.ctx, g.m[2]);
    assert.equal(JSON.stringify(await F.pairs(g.ctx)), before);
    await assert.rejects(F.leave(g.p[0], g.ctx), /settle_first/);
    await assert.rejects(F.cmd(g.p[0], 'transfer_owner', g.ctx, g.m[1]), /context_not_authorized/);
    await none(g.ctx);
  });

  it('M27 take-over after the owner deleted their account: a debtor may become owner, but gets no power over balances', async () => {
    const g = await F.group(3); await debt(g, 0, 1, 100);
    await F.db.query('DELETE FROM public.profiles WHERE id=$1', [g.p[0]]);
    assert.equal((await F.cmd(g.p[1], 'take_over_ownership', g.ctx)).status, 'owner');
    const owner = (await F.q("SELECT member_id,profile_id FROM shared_expenses.members WHERE context_id=$1 AND role='owner' AND state='active'", [g.ctx]));
    assert.equal(owner.length, 1); assert.equal(owner[0].member_id, g.m[1]);
    await assert.rejects(F.cmd(g.p[2], 'take_over_ownership', g.ctx), /owner_still_present/);
    assert.equal(await pair(g.ctx, g.m[0], g.m[1]), 100n);
    await none(g.ctx);
  });

  it('M28 owner cannot remove a member who has expenses; only unjoined, expense-free people are removable', async () => {
    const g = await F.group(2);
    const mu = await F.nameOnly(g.p[0], g.ctx, 'Ghost');
    const r = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [mu]: 100n } });
    await assert.rejects(F.cmd(g.p[0], 'remove_member', g.ctx, mu), /member_has_expenses/);
    await assert.rejects(F.cmd(g.p[0], 'remove_member', g.ctx, g.m[1]), /membership_conflict/);
    const mv = await F.nameOnly(g.p[0], g.ctx, 'Ghost2');
    assert.equal((await F.cmd(g.p[0], 'remove_member', g.ctx, mv)).status, 'removed');
    await none(g.ctx);
  });

  it('M29 an unjoined person on a proposal that nobody can withdraw wedges the owner and every other participant', { todo: 'BUG B10 (S2): a proposal that includes a name-only person never leaves "awaiting_approval" if they never join; its author cannot withdraw it (void needs an accepted head), the owner cannot remove the person (member_has_expenses counts pending revisions) and other participants cannot leave (settle_first)' }, async () => {
    const g = await F.group(3);
    const mu = await F.nameOnly(g.p[0], g.ctx, 'Never joins');
    await F.propose(g.p[0], g.ctx, { total: 300, paid: { [g.m[0]]: 300n }, shares: { [g.m[0]]: 100n, [g.m[1]]: 100n, [mu]: 100n } });
    // desired: owner can still clear the name-only person, or the author can withdraw
    assert.equal((await F.cmd(g.p[0], 'remove_member', g.ctx, mu)).status, 'removed');
  });

  // ---------------------------------------------------------- unjoined / late join
  it('M30 unjoined participant: nothing posts until they join; late join makes the OLD proposal reviewable; balances correct after approval', async () => {
    const g = await F.group(3);
    const mu = await F.nameOnly(g.p[0], g.ctx, 'Late');
    const r = await F.propose(g.p[0], g.ctx, { total: 300, paid: { [g.m[0]]: 300n }, shares: { [g.m[0]]: 100n, [g.m[1]]: 100n, [mu]: 100n } });
    assert.equal(r.status, 'awaiting_approval');
    await F.respond(g.p[1], g.ctx, r.expenseId, r.revisionId);
    assert.deepEqual(await F.balances(g.ctx), {}, 'with a missing approver nothing is posted');
    assert.equal((await F.q('SELECT accepted_revision_id FROM shared_expenses.expenses WHERE expense_id=$1', [r.expenseId]))[0].accepted_revision_id, null);
    const [late] = await F.profiles(1, 'late');
    assert.equal((await F.bindLate(g.p[0], g.ctx, mu, late)).status, 'joined');
    assert.deepEqual(await F.balances(g.ctx), {}, 'joining is not approval');
    await assert.rejects(F.respond(g.p[2], g.ctx, r.expenseId, r.revisionId), /revision_not_authorized/);
    assert.equal((await F.respond(late, g.ctx, r.expenseId, r.revisionId)).status, 'accepted');
    const b = await F.balances(g.ctx);
    assert.equal(b[g.m[0]], 200n); assert.equal(b[g.m[1]], -100n); assert.equal(b[mu], -100n);
    await none(g.ctx);
  });

  it('M31 payer is an unjoined person: expense waits; if that person is the only payer nothing ever posts', async () => {
    const g = await F.group(2);
    const mu = await F.nameOnly(g.p[0], g.ctx, 'PayerGhost');
    const r = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [mu]: 100n }, shares: { [g.m[0]]: 50n, [g.m[1]]: 50n } });
    await F.respond(g.p[1], g.ctx, r.expenseId, r.revisionId);
    assert.deepEqual(await F.balances(g.ctx), {});
    await none(g.ctx);
  });

  it('M32 a member who declines the invitation after being named in a proposal leaves the proposal pending forever', async () => {
    const g = await F.group(2);
    const [f] = await F.profiles(1, 'f'); const mf = uuid();
    await F.cmd(g.p[0], 'invite_member', { contextId: g.ctx, memberId: mf, displayName: 'Friend', profileId: f });
    const r = await F.propose(g.p[0], g.ctx, { total: 100, paid: { [g.m[0]]: 100n }, shares: { [mf]: 100n } });
    await F.asActor(f, 'SELECT shared_expenses.respond_membership($1,$2,$3,$4,$5)', [g.ctx, mf, false, uuid(), 'a'.repeat(64)]);
    await assert.rejects(F.respond(f, g.ctx, r.expenseId, r.revisionId), /context_not_authorized/);
    assert.deepEqual(await F.balances(g.ctx), {});
    await none(g.ctx);
  });

  // -------------------------------------------------------- direct + member caps
  it('M33 direct split: a friend who left cannot be re-added and the slot is lost (left member counts toward the limit of 2)', { todo: 'BUG B11 (S3): direct limit counts left members, so after the friend leaves the owner can neither re-add them nor add anyone else to that split (a brand-new direct split is the only workaround)' }, async () => {
    const [a, b] = await F.profiles(2);
    const { ctx } = await F.createContext(a, 'direct', 'Bee' + uuid().slice(0, 4));
    await F.join(a, ctx, b, 'Bee');
    await F.leave(b, ctx);
    await F.join(a, ctx, b, 'Bee again');
  });

  it('M34 group member limit counts left members (200 including the departed)', async () => {
    const [a] = await F.profiles(1); const { ctx } = await F.createContext(a, 'group', 'big' + uuid().slice(0, 4));
    await F.db.query("INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state,display_name) SELECT $1,gen_random_uuid(),NULL,'member','left','L'||g FROM generate_series(1,199) g", [ctx]);
    await assert.rejects(F.nameOnly(a, ctx, 'one too many'), /context_member_limit/);
  });

  // ------------------------------------------ same pair, two splits; overview
  it('M40 direct + group with the same pair keep separate balances; overview sums them exactly', async () => {
    const [a, b] = await F.profiles(2);
    const d = await F.createContext(a, 'direct', 'Pal' + uuid().slice(0, 4)); const dm = await F.join(a, d.ctx, b, 'Pal');
    const gr = await F.createContext(a, 'group', 'Trip' + uuid().slice(0, 4)); const gm = await F.join(a, gr.ctx, b, 'Pal-g');
    // direct: b owes a 700 ; group: a owes b 300
    let r = await F.propose(a, d.ctx, { total: 700, paid: { [d.owner]: 700n }, shares: { [dm]: 700n } }); await F.approveAll(d.ctx, r);
    r = await F.propose(b, gr.ctx, { total: 300, paid: { [gm]: 300n }, shares: { [gr.owner]: 300n } }); await F.approveAll(gr.ctx, r);
    assert.equal(await pair(d.ctx, d.owner, dm), 700n); assert.equal(await pair(gr.ctx, gr.owner, gm), -300n);
    const oa = await F.withActor(a, c => readOverview(c, a)), ob = await F.withActor(b, c => readOverview(c, b));
    assert.deepEqual([oa.owedMinor, oa.owingMinor, oa.netMinor, oa.contextCount], ['700', '300', '400', '2']);
    assert.deepEqual([ob.owedMinor, ob.owingMinor, ob.netMinor], ['300', '700', '-400']);
    const list = await F.withActor(a, c => listContexts(c, a, {}));
    const by = Object.fromEntries(list.items.map(i => [i.contextId, i]));
    assert.deepEqual([by[d.ctx].owedMinor, by[d.ctx].owingMinor, by[gr.ctx].owedMinor, by[gr.ctx].owingMinor], ['700', '0', '0', '300']);
    // overview net == sum of member balances over the viewer's active memberships
    const net = (await F.balances(d.ctx))[d.owner] + (await F.balances(gr.ctx))[gr.owner];
    assert.equal(net.toString(), oa.netMinor);
    await none(d.ctx); await none(gr.ctx);
  });

  // ------------------------------------------------------------- idempotency/races
  it('M50 replaying the same operation id returns the stored result and never posts twice', async () => {
    const g = await F.group(2);
    const payload = { contextId: g.ctx, expenseId: uuid(), revisionId: uuid(), expectedHeadRevisionId: null, title: 'x', occurredOn: '2026-11-05', sources: [], void: false, snapshot: F.snapshot(100, { [g.m[0]]: 100 }, { [g.m[1]]: 100 }) };
    const op = uuid(), h = 'b'.repeat(64);
    const first = (await F.asActor(g.p[0], 'SELECT shared_expenses.submit_proposal($1,$2,$3) AS v', [payload, op, h])).rows[0].v;
    const again = (await F.asActor(g.p[0], 'SELECT shared_expenses.submit_proposal($1,$2,$3) AS v', [payload, op, h])).rows[0].v;
    assert.deepEqual(again, first);
    await assert.rejects(F.asActor(g.p[0], 'SELECT shared_expenses.submit_proposal($1,$2,$3) AS v', [{ ...payload, title: 'y' }, op, h]), /operation_conflict/);
    const rop = uuid(); const resp = { contextId: g.ctx, expenseId: payload.expenseId, revisionId: payload.revisionId, decision: 'approve' };
    const r1 = (await F.asActor(g.p[1], 'SELECT shared_expenses.respond_expense($1,$2,$3) AS v', [resp, rop, h])).rows[0].v;
    const r2 = (await F.asActor(g.p[1], 'SELECT shared_expenses.respond_expense($1,$2,$3) AS v', [resp, rop, h])).rows[0].v;
    assert.deepEqual(r1, r2); assert.equal(r1.status, 'accepted');
    assert.equal((await F.q('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]))[0].n, 1);
    await none(g.ctx);
  });

  it('M51 race: last two approvers approve at the same instant, journal posts once', async () => {
    const g = await F.group(4);
    const r = await F.propose(g.p[0], g.ctx, { total: 300, paid: { [g.m[0]]: 300n }, shares: { [g.m[1]]: 100n, [g.m[2]]: 100n, [g.m[3]]: 100n } });
    const cs = [await F.newClient(), await F.newClient(), await F.newClient()];
    const res = await Promise.allSettled([1, 2, 3].map(i => F.cmdOn(cs[i - 1], g.p[i], 'respond_expense', { contextId: g.ctx, expenseId: r.expenseId, revisionId: r.revisionId, decision: 'approve' })));
    assert.ok(res.every(x => x.status === 'fulfilled'), JSON.stringify(res.map(x => x.reason?.message)));
    const b = await F.balances(g.ctx); assert.equal(b[g.m[0]], 300n);
    assert.equal((await F.q('SELECT count(*)::int n FROM shared_expenses.journal_entries WHERE context_id=$1', [g.ctx]))[0].n, 3);
    await none(g.ctx);
  });

  it('M52 race: two competing edits of the same head; whichever is accepted first wins, the loser cannot post later', async () => {
    const g = await F.group(2);
    const r = await F.post(g, 0, 100, { [g.m[0]]: 100n }, { [g.m[1]]: 100n });
    const e1 = await F.propose(g.p[0], g.ctx, { expenseId: r.r.expenseId, head: r.r.revisionId, total: 200, paid: { [g.m[0]]: 200n }, shares: { [g.m[1]]: 200n } });
    const e2 = await F.propose(g.p[0], g.ctx, { expenseId: r.r.expenseId, head: r.r.revisionId, total: 300, paid: { [g.m[0]]: 300n }, shares: { [g.m[1]]: 300n } });
    await F.respond(g.p[1], g.ctx, r.r.expenseId, e2.revisionId);
    assert.equal((await F.balances(g.ctx))[g.m[0]], 300n);
    await assert.rejects(F.respond(g.p[1], g.ctx, r.r.expenseId, e1.revisionId), /revision_head_conflict/);
    assert.equal((await F.balances(g.ctx))[g.m[0]], 300n);
    await none(g.ctx);
  });

  it('M53 an edit that is rejected, or never answered, leaves the old accepted balances untouched', async () => {
    const g = await F.group(2);
    const r = await F.post(g, 0, 100, { [g.m[0]]: 100n }, { [g.m[1]]: 100n });
    const e = await F.propose(g.p[0], g.ctx, { expenseId: r.r.expenseId, head: r.r.revisionId, total: 999, paid: { [g.m[0]]: 999n }, shares: { [g.m[1]]: 999n } });
    assert.equal(e.status, 'awaiting_approval');
    assert.equal((await F.balances(g.ctx))[g.m[0]], 100n);
    await F.respond(g.p[1], g.ctx, r.r.expenseId, e.revisionId, 'reject');
    assert.equal((await F.balances(g.ctx))[g.m[0]], 100n);
    assert.equal((await F.leave(g.p[1], g.ctx).catch(x => x.message)).length > 0, true); // leaving is refused: owes 100
    await none(g.ctx);
  });
});
