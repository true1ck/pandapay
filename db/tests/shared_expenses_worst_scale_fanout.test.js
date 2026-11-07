'use strict';
// Z04 : PUSH / NOTIFICATION FAN-OUT. Runs the REAL api/src/shared_expenses/notifications.js (loadAudience SQL, plan(),
// slice(0,50), deliverOne SQL) against the real shared_expenses schema under RLS. Only the inbox table is a stub
// (public.notifications / notification_preferences with the same insert + unique dedupe index); the outbox is off.
// Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers are printed as `SCALE {json}` lines.
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed } = S;
const { notifyAfterCommit } = SKIP ? {} : S.requireApi('./src/shared_expenses/notifications');

describe('Z04 push / notification fan-out', { skip: SKIP, timeout: 3600 * 1000 }, () => {
  let F;
  before(async () => {
    F = await S.createFixture('z04');
    await F.db.query(`CREATE TABLE public.notifications(id uuid PRIMARY KEY DEFAULT gen_random_uuid(),profile_id uuid NOT NULL,category text,severity text,title text,body text,deep_link text,dedupe_key text,created_at timestamptz DEFAULT now());
      CREATE UNIQUE INDEX notifications_dedupe ON public.notifications(profile_id,dedupe_key) WHERE dedupe_key IS NOT NULL;
      CREATE TABLE public.notification_preferences(profile_id uuid PRIMARY KEY,category_needs_review boolean);
      GRANT ALL ON public.notifications,public.notification_preferences TO app_user;`);
  });
  after(async () => { if (F) await F.close(); });
  const withUserClient = async (profile, fn) => {
    await F.db.query('BEGIN'); await F.db.query('SET LOCAL ROLE app_user'); await F.db.query("SELECT set_config('app.user_id',$1,true)", [profile]);
    try { const r = await fn(F.db); await F.db.query('COMMIT'); return r; } catch (e) { await F.db.query('ROLLBACK').catch(() => {}); throw e; }
  };
  const notify = (g, authorIdx, op) => notifyAfterCommit({ withUserClient, actorId: g.members[authorIdx].p, kind: 'expense.propose', payload: {}, contextId: g.ctx, operationId: op, options: { enabled: true }, logger: { warn() {} } });

  it('Z04.1 expense.propose in groups of 10 / 50 / 100 / 200: rows created, cost, and reviewers dropped by slice(0,50)', async () => {
    const rows = {};
    for (const n of [10, 50, 100, 200]) {
      const g = await S.buildGroup(F, n, 'n' + n);
      // 20 required reviewers = sharers 100..119 (or the first up to 20 other members in small groups)
      const reviewerIdx = Array.from({ length: Math.min(20, n - 1) }, (_, i) => n >= 100 ? n - 1 - i : 1 + i);
      const ids = [0, ...reviewerIdx].map(i => g.members[i].m);
      const proposal = S.proposal(g.ctx, S.equalSnapshot(10000, g.members[0].m, ids));
      const pr = await S.submit(F, g.members[0].p, proposal); assert.equal(pr.status, 'awaiting_approval');
      const op = uuid();
      const t = await timed(() => notify(g, 0, op));
      const notified = new Set((await F.q(`SELECT profile_id FROM public.notifications WHERE dedupe_key LIKE $1`, ['split:' + op + ':%'])).map(r => r.profile_id));
      const required = reviewerIdx.map(i => g.members[i].p);
      const missed = required.filter(p => !notified.has(p));
      const notReviewers = [...notified].filter(p => !required.includes(p) && p !== g.members[0].p);
      // replay: the same operation id must not notify again (dedupe)
      const replay = await notify(g, 0, op);
      rows[n] = { activeMembers: n, rowsCreated: t.value, ms: Math.round(t.ms), msPerRow: Math.round(t.ms / Math.max(1, t.value) * 10) / 10, requiredReviewers: required.length, reviewersNotified: required.length - missed.length, reviewersDropped: missed.length, nonReviewersNotified: notReviewers.length, replayRows: replay };
    }
    record('Z04.1', rows);
    // desired: everyone who must review gets told, regardless of group size (D3)
  });
  it('Z04.1b desired: every required reviewer of a proposal in a 200-member group is notified (D3: slice(0,50) of an unordered member list drops them)', { todo: 'D3: notifications.plan() targets all other active members then slice(0,50) in unspecified order; required reviewers can be cut, non-reviewers are pinged' }, async () => {
    const g = await S.buildGroup(F, 200, 'd3');
    const reviewerIdx = Array.from({ length: 20 }, (_, i) => 199 - i); const ids = [0, ...reviewerIdx].map(i => g.members[i].m);
    await S.submit(F, g.members[0].p, S.proposal(g.ctx, S.equalSnapshot(10000, g.members[0].m, ids)));
    const op = uuid(); await notify(g, 0, op);
    const notified = new Set((await F.q(`SELECT profile_id FROM public.notifications WHERE dedupe_key LIKE $1`, ['split:' + op + ':%'])).map(r => r.profile_id));
    assert.deepEqual(reviewerIdx.map(i => g.members[i].p).filter(p => !notified.has(p)), []);
  });

  it('Z04.2 a user in many splits receiving events: inbox rows, insert cost, dedupe, row size', async () => {
    const U = await F.profile('Inbox User'); const rowsN = 2000;
    const ms = [];
    for (let i = 0; i < rowsN; i++) ms.push((await timed(() => withUserClient(U, c => c.query(`INSERT INTO notifications (profile_id, category, severity, title, body, deep_link, dedupe_key) VALUES ($1,'needs_review','info','New expense to review','Someone added a shared expense in Trip. Review it before it counts.',$2,$3) ON CONFLICT (profile_id, dedupe_key) WHERE dedupe_key IS NOT NULL DO NOTHING RETURNING id`, [U, '/insights/splits/' + uuid(), 'split:' + uuid() + ':' + U])))).ms);
    await F.db.query('VACUUM ANALYZE public.notifications');
    const sz = (await F.q(`SELECT count(*)::int n,pg_total_relation_size('public.notifications')::bigint b FROM public.notifications WHERE profile_id=$1`, [U]))[0];
    const count = await timed(() => withUserClient(U, c => c.query('SELECT count(*) FROM notifications WHERE profile_id=$1', [U])));
    record('Z04.2', { inboxRowsForUser: sz.n, insertMs: stats(ms), tableBytesPerRow: Math.round(Number(sz.b) / sz.n), countQueryMs: Math.round(count.ms * 10) / 10, note: 'one inbox row per (operation, recipient): a user in 2000 splits with 1 expense/split/day gets 2000 rows/day, no collapsing or cap in the planner' });
    assert.ok(stats(ms).p95 < 100);
  });
});
