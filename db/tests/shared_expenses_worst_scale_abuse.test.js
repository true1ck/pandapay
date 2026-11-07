'use strict';
// Z07 : ABUSE VOLUME. One hostile user: 10,000 groups, 3,000 direct splits (O(n) friend-name scan), ~100k name-only member
// rows, spam-inviting one victim into 2,000 groups, and what that costs the database and the victim. Also the global
// lookup_phone scan. Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers are printed as `SCALE {json}` lines.
// Env knobs: PANDAPAY_WORST_SCALE_GROUPS (10000), _VICTIM (2000), _NAMEONLY_GROUPS (500), _DIRECTS (3000).
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed } = S;
const Q = S.requireApi('./src/shared_expenses/queries');
const env = (k, d) => Number(process.env['PANDAPAY_WORST_SCALE_' + k] || d);
const GROUPS = env('GROUPS', 10000), VICTIM = env('VICTIM', 2000), NAMEONLY = env('NAMEONLY_GROUPS', 500), DIRECTS = env('DIRECTS', 3000);

describe('Z07 abuse volume: one hostile user', { skip: SKIP, timeout: 6 * 3600 * 1000 }, () => {
  let F, H, V, groups = [];
  before(async () => { F = await S.createFixture('z07'); H = await F.profile('Hostile Harry'); V = await F.profile('Victim Vera'); });
  after(async () => { if (F) await F.close(); });
  const size = async () => (await F.q(`SELECT relname,pg_total_relation_size(c.oid)::bigint b,reltuples::bigint rows FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='shared_expenses' AND relkind='r' ORDER BY b DESC LIMIT 8`)).map(r => `${r.relname}:${Math.round(Number(r.b) / 1048576 * 10) / 10}MB/${r.rows}rows`);

  it(`Z07.1 ${GROUPS} groups by one user in one run: create latency per decile, no per-user or per-day cap`, async () => {
    const t0 = Date.now(); const ms = []; let firstRefusal = null;
    for (let i = 0; i < GROUPS; i++) { const ctx = uuid(); const t = process.hrtime.bigint(); try { await S.createCtx(F, H, ctx, 'group', `Spam group ${i}`); } catch (e) { firstRefusal = firstRefusal || { at: i, message: e.message }; break; } ms.push(Number(process.hrtime.bigint() - t) / 1e6); groups.push(ctx); }
    await F.db.query('ANALYZE');
    const dec = []; const step = Math.ceil(ms.length / 10); for (let d = 0; d < 10; d++) dec.push(stats(ms.slice(d * step, (d + 1) * step)).p50);
    const mine = (await S.asActorTimed(F, H, c => Q.listContexts(c, H, {}))).ms;
    const lc = []; for (let i = 0; i < 10; i++) lc.push((await S.asActorTimed(F, H, c => Q.listContexts(c, H, {}))).ms);
    const ov = []; for (let i = 0; i < 10; i++) ov.push((await S.asActorTimed(F, H, c => Q.readOverview(c, H))).ms);
    const srch = []; for (let i = 0; i < 5; i++) srch.push((await S.asActorTimed(F, H, c => Q.listContexts(c, H, { q: 'group 99' }))).ms);
    const walkMs = []; let after2, more = true, n = 0; while (more) { const r = await S.asActorTimed(F, H, c => Q.listContexts(c, H, { limit: '100', ...(after2 ? { after: after2 } : {}) })); walkMs.push(r.ms); n += r.value.items.length; after2 = r.value.nextCursor; more = r.value.hasMore; }
    record('Z07.1', { groupsCreated: groups.length, secondsTotal: Math.round((Date.now() - t0) / 1000), createMsP50ByDecile: dec, firstRefusal, hostileListFirst50: stats(lc), hostileOverview: stats(ov), hostileSearch: stats(srch), fullWalkPages: walkMs.length, walkPageP95: stats(walkMs).p95, walkItems: n, sizes: await size() });
    assert.equal(firstRefusal, null, 'no cap: all groups created');
  });
  it('Z07.1b desired: a single user cannot create more than a sane number of splits per day (product cap)', { todo: 'A: no cap on groups per user and no per-day cap on create_context; 10,000 groups in minutes' }, async () => {
    let refused = false; for (let i = 0; i < 20 && !refused; i++) { try { await S.createCtx(F, H, uuid(), 'group', 'Extra ' + i); } catch { refused = true; } }
    assert.ok(groups.length <= 2000 || refused, `user already owns ${groups.length} groups and was never refused`);
  });

  it(`Z07.2 spam-inviting one victim into ${VICTIM} groups: victim's list, changes feed, projection feed, inbox of invitations`, async () => {
    const ms = []; for (let i = 0; i < Math.min(VICTIM, groups.length); i++) ms.push((await timed(() => S.inviteMember(F, H, groups[i], uuid(), 'Vera', V))).ms);
    await F.db.query('ANALYZE');
    const t = async fn => { const a = []; for (let k = 0; k < 8; k++) a.push((await S.asActorTimed(F, V, fn)).ms); return stats(a); };
    const list = await t(c => Q.listContexts(c, V, {})); const ov = await t(c => Q.readOverview(c, V)); const ch = await t(c => Q.listChanges(c, V, { limit: '100' })); const pr = await t(c => Q.pullProjectionChanges(c, V, { limit: '100' }));
    const counts = (await F.q(`SELECT count(*) FILTER(WHERE state='invited')::int invited FROM shared_expenses.members WHERE profile_id=$1`, [V]))[0];
    const stream = (await F.q(`SELECT count(*)::int ev FROM shared_expenses.profile_events WHERE profile_id=$1`, [V]))[0];
    // can the victim stop it? there is no block / mute: each decline is one command
    const decl = []; const mem = await F.q(`SELECT context_id,member_id FROM shared_expenses.members WHERE profile_id=$1 AND state='invited' LIMIT 20`, [V]);
    for (const m of mem) decl.push((await timed(() => S.respondMembership(F, V, m.context_id, m.member_id, false))).ms);
    record('Z07.2', { invitesSent: ms.length, inviteMs: stats(ms), victimInvitedMemberships: counts.invited, victimStreamEvents: stream.ev, victimListFirst50: list, victimOverview: ov, victimChanges: ch, victimProjectionPage: pr, declineOneMs: stats(decl), note: 'invite_member with a profileId needs no relationship, consent, block list or rate limit' });
    assert.ok(list.p95 < 300, `victim list p95 ${list.p95}`);
  });
  it('Z07.2b desired: inviting a registered profile into a split is rate limited per inviter (invite spam)', { todo: 'invite_member(profileId) has no per-inviter rate limit (only create_invitation links are capped at 50/h)' }, async () => {
    const victim = await F.profile('Victim 2'); let refused = false;
    for (let i = 0; i < 120 && !refused; i++) { try { await S.inviteMember(F, H, groups[3000 + i] || groups[i], uuid(), 'Vee ' + i, victim); } catch (e) { if (/rate/.test(e.message)) refused = true; } }
    assert.ok(refused, '120 invites of one stranger in an hour were all accepted');
  });

  it(`Z07.3 ~${NAMEONLY * 198} name-only member rows (${NAMEONLY} groups x 198): per-invite latency growth, storage per member`, async () => {
    const t0 = Date.now(); const byPos = { 1: [], 50: [], 100: [], 150: [], 197: [] }; let rows = 0;
    const g = groups.slice(5000, 5000 + NAMEONLY);
    for (const ctx of g) { for (let k = 0; k < 198; k++) { const m = uuid(); const t = await timed(() => S.inviteMember(F, H, ctx, m, `N${k}-${Math.random().toString(36).slice(2, 8)}`)); rows++; if (byPos[k]) byPos[k].push(t.ms); }
      if (Date.now() - t0 > 20 * 60 * 1000) break; }
    await F.db.query('ANALYZE');
    const pos = Object.fromEntries(Object.entries(byPos).map(([k, v]) => [k, v.length ? stats(v).p50 : null]));
    const sz = (await F.q(`SELECT pg_total_relation_size('shared_expenses.members')::bigint b,(SELECT count(*) FROM shared_expenses.members)::int n`))[0];
    const roster = (await S.asActorTimed(F, H, c => Q.listContextMembers(c, H, g[0], { limit: '100' }))).ms;
    record('Z07.3', { memberRowsAdded: rows, seconds: Math.round((Date.now() - t0) / 1000), perInviteP50ByPosition: pos, membersTableMb: Math.round(Number(sz.b) / 1048576), membersRows: sz.n, bytesPerMemberRowInclIdx: Math.round(Number(sz.b) / sz.n), rosterPage100Ms: Math.round(roster * 10) / 10, sizes: await size() });
  });

  it(`Z07.4 ${DIRECTS} direct splits by one user: create_context(direct) latency grows with the number already owned (friend-name scan)`, async () => {
    const t = []; for (let i = 0; i < DIRECTS; i++) t.push((await timed(() => S.createCtx(F, H, uuid(), 'direct', `Bot friend ${i}`))).ms);
    const pts = {}; for (const at of [100, 500, 1000, 2000, 3000]) if (t.length >= at) pts[at] = stats(t.slice(at - 50, at)).p50;
    const sz = await F.q(`SELECT count(*)::int c FROM shared_expenses.contexts WHERE created_by=$1 AND kind='direct'`, [H]);
    record('Z07.4', { directCreated: sz[0].c, createMsP50AtOwnedCount: pts, perCallGrowthMsPer1000: pts[3000] && pts[1000] ? Math.round((pts[3000] - pts[1000]) / 2) : null, note: '_friend_context scans every direct split the creator owns and calls _context_label per row; create AND invite_member both pay it' });
    assert.ok(Math.max(...t.slice(-20)) < 500, `create_context(direct) at ${t.length} owned splits stays under 500ms`);
  });

  it('Z07.5 lookup_phone scans direct splits globally: cost with all of the above in the database', async () => {
    const a = await F.profile('Look A'), b = await F.profile('Look B'); const ha = 'a'.repeat(64), hb = 'b'.repeat(64);
    await S.callFn(F, a, `shared_expenses.register_phone(${S.lit(F, ha)},true)`); await S.callFn(F, b, `shared_expenses.register_phone(${S.lit(F, hb)},true)`);
    const ctx = uuid(); const c = await S.createCtx(F, a, ctx, 'direct', 'Look B'); const m = uuid(); await S.inviteMember(F, a, ctx, m, 'Look B', b); await S.respondMembership(F, b, ctx, m, true);
    const r = await timed(() => S.callFn(F, a, `shared_expenses.lookup_phone(${S.lit(F, hb)})`));
    const plan = (await S.explain(F, a, `SELECT c.context_id FROM shared_expenses.contexts c WHERE c.kind='direct' AND c.state='active'
     AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.profile_id=$1 AND m.state='active')
     AND EXISTS(SELECT FROM shared_expenses.members m WHERE m.context_id=c.context_id AND m.profile_id=$2 AND m.state IN ('active','invited')) ORDER BY c.created_at LIMIT 1`, [a, b])).split('\n').filter(l => /Scan|Join|Execution|Rows Removed/.test(l)).slice(0, 8).map(l => l.trim());
    const total = (await F.q(`SELECT count(*)::int c FROM shared_expenses.contexts WHERE kind='direct'`))[0].c;
    record('Z07.5', { directSplitsInDb: total, lookupFoundMs: Math.round(r.ms * 10) / 10, result: r.value, plan });
    assert.ok(r.ms < 300);
  });

  it('Z07.6 storage after the run (per-table MB and rows) and cost per context / per event row', async () => {
    const t = await F.q(`SELECT (SELECT count(*) FROM shared_expenses.contexts)::int ctxs,(SELECT count(*) FROM shared_expenses.members)::int members,(SELECT count(*) FROM shared_expenses.context_events)::int ctx_events,(SELECT count(*) FROM shared_expenses.profile_events)::int profile_events,(SELECT count(*) FROM shared_expenses.operation_receipts)::int receipts,
      pg_total_relation_size('shared_expenses.contexts')/1024/1024 contexts_mb,pg_total_relation_size('shared_expenses.members')/1024/1024 members_mb,pg_total_relation_size('shared_expenses.context_events')/1024/1024 ctx_events_mb,pg_total_relation_size('shared_expenses.profile_events')/1024/1024 profile_events_mb,pg_total_relation_size('shared_expenses.operation_receipts')/1024/1024 receipts_mb,pg_database_size(current_database())/1024/1024 db_mb`);
    record('Z07.6', t[0]);
  });
});
