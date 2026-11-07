'use strict';
// Worst-case replay / idempotency / flag behaviour of the split API layer (no database).
// Companion of db/tests/shared_expenses_worst_concurrency_postgres.test.js (real concurrent sessions).
// Tests marked { todo } assert the CORRECT behaviour and currently fail (a recorded defect).
process.env.API_DATABASE_URL ||= 'postgres://unused:unused@localhost:5432/pandapay';
process.env.JWT_ACCESS_SECRET ||= 'ci_only_not_a_real_secret';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const express = require('express');
const { registerSharedExpenseRoutes, sendError } = require('../src/shared_expenses/routes');
const { validateCommand } = require('../src/shared_expenses/commands');

const actor = '11111111-1111-4111-8111-111111111111', ctx = '22222222-2222-4222-8222-222222222222', op = '33333333-3333-4333-8333-333333333333', inv = '44444444-4444-4444-8444-444444444444';
const secret = 'synthetic-secret-for-tests-only-32-bytes';
const verified = { verifiedContacts: { phone: { verified: true, value: '+919876543210' } } };
const status = (error) => { let s = 0; const res = { status(x) { s = x; return res; }, json() { return res; } }; sendError(res, error); return s; };

async function fixture(t, { phoneOn = false, query }) {
  const app = express(); app.use(express.json({ limit: '100kb' }));
  const calls = [];
  const flag = { on: phoneOn };
  registerSharedExpenseRoutes(app, {
    requireAuth: (req, res, next) => { req.userId = actor; req.verifiedSession = verified; next(); },
    withUserClient: async (id, fn) => fn({ query: async (sql, params) => { calls.push({ sql, params }); return query(sql, params); } }),
    invitationSecret: secret, phone: { enabled: () => flag.on, ring: () => null },
  });
  const server = await new Promise((r) => { const s = app.listen(0, '127.0.0.1', () => r(s)); });
  t.after(() => new Promise((r) => server.close(r)));
  const post = (p, body) => fetch(`http://127.0.0.1:${server.address().port}${p}`, { method: 'POST', headers: { 'content-type': 'application/json', authorization: 'Bearer x' }, body: typeof body === 'string' ? body : JSON.stringify(body) });
  return { calls, flag, post };
}

test('every error the shared-expense SQL raises maps to a non-500 HTTP status', () => {
  const dir = path.resolve(__dirname, '../../db/supabase/migrations');
  const codes = new Map();
  for (const f of fs.readdirSync(dir).filter((n) => n.includes('shared_expense'))) {
    for (const m of fs.readFileSync(path.join(dir, f), 'utf8').matchAll(/RAISE EXCEPTION '([a-z_0-9]+)'(?: USING ERRCODE='([0-9A-Z]+)')?/g)) codes.set(m[1], m[2]);
  }
  assert.ok(codes.size > 55, 'scanned the migrations');
  const leaked = [...codes.keys()].filter((c) => c !== 'unsafe_shared_expenses_owner' && status(Object.assign(new Error(c), { code: codes.get(c) })) === 500);
  assert.deepEqual(leaked, [], 'raised but unmapped => the client sees a bare 500');
});

test('lock and serialization failures are surfaced as retryable, constraint races as a clean conflict', () => {
  assert.equal(status(Object.assign(new Error('deadlock detected'), { code: '40P01' })), 409);
  assert.equal(status(Object.assign(new Error('could not serialize'), { code: '40001' })), 409);
  assert.equal(status(Object.assign(new Error('duplicate key'), { code: '23505' })), 409);
  assert.equal(status(Object.assign(new Error('operation_conflict'), { code: '23505' })), 409);
  assert.equal(status(Object.assign(new Error('friend_name_taken'), { code: '23505', detail: ctx })), 409);
  // documented current behaviour: a statement timeout while waiting on a lock is an opaque 500
  assert.equal(status(Object.assign(new Error('canceling statement due to statement timeout'), { code: '57014' })), 500);
});

test('the request hash of a command is independent of JSON key order and unique per body, so a retry replays and a changed body conflicts', () => {
  const a = { schemaVersion: 1, operationId: op, kind: 'member.rename', payload: { contextId: ctx, memberId: inv, displayName: 'Asha' } };
  const reordered = { payload: { displayName: 'Asha', memberId: inv, contextId: ctx }, kind: 'member.rename', operationId: op, schemaVersion: 1 };
  const hashes = new Set([validateCommand(a).requestHash, validateCommand(reordered).requestHash]);
  assert.equal(hashes.size, 1);
  const changed = { ...a, payload: { ...a.payload, displayName: 'Asha2' } };
  assert.notEqual(validateCommand(changed).requestHash, validateCommand(a).requestHash);
  assert.notEqual(validateCommand({ ...a, kind: 'member.invite' }).requestHash, validateCommand(a).requestHash);
  for (let i = 0; i < 200; i++) assert.equal(validateCommand(JSON.parse(JSON.stringify(a))).requestHash, validateCommand(a).requestHash);
});

test('20 parallel identical command POSTs bind identical operation id and hash (the database dedupes on exactly this pair)', async (t) => {
  const f = await fixture(t, { query: async () => ({ rows: [{ result: { status: 'created', contextId: ctx } }] }) });
  const cmd = { schemaVersion: 1, operationId: op, kind: 'context.create', payload: { contextId: ctx, contextKind: 'group', name: 'Flat' } };
  const rs = await Promise.all(Array.from({ length: 20 }, () => f.post('/shared-expenses/commands', cmd)));
  assert.equal(rs.every((r) => r.status === 200), true);
  assert.equal(new Set(f.calls.map((c) => JSON.stringify(c.params))).size, 1);
  assert.equal(f.calls.length, 20);
});

test('phone-sharing flag off: reveal and check-phone are 404 and never reach the database', async (t) => {
  const f = await fixture(t, { phoneOn: false, query: async () => { throw new Error('must not query'); } });
  assert.equal((await f.post('/shared-expenses/invitations/reveal-phone', { invitationId: inv, operationId: op })).status, 404);
  assert.equal((await f.post('/shared-expenses/invitations/check-phone', { invitationId: inv, phoneNumber: '9876543210' })).status, 404);
  assert.deepEqual(f.calls, []);
});

test('flag off: a claim stores no consent and returns no invitation id (nothing to attach a number to)', async (t) => {
  const f = await fixture(t, { phoneOn: false, query: async () => ({ rows: [{ result: { contextId: ctx, memberId: inv, invitationId: inv, status: 'awaiting_owner', fresh: true } }] }) });
  const r = await f.post('/shared-expenses/invitations/claim', { token: 'A'.repeat(43), operationId: op, sharePhone: true });
  assert.equal(r.status, 200);
  const body = await r.json();
  assert.equal(Object.hasOwn(body, 'invitationId'), false);
  const claims = f.calls.filter((c) => c.sql.includes('claim_invitation('));
  assert.equal(claims[0].params[5], null, 'share is null while the feature is off');
  assert.equal(f.calls.filter((c) => c.sql.includes('attach_claimant_phone')).length, 0, 'no attach_claimant_phone call');
});

test('every parameter bound by an invitation route is referenced by its SQL (PostgreSQL rejects unreferenced $n with 42P18)', async (t) => {
  const f = await fixture(t, { phoneOn: false, query: async () => ({ rows: [{ result: { status: 'ok' } }] }) });
  for (const p of ['accept', 'decline']) await f.post('/shared-expenses/invitations/' + p, { invitationId: inv, operationId: op });
  assert.equal(f.calls.length, 2);
  for (const c of f.calls) {
    const referenced = new Set([...c.sql.matchAll(/\$(\d+)/g)].map((m) => Number(m[1])));
    for (let i = 1; i <= c.params.length; i++) assert.ok(referenced.has(i), `$${i} is bound but never referenced in: ${c.sql}`);
  }
});

test('a legitimate retry whose JSON keys arrive in another order must still hit the stored result', { todo: 'BUG B13 (S4): /invitations/respond hashes JSON.stringify(body) in arrival order, unlike /commands which canonicalises; the same logical retry with reordered keys becomes operation_conflict' }, async (t) => {
  const f = await fixture(t, { query: async () => ({ rows: [{ result: { status: 'joined' } }] }) });
  await f.post('/shared-expenses/invitations/respond', `{"invitationId":"${inv}","operationId":"${op}","approve":true}`);
  await f.post('/shared-expenses/invitations/respond', `{"approve":true,"operationId":"${op}","invitationId":"${inv}"}`);
  assert.equal(f.calls.length, 2);
  assert.equal(f.calls[0].params[3], f.calls[1].params[3]);
});

test('a lost-reply retry after the phone-sharing flag was flipped must not turn into operation_conflict', { todo: 'BUG B14 (S3): /invitations/claim derives the request hash from the current flag (sharePhone is nulled when the flag is off), so a retry after a config flip carries a different hash for the same operation id' }, async (t) => {
  const f = await fixture(t, { phoneOn: true, query: async () => ({ rows: [{ result: { contextId: ctx, memberId: inv, invitationId: inv, status: 'awaiting_owner' } }] }) });
  const body = { token: 'A'.repeat(43), operationId: op, sharePhone: true };
  await f.post('/shared-expenses/invitations/claim', body);
  f.flag.on = false;
  await f.post('/shared-expenses/invitations/claim', body);
  const claims = f.calls.filter((c) => c.sql.includes('claim_invitation('));
  assert.equal(claims.length, 2);
  assert.equal(claims[0].params[4], claims[1].params[4]);
});
