'use strict';
// Z05 : SAME PEOPLE ACROSS MANY SPLITS. One friend in 50 groups + a direct split, duplicate labels,
// per-context pair balances vs a per-person aggregate, and the per-creator friend-name advisory lock
// under 5 parallel devices. Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed } = S;
const Q = S.requireApi('./src/shared_expenses/queries');

describe('Z05 same people across many splits', { skip: SKIP, timeout: 3600 * 1000 }, () => {
  let F;
  before(async () => { F = await S.createFixture('z05'); });
  after(async () => { if (F) await F.close(); });

  it('Z05.1 one friend X in 50 groups + 1 direct split: per-context balances, overview (gross per context) vs per-person net, duplicate labels', async () => {
    const [U, X] = await S.bulkProfiles(F, 2, 'pp');
    const owed = []; // [{ctx, uOwedByX}]
    let uMember = {}, xMember = {};
    const ctxs = [];
    for (let i = 0; i < 51; i++) {
      const ctx = uuid(); const kind = i === 0 ? 'direct' : 'group';
      const c = await S.createCtx(F, U, ctx, kind, kind === 'direct' ? 'Xavier' : `Group ${i}`);
      const m = uuid(); await S.inviteMember(F, U, ctx, m, 'Xavier', X); await S.respondMembership(F, X, ctx, m, true);
      // alternate who paid: U paid 1000 split evenly (X owes 500) or X paid 600 (U owes 300)
      const uPays = i % 3 !== 0, amount = uPays ? 1000 : 600;
      const payer = uPays ? { p: U, m: c.memberId } : { p: X, m }; const other = uPays ? { p: X } : { p: U };
      const pr = S.proposal(ctx, S.equalSnapshot(amount, payer.m, [c.memberId, m]));
      const r = await S.submit(F, payer.p, pr); if (r.status !== 'accepted') await S.respondExpense(F, other.p, ctx, pr.expenseId, pr.revisionId);
      ctxs.push({ ctx, xOwesU: uPays ? 500 : -300 });
    }
    const perContext = await F.q(`SELECT p.context_id,sum(CASE WHEN low_member_id=mu.member_id THEN balance_minor ELSE -balance_minor END)::int u_is_owed FROM shared_expenses.pair_balances p JOIN shared_expenses.members mu ON mu.context_id=p.context_id AND mu.profile_id=$1 AND mu.member_id IN (p.low_member_id,p.high_member_id) GROUP BY 1`, [U]);
    const byCtx = new Map(perContext.map(r => [r.context_id, r.u_is_owed]));
    for (const c of ctxs) assert.equal(byCtx.get(c.ctx), c.xOwesU, 'each context has its own independent pair balance');
    const personNet = ctxs.reduce((a, c) => a + c.xOwesU, 0);
    const grossOwed = ctxs.filter(c => c.xOwesU > 0).reduce((a, c) => a + c.xOwesU, 0), grossOwing = -ctxs.filter(c => c.xOwesU < 0).reduce((a, c) => a + c.xOwesU, 0);
    const ov = (await S.asActorTimed(F, U, c => Q.readOverview(c, U))).value;
    assert.equal(Number(ov.owedMinor), grossOwed); assert.equal(Number(ov.owingMinor), grossOwing);
    const list = (await S.asActorTimed(F, U, c => Q.listContexts(c, U, { limit: '100' }))).value.items;
    // same person, 51 rows in the list, 51 different "Xavier"-like labels? the group rows are group names, the direct row is the friend's name
    const labels = list.map(i => i.name);
    // duplicate labels: same label in all 50 groups for different members is fine; a second direct "Xavier" for the same creator is not
    let dupErr = null; try { await S.createCtx(F, U, uuid(), 'direct', 'xavier'); } catch (e) { dupErr = e.message; }
    let accentErr = null; try { await S.createCtx(F, U, uuid(), 'direct', 'Xävier'); } catch (e) { accentErr = e.message; }
    record('Z05.1', { contexts: ctxs.length, overview: { owed: ov.owedMinor, owing: ov.owingMinor, net: ov.netMinor }, perPersonNetWithX: personNet, grossVsNetInflation: Number(ov.owedMinor) - Math.max(personNet, 0),
      listRowsForX: list.length, distinctLabels: new Set(labels).size, secondDirectXavier: dupErr, accentVariant: accentErr });
    assert.equal(dupErr, 'friend_name_taken'); assert.equal(accentErr, 'friend_name_taken');
    assert.equal(Number(ov.netMinor), personNet, 'net across contexts equals the per-person net');
  });

  it('Z05.2 5 devices of one user add friends in parallel at 1000 existing direct splits: lock contention + same-name race', async () => {
    const U = await F.profile('Multi Device'); const friends = await S.bulkProfiles(F, 400, 'fr');
    // seed 1000 existing direct splits (name-only friends so no accept round trip)
    for (let i = 0; i < 1000; i++) { const ctx = uuid(); await S.createCtx(F, U, ctx, 'direct', `Seed friend ${i}`); }
    const clients = []; for (let i = 0; i < 5; i++) clients.push(await F.newClient());
    const seqMs = []; for (let i = 0; i < 10; i++) seqMs.push((await timed(() => S.createCtx(F, U, uuid(), 'direct', `Seq friend ${i}`))).ms);
    const per = []; const wall0 = process.hrtime.bigint();
    await Promise.all(clients.map(async (c, d) => { for (let i = 0; i < 10; i++) per.push((await timed(() => S.fast(F, U, `SELECT shared_expenses.create_context(${S.lit(F, uuid())}::uuid,'direct',${S.lit(F, `Dev${d} friend ${i}`)},${S.op(F)}) AS v`, c))).ms); }));
    const wall = Number(process.hrtime.bigint() - wall0) / 1e6;
    // same-name race from 5 devices
    const results = await Promise.allSettled(clients.map(c => S.fast(F, U, `SELECT shared_expenses.create_context(${S.lit(F, uuid())}::uuid,'direct','Race Friend',${S.op(F)}) AS v`, c)));
    const ok = results.filter(r => r.status === 'fulfilled').length, taken = results.filter(r => r.status === 'rejected' && /friend_name_taken/.test(r.reason.message)).length;
    // same race through invite_member on 5 existing empty splits with the same target name
    const empties = []; for (let i = 0; i < 5; i++) { const c = uuid(); await S.createCtx(F, U, c, 'direct', `Empty ${i}`); empties.push(c); }
    const inv = await Promise.allSettled(clients.map((c, i) => S.fast(F, U, `SELECT shared_expenses.invite_member(${S.lit(F, JSON.stringify({ contextId: empties[i], memberId: uuid(), displayName: 'Invite Race', profileId: friends[i] }))}::jsonb,${S.op(F)}) AS v`, c)));
    const invOk = inv.filter(r => r.status === 'fulfilled').length;
    const dups = (await F.q(`SELECT count(*)::int c FROM shared_expenses.contexts WHERE created_by=$1 AND kind='direct' AND name='Race Friend'`, [U]))[0].c;
    record('Z05.2', { existingDirectSplits: 1000, sequential: stats(seqMs), parallel5x10: { ...stats(per), wallMs: Math.round(wall), perSec: Math.round(50 / (wall / 1000) * 10) / 10 }, sameNameRace: { created: ok, rejectedFriendNameTaken: taken, rowsNamedRaceFriend: dups }, inviteRace: { succeeded: invOk, of: 5 } });
    assert.equal(ok, 1, 'exactly one device wins the same-name race'); assert.equal(taken, 4); assert.equal(dups, 1);
    assert.equal(invOk, 1, 'exactly one invite of the same friend name across 5 empty splits succeeds');
    assert.ok(stats(per).p95 < 1500, `parallel adds p95 ${stats(per).p95}ms`);
  });
});
