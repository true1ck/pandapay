'use strict';
// Shared helpers for the shared_expenses_worst_scale_*.test.js suites (no tests of its own).
// Needs a throwaway loopback postgres: PANDAPAY_WORST_SCALE_PG_URL=postgres://postgres:<pw>@127.0.0.1:<port>/postgres
// Without it every scale suite is skipped, so the normal suite stays green.
// It reuses the worst-money fixture (real migrations, app_user under RLS, real functions).
//
// Timings are wall-clock from the node client on loopback to a docker postgres started with
// fsync=off / synchronous_commit=off / full_page_writes=off: commit costs are OPTIMISTIC, CPU and
// plan costs are real. Results are appended as JSON lines to PANDAPAY_WORST_SCALE_OUT (default: none).
const fs = require('node:fs');
const crypto = require('node:crypto');
if (process.env.PANDAPAY_WORST_SCALE_PG_URL) process.env.PANDAPAY_WORST_MONEY_PG_URL = process.env.PANDAPAY_WORST_SCALE_PG_URL;
const money = require('./shared_expenses_worst_money_common.test.js');
const requireApi = require('node:module').createRequire(require('node:path').resolve(__dirname, '../../api/package.json'));

const SKIP = money.SKIP && 'PANDAPAY_WORST_SCALE_PG_URL not supplied (loopback throwaway postgres required)';
const { createFixture, uuid, hex } = money;
const OUT = process.env.PANDAPAY_WORST_SCALE_OUT;

const pct = (arr, p) => { const s = [...arr].sort((a, b) => a - b); return s.length ? s[Math.min(s.length - 1, Math.ceil(p / 100 * s.length) - 1)] : 0; };
const round = n => Math.round(n * 100) / 100;
function stats(ms) { return { n: ms.length, p50: round(pct(ms, 50)), p95: round(pct(ms, 95)), max: round(Math.max(...ms)), mean: round(ms.reduce((a, b) => a + b, 0) / ms.length) }; }
function record(id, data) {
  const line = JSON.stringify({ id, ...data });
  console.log('SCALE ' + line);
  if (OUT) fs.appendFileSync(OUT, line + '\n');
}
async function timed(fn) { const t = process.hrtime.bigint(); const value = await fn(); return { ms: Number(process.hrtime.bigint() - t) / 1e6, value }; }
async function repeat(n, fn) { const ms = []; let last; for (let i = 0; i < n; i++) { const r = await timed(() => fn(i)); ms.push(r.ms); last = r.value; } return { ...stats(ms), last }; }

// One round trip, one transaction, as `profile` under RLS (app_user). Literals are escaped by pg.
function lit(F, v) { return F.db.escapeLiteral(String(v)); }
async function fast(F, profile, callSql, client = F.db) {
  try {
    const r = await client.query(`BEGIN; SET LOCAL ROLE app_user; SELECT set_config('app.user_id',${client.escapeLiteral(profile)},true); ${callSql}; COMMIT;`);
    return r[3].rows[0]?.v;
  } catch (e) { await client.query('ROLLBACK').catch(() => {}); F.tally(e); throw e; }
}
const op = F => `${lit(F, uuid())}::uuid,${lit(F, hex())}`;
const createCtx = (F, p, ctx, kind, name) => fast(F, p, `SELECT shared_expenses.create_context(${lit(F, ctx)}::uuid,${lit(F, kind)},${lit(F, name)},${op(F)}) AS v`);
const inviteMember = (F, p, ctx, member, name, profile) => fast(F, p, `SELECT shared_expenses.invite_member(${lit(F, JSON.stringify({ contextId: ctx, memberId: member, displayName: name, ...(profile ? { profileId: profile } : {}) }))}::jsonb,${op(F)}) AS v`);
const respondMembership = (F, p, ctx, member, accept = true) => fast(F, p, `SELECT shared_expenses.respond_membership(${lit(F, ctx)}::uuid,${lit(F, member)}::uuid,${accept},${op(F)}) AS v`);
const submit = (F, p, payload) => fast(F, p, `SELECT shared_expenses.submit_proposal(${lit(F, JSON.stringify(payload))}::jsonb,${op(F)}) AS v`);
const respondExpense = (F, p, ctx, expenseId, revisionId, decision = 'approve') => fast(F, p, `SELECT shared_expenses.respond_expense(${lit(F, JSON.stringify({ contextId: ctx, expenseId, revisionId, decision }))}::jsonb,${op(F)}) AS v`);
const leaveCtx = (F, p, ctx) => fast(F, p, `SELECT shared_expenses.leave_context(${lit(F, ctx)}::uuid,${op(F)}) AS v`);
const callFn = (F, p, call) => fast(F, p, `SELECT ${call} AS v`);

function equalSnapshot(total, paidMember, memberIds) {
  const share = Math.floor(total / memberIds.length); let rest = total - share * memberIds.length;
  const shares = memberIds.map(m => { const a = share + (rest > 0 ? 1 : 0); if (rest > 0) rest--; return { memberId: m, amountMinor: String(a) }; });
  return { currency: 'INR', totalMinor: String(total), memberOrder: memberIds, contributions: [{ memberId: paidMember, amountMinor: String(total) }], shares };
}
function proposal(ctx, snapshot, o = {}) {
  return { contextId: ctx, expenseId: o.expenseId || uuid(), revisionId: o.revisionId || uuid(), expectedHeadRevisionId: o.head || null, title: o.title || 'dinner', occurredOn: '2026-11-05', sources: [], void: false, snapshot };
}
// Run fn(client) as `profile` and time only the query work (not BEGIN/SET ROLE/COMMIT).
async function asActorTimed(F, profile, fn, client = F.db) {
  await client.query('BEGIN'); await client.query('SET LOCAL ROLE app_user'); await client.query('SELECT set_config($1,$2,true)', ['app.user_id', profile]);
  try { const t = process.hrtime.bigint(); const value = await fn(client); const ms = Number(process.hrtime.bigint() - t) / 1e6; await client.query('COMMIT'); return { ms, value }; }
  catch (e) { await client.query('ROLLBACK').catch(() => {}); throw e; }
}
async function bulkProfiles(F, n, prefix) {
  const ids = Array.from({ length: n }, () => uuid());
  await F.db.query('INSERT INTO public.profiles(id,display_name) SELECT id,$2||(row_number() OVER ())::text FROM unnest($1::uuid[]) id', [ids, prefix]);
  return ids;
}
async function explain(F, profile, sql, params, analyze = true) {
  await F.db.query('BEGIN'); await F.db.query('SET LOCAL ROLE app_user'); await F.db.query('SELECT set_config($1,$2,true)', ['app.user_id', profile]);
  try { const r = await F.db.query(`EXPLAIN (${analyze ? 'ANALYZE, BUFFERS, ' : ''}COSTS, TIMING OFF, SUMMARY) ${sql}`, params); return r.rows.map(x => x['QUERY PLAN']).join('\n'); }
  finally { await F.db.query('ROLLBACK').catch(() => {}); }
}
async function buildGroup(F, n, tag) {
  const profiles = await bulkProfiles(F, n, 'g' + tag + '_');
  const ctx = uuid(); const o = await createCtx(F, profiles[0], ctx, 'group', 'Group ' + tag);
  const members = [{ p: profiles[0], m: o.memberId }];
  for (let i = 1; i < n; i++) { const m = uuid(); await inviteMember(F, profiles[0], ctx, m, `Name ${i}`, profiles[i]); await respondMembership(F, profiles[i], ctx, m, true); members.push({ p: profiles[i], m }); }
  return { ctx, members, owner: members[0] };
}
module.exports = { buildGroup, SKIP, createFixture, uuid, hex, stats, record, timed, repeat, pct, lit, fast, op, createCtx, inviteMember, respondMembership, submit, respondExpense, leaveCtx, callFn, equalSnapshot, proposal, asActorTimed, bulkProfiles, explain, requireApi };
