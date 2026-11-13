'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { createConsentPostHandler } = require('../src/consents_route');
const { createSmsImportBatchPostHandler } = require('../src/sms_import_batches_route');
const { createSupportTicketHandler, createSupportTicketRateLimiter, INSERT_SUPPORT_TICKET_SQL } = require('../src/support_tickets');

const MID = '66666666-6666-4666-8666-666666666666';
const res = () => ({ code: 200, headers: {}, status(c) { this.code = c; return this; }, set(k, v) { this.headers[k] = v; return this; }, json(b) { this.body = b; return this; } });

// ---- consents ---------------------------------------------------------------
function consentFixture() {
  const rows = []; const sqls = [];
  const client = { query: async (sql, p) => {
    sqls.push(sql);
    if (/pg_advisory_xact_lock/.test(sql)) return { rows: [] };
    if (/^\s*INSERT INTO user_consents/.test(sql)) {
      const mid = p[5] ?? null;
      if (mid && rows.some((r) => r.mid === mid)) return { rows: [] }; // ON CONFLICT DO NOTHING
      const r = { mid, purpose: p[1], policy_version: p[2], granted: p[3], source_screen: p[4], granted_at: `t${rows.length}` };
      rows.push(r); return { rows: [r] };
    }
    if (/FROM user_consents WHERE profile_id/.test(sql)) return { rows: rows.filter((r) => r.mid === p[1]) };
    throw new Error(sql);
  } };
  const handler = createConsentPostHandler({ withUserClient: async (_u, fn) => fn(client), CONSENT_PURPOSES: ['terms', 'sms_shared_learning'] });
  return { rows, sqls, call: async (body) => { const r = res(); await handler({ userId: 'u', body }, r); return r; } };
}
const CONSENT = { purpose: 'terms', granted: true, policyVersion: 'v1', sourceScreen: 'x' };

test('consents: without clientMutationId the SQL has no ON CONFLICT and every call inserts', async () => {
  const f = consentFixture();
  assert.equal((await f.call(CONSENT)).code, 201); assert.equal((await f.call(CONSENT)).code, 201);
  assert.equal(f.rows.length, 2); assert.ok(f.sqls.every((s) => !/ON CONFLICT/.test(s)));
});
test('consents: replayed clientMutationId returns the stored row (200 replayed) and keeps granted_at', async () => {
  const f = consentFixture();
  const a = await f.call({ ...CONSENT, clientMutationId: MID, clientRecordedAt: '2026-11-01T00:00:00Z' });
  assert.equal(a.code, 201);
  const b = await f.call({ ...CONSENT, clientMutationId: MID });
  assert.equal(b.code, 200); assert.equal(b.body.replayed, true);
  assert.equal(b.body.consent.granted_at, a.body.consent.granted_at); assert.equal(f.rows.length, 1);
});
test('consents: sms_shared_learning keeps its advisory lock on the mutation-id path; bad id is 400', async () => {
  const f = consentFixture();
  await f.call({ ...CONSENT, purpose: 'sms_shared_learning', clientMutationId: MID });
  assert.ok(f.sqls.some((s) => /pg_advisory_xact_lock/.test(s)));
  assert.equal((await f.call({ ...CONSENT, clientMutationId: 'nope' })).code, 400);
  assert.equal((await f.call({ ...CONSENT, purpose: 'bogus' })).code, 400);
});

// ---- sms import batches -----------------------------------------------------
function batchFixture() {
  const rows = [];
  const client = { query: async (sql, p) => {
    if (/^\s*INSERT/.test(sql)) {
      const mid = p[4] ?? null;
      if (mid && rows.some((r) => r.mid === mid)) return { rows: [] };
      const r = { mid, id: `b${rows.length}`, message_count: p[1] }; rows.push(r); return { rows: [r] };
    }
    return { rows: rows.filter((r) => r.mid === p[1]) };
  } };
  const h = createSmsImportBatchPostHandler({ withUserClient: async (_u, fn) => fn(client) });
  return { rows, call: async (body) => { const r = res(); await h({ userId: 'u', body }, r); return r; } };
}
test('sms-import-batches: plain call 201 each time; mutation id replays with 200 and no duplicate', async () => {
  const f = batchFixture();
  assert.equal((await f.call({ messageCount: 3 })).code, 201); assert.equal((await f.call({ messageCount: 3 })).code, 201);
  assert.equal(f.rows.length, 2);
  assert.equal((await f.call({ messageCount: 3, clientMutationId: MID })).code, 201);
  const r = await f.call({ messageCount: 3, clientMutationId: MID });
  assert.equal(r.code, 200); assert.equal(r.body.replayed, true); assert.equal(f.rows.length, 3);
  assert.equal((await f.call({ clientMutationId: 'x' })).code, 400);
});

// ---- support tickets --------------------------------------------------------
function ticketFixture({ limit = 5 } = {}) {
  const ids = new Set(); let consumed = 0;
  const limiter = { consume: async () => { consumed += 1; return consumed > limit ? { allowed: false, retryAfterSeconds: 60 } : { allowed: true }; } };
  const client = { query: async (sql, p) => {
    if (/gen_random_uuid/.test(sql)) return { rows: [{ id: 'gen-id', created_at: 'now' }] };
    if (/^SELECT id, kind, state/.test(sql)) return { rows: ids.has(p[0]) ? [{ id: p[0], kind: 'general', state: 'pending', created_at: 'stored' }] : [] };
    if (sql.startsWith(INSERT_SUPPORT_TICKET_SQL)) {
      if (/ON CONFLICT \(id\) DO NOTHING/.test(sql) && ids.has(p[0])) return { rows: [], rowCount: 0 };
      ids.add(p[0]); return { rows: [], rowCount: 1 };
    }
    throw new Error(sql);
  } };
  // Transaction rollback emulation: a throw drops ids added during the call.
  const withUserClient = async (_u, fn) => { const snap = new Set(ids); try { return await fn(client); } catch (e) { ids.clear(); snap.forEach((x) => ids.add(x)); throw e; } };
  const h = createSupportTicketHandler({ withUserClient, limiter });
  return { ids, consumed: () => consumed, call: async (req) => { const r = res(); await h({ headers: {}, ...req }, r); return r; } };
}
const TBODY = { kind: 'general', message: 'help' };

test('support tickets: without id behaviour is unchanged (limiter charged, server id)', async () => {
  const f = ticketFixture();
  const r = await f.call({ userId: 'u', body: TBODY });
  assert.equal(r.code, 201); assert.equal(r.body.ticket.id, 'gen-id'); assert.equal(f.consumed(), 1);
});
test('support tickets: body id is used; a replay returns 201 shape and charges the limiter only once', async () => {
  const f = ticketFixture();
  const a = await f.call({ userId: 'u', body: { ...TBODY, id: MID } });
  assert.equal(a.code, 201); assert.equal(a.body.ticket.id, MID);
  const b = await f.call({ userId: 'u', body: { ...TBODY, id: MID } });
  assert.equal(b.code, 201); assert.equal(b.body.ticket.id, MID); assert.deepEqual(Object.keys(b.body.ticket), ['id', 'kind', 'state', 'created_at']);
  assert.equal(f.consumed(), 1); assert.equal(f.ids.size, 1);
});
test('support tickets: a rate-limited new id is refused (429) and rolled back so a retry can succeed', async () => {
  const f = ticketFixture({ limit: 0 });
  const r = await f.call({ userId: 'u', body: { ...TBODY, id: MID } });
  assert.equal(r.code, 429); assert.equal(r.headers['Retry-After'], '60'); assert.equal(f.ids.size, 0);
});
test('support tickets: invalid id 400; invalid Authorization header 401, not an anonymous ticket', async () => {
  const f = ticketFixture();
  assert.equal((await f.call({ userId: 'u', body: { ...TBODY, id: 'v2:abc' } })).code, 400);
  const r = await f.call({ userId: null, headers: { authorization: 'Bearer expired' }, body: TBODY });
  assert.equal(r.code, 401); assert.equal(f.ids.size, 0); assert.equal(f.consumed(), 0);
  assert.equal((await f.call({ userId: null, ip: '203.0.113.1', body: TBODY })).code, 201);
});
