'use strict';
// Z03 : MANY EVENTS / FEED. 100k profile_events for one profile, 100k invitation rows, phone_reveals and
// operation_receipts growth, table bloat from the per-event stream-head updates, and the B15 impact.
// Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers are printed as `SCALE {json}` lines.
const fs = require('node:fs');
const path = require('node:path');
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed, repeat } = S;
const Q = S.requireApi('./src/shared_expenses/queries');
const FEED_SQL = /const PROJECTION_FEED_SQL=`([\s\S]*?)`;/.exec(fs.readFileSync(path.resolve(__dirname, '../../api/src/shared_expenses/queries.js'), 'utf8'))[1];
const EVENTS = Number(process.env.PANDAPAY_WORST_SCALE_EVENTS || 100000);

describe('Z03 many events / feed', { skip: SKIP, timeout: 4 * 3600 * 1000 }, () => {
  let F, P, ctx, member, other;
  before(async () => {
    F = await S.createFixture('z03');
    P = await F.profile('Pia Power'); other = await F.profile('Ola Other');
    ctx = uuid(); const c = await S.createCtx(F, P, ctx, 'group', 'Big stream'); member = c.memberId;
  });
  after(async () => {
    if (!F) return;
    if (process.env.PANDAPAY_WORST_SCALE_KEEP_DB) { await F.db.end().catch(() => {}); await F.admin.end().catch(() => {}); console.log('KEPT DB ' + F.dbName); } else await F.close();
  });
  const actor = (fn, p = P) => S.asActorTimed(F, p, fn);

  it(`Z03.1 ${EVENTS} profile_events for one profile: changes pull, projection pull, personal activity, cursor paging`, async () => {
    const t0 = Date.now();
    await F.db.query(`INSERT INTO shared_expenses.context_events(context_id,sequence,kind,origin_id,actor_profile_id,payload)
      SELECT $1::uuid,s,'member.renamed',$2::uuid,$3::uuid,jsonb_build_object('memberId',$2::uuid::text) FROM generate_series(2,$4::int) s`, [ctx, member, P, EVENTS + 1]);
    await F.db.query(`INSERT INTO shared_expenses.profile_events(profile_id,sequence,context_id,context_sequence) SELECT $3::uuid,s,$1::uuid,s FROM generate_series(2,$2::int) s`, [ctx, EVENTS + 1, P]);
    await F.db.query('UPDATE shared_expenses.contexts SET committed_sequence=$2 WHERE context_id=$1', [ctx, EVENTS + 1]);
    await F.db.query('UPDATE shared_expenses.profile_stream_heads SET committed_sequence=$2 WHERE profile_id=$1', [P, EVENTS + 1]);
    await F.db.query('VACUUM ANALYZE shared_expenses.profile_events, shared_expenses.context_events');
    const size = (await F.q(`SELECT pg_total_relation_size('shared_expenses.profile_events')/1024/1024 pe_mb,pg_total_relation_size('shared_expenses.context_events')/1024/1024 ce_mb,(SELECT count(*) FROM shared_expenses.profile_events)::int pe_rows`))[0];
    const out = { events: EVENTS, seedSeconds: Math.round((Date.now() - t0) / 1000), sizes: size };

    const cur = (kind, key) => Q.encodeCursor({ actorId: P, kind, contextId: null }, key);
    out.changes_first = stats((await (async () => { const a = []; for (let i = 0; i < 15; i++) a.push((await actor(c => Q.listChanges(c, P, { limit: '100' }))).ms); return a; })()));
    out.changes_deep = stats((await (async () => { const a = []; for (let i = 0; i < 15; i++) a.push((await actor(c => Q.listChanges(c, P, { limit: '100', after: cur('changes', [String(EVENTS - 500)]) }))).ms); return a; })()));
    // catch-up of the whole listChanges stream
    const w0 = Date.now(); let after2, more = true, pages = 0, n = 0; while (more) { const r = (await actor(c => Q.listChanges(c, P, { limit: '100', ...(after2 ? { after: after2 } : {}) }))).value; n += r.items.length; after2 = r.nextCursor; more = r.hasMore; pages++; }
    out.changes_fullwalk = { pages, items: n, seconds: Math.round((Date.now() - w0) / 100) / 10 };
    out.changes_fullwalk.expected = EVENTS; out.changes_fullwalk.lost = EVENTS + 1 - n; // +1 = the context.created event

    // projection feed: LIMIT 10 events per page. Walk 200 pages from the start.
    const pull = async (after3, limit = '100') => (await actor(c => Q.pullProjectionChanges(c, P, { limit, ...(after3 ? { after: after3 } : {}) })));
    const pms = []; let a3, pg = 0, recs = 0, more3 = true; while (more3 && pg < 200) { const r = await pull(a3); pms.push(r.ms); recs += r.value.records.length; a3 = r.value.nextCursor; more3 = r.value.hasMore; pg++; }
    const evPerPage = recs / pg;
    out.projection_from_start = { pagesWalked: pg, ...stats(pms), recordsPerPage: Math.round(evPerPage * 10) / 10 };
    const deepCursor = cur('projection_changes', [String(EVENTS - 2000), '00_context:' + ctx]);
    out.projection_deep = stats((await (async () => { const a = []; for (let i = 0; i < 10; i++) a.push((await pull(deepCursor)).ms); return a; })()));
    out.projection_catchup_estimate = { pagesNeeded: Math.ceil(EVENTS / 10), secondsAtP50: Math.round(Math.ceil(EVENTS / 10) * out.projection_from_start.p50 / 100) / 10, note: 'LIMIT 10 profile events per page is hard-coded in selected_events' };

    // personal activity (the "Activity" tab): filter applies AFTER the join, so a rare/absent q scans the whole stream
    out.personal_first = stats((await (async () => { const a = []; for (let i = 0; i < 10; i++) a.push((await actor(c => Q.listPersonalActivity(c, P, {}))).ms); return a; })()));
    out.personal_search_hit = stats((await (async () => { const a = []; for (let i = 0; i < 5; i++) a.push((await actor(c => Q.listPersonalActivity(c, P, { q: 'Big' }))).ms); return a; })()));
    out.personal_search_miss = stats((await (async () => { const a = []; for (let i = 0; i < 3; i++) a.push((await actor(c => Q.listPersonalActivity(c, P, { q: 'zzz-no-such' }))).ms); return a; })()));
    out.plan_projection_first = (await S.explain(F, P, FEED_SQL, [P, '0', '', 101, -1, null, null])).split('\n').filter(l => /Execution|Planning Time|Buffers: shared/.test(l)).slice(-3).map(l => l.trim());
    out.plan_personal_miss = (await S.explain(F, P, `SELECT pe.sequence::text FROM shared_expenses.profile_events pe JOIN shared_expenses.contexts c ON c.context_id=pe.context_id
      JOIN shared_expenses.context_events ce ON ce.context_id=pe.context_id AND ce.sequence=pe.context_sequence
      WHERE pe.profile_id=$1::uuid AND ($2::bigint IS NULL OR pe.sequence<$2::bigint) AND position(lower($4::text) in lower(shared_expenses._context_label(c.kind,c.name,c.created_by,$1::uuid,c.context_id)||' '||ce.kind))>0 ORDER BY pe.sequence DESC LIMIT $3::int`, [P, null, 51, 'zzz-no-such'])).split('\n').filter(l => /Scan|Execution|Rows Removed|Sort/.test(l)).slice(0, 8).map(l => l.trim());
    record('Z03.1', out);
    assert.ok(out.personal_first.p95 < 300, 'unfiltered personal activity page is index-bounded');
    assert.ok(out.personal_search_miss.p95 < 1000, `personal activity search with no match on a ${EVENTS}-event stream p95 ${out.personal_search_miss.p95}ms (< 1s)`);
  });

  it('Z03.2 B15 impact: text-ordered profile_sequence loses events once a stream has more than 9 entries (quantified)', async () => {
    const rows = {};
    for (const [events, limit] of [[12, '100'], [60, '100'], [60, '30'], [150, '100'], [150, '5']]) {
      const A = await F.profile('b15a'), Bp = await F.profile('b15b'); const cx = uuid(); const c = await S.createCtx(F, A, cx, 'group', 'B15 ' + cx.slice(0, 4)); const m = uuid();
      await S.inviteMember(F, A, cx, m, 'Bea', Bp); await S.respondMembership(F, Bp, cx, m, true);
      const have = (await F.q('SELECT count(*)::int c FROM shared_expenses.profile_events WHERE profile_id=$1', [Bp]))[0].c;
      for (let i = have; i < events; i++) await S.submit(F, A, S.proposal(cx, S.equalSnapshot(1000 + i, c.memberId, [c.memberId])));
      const expect = new Set((await F.q('SELECT context_sequence::text s FROM shared_expenses.profile_events WHERE profile_id=$1', [Bp])).map(r => r.s));
      const total = expect.size; const got = new Map(); let after3, more = true, pages = 0, dup = 0, guard = 0;
      while (more && guard++ < 2000) { const r = (await S.asActorTimed(F, Bp, cl => Q.pullProjectionChanges(cl, Bp, { limit, ...(after3 ? { after: after3 } : {}) }))).value; pages++;
        for (const rec of r.records) if (rec.entity === 'activity') { const s = rec.payload.sequence; got.set(s, (got.get(s) || 0) + 1); if (got.get(s) > 1) dup++; }
        after3 = r.nextCursor; more = r.hasMore; }
      const missing = [...expect].filter(s => !got.has(s));
      rows[`${total}ev_limit${limit}`] = { streamEvents: total, delivered: got.size, missing: missing.length, missingSample: missing.slice(0, 6), duplicates: dup, pages, stuckGuard: guard >= 2000 };
    }
    record('Z03.2_B15', rows);
    // desired behaviour: every event delivered exactly once (known defect B15 -> todo)
  });
  it('Z03.2b desired: a 150-event stream paged with limit 5 delivers every event exactly once (B15)', { todo: 'BUG B15 (S1): final ORDER BY uses the text alias of profile_sequence, so "10"<"2"; events are skipped' }, async () => {
    const A = await F.profile('b15c'), Bp = await F.profile('b15d'); const cx = uuid(); const c = await S.createCtx(F, A, cx, 'group', 'B15x'); const m = uuid();
    await S.inviteMember(F, A, cx, m, 'Bea', Bp); await S.respondMembership(F, Bp, cx, m, true);
    for (let i = 0; i < 30; i++) await S.submit(F, A, S.proposal(cx, S.equalSnapshot(1000 + i, c.memberId, [c.memberId])));
    const expect = (await F.q('SELECT context_sequence::text s FROM shared_expenses.profile_events WHERE profile_id=$1', [Bp])).map(r => r.s);
    const got = new Set(); let after3, more = true, guard = 0;
    while (more && guard++ < 500) { const r = (await S.asActorTimed(F, Bp, cl => Q.pullProjectionChanges(cl, Bp, { limit: '5', ...(after3 ? { after: after3 } : {}) }))).value; for (const rec of r.records) if (rec.entity === 'activity') got.add(rec.payload.sequence); after3 = r.nextCursor; more = r.hasMore; }
    assert.deepEqual(expect.filter(s => !got.has(s)), []);
  });

  it('Z03.5 same text-alias ORDER BY in listChanges and listContextActivity: order and paging are wrong once a stream/context has more than 9 events', async () => {
    const A = await F.profile('act-a'), B = await F.profile('act-b'); const cx = uuid(); const c = await S.createCtx(F, A, cx, 'group', 'Act ' + cx.slice(0, 4)); const m = uuid();
    await S.inviteMember(F, A, cx, m, 'Bea', B); await S.respondMembership(F, B, cx, m, true);
    for (let i = 0; i < 40; i++) await S.submit(F, A, S.proposal(cx, S.equalSnapshot(1000 + i, c.memberId, [c.memberId])));
    const total = (await F.q('SELECT count(*)::int c FROM shared_expenses.context_events WHERE context_id=$1', [cx]))[0].c;
    const walk = async (fn, key) => { const seen = []; let after3, more = true, guard = 0; while (more && guard++ < 200) { const r = (await S.asActorTimed(F, B, cl => fn(cl, after3))).value; seen.push(...r.items.map(i => i.sequence)); after3 = r.nextCursor; more = r.hasMore; } return seen; };
    const act = await walk((cl, a) => Q.listContextActivity(cl, B, cx, { limit: '10', ...(a ? { after: a } : {}) }));
    const chg = await walk((cl, a) => Q.listChanges(cl, B, { limit: '10', ...(a ? { after: a } : {}) }));
    const firstPage = (await S.asActorTimed(F, B, cl => Q.listContextActivity(cl, B, cx, { limit: '10' }))).value.items.map(i => i.sequence);
    const uniq = a => new Set(a).size;
    record('Z03.5', { contextEvents: total, activity: { delivered: uniq(act), duplicates: act.length - uniq(act), firstPageOfTenSequences: firstPage }, changes: { delivered: uniq(chg), duplicates: chg.length - uniq(chg), expected: (await F.q('SELECT count(*)::int c FROM shared_expenses.profile_events WHERE profile_id=$1', [B]))[0].c } });
    globalThis.__act = { total, act, chg };
  });
  it('Z03.5b desired: the activity feed of a split returns events 1..N in order, exactly once (listContextActivity / listChanges)', { todo: 'NEW (same root cause as B15): SELECT sequence::text ... ORDER BY sequence sorts by the text alias: wrong order, events skipped/duplicated across pages, and a full sort of the whole split per page (457ms at 3.4k events, 2.3s at 15k)' }, () => {
    const { total, act } = globalThis.__act; assert.deepEqual(act.slice(0, 10), ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10']); assert.equal(new Set(act).size, total);
  });
  it('Z03.3 invitation / purge backlog: 100k invitation rows (half with phone ciphertext due), hourly purge batch, lazy purge on reads', async () => {
    const N = Number(process.env.PANDAPAY_WORST_SCALE_INVITES || 100000);
    // 1000 other owners share the backlog; the probing owner has none
    const owners = await S.bulkProfiles(F, 20, 'own');
    const cx = uuid(); const c = await S.createCtx(F, owners[0], cx, 'group', 'Backlog'); const mem = uuid(); await S.inviteMember(F, owners[0], cx, mem, 'Pending Pat');
    await F.db.query(`INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,state,created_at,expires_at,claimed_profile_id,claimant_phone_enc,claimant_phone_key_id,claimant_phone_cc,claimant_phone_mask,phone_share,verified_phone_suffix)
      SELECT gen_random_uuid(),$1,$2,$3,encode(sha256(convert_to(s::text||'t','UTF8')),'hex'),'rejected',now()-interval '3 days',now()-interval '1 day',$3,
        CASE WHEN s%2=0 THEN decode(repeat('ab',40),'hex') END,CASE WHEN s%2=0 THEN 'k1' END,CASE WHEN s%2=0 THEN '+91' END,CASE WHEN s%2=0 THEN '+91 ••••• 1234' END,CASE WHEN s%2=0 THEN 'shared' ELSE 'none' END,'1234'
      FROM generate_series(1,$4::int) s`, [cx, mem, owners[1], N]);
    await F.db.query('VACUUM ANALYZE shared_expenses.invitations');
    const sz = (await F.q(`SELECT pg_total_relation_size('shared_expenses.invitations')/1024/1024 mb,(SELECT count(*) FROM shared_expenses.invitations WHERE claimant_phone_enc IS NOT NULL)::int due`))[0];
    const out = { invitationRows: N, sizeMb: sz.mb, dueWithCiphertext: sz.due };
    // an unrelated owner reads their join requests: _purge_lazy(owner) must not scan the whole backlog
    const probe = owners[2]; const pc = uuid(); await S.createCtx(F, probe, pc, 'group', 'Probe');
    out.list_join_requests_unrelated_owner = stats((await (async () => { const a = []; for (let i = 0; i < 10; i++) a.push((await timed(() => S.callFn(F, probe, 'shared_expenses.list_join_requests()'))).ms); return a; })()));
    out.list_invitations_unrelated_owner = stats((await (async () => { const a = []; for (let i = 0; i < 10; i++) a.push((await timed(() => S.callFn(F, probe, `shared_expenses.list_invitations(${S.lit(F, pc)}::uuid,NULL)`))).ms); return a; })()));
    out.plan_purge_lazy_unrelated_owner = (await F.q(`EXPLAIN (ANALYZE,BUFFERS,TIMING OFF) WITH due AS (SELECT i.invitation_id FROM shared_expenses.invitations i WHERE i.claimant_phone_enc IS NOT NULL AND (i.state<>'awaiting_owner' OR i.expires_at<=clock_timestamp())
       AND EXISTS(SELECT FROM shared_expenses.members o WHERE o.context_id=i.context_id AND o.profile_id=$1 AND o.role='owner' AND o.state='active') ORDER BY i.expires_at LIMIT 50 FOR UPDATE SKIP LOCKED) SELECT count(*) FROM due`, [probe])).map(r => r['QUERY PLAN']).filter(l => /Scan|Execution|Rows Removed|Heap Fetches/.test(l)).slice(0, 6).map(l => l.trim());
    // the owner who owns the backlog: lazy purge handles only 50 rows per read
    const mine = await timed(() => S.callFn(F, owners[0], 'shared_expenses.list_join_requests()'));
    const left1 = (await F.q('SELECT count(*)::int c FROM shared_expenses.invitations WHERE claimant_phone_enc IS NOT NULL'))[0].c;
    out.lazy_purge_owner_read = { ms: Math.round(mine.ms * 10) / 10, purgedByThatRead: sz.due - left1 };
    // hourly job: 1000 per call
    const batches = []; for (let i = 0; i < 3; i++) { const b = await timed(() => F.db.query('SELECT shared_expenses.purge_expired_claimant_phones() AS v').then(r => r.rows[0].v)); batches.push({ ms: Math.round(b.ms), purged: b.value }); }
    out.hourly_purge_batches = batches; out.hoursToDrainBacklogAt1000PerHour = Math.ceil(left1 / 1000);
    record('Z03.3', out);
    assert.ok(out.list_join_requests_unrelated_owner.p95 < 300, `a read by an unrelated owner must not scan the whole phone backlog (p95 ${out.list_join_requests_unrelated_owner.p95}ms)`);
  });

  it('Z03.4 phone_reveals + operation_receipts growth, per-event stream-head bloat', async () => {
    const out = {};
    // phone_reveals: rows/size, budget check cost for an owner with many reveals
    const owner = await F.profile('rev');
    const cx = uuid(); await S.createCtx(F, owner, cx, 'group', 'Rev'); const m = uuid(); await S.inviteMember(F, owner, cx, m, 'Pending');
    const inv = uuid(); await F.db.query(`INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,state) VALUES($1::uuid,$2::uuid,$3::uuid,$4::uuid,encode(sha256(convert_to($1::uuid::text,'UTF8')),'hex'),'open')`, [inv, cx, m, owner]);
    await F.db.query(`INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via,at) SELECT $1::uuid,$2::uuid,'tap',now()-(s||' seconds')::interval FROM generate_series(1,200000) s`, [inv, owner]);
    await F.db.query(`INSERT INTO shared_expenses.phone_reveals(invitation_id,owner_profile_id,via,at) SELECT $1::uuid,gen_random_uuid(),'tap',now()-(s||' seconds')::interval FROM generate_series(1,100000) s`, [inv]);
    await F.db.query('VACUUM ANALYZE shared_expenses.phone_reveals');
    const rv = (await F.q(`SELECT pg_total_relation_size('shared_expenses.phone_reveals') b,(SELECT count(*) FROM shared_expenses.phone_reveals)::int n`))[0];
    out.phone_reveals = { rows: rv.n, bytesPerRow: Math.round(Number(rv.b) / rv.n), budgetCheck: await repeat(20, () => F.db.query('SELECT shared_expenses._reveal_budget_left($1)', [owner])).then(r => ({ p50: r.p50, p95: r.p95 })), noPurgeJob: (await F.q(`SELECT count(*)::int c FROM pg_proc WHERE pronamespace='shared_expenses'::regnamespace AND prosrc ILIKE '%DELETE FROM shared_expenses.phone_reveals%'`))[0].c === 0 };
    // operation_receipts: real commands -> average row size incl. result jsonb
    const u = await S.bulkProfiles(F, 5, 'rcp'); const g = uuid(); const gc = await S.createCtx(F, u[0], g, 'group', 'Receipts'); const mm = [];
    for (let i = 1; i < 5; i++) { const x = uuid(); await S.inviteMember(F, u[0], g, x, 'R' + i, u[i]); await S.respondMembership(F, u[i], g, x, true); mm.push(x); }
    for (let i = 0; i < 400; i++) { const a = u[i % 5]; const mid = i % 5 === 0 ? gc.memberId : mm[(i % 5) - 1]; await S.submit(F, a, S.proposal(g, S.equalSnapshot(1000 + i, mid, [mid]))); }
    const rr = (await F.q(`SELECT count(*)::int n,round(avg(pg_column_size(r.*)))::int avg_row_bytes,round(avg(pg_column_size(result)))::int avg_result,pg_total_relation_size('shared_expenses.operation_receipts')::bigint total FROM shared_expenses.operation_receipts r`))[0];
    const perRow = Math.round(Number(rr.total) / rr.n);
    out.operation_receipts = { rows: rr.n, avgRowBytes: rr.avg_row_bytes, avgResultBytes: rr.avg_result, totalBytesPerRowInclIndex: perRow, hasTtlOrPurge: (await F.q(`SELECT count(*)::int c FROM pg_proc WHERE pronamespace='shared_expenses'::regnamespace AND prosrc ILIKE '%DELETE FROM shared_expenses.operation_receipts%'`))[0].c > 0,
      estimateMbPerDay: { 'users=1k,cmds/user/day=10': Math.round(1000 * 10 * perRow / 1048576 * 10) / 10, 'users=100k,cmds/user/day=10': Math.round(100000 * 10 * perRow / 1048576), 'users=100k,cmds=10 per year GB': Math.round(100000 * 10 * 365 * perRow / 1073741824 * 10) / 10 } };
    // stream-head bloat: one 100-member group, 300 events
    const big = await S.bulkProfiles(F, 100, 'bl'); const bg = uuid(); const bc = await S.createCtx(F, big[0], bg, 'group', 'Bloat');
    for (let i = 1; i < 100; i++) { const x = uuid(); await S.inviteMember(F, big[0], bg, x, 'B' + i, big[i]); await S.respondMembership(F, big[i], bg, x, true); }
    for (let i = 0; i < 300; i++) await S.submit(F, big[0], S.proposal(bg, S.equalSnapshot(1000 + i, bc.memberId, [bc.memberId])));
    await F.db.query('SELECT pg_stat_force_next_flush()');
    const hb = (await F.q(`SELECT n_live_tup::int live,n_dead_tup::int dead,n_tup_upd::int upd,n_tup_hot_upd::int hot,pg_relation_size('shared_expenses.profile_stream_heads')/1024 kb FROM pg_stat_user_tables WHERE schemaname='shared_expenses' AND relname='profile_stream_heads'`))[0];
    const ctxb = (await F.q(`SELECT n_dead_tup::int dead,n_tup_upd::int upd FROM pg_stat_user_tables WHERE schemaname='shared_expenses' AND relname='contexts'`))[0];
    out.stream_head_bloat = { headsTable: hb, contextsTable: ctxb, note: 'every event updates one profile_stream_heads row per active member plus the contexts row' };
    record('Z03.4', out);
  });
});
