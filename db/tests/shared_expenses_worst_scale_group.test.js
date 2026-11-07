'use strict';
// Z02 / Z03 : ONE GROUP, MANY PEOPLE and the profile change feed at volume.
// Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers are printed as `SCALE {json}` lines.
// Env: PANDAPAY_WORST_SCALE_EXPENSES (comma list of cumulative accepted-expense checkpoints, default 1000,5000).
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed, repeat } = S;
const Q = S.requireApi('./src/shared_expenses/queries');

const CHECKPOINTS = (process.env.PANDAPAY_WORST_SCALE_EXPENSES || '1000,5000').split(',').map(Number);
const BUDGET_CMD_P95 = 500;   // ms single command p95 at 200 members
const rnd = (() => { let a = 12345; return () => { a = (a * 1664525 + 1013904223) >>> 0; return a / 4294967296; }; })();

describe('Z02 one group, many people', { skip: SKIP, timeout: 4 * 3600 * 1000 }, () => {
  let F;
  before(async () => { F = await S.createFixture('z02'); await F.db.query('SELECT pg_stat_reset()'); });
  after(async () => { if (F) await F.close(); });

  // Build a group of n active members (index 0 owns). Records invite/accept latency at checkpoints.
  async function build(n, tag, probes = [10, 50, 100, 150, 199]) {
    const profiles = await S.bulkProfiles(F, n, 'm' + tag + '_');
    const ctx = uuid(); const o = await S.createCtx(F, profiles[0], ctx, 'group', 'Group ' + tag);
    const members = [{ p: profiles[0], m: o.memberId }]; const inv = {}, acc = {};
    for (let i = 1; i < n; i++) {
      const m = uuid();
      const a = await timed(() => S.inviteMember(F, profiles[0], ctx, m, `Name ${i}`, profiles[i]));
      const b = await timed(() => S.respondMembership(F, profiles[i], ctx, m, true));
      members.push({ p: profiles[i], m });
      if (probes.includes(i)) { inv[i] = Math.round(a.ms * 100) / 100; acc[i] = Math.round(b.ms * 100) / 100; }
    }
    return { ctx, members, owner: members[0], inv, acc };
  }
  // propose with `k` participants chosen from a pool (author pays everything, equal split), then approve; returns timings
  async function postExpense(g, authorIdx, k, pool) {
    const idx = [authorIdx]; while (idx.length < k) { const c = pool[Math.floor(rnd() * pool.length)]; if (!idx.includes(c)) idx.push(c); }
    const ms = idx.map(i => g.members[i].m), author = g.members[authorIdx];
    const snap = S.equalSnapshot(1000 + Math.floor(rnd() * 900) * 10, author.m, ms);
    const p = S.proposal(g.ctx, snap);
    const t1 = await timed(() => S.submit(F, author.p, p));
    const out = { propose: t1.ms, approve: [] };
    if (t1.value.status !== 'accepted') for (const i of idx.slice(1)) { const t = await timed(() => S.respondExpense(F, g.members[i].p, g.ctx, p.expenseId, p.revisionId)); out.approve.push(t.ms); }
    return out;
  }

  // ---------------------------------------------------------------- _emit cost vs group size
  it('Z02.emit cost per event vs group size (2, 10, 50, 100, 200 active members): author-only expense = 1 propose + auto-accept, 1 emit', async () => {
    const rows = {};
    for (const n of [2, 10, 50, 100, 200]) {
      const g = await build(n, 'e' + n, [n - 1]);
      const ms = [];
      for (let k = 0; k < 15; k++) {
        const author = g.members[k % n]; const snap = S.equalSnapshot(1000 + k * 10, author.m, [author.m]);
        ms.push((await timed(() => S.submit(F, author.p, S.proposal(g.ctx, snap)))).ms);
      }
      const evRows = await F.q(`SELECT count(*)::int c FROM shared_expenses.profile_events WHERE context_id=$1`, [g.ctx]);
      rows[n] = { ...stats(ms), profileEventRowsForCtx: evRows[0].c, inviteMsAtLast: g.inv[n - 1], acceptMsAtLast: g.acc[n - 1] };
    }
    record('Z02.emit_scaling', rows);
    assert.ok(rows[200].p95 < BUDGET_CMD_P95, `single command p95 at 200 members ${rows[200].p95}ms`);
  });

  // ---------------------------------------------------------------- big group A: 180 active + 20 pending join requests
  let A, mem = {};
  it('Z02.A build 180 active + 20 pending join requests (200 counted members); invite/accept growth; join-request path', async () => {
    A = await build(180, 'A', [10, 50, 100, 150, 179]);
    // owner publishes a link; 20 distinct claimants request to join
    const tokenHash = S.hex ? require('node:crypto').randomBytes(32).toString('hex') : null;
    await S.callFn(F, A.owner.p, `shared_expenses.create_group_link(${S.lit(F, A.ctx)}::uuid,${S.lit(F, tokenHash)},${S.op(F)})`);
    const claimants = await S.bulkProfiles(F, 22, 'claim_'); const claimMs = [];
    let full = null;
    for (let i = 0; i < claimants.length; i++) {
      try { claimMs.push((await timed(() => S.callFn(F, claimants[i], `shared_expenses.claim_invitation(${S.lit(F, tokenHash)},${S.lit(F, 'p' + i)},'3210',${S.op(F)})`))).ms); }
      catch (e) { if (full === null) full = { atClaim: i + 1, message: e.message }; }
    }
    const counts = await F.q(`SELECT count(*) FILTER(WHERE state='active')::int active,count(*) FILTER(WHERE state='invited')::int invited,count(*) FILTER(WHERE state<>'declined')::int counted FROM shared_expenses.members WHERE context_id=$1`, [A.ctx]);
    mem.joinFull = full;
    record('Z02.A_build', { counts: counts[0], inviteMs: A.inv, acceptMs: A.acc, claimMs: stats(claimMs), twentyFirstClaim: full });
    assert.equal(counts[0].invited, 20, '20 pending join requests max');
    assert.match(full?.message || '', /join_requests_full/);
  });

  const phases = []; // per checkpoint measurements
  let posted = 0; const postMs = { propose: [], approve: [] };
  async function seedTo(n) {
    const pool = Array.from({ length: 170 }, (_, i) => i);  // members 170..179 never take part in an expense (balance 0, can leave)
    while (posted < n) { const r = await postExpense(A, Math.floor(rnd() * 170), 2 + Math.floor(rnd() * 3), pool); postMs.propose.push(r.propose); postMs.approve.push(...r.approve); posted++; }
  }
  async function readPoints(label) {
    const reader = A.members[5], owner = A.owner;
    const out = { label, expenses: posted };
    out.rows = (await F.q(`SELECT (SELECT count(*) FROM shared_expenses.context_events WHERE context_id=$1)::int ctx_events,(SELECT count(*) FROM shared_expenses.profile_events WHERE context_id=$1)::int profile_event_rows,
      (SELECT count(*) FROM shared_expenses.pair_balances WHERE context_id=$1)::int pairs,(SELECT count(*) FROM shared_expenses.operation_receipts)::int receipts,
      pg_total_relation_size('shared_expenses.profile_events')/1024/1024 profile_events_mb,pg_total_relation_size('shared_expenses.profile_stream_heads')/1024 heads_kb,
      pg_total_relation_size('shared_expenses.expense_revisions')/1024/1024 revisions_mb`, [A.ctx]))[0];
    const t = async (fn, n = 15) => { const a = []; for (let k = 0; k < n; k++) a.push((await S.asActorTimed(F, reader.p, fn)).ms); return stats(a); };
    out.roster_p1_100 = await t(c => Q.listContextMembers(c, reader.p, A.ctx, { limit: '100' }));
    // walk the roster: 200 rows incl. pending
    const items = []; let after, more = true, pages = 0; while (more) { const r = (await S.asActorTimed(F, reader.p, c => Q.listContextMembers(c, reader.p, A.ctx, { limit: '100', ...(after ? { after } : {}) }))).value; items.push(...r.items); after = r.nextCursor; more = r.hasMore; pages++; }
    assert.equal(items.length, 200); assert.equal(new Set(items.map(i => i.memberId)).size, 200);
    out.roster = { pages, rows: items.length, pending: items.filter(i => i.state === 'invited').length };
    out.balances_p1_100 = await t(c => Q.readBalances(c, reader.p, A.ctx, { limit: '100' }));
    out.expenses_p1_100 = await t(c => Q.listContextExpenses(c, reader.p, A.ctx, { limit: '100' }));
    out.activity_p1_100 = await t(c => Q.listContextActivity(c, reader.p, A.ctx, { limit: '100' }));
    const mid = String(Math.floor(out.rows.ctx_events / 2)); const cur = Q.encodeCursor({ actorId: reader.p, kind: 'activity', contextId: A.ctx }, [mid]);
    out.activity_deep_100 = await t(c => Q.listContextActivity(c, reader.p, A.ctx, { limit: '100', after: cur }));
    out.totals = await t(c => Q.readContextTotals(c, reader.p, A.ctx));
    out.overview_member = await t(c => Q.readOverview(c, reader.p));
    out.list_contexts_member = await t(c => Q.listContexts(c, reader.p, {}));
    out.changes_first_100 = await t(c => Q.listChanges(c, reader.p, { limit: '100' }));
    out.projection_first_100 = await t(c => Q.pullProjectionChanges(c, reader.p, { limit: '100' }), 8);
    out.personal_activity = await t(c => Q.listPersonalActivity(c, reader.p, {}), 8);
    const res = await S.asActorTimed(F, reader.p, c => Q.pullProjectionChanges(c, reader.p, { limit: '100' }));
    out.projection_page_records = res.value.records.length;
    // initial sync of this split on a new device: walk the projection feed from 0, wall-clock capped
    {
    const head = Number((await F.q('SELECT committed_sequence::text s FROM shared_expenses.profile_stream_heads WHERE profile_id=$1', [reader.p]))[0].s);
    const cap = Number(process.env.PANDAPAY_WORST_SCALE_SYNC_CAP_MS || 90000); const t0 = Date.now(); let scur, pages = 0, recs = 0, lastSeq = 0, more = true, bytes = 0; const pm = [];
    while (more && Date.now() - t0 < cap) {
      const r = await S.asActorTimed(F, reader.p, c => Q.pullProjectionChanges(c, reader.p, { limit: '100', ...(scur ? { after: scur } : {}) })); pm.push(r.ms);
      pages++; recs += r.value.records.length; bytes += JSON.stringify(r.value).length; scur = r.value.nextCursor; more = r.value.hasMore;
      lastSeq = Number(JSON.parse(Buffer.from(scur, 'base64url').toString('utf8')).lastKey[0]);
    }
    const spent = (Date.now() - t0) / 1000, frac = more ? lastSeq / head : 1;
    out.initial_sync = { streamEvents: head, capSeconds: cap / 1000, finished: !more, pages, records: recs, mb: Math.round(bytes / 1048576 * 10) / 10, secondsSpent: Math.round(spent * 10) / 10, pageMs: stats(pm), fractionOfStreamConsumed: Math.round(frac * 1000) / 1000, projectedTotalSeconds: Math.round(spent / Math.max(frac, 0.001)), projectedPages: Math.round(pages / Math.max(frac, 0.001)) };
    }
    phases.push(out); record('Z02.A_at_' + posted, out);
    return out;
  }
  for (const cp of CHECKPOINTS) {
    it(`Z02.A seed to ${cp} accepted expenses (real submit/approve under the context lock), then read costs`, async () => {
      const t0 = Date.now(); const before = posted; await seedTo(cp);
      const ph = await readPoints('cp' + cp);
      record('Z02.A_write_cost_' + cp, { newExpenses: posted - before, seconds: Math.round((Date.now() - t0) / 1000), propose: stats(postMs.propose.slice(-500)), approve: stats(postMs.approve.slice(-500)) });
      assert.ok(ph.roster_p1_100.p95 < 300, 'roster page p95 < 300ms'); assert.ok(ph.balances_p1_100.p95 < 300);
    });
  }

  it('Z02.A desired: group activity page (100 rows) p95 < 300ms however many events the split has', { todo: 'measured 457ms at 3.4k events and 2.3s at 15k events: cost scales with the size of the split, not the page' }, () => {
    const last = phases.at(-1); assert.ok(last.activity_p1_100.p95 < 300, `activity page p95 ${last.activity_p1_100.p95}ms at ${last.rows.ctx_events} events`);
  });
  it('Z02.A desired: first projection-feed page for a member of a 5000-expense split p95 < 300ms', { todo: 'measured 257ms at 1000 expenses and 1174ms at 5000: the full-grant snapshot page re-reads the whole split under RLS' }, () => {
    const last = phases.at(-1); assert.ok(last.projection_first_100.p95 < 300, `projection page p95 ${last.projection_first_100.p95}ms at ${last.expenses} expenses`);
  });
  it('Z02.A plans of the slow reads (activity page, expense page, projection first page) at the final size', async () => {
    const fs = require('node:fs'), path = require('node:path');
    const src = fs.readFileSync(path.resolve(__dirname, '../../api/src/shared_expenses/queries.js'), 'utf8');
    const feed = /const PROJECTION_FEED_SQL=`([\s\S]*?)`;/.exec(src)[1];
    const exp = /client\.query\(`(SELECT e\.expense_id[\s\S]*?)`,\[contextId,after,request\.limit\+1,actorId\]/.exec(src)[1];
    const reader = A.members[5].p;
    const keep = (t, re, n = 24) => t.split('\n').filter(l => re.test(l)).slice(0, n).map(l => l.trim().slice(0, 190));
    const re = /Scan|Join|Sort|Limit|Execution|Planning Time|Filter|Rows Removed|SubPlan|Function Call|Buffers: shared/;
    const act0 = 'SELECT sequence::text,event_id,kind,origin_id,actor_profile_id,payload,created_at FROM shared_expenses.context_events WHERE context_id=$1::uuid AND sequence>$2::bigint ORDER BY sequence LIMIT $3::int';
    const act = await S.explain(F, reader, act0, [A.ctx, '7000', 101]);
    const exs = await S.explain(F, reader, exp, [A.ctx, null, 101, reader]);
    const prj = await S.explain(F, reader, feed, [reader, '0', '', 101, -1, null, null]);
    await F.db.query('SELECT pg_stat_force_next_flush()');
    const balSql = 'SELECT low_member_id,high_member_id,currency,balance_minor::text FROM shared_expenses.pair_balances WHERE context_id=$1::uuid AND ($2::uuid IS NULL OR (low_member_id,high_member_id)>($2::uuid,$3::uuid)) ORDER BY low_member_id,high_member_id LIMIT $4::int';
    const balFix = "SELECT low_member_id,high_member_id,currency,balance_minor::text FROM shared_expenses.pair_balances WHERE context_id=$1::uuid AND currency='INR' AND (low_member_id,high_member_id)>($2::uuid,$3::uuid) ORDER BY low_member_id,high_member_id LIMIT $4::int";
    const actFix = 'SELECT e.sequence::text,e.event_id,e.kind,e.origin_id,e.actor_profile_id,e.payload,e.created_at FROM shared_expenses.context_events e WHERE e.context_id=$1::uuid AND e.sequence>$2::bigint ORDER BY e.sequence LIMIT $3::int';
    const Z = '00000000-0000-0000-0000-000000000000';
    const time = async (sql, params) => { const a = []; for (let k = 0; k < 8; k++) a.push((await S.asActorTimed(F, reader, c => c.query(sql, params))).ms); return stats(a); };
    const bal = await S.explain(F, reader, balSql, [A.ctx, null, null, 101]);
    const timings = { balances_current: await time(balSql, [A.ctx, null, null, 101]), balances_keyset_no_null_or: await time(balFix, [A.ctx, Z, Z, 101]), activity_current: await time(act0, [A.ctx, '7000', 101]), activity_qualified_order_by: await time(actFix, [A.ctx, '7000', 101]) };
    record('Z02.A_plans', { activity: keep(act, re, 14), balances: keep(bal, re, 12), expenses: keep(exs, re, 22), projection: keep(prj, re, 40), timings });
  });
  it('Z02.A 50 sequential proposals + 20 parallel proposals from 20 different members (context lock contention)', async () => {
    const seqMs = []; for (let k = 0; k < 50; k++) { const a = A.members[10 + k]; seqMs.push((await timed(() => S.submit(F, a.p, S.proposal(A.ctx, S.equalSnapshot(1500 + k, a.m, [a.m]))))).ms); }
    const clients = []; for (let k = 0; k < 20; k++) clients.push(await F.newClient());
    const par = await Promise.all(clients.map((c, k) => { const a = A.members[70 + k]; return timed(() => S.fast(F, a.p, `SELECT shared_expenses.submit_proposal(${S.lit(F, JSON.stringify(S.proposal(A.ctx, S.equalSnapshot(1700 + k, a.m, [a.m]))))}::jsonb,${S.op(F)}) AS v`, c)); }));
    const wall0 = process.hrtime.bigint();
    const par2 = await Promise.all(clients.map((c, k) => { const a = A.members[100 + k]; return timed(() => S.fast(F, a.p, `SELECT shared_expenses.submit_proposal(${S.lit(F, JSON.stringify(S.proposal(A.ctx, S.equalSnapshot(1900 + k, a.m, [a.m]))))}::jsonb,${S.op(F)}) AS v`, c)); }));
    const wall = Number(process.hrtime.bigint() - wall0) / 1e6;
    const seqTotal = seqMs.reduce((x, y) => x + y, 0);
    record('Z02.A_sequential_50_parallel_20', { sequential: stats(seqMs), sequentialPerSec: Math.round(50 / (seqTotal / 1000) * 10) / 10, parallel20: stats(par.map(x => x.ms)), parallel20_second: stats(par2.map(x => x.ms)), parallelWallMsFor20: Math.round(wall), parallelPerSec: Math.round(20 / (wall / 1000) * 10) / 10, allAccepted: par2.every(x => x.value.status === 'accepted') });
    assert.ok(stats(seqMs).p95 < BUDGET_CMD_P95, `sequential p95 ${stats(seqMs).p95}`);
    assert.ok(stats(par2.map(x => x.ms)).p95 < 2000, 'parallel 20 on one context: the last waiter p95 < 2s');
  });

  it('Z02.A two-person approval, edit, void, settlement report/confirm, remove pending member, leave at 200 members', async () => {
    const x = A.members[1], y = A.members[2];
    const ex = await postExpense(A, 1, 2, [2]);
    const snap = S.equalSnapshot(5000, x.m, [x.m, y.m]); const p = S.proposal(A.ctx, snap);
    const prop = await timed(() => S.submit(F, x.p, p)); const appr = await timed(() => S.respondExpense(F, y.p, A.ctx, p.expenseId, p.revisionId));
    const edit = S.proposal(A.ctx, S.equalSnapshot(5200, x.m, [x.m, y.m]), { expenseId: p.expenseId, head: p.revisionId });
    const e1 = await timed(() => S.submit(F, x.p, edit)); const e2 = await timed(() => S.respondExpense(F, y.p, A.ctx, p.expenseId, edit.revisionId));
    const sid = uuid(); const bal = await F.q(`SELECT low_member_id l,high_member_id h,balance_minor::text b FROM shared_expenses.pair_balances WHERE context_id=$1 AND (low_member_id=$2 OR high_member_id=$2) AND (low_member_id=$3 OR high_member_id=$3)`, [A.ctx, x.m, y.m]);
    const rep = await timed(() => S.callFn(F, y.p, `shared_expenses.report_settlement(${S.lit(F, JSON.stringify({ contextId: A.ctx, settlementId: sid, payerMemberId: y.m, receiverMemberId: x.m, amountMinor: '100', currency: 'INR', method: 'upi', paidOn: '2026-11-06' }))}::jsonb,${S.op(F)})`));
    const conf = await timed(() => S.callFn(F, x.p, `shared_expenses.respond_settlement(${S.lit(F, JSON.stringify({ contextId: A.ctx, settlementId: sid, decision: 'confirm' }))}::jsonb,${S.op(F)})`));
    const pending = await F.q(`SELECT member_id FROM shared_expenses.members WHERE context_id=$1 AND state='invited' LIMIT 1`, [A.ctx]);
    const rm = await timed(() => S.callFn(F, A.owner.p, `shared_expenses.remove_member(${S.lit(F, A.ctx)}::uuid,${S.lit(F, pending[0].member_id)}::uuid,${S.op(F)})`));
    const lv = await timed(() => S.leaveCtx(F, A.members[179].p, A.ctx));
    record('Z02.A_single_commands_at_200', { propose2p_ms: Math.round(prop.ms * 10) / 10, approve_accept_ms: Math.round(appr.ms * 10) / 10, edit_ms: Math.round(e1.ms * 10) / 10, editApprove_ms: Math.round(e2.ms * 10) / 10, report_settlement_ms: Math.round(rep.ms * 10) / 10, confirm_settlement_ms: Math.round(conf.ms * 10) / 10, remove_member_ms: Math.round(rm.ms * 10) / 10, leave_ms: Math.round(lv.ms * 10) / 10, pairBalanceXY: bal });
    for (const t of [prop, appr, e1, e2, rep, conf, rm, lv]) assert.ok(t.ms < BUDGET_CMD_P95, 'single command < 500ms at 200 members');
    assert.deepEqual(await F.invariants(A.ctx), [], 'money invariants hold after all that');
  });

  // ---------------------------------------------------------------- B: full pair mesh (19,900 pairs)
  it('Z02.B 200 active members with a full pair mesh (19,900 pair_balances): accept path sum(abs()) , balances paging, overview, list, settlement', async () => {
    const B = await build(200, 'B', [199]);
    await F.db.query(`INSERT INTO shared_expenses.pair_balances(context_id,currency,low_member_id,high_member_id,balance_minor)
      SELECT $1,'INR',a.member_id,b.member_id,(CASE WHEN mod(abs(hashtext(a.member_id::text||b.member_id::text)),2)=0 THEN 1 ELSE -1 END)*(1+mod(abs(hashtext(b.member_id::text||a.member_id::text)),1000))
      FROM shared_expenses.members a JOIN shared_expenses.members b ON b.context_id=a.context_id AND b.member_id>a.member_id WHERE a.context_id=$1`, [B.ctx]);
    await F.db.query(`INSERT INTO shared_expenses.member_balances(context_id,member_id,currency,balance_minor)
      SELECT $1,m,'INR',sum(d) FROM (SELECT low_member_id m,balance_minor d FROM shared_expenses.pair_balances WHERE context_id=$1 UNION ALL SELECT high_member_id,-balance_minor FROM shared_expenses.pair_balances WHERE context_id=$1) x GROUP BY m
      ON CONFLICT(context_id,member_id,currency) DO UPDATE SET balance_minor=excluded.balance_minor`, [B.ctx]);
    await F.db.query('ANALYZE shared_expenses.pair_balances');
    const pairs = (await F.q('SELECT count(*)::int c FROM shared_expenses.pair_balances WHERE context_id=$1', [B.ctx]))[0].c; assert.equal(pairs, 19900);
    const sumSql = `SELECT coalesce(sum(abs(balance_minor::numeric)),0) FROM shared_expenses.pair_balances WHERE context_id=$1`;
    const sumT = await repeat(20, () => F.db.query(sumSql, [B.ctx]));
    const sumPlan = (await F.q(`EXPLAIN (ANALYZE,BUFFERS,TIMING OFF) ${sumSql}`, [B.ctx])).map(r => r['QUERY PLAN']).join('\n');
    const owner = B.members[0], m1 = B.members[1], m2 = B.members[2];
    // accept path on the mesh: author-only expense (auto-accept) and a 2-person approval
    const auth = []; for (let k = 0; k < 10; k++) { const a = B.members[3 + k]; auth.push((await timed(() => S.submit(F, a.p, S.proposal(B.ctx, S.equalSnapshot(900 + k, a.m, [a.m]))))).ms); }
    const snap = S.equalSnapshot(4000, m1.m, [m1.m, m2.m]); const p = S.proposal(B.ctx, snap);
    const prop = await timed(() => S.submit(F, m1.p, p)); const appr = await timed(() => S.respondExpense(F, m2.p, B.ctx, p.expenseId, p.revisionId));
    // a 50-sharer / 8-payer expense (400 edges) on top of the mesh
    const pay = B.members.slice(20, 28), sh = B.members.slice(30, 80);
    const total = 50000, per = total / 8;
    const big = { currency: 'INR', totalMinor: String(total), memberOrder: [...pay, ...sh].map(x => x.m), contributions: pay.map(x => ({ memberId: x.m, amountMinor: String(per) })), shares: sh.map(x => ({ memberId: x.m, amountMinor: '1000' })) };
    const bigP = S.proposal(B.ctx, big); const bigProp = await timed(() => S.submit(F, pay[0].p, bigP));
    let bigAccept = null; const bigApprovals = [];
    for (const who of [...pay.slice(1), ...sh]) { const t = await timed(() => S.respondExpense(F, who.p, B.ctx, bigP.expenseId, bigP.revisionId)); bigApprovals.push(t.ms); }
    const edges = (await F.q('SELECT count(*)::int c FROM shared_expenses.obligation_edges WHERE context_id=$1 AND revision_id=$2', [B.ctx, bigP.revisionId]))[0].c;
    bigAccept = await F.q(`SELECT accepted_revision_id=$3 ok FROM shared_expenses.expenses WHERE context_id=$1 AND expense_id=$2`, [B.ctx, bigP.expenseId, bigP.revisionId]);
    // settlement
    const sid = uuid(); const rep = await timed(() => S.callFn(F, m2.p, `shared_expenses.report_settlement(${S.lit(F, JSON.stringify({ contextId: B.ctx, settlementId: sid, payerMemberId: m2.m, receiverMemberId: m1.m, amountMinor: '10', currency: 'INR', method: 'upi', paidOn: '2026-11-06' }))}::jsonb,${S.op(F)})`));
    const conf = await timed(() => S.callFn(F, m1.p, `shared_expenses.respond_settlement(${S.lit(F, JSON.stringify({ contextId: B.ctx, settlementId: sid, decision: 'confirm' }))}::jsonb,${S.op(F)})`));
    // reads over the mesh
    const t = async (p, fn, n = 12) => { const a = []; for (let k = 0; k < n; k++) a.push((await S.asActorTimed(F, p, fn)).ms); return stats(a); };
    const bal1 = await t(owner.p, c => Q.readBalances(c, owner.p, B.ctx, { limit: '100' }));
    const walk = []; let after, more = true; const keys = new Set(); while (more) { const r = await S.asActorTimed(F, owner.p, c => Q.readBalances(c, owner.p, B.ctx, { limit: '100', ...(after ? { after } : {}) })); walk.push(r.ms); r.value.items.forEach(i => keys.add(i.lowMemberId + i.highMemberId)); after = r.value.nextCursor; more = r.value.hasMore; }
    assert.equal(keys.size, 19900, 'balances walk returns every pair exactly once');
    const overview = await t(owner.p, c => Q.readOverview(c, owner.p));
    const list = await t(owner.p, c => Q.listContexts(c, owner.p, {}));
    const members = await t(owner.p, c => Q.listContextMembers(c, owner.p, B.ctx, { limit: '100' }));
    const ovPlan = await S.explain(F, owner.p, `WITH mine AS MATERIALIZED(SELECT context_id,member_id FROM shared_expenses.members WHERE profile_id=$1::uuid AND state='active')
      SELECT sum(CASE WHEN p.low_member_id=m.member_id THEN p.balance_minor::numeric ELSE -p.balance_minor::numeric END) FROM mine m JOIN shared_expenses.pair_balances p ON p.context_id=m.context_id AND (p.low_member_id=m.member_id OR p.high_member_id=m.member_id)`, [owner.p]);
    const pairIdx = await F.q(`SELECT indexname FROM pg_indexes WHERE schemaname='shared_expenses' AND tablename='pair_balances'`);
    const reader = await S.asActorTimed(F, owner.p, c => Q.readOverview(c, owner.p));
    record('Z02.B_mesh', { pairs, sumAbs: { p50: sumT.p50, p95: sumT.p95, max: sumT.max }, sumAbsPlan: sumPlan.split('\n').filter(l => /Scan|Execution|Buffers/.test(l)).map(l => l.trim()).slice(0, 4),
      authorOnlyAccept: stats(auth), twoPersonPropose_ms: Math.round(prop.ms * 10) / 10, twoPersonApproveAccept_ms: Math.round(appr.ms * 10) / 10,
      bigExpense: { edges, payers: 8, sharers: 50, proposeMs: Math.round(bigProp.ms * 10) / 10, approvals: bigApprovals.length, approvalMs: stats(bigApprovals), accepted: bigAccept[0].ok },
      settlement: { report_ms: Math.round(rep.ms * 10) / 10, confirm_ms: Math.round(conf.ms * 10) / 10 },
      balances_p1_100: bal1, balances_walk: { pages: walk.length, ...stats(walk) }, overview_owner: overview, overviewValue: reader.value, listContexts_owner: list, roster_p1_100: members,
      pairBalanceIndexes: pairIdx.map(r => r.indexname), overviewPlan: ovPlan.split('\n').filter(l => /Scan|Filter|Execution|Rows Removed/.test(l)).map(l => l.trim()).slice(0, 8) });
    assert.ok(stats(auth).p95 < BUDGET_CMD_P95, `accept path on mesh p95 ${stats(auth).p95}`);
    assert.ok(prop.ms < BUDGET_CMD_P95 && appr.ms < BUDGET_CMD_P95 && bigProp.ms < BUDGET_CMD_P95);
    assert.ok(bal1.p95 < 300 && overview.p95 < 300 && list.p95 < 300, 'reads over the mesh < 300ms p95');
    assert.equal(bigAccept[0].ok, true);
  });
});
