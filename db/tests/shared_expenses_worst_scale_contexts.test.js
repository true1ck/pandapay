'use strict';
// Z01 / Z05 : ONE USER, MANY SPLITS (100 -> 500 -> 2000 contexts) and the same people across many splits.
// Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers are printed as `SCALE {json}` lines.
// `{ todo }` tests state desired behaviour that currently fails (real defect / limit); they keep the suite green.
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed, repeat } = S;
const { listContexts, readOverview, listPersonalActivity, listChanges, pullProjectionChanges, listContextMembers, listContextActivity } = S.requireApi('./src/shared_expenses/queries');

const SIZES = (process.env.PANDAPAY_WORST_SCALE_SIZES || '100,500,2000').split(',').map(Number);
const BUDGET_LIST_P95 = 300;   // ms; list screens must feel instant on a mid phone after one RTT.

describe('Z01 one user, many splits', { skip: SKIP, timeout: 3 * 3600 * 1000 }, () => {
  let F, U, friends, people, model = [], createMs = { direct: [], group: [] };
  before(async () => {
    F = await S.createFixture('z01');
    U = await F.profile('Uma User');
    friends = await S.bulkProfiles(F, 1700, 'Friend');
    people = await S.bulkProfiles(F, 300, 'Person');
    await F.db.query('SELECT pg_stat_reset()');
  });
  after(async () => { if (F) await F.close(); });

  // Seed one more context for U. 70% direct, 30% group; ~5% left, ~3% declined, ~3% still invited; ~45% with an expense.
  let seq = 0, friendIx = 0;
  async function seedOne() {
    const i = seq++;
    const roll = (i * 7919) % 100;                 // deterministic mix
    const kind = roll < 70 ? 'direct' : 'group';
    const uOwns = (i * 31) % 100 < 85;             // 15% created by somebody else who then invites U
    const ctx = uuid();
    const entry = { ctx, kind, uState: 'active', owed: 0n, owing: 0n, expenses: 0, uOwns };
    const exp = (i * 13) % 100 < 45;
    if (kind === 'direct') {
      const f = friends[friendIx++], name = `Friend ${i}`;
      const t0 = process.hrtime.bigint();
      let creatorP = uOwns ? U : f, other = uOwns ? f : U;
      const c = await S.createCtx(F, creatorP, ctx, 'direct', uOwns ? name : `Uma ${i}`);
      createMs.direct.push(Number(process.hrtime.bigint() - t0) / 1e6);
      const member = uuid();
      await S.inviteMember(F, creatorP, ctx, member, uOwns ? name : `Uma ${i}`, other);
      const r = (i * 17) % 100;
      if (!uOwns && r < 6) { await S.respondMembership(F, U, ctx, member, false); entry.uState = 'declined'; }
      else if (!uOwns && r < 12) { entry.uState = 'invited'; }
      else {
        await S.respondMembership(F, other, ctx, member, true);
        if (exp) {
          const ids = [c.memberId, member];
          const payerP = i % 2 ? creatorP : other, payerM = i % 2 ? c.memberId : member;
          const snap = S.equalSnapshot(1000 + (i % 37) * 100, payerM, ids);
          const p = S.proposal(ctx, snap);
          const res = await S.submit(F, payerP, p);
          if (res.status !== 'accepted') await S.respondExpense(F, i % 2 ? other : creatorP, ctx, p.expenseId, p.revisionId);
          const uShare = BigInt(snap.shares.find(s => s.memberId === (uOwns ? c.memberId : member)).amountMinor);
          const total = BigInt(snap.totalMinor);
          const uPays = payerP === U;
          if (uPays) entry.owed += total - uShare; else entry.owing += uShare;
          entry.expenses = 1;
        }
      }
    } else {
      const ownerP = uOwns ? U : people[i % people.length];
      const c = await S.createCtx(F, ownerP, ctx, 'group', `Trip ${i}`);
      const nMembers = 2 + (i % 3);
      const joined = [{ p: ownerP, m: c.memberId }]; let uMember = uOwns ? c.memberId : null;
      const pick = []; for (let k = 0; pick.length < nMembers + (uOwns ? 0 : 1); k++) { const cand = people[(i * 5 + k * 3) % people.length]; if (cand !== ownerP && !pick.includes(cand)) pick.push(cand); }
      const targets = uOwns ? pick : [U, ...pick.slice(0, nMembers)];
      const r = (i * 17) % 100;
      for (const [k, p] of targets.entries()) {
        const m = uuid();
        await S.inviteMember(F, ownerP, ctx, m, `m${k}-${i}`, p);
        if (p === U && !uOwns && r < 6) { await S.respondMembership(F, U, ctx, m, false); entry.uState = 'declined'; continue; }
        if (p === U && !uOwns && r < 12) { entry.uState = 'invited'; continue; }
        await S.respondMembership(F, p, ctx, m, true); joined.push({ p, m });
        if (p === U) uMember = m;
      }
      if (entry.uState === 'active' && exp && uMember) {
        const payer = joined[i % joined.length], ids = joined.map(j => j.m);
        const snap = S.equalSnapshot(3000 + (i % 29) * 100, payer.m, ids);
        const pr = S.proposal(ctx, snap);
        const res = await S.submit(F, payer.p, pr);
        if (res.status !== 'accepted') for (const j of joined) if (j.p !== payer.p) await S.respondExpense(F, j.p, ctx, pr.expenseId, pr.revisionId);
        const uShare = BigInt(snap.shares.find(s => s.memberId === uMember).amountMinor), total = BigInt(snap.totalMinor);
        if (payer.p === U) entry.owed += total - uShare; else entry.owing += uShare;
        entry.expenses = 1;
      }
      if (entry.uState === 'active' && !uOwns && !entry.expenses && r >= 90 && uMember) { await S.leaveCtx(F, U, ctx); entry.uState = 'left'; }
    }
    model.push(entry);
  }
  async function seedTo(n) { while (model.length < n) await seedOne(); }
  const visible = () => model.filter(e => e.uState === 'active' || e.uState === 'invited');

  async function brute() {
    const rows = await F.q(`SELECT coalesce(sum(greatest(CASE WHEN p.low_member_id=m.member_id THEN p.balance_minor ELSE -p.balance_minor END,0)),0)::text owed,
      coalesce(sum(greatest(CASE WHEN p.low_member_id=m.member_id THEN -p.balance_minor ELSE p.balance_minor END,0)),0)::text owing
      FROM shared_expenses.members m JOIN shared_expenses.pair_balances p ON p.context_id=m.context_id AND m.member_id IN (p.low_member_id,p.high_member_id) WHERE m.profile_id=$1 AND m.state='active'`, [U]);
    return rows[0];
  }
  async function walk(query, limit) {
    const items = []; let after, pages = 0, hasMore = true; const ms = [];
    while (hasMore) {
      const r = await S.asActorTimed(F, U, c => listContexts(c, U, { limit: String(limit), ...(after ? { after } : {}), ...query }));
      ms.push(r.ms); pages++; items.push(...r.value.items); hasMore = r.value.hasMore; after = r.value.nextCursor;
      if (pages > 200) throw new Error('runaway pagination');
    }
    return { items, pages, ms };
  }

  for (const size of SIZES) {
    it(`Z01.${size} seed to ${size} contexts, list/search/overview/activity latency + correctness`, async () => {
      const seedT = await timed(() => seedTo(size));
      const vis = visible();
      const counts = await F.q(`SELECT count(*) FILTER(WHERE state='active')::int a,count(*) FILTER(WHERE state='invited')::int i,count(*) FILTER(WHERE state='left')::int l,count(*) FILTER(WHERE state='declined')::int d FROM shared_expenses.members WHERE profile_id=$1`, [U]);
      const tbl = await F.q(`SELECT (SELECT count(*) FROM shared_expenses.contexts)::int contexts,(SELECT count(*) FROM shared_expenses.members)::int members,(SELECT count(*) FROM shared_expenses.profile_events WHERE profile_id=$1)::int u_events,(SELECT count(*) FROM shared_expenses.pair_balances)::int pairs`, [U]);
      await F.db.query('ANALYZE');
      await F.db.query('SELECT pg_stat_reset()');
      const out = { size, seedSeconds: Math.round(seedT.ms / 1000), mix: counts[0], tables: tbl[0] };

      // --- first page (default 50), limit 100, deepest page, kind filter, search hit/miss.
      const first = await repeat(30, () => S.asActorTimed(F, U, c => listContexts(c, U, {})).then(r => r.ms));
      out.list_first50 = { p50: first.p50, p95: first.p95, max: first.max };
      const ms = async q => stats(await Promise.all([]).then(async () => { const a = []; for (let k = 0; k < 15; k++) a.push((await S.asActorTimed(F, U, c => listContexts(c, U, q))).ms); return a; }));
      out.list_limit100 = await ms({ limit: '100' });
      out.list_kind_group = await ms({ kind: 'group' });
      out.search_hit = await ms({ q: 'Trip 1' });
      out.search_miss = await ms({ q: 'zzzzzz-no-such' });
      // function-call evidence for the "N+1 inside one SQL" pattern, from a FRESH session so no pending counters leak in
      const fnCalls = async q => {
        const c2 = await F.newClient(); await F.db.query('SELECT pg_stat_reset()');
        await S.asActorTimed(F, U, c => listContexts(c, U, q), c2); await c2.query('SELECT pg_stat_force_next_flush()'); await c2.end(); F.extra.pop();
        return Object.fromEntries((await F.q(`SELECT funcname,calls::int FROM pg_stat_user_functions WHERE schemaname='shared_expenses' ORDER BY calls DESC LIMIT 4`)).map(r => [r.funcname, r.calls]));
      };
      out.fn_calls_first50 = await fnCalls({});
      out.fn_calls_search = await fnCalls({ q: 'Trip 1' });

      // --- full walk: no dupes, no misses, count == visible, hasMore/nextCursor consistent
      const w = await walk({}, 50);
      const ids = w.items.map(x => x.contextId);
      assert.equal(new Set(ids).size, ids.length, 'no duplicate contexts across pages');
      assert.equal(ids.length, vis.length, 'walk returns every active+invited context exactly once');
      assert.deepEqual(new Set(ids), new Set(vis.map(e => e.ctx)));
      for (let i = 1; i < w.items.length; i++) assert.ok(w.items[i - 1].createdAt >= w.items[i].createdAt, 'sorted by createdAt desc');
      out.walk50 = { pages: w.pages, totalItems: ids.length, pageP50: stats(w.ms).p50, pageP95: stats(w.ms).p95, pageMax: stats(w.ms).max, totalMs: Math.round(w.ms.reduce((a, b) => a + b, 0)) };
      const w100 = await walk({}, 100); assert.equal(w100.items.length, vis.length);
      const heap0 = process.memoryUsage().heapUsed; const big = (await S.asActorTimed(F, U, c => listContexts(c, U, { limit: '100' }))).value;
      out.memory = { page100JsonKb: Math.round(JSON.stringify(big).length / 102.4) / 10, fullWalkItemsJsonKb: Math.round(JSON.stringify(w100.items).length / 102.4) / 10, heapDeltaMbAfterWalk: Math.round((process.memoryUsage().heapUsed - heap0) / 104857.6) / 10 };
      out.walk100 = { pages: w100.pages, pageP95: stats(w100.ms).p95 };

      // --- overview vs brute force (independent SQL, bypassing RLS) and vs the JS model
      const ov = await repeat(15, () => S.asActorTimed(F, U, c => readOverview(c, U)).then(r => r.ms));
      const ovv = (await S.asActorTimed(F, U, c => readOverview(c, U))).value;
      const b = await brute();
      assert.equal(ovv.owedMinor, b.owed, 'overview owed == brute force'); assert.equal(ovv.owingMinor, b.owing);
      assert.equal(ovv.netMinor, (BigInt(b.owed) - BigInt(b.owing)).toString());
      const expOwed = model.filter(e => e.uState === 'active').reduce((a, e) => a + e.owed, 0n), expOwing = model.filter(e => e.uState === 'active').reduce((a, e) => a + e.owing, 0n);
      assert.equal(BigInt(ovv.owedMinor), expOwed, 'overview owed == value derived from the seeded expenses');
      assert.equal(BigInt(ovv.owingMinor), expOwing);
      assert.equal(ovv.contextCount, String(counts[0].a));
      out.overview = { p50: ov.p50, p95: ov.p95, max: ov.max, contextCount: ovv.contextCount, owedMinor: ovv.owedMinor, owingMinor: ovv.owingMinor, expenseCount: ovv.expenseCount };

      // --- list row owed/owing per context vs model (first page)
      const page1 = (await S.asActorTimed(F, U, c => listContexts(c, U, { limit: '100' }))).value.items;
      for (const it2 of page1) { const e = model.find(x => x.ctx === it2.contextId); if (e.uState === 'active') { assert.equal(it2.owedMinor, e.owed.toString()); assert.equal(it2.owingMinor, e.owing.toString()); assert.equal(it2.expenseCount, String(e.expenses)); } }

      // --- other read endpoints for this user
      out.personal_activity = stats((await (async () => { const a = []; for (let k = 0; k < 15; k++) a.push((await S.asActorTimed(F, U, c => listPersonalActivity(c, U, {}))).ms); return a; })()));
      const act = []; for (let k = 0; k < 10; k++) act.push((await S.asActorTimed(F, U, c => listPersonalActivity(c, U, { q: 'Trip' }))).ms); out.personal_activity_search = stats(act);
      out.changes_first = stats((await (async () => { const a = []; for (let k = 0; k < 15; k++) a.push((await S.asActorTimed(F, U, c => listChanges(c, U, { limit: '100' }))).ms); return a; })()));
      out.projection_first = stats((await (async () => { const a = []; for (let k = 0; k < 10; k++) a.push((await S.asActorTimed(F, U, c => pullProjectionChanges(c, U, { limit: '100' }))).ms); return a; })()));
      const inv = []; for (let k = 0; k < 10; k++) inv.push((await timed(() => S.callFn(F, U, `shared_expenses.list_my_invitations(${S.lit(F, 'a'.repeat(64))})`))).ms); out.list_my_invitations = stats(inv);
      const jr = []; for (let k = 0; k < 10; k++) jr.push((await timed(() => S.callFn(F, U, 'shared_expenses.list_join_requests()'))).ms); out.list_join_requests = stats(jr);
      const caps = []; for (let k = 0; k < 10; k++) caps.push((await timed(() => S.callFn(F, U, 'shared_expenses.capabilities()'))).ms); out.capabilities = stats(caps);

      // --- plans
      out.plan_list = (await S.explain(F, U, `SELECT c.context_id FROM shared_expenses.members me JOIN shared_expenses.contexts c ON c.context_id=me.context_id
        LEFT JOIN shared_expenses.context_totals t ON t.context_id=c.context_id
        WHERE me.profile_id=$1::uuid AND me.state IN ('active','invited') ORDER BY c.created_at DESC,c.context_id DESC LIMIT 51`, [U])).split('\n').filter(l => /Scan|Sort|Rows Removed|Execution|Planning/.test(l)).map(l => l.trim()).slice(0, 14);
      out.created = {
        direct: { first100: stats(createMs.direct.slice(0, 100)), last100: stats(createMs.direct.slice(-100)) },
      };
      record('Z01.' + size, out);
      if (size === 2000) {
        assert.ok(out.list_first50.p95 < BUDGET_LIST_P95, `first page p95 ${out.list_first50.p95}ms < ${BUDGET_LIST_P95}ms`);
      }
    });
  }

  it('Z01.cursor stable under inserts: new newer contexts appear between page fetches without dupes/misses of the old set', async () => {
    const before = visible().length;
    const p1 = (await S.asActorTimed(F, U, c => listContexts(c, U, { limit: '50' }))).value;
    // 10 brand-new newer contexts arrive between page 1 and page 2
    const added = []; for (let k = 0; k < 10; k++) { const c = uuid(); await S.createCtx(F, U, c, 'group', `Late ${k}`); added.push(c); model.push({ ctx: c, kind: 'group', uState: 'active', owed: 0n, owing: 0n, expenses: 0, uOwns: true }); }
    const seen = [...p1.items.map(x => x.contextId)]; let after = p1.nextCursor, more = p1.hasMore;
    while (more) { const r = (await S.asActorTimed(F, U, c => listContexts(c, U, { limit: '50', after }))).value; seen.push(...r.items.map(x => x.contextId)); after = r.nextCursor; more = r.hasMore; }
    assert.equal(new Set(seen).size, seen.length, 'no duplicates across pages after concurrent inserts');
    assert.equal(seen.length, before, 'the old set is returned exactly once; the new contexts are not injected mid-walk (they show on the next refresh)');
    for (const a of added) assert.ok(!seen.includes(a));
    record('Z01.cursor_insert', { before, walked: seen.length });
  });

  it('Z01.sort ties: 120 contexts with an identical created_at paginate without gaps (keyset on created_at,context_id)', async () => {
    const T = U; const ids = Array.from({ length: 120 }, () => uuid());
    await F.db.query(`INSERT INTO shared_expenses.contexts(context_id,kind,name,created_by,created_at) SELECT id,'group','Tie '||left(id::text,4),$2,'2030-01-01T00:00:00Z' FROM unnest($1::uuid[]) id`, [ids, T]);
    await F.db.query(`INSERT INTO shared_expenses.members(context_id,member_id,profile_id,role,state) SELECT id,gen_random_uuid(),$2,'owner','active' FROM unnest($1::uuid[]) id`, [ids, T]);
    const w = await walk({}, 50);
    const seen = w.items.map(x => x.contextId);
    assert.equal(new Set(seen).size, seen.length);
    for (const id of ids) assert.ok(seen.includes(id), 'tied context returned');
    const tie = seen.filter(i => ids.includes(i));
    assert.deepEqual(tie, [...ids].sort().reverse(), 'ties ordered by context_id DESC');
    record('Z01.sort_ties', { tied: 120, pages: w.pages });
    for (const id of ids) model.push({ ctx: id, kind: 'group', uState: 'active', owed: 0n, owing: 0n, expenses: 0 });
  });

  it('Z01.limits: limit caps (100 max), invalid cursors, search wildcard literal', async () => {
    await assert.rejects(S.asActorTimed(F, U, c => listContexts(c, U, { limit: '101' })), /INVALID|limit/i);
    await assert.rejects(S.asActorTimed(F, U, c => listContexts(c, U, { limit: '0' })));
    const r = (await S.asActorTimed(F, U, c => listContexts(c, U, { limit: '100' }))).value; assert.equal(r.items.length, 100);
    const pct = (await S.asActorTimed(F, U, c => listContexts(c, U, { q: '%' }))).value; assert.equal(pct.items.length, 0, 'search uses position(), % is literal');
  });

  it('Z01.members/activity of one direct split stay tiny at 2000 contexts; user stream totals', async () => {
    const e = model.find(x => x.kind === 'direct' && x.uState === 'active');
    const m = await S.asActorTimed(F, U, c => listContextMembers(c, U, e.ctx, {})); const a = await S.asActorTimed(F, U, c => listContextActivity(c, U, e.ctx, {}));
    const total = await F.q(`SELECT (SELECT committed_sequence FROM shared_expenses.profile_stream_heads WHERE profile_id=$1)::int heads,(SELECT count(*) FROM shared_expenses.profile_events WHERE profile_id=$1)::int ev`, [U]);
    record('Z01.small_context_reads', { members_ms: Math.round(m.ms * 100) / 100, activity_ms: Math.round(a.ms * 100) / 100, userStream: total[0] });
    assert.equal(total[0].heads, total[0].ev);
  });

  // ---------------------------------------------------------------- Z05 unique-name cost vs number of splits
  it('Z05 add-a-friend cost vs 2000 splits: EXPLAIN of _friend_context (creator scan) and per-call latency', async () => {
    const sql = `SELECT shared_expenses._friend_context($1::uuid,NULL,'Friend 999999')`;
    const t = await repeat(20, () => F.db.query(sql, [U]));
    const plan = await F.q(`EXPLAIN (ANALYZE,BUFFERS,TIMING OFF) SELECT c.context_id FROM shared_expenses.contexts c WHERE c.kind='direct' AND c.state='active' AND c.created_by=$1::uuid`, [U]);
    const planText = plan.map(r => r['QUERY PLAN']).join('\n');
    const idx = await F.q(`SELECT indexdef FROM pg_indexes WHERE schemaname='shared_expenses' AND tablename='contexts'`);
    const dcount = model.filter(e => e.kind === 'direct' && e.uOwns).length;
    // a hostile/heavy account: how does the same call scale with the number of direct splits the creator owns?
    record('Z05.friend_context', { creatorDirectSplits: dcount, p50: t.p50, p95: t.p95, scansContextsWithoutCreatedByIndex: /Seq Scan on contexts/.test(planText), contextIndexes: idx.map(r => r.indexdef.replace(/CREATE (UNIQUE )?INDEX /, '')), plan: planText.split('\n').slice(0, 6).map(l => l.trim()) });
    assert.ok(t.p95 < 200, `_friend_context p95 ${t.p95}ms`);
  });

  it('Z05 label uniqueness across the creator\'s splits: add 30 more friends at 2000+ contexts, latency of create_context(direct) per call', async () => {
    const ms = [];
    for (let k = 0; k < 30; k++) { const r = await timed(() => S.createCtx(F, U, uuid(), 'direct', `Late friend ${k}`)); ms.push(r.ms); }
    const first = createMs.direct.slice(0, 50), last = createMs.direct.slice(-50);
    record('Z05.create_direct_at_scale', { at2000: stats(ms), seedFirst50: stats(first), seedLast50: stats(last) });
    assert.ok(stats(ms).p95 < 500, 'single command p95 < 500ms');
  });
});
