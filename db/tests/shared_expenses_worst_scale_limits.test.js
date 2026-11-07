'use strict';
// Z06 : LIMITS AND HARD CAPS at the boundary: what the database raises, what HTTP status the API maps it to, and whether
// the app has plain-language text for it. Also finds caps that interact badly (declined/left rows count toward the cap).
// Skipped unless PANDAPAY_WORST_SCALE_PG_URL is set. Numbers/outcomes are printed as `SCALE {json}` lines.
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { describe, it, before, after } = require('node:test');
const assert = require('node:assert/strict');
const S = require('./shared_expenses_worst_scale_common.test.js');
const { SKIP, uuid, record, stats, timed } = S;

const ROUTES = fs.readFileSync(path.resolve(__dirname, '../../api/src/shared_expenses/routes.js'), 'utf8');
const DIRECTORY = fs.existsSync(path.resolve(__dirname, '../../app/lib/features/shared_expenses/data/shared_directory.dart')) ? fs.readFileSync(path.resolve(__dirname, '../../app/lib/features/shared_expenses/data/shared_directory.dart'), 'utf8') : '';
function httpFor(code) {
  const block = /const SQL_ERRORS=new Map\(\[([\s\S]*?)\]\);\s*function sendError/.exec(ROUTES)?.[1] || '';
  const single = new RegExp(`\\['${code}',(\\d{3})\\]`).exec(block); if (single) return Number(single[1]);
  for (const g of block.matchAll(/\.\.\.\[([^\]]*)\]\.map\(code=>\[code,(\d{3})\]\)/g)) if (g[1].includes(`'${code}'`)) return Number(g[2]);
  return null;
}
const appText = code => { const m = new RegExp(`'${code}'(?: \\|\\| '[a-z_]+')* =>\\s*'([^']+)'`).exec(DIRECTORY); return m ? m[1] : null; };
async function outcome(fn) { try { const v = await fn(); return { ok: true, status: v?.status }; } catch (e) { const code = String(e.message).split('\n')[0]; return { ok: false, code, http: httpFor(code), appText: appText(code) }; } }

describe('Z06 limits and hard caps at the boundary', { skip: SKIP, timeout: 3600 * 1000 }, () => {
  let F;
  before(async () => { F = await S.createFixture('z06'); });
  after(async () => { if (F) await F.close(); });
  const res = {};

  it('Z06.1 member cap: 200th ok, 201st refused; invite vs link-claim vs proposal paths', async () => {
    const g = await S.buildGroup(F, 199, 'cap');           // owner + 198 = 199 counted
    const o = g.owner, extra = await S.bulkProfiles(F, 4, 'x');
    const m200 = uuid(), m201 = uuid();
    res.member200 = await outcome(() => S.inviteMember(F, o.p, g.ctx, m200, 'Two Hundredth', extra[0]));
    res.member201 = await outcome(() => S.inviteMember(F, o.p, g.ctx, m201, 'Two Hundred One', extra[1]));
    // link claim at the cap
    const th = crypto.randomBytes(32).toString('hex'); await S.callFn(F, o.p, `shared_expenses.create_group_link(${S.lit(F, g.ctx)}::uuid,${S.lit(F, th)},${S.op(F)})`);
    res.claimAtCap = await outcome(() => S.callFn(F, extra[2], `shared_expenses.claim_invitation(${S.lit(F, th)},'p','3210',${S.op(F)})`));
    // a member who declined frees a slot; a member who LEFT does not
    await S.respondMembership(F, extra[0], g.ctx, m200, false);
    res.afterDecline = await outcome(() => S.inviteMember(F, o.p, g.ctx, uuid(), 'Replacement', extra[3]));
    record('Z06.1', res);
    assert.equal(res.member200.ok, true); assert.equal(res.member201.code, 'context_member_limit'); assert.equal(res.member201.http, 400);
  });
  it('Z06.1b left / removed / declined rows must not block expenses: a split with 205 member ROWS (195 live) can still take an expense', { todo: 'submit_proposal counts every members row (declined, left, erased) against 200, while invite counts state<>declined: a split with more than 200 rows ever can never take an expense' }, async () => {
    const g = await S.buildGroup(F, 190, 'rows');
    // owner invites and removes 15 name-only people: 15 declined rows, 190 live members
    for (let i = 0; i < 15; i++) { const m = uuid(); await S.inviteMember(F, g.owner.p, g.ctx, m, 'Temp ' + i); await S.callFn(F, g.owner.p, `shared_expenses.remove_member(${S.lit(F, g.ctx)}::uuid,${S.lit(F, m)}::uuid,${S.op(F)})`); }
    const rows = (await F.q('SELECT count(*)::int c FROM shared_expenses.members WHERE context_id=$1', [g.ctx]))[0].c;
    const live = (await F.q(`SELECT count(*)::int c FROM shared_expenses.members WHERE context_id=$1 AND state<>'declined'`, [g.ctx]))[0].c;
    const r = await outcome(() => S.submit(F, g.owner.p, S.proposal(g.ctx, S.equalSnapshot(1000, g.owner.m, [g.owner.m]))));
    record('Z06.1b', { memberRows: rows, liveMembers: live, expenseOutcome: r });
    assert.equal(r.ok, true, `expense refused: ${r.code}`);
  });
  it('Z06.1c abuse of the above: an owner can brick their own split (and the roster grows) by inviting+removing name-only people; no cap on that churn', async () => {
    const g = await S.buildGroup(F, 3, 'brick'); const ms = [];
    for (let i = 0; i < 260; i++) { const m = uuid(); const t0 = process.hrtime.bigint(); await S.inviteMember(F, g.owner.p, g.ctx, m, 'Churn ' + i); await S.callFn(F, g.owner.p, `shared_expenses.remove_member(${S.lit(F, g.ctx)}::uuid,${S.lit(F, m)}::uuid,${S.op(F)})`); ms.push(Number(process.hrtime.bigint() - t0) / 1e6); }
    const rows = (await F.q('SELECT count(*)::int c FROM shared_expenses.members WHERE context_id=$1', [g.ctx]))[0].c;
    const exp = await outcome(() => S.submit(F, g.owner.p, S.proposal(g.ctx, S.equalSnapshot(1000, g.owner.m, [g.owner.m]))));
    record('Z06.1c', { memberRows: rows, liveMembers: 3, inviteRemoveCycleMs: stats(ms), expenseAfter: exp });
    assert.equal(rows, 263);
  });

  it('Z06.2 expense shape caps: 8/9 payers, 50/51 sharers, title 200/201, total 1e9', async () => {
    const g = await S.buildGroup(F, 60, 'shape');
    const mk = (payers, sharers, total = 100000) => { const pay = g.members.slice(0, payers), sh = g.members.slice(0, sharers); const per = Math.floor(total / payers), rest = total - per * payers, per2 = Math.floor(total / sharers), rest2 = total - per2 * sharers;
      return { currency: 'INR', totalMinor: String(total), memberOrder: [...new Set([...pay, ...sh].map(x => x.m))], contributions: pay.map((x, i) => ({ memberId: x.m, amountMinor: String(per + (i === 0 ? rest : 0)) })), shares: sh.map((x, i) => ({ memberId: x.m, amountMinor: String(per2 + (i === 0 ? rest2 : 0)) })) }; };
    res.payers8 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(8, 8))));
    res.payers9 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(9, 9))));
    res.sharers50 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(1, 50))));
    res.sharers51 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(1, 51))));
    const t = ttl => ({ ...S.proposal(g.ctx, mk(1, 1)), title: ttl });
    res.title200 = await outcome(() => S.submit(F, g.members[0].p, t('x'.repeat(200))));
    res.title201 = await outcome(() => S.submit(F, g.members[0].p, t('x'.repeat(201))));
    res.total1e9 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(1, 1, 1000000000))));
    res.total1e9plus1 = await outcome(() => S.submit(F, g.members[0].p, S.proposal(g.ctx, mk(1, 1, 1000000001))));
    for (const k of ['payers9', 'sharers51', 'title201', 'total1e9plus1']) res[k].userExplainable = Boolean(res[k].appText);
    record('Z06.2', { payers8: res.payers8, payers9: res.payers9, sharers50: res.sharers50, sharers51: res.sharers51, title200: res.title200, title201: res.title201, total1e9: res.total1e9, total1e9plus1: res.total1e9plus1 });
    assert.equal(res.payers8.ok, true); assert.equal(res.payers9.ok, false); assert.equal(res.sharers50.ok, true); assert.equal(res.sharers51.ok, false);
  });

  it('Z06.3 names: group 120/121 chars, direct 40/41 chars (silent truncation?), label 40/41', async () => {
    const [U] = await S.bulkProfiles(F, 1, 'nm');
    res.group120 = await outcome(() => S.createCtx(F, U, uuid(), 'group', 'g'.repeat(120)));
    res.group121 = await outcome(() => S.createCtx(F, U, uuid(), 'group', 'g'.repeat(121)));
    const d40 = 'a'.repeat(40), d41 = 'a'.repeat(40) + 'b', d41c = 'a'.repeat(40) + 'c';
    res.direct40 = await outcome(() => S.createCtx(F, U, uuid(), 'direct', d40));
    res.direct41_sharesPrefixWith40 = await outcome(() => S.createCtx(F, U, uuid(), 'direct', d41));
    const stored = await F.q(`SELECT length(name)::int len FROM shared_expenses.contexts WHERE created_by=$1 AND kind='direct' ORDER BY created_at`, [U]);
    const g = await S.buildGroup(F, 3, 'lab');
    res.label40 = await outcome(() => S.inviteMember(F, g.owner.p, g.ctx, uuid(), 'L'.repeat(40) + '', null));
    res.label41_collidesWith40 = await outcome(() => S.inviteMember(F, g.owner.p, g.ctx, uuid(), 'L'.repeat(40) + 'Z', null));
    record('Z06.3', { group120: res.group120, group121: res.group121, direct40: res.direct40, direct41: res.direct41_sharesPrefixWith40, storedDirectLengths: stored.map(r => r.len), label40: res.label40, label41: res.label41_collidesWith40 });
    assert.equal(res.group121.code, 'invalid_context');
  });
  it('Z06.3b desired: a 41-char friend name is refused or kept in full, not silently cut to 40 (two different long names must not collide)', { todo: 'direct names and member labels are silently truncated to 40 chars: two names differing only after char 40 collide as member_name_taken/friend_name_taken with no hint about length' }, async () => {
    const [U] = await S.bulkProfiles(F, 1, 'nm2');
    await S.createCtx(F, U, uuid(), 'direct', 'a'.repeat(40) + 'b');
    await S.createCtx(F, U, uuid(), 'direct', 'a'.repeat(40) + 'c');   // different person whose name differs after char 40
  });

  it('Z06.4 pending join requests 20/21 and claim rate 10/11 per hour (different groups)', async () => {
    const g = await S.buildGroup(F, 3, 'jr'); const th = crypto.randomBytes(32).toString('hex');
    await S.callFn(F, g.owner.p, `shared_expenses.create_group_link(${S.lit(F, g.ctx)}::uuid,${S.lit(F, th)},${S.op(F)})`);
    const claimants = await S.bulkProfiles(F, 22, 'cl'); const outs = [];
    for (let i = 0; i < 21; i++) outs.push(await outcome(() => S.callFn(F, claimants[i], `shared_expenses.claim_invitation(${S.lit(F, th)},'p','3210',${S.op(F)})`)));
    res.requests = { first20ok: outs.slice(0, 20).every(o => o.ok), request21: outs[20] };
    // 10 claims/hour: one claimant, 11 groups
    const gs = []; for (let i = 0; i < 11; i++) { const owner = await F.profile('ow' + i); const ctx = uuid(); await S.createCtx(F, owner, ctx, 'group', 'Cl ' + i); const t = crypto.randomBytes(32).toString('hex'); await S.callFn(F, owner, `shared_expenses.create_group_link(${S.lit(F, ctx)}::uuid,${S.lit(F, t)},${S.op(F)})`); gs.push(t); }
    const one = claimants[21], co = []; for (const t of gs) co.push(await outcome(() => S.callFn(F, one, `shared_expenses.claim_invitation(${S.lit(F, t)},'p','3210',${S.op(F)})`)));
    res.claims = { first10ok: co.slice(0, 10).every(o => o.ok), claim11: co[10] };
    record('Z06.4', res.requests && { requests: res.requests, claimsPerHour: res.claims });
    assert.equal(outs[20].code, 'join_requests_full'); assert.equal(co[10].code, 'invitation_rate_limited');
  });

  it('Z06.5 50 invitation links per hour per owner (51st) and 25 phone lookups per day (26th)', async () => {
    const o = await F.profile('inviter'); const ctx = uuid(); await S.createCtx(F, o, ctx, 'group', 'Inv cap'); const outs = [];
    for (let i = 0; i < 51; i++) { const m = uuid(); await S.inviteMember(F, o, ctx, m, 'Guest ' + i);
      outs.push(await outcome(() => S.callFn(F, o, `shared_expenses.create_invitation(${S.lit(F, JSON.stringify({ invitationId: uuid(), contextId: ctx, memberId: m, tokenHash: crypto.randomBytes(32).toString('hex') }))}::jsonb,${S.lit(F, crypto.randomBytes(32).toString('hex'))})`))); }
    res.invites = { first50ok: outs.slice(0, 50).every(x => x.ok), invite51: outs[50] };
    const l = await F.profile('looker'); const lo = []; for (let i = 0; i < 26; i++) lo.push(await outcome(() => S.callFn(F, l, `shared_expenses.lookup_phone(${S.lit(F, crypto.randomBytes(32).toString('hex'))})`)));
    res.lookups = { first25ok: lo.slice(0, 25).every(x => x.ok), lookup26: lo[25] };
    record('Z06.5', res.invites && { invites: res.invites, lookups: res.lookups });
    assert.equal(outs[50].code, 'invitation_rate_limited'); assert.equal(lo[25].code, 'lookup_rate_limited');
  });

  it('Z06.7 owner invitation list with 130 invitation rows on one split: pages of 50, every row once?', async () => {
    const o = await F.profile('lister'); const ctx = uuid(); await S.createCtx(F, o, ctx, 'group', 'Many invites'); const m = uuid(); await S.inviteMember(F, o, ctx, m, 'Pending Pia');
    await F.db.query(`INSERT INTO shared_expenses.invitations(invitation_id,context_id,member_id,issuer_profile_id,token_hash,state,created_at,expires_at)
      SELECT gen_random_uuid(),$1::uuid,$2::uuid,$3::uuid,encode(sha256(convert_to(s::text||'inv','UTF8')),'hex'),'rejected',now()-(s||' minutes')::interval,now()+interval '1 day' FROM generate_series(1,130) s`, [ctx, m, o]);
    const seen = []; let after = null, more = true, pages = 0, ms = [];
    while (more && pages < 20) { const t = await timed(() => S.callFn(F, o, `shared_expenses.list_invitations(${S.lit(F, ctx)}::uuid,${after ? S.lit(F, after) + '::uuid' : 'NULL'})`)); ms.push(t.ms); seen.push(...t.value.items.map(i => i.invitationId)); after = t.value.nextCursor; more = t.value.hasMore; pages++; }
    globalThis.__inv = { seen, total: 130 };
    record('Z06.7', { invitationRows: 130, pages, itemsReturned: seen.length, distinct: new Set(seen).size, missing: 130 - new Set(seen).size, duplicates: seen.length - new Set(seen).size, pageMs: stats(ms) });
  });
  it('Z06.7b desired: the owner invitation list returns every invitation exactly once across pages', { todo: 'NEW: list_invitations orders by created_at DESC but pages with invitation_id > cursor (random uuid order): rows are skipped and repeated once a split has more than 50 invitation rows' }, () => {
    const { seen, total } = globalThis.__inv; assert.equal(new Set(seen).size, total); assert.equal(seen.length, total);
  });
  it('Z06.6 pagination caps at the API edge: limit 100 max (101 refused), cursor over 1024 chars refused', async () => {
    const Q = S.requireApi('./src/shared_expenses/queries');
    const u = await F.profile('pg'); const bad = [];
    for (const q of [{ limit: '101' }, { limit: '0' }, { limit: '-1' }, { limit: 'abc' }, { after: 'x'.repeat(1025) }, { after: '!!' }]) bad.push(await outcome(() => S.asActorTimed(F, u, c => Q.listContexts(c, u, q)).then(() => { throw new Error('accepted'); }).catch(e => { throw new Error(e.code || e.message); })));
    record('Z06.6', { rejected: bad.map(b => b.code) });
    assert.ok(bad.every(b => b.ok === false && b.code !== 'accepted'));
  });
});
