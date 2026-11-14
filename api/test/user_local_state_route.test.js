'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const { createUserLocalStateHandlers } = require('../src/user_local_state_route');
const { loadImapKeyring } = require('../src/imap_credentials');

const U = '11111111-1111-4111-8111-111111111111';
const CARD = '22222222-2222-4222-8222-222222222222';
const b64 = (n) => Buffer.alloc(32, n).toString('base64');
const RING = loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64(7), IMAP_ENCRYPTION_KEY_ID: 'k1' });
const T = (m) => `2026-11-01T10:${String(m).padStart(2, '0')}:00.000Z`;

// Stateful fake of user_local_state keyed on the SQL the handlers emit.
function fixture(keyring = RING) {
  const rows = new Map(); let seq = 0; const calls = [];
  const client = { query: async (rawSql, p) => {
    const sql = rawSql.replace(/\s+/g, ' ').trim();
    calls.push({ sql, p });
    if (/^INSERT INTO user_local_state/.test(sql)) {
      const [pid, kind, key, payload, enc, at, deleted] = p;
      const id = `${pid}|${kind}|${key}`; const cur = rows.get(id);
      if (cur && !(cur.client_edited_at <= Date.parse(at))) return { rows: [] };
      const r = { kind, state_key: key, payload: payload ? JSON.parse(payload) : null, payload_enc: enc,
        client_edited_at: new Date(at), deleted, updated_at: new Date(), server_seq: String(++seq) };
      r.client_edited_at = r.client_edited_at; rows.set(id, { ...r, client_edited_at: Date.parse(at), _d: new Date(at) });
      return { rows: [{ ...r, client_edited_at: new Date(at) }] };
    }
    if (/^SELECT .* WHERE profile_id = \$1 AND kind = \$2 AND state_key = \$3/.test(sql)) {
      const r = rows.get(`${p[0]}|${p[1]}|${p[2]}`);
      return { rows: r ? [{ ...r, client_edited_at: r._d }] : [] };
    }
    if (/ORDER BY server_seq/.test(sql)) {
      let list = [...rows.values()];
      let i = 1;
      if (/kind = \$2/.test(sql)) { list = list.filter((r) => r.kind === p[1]); i = 2; }
      if (/server_seq > \$/.test(sql)) list = list.filter((r) => Number(r.server_seq) > Number(p[i]));
      list.sort((a, b) => a.server_seq - b.server_seq);
      return { rows: list.slice(0, 501).map((r) => ({ ...r, client_edited_at: r._d })) };
    }
    throw new Error(`unexpected sql ${sql}`);
  } };
  const h = createUserLocalStateHandlers({ withUserClient: async (_u, fn) => fn(client), keyring });
  return { rows, calls, ...h };
}
const res = () => ({ code: 200, status(c) { this.code = c; return this; }, json(b) { this.body = b; return this; } });
const put = async (f, kind, key, body) => { const r = res(); await f.put({ userId: U, params: { kind, key }, body }, r); return r; };
const del = async (f, kind, key, at) => { const r = res(); await f.del({ userId: U, params: { kind, key }, get: () => at }, r); return r; };
const list = async (f, query = {}) => { const r = res(); await f.list({ userId: U, query }, r); return r; };
const SUB = { hidden: true, displayName: 'Streaming' };

test('LWW: older write is superseded and does not write; newer wins', async () => {
  const f = fixture();
  assert.equal((await put(f, 'subscription_override', 's1', { payload: SUB, clientEditedAt: T(5) })).code, 200);
  const old = await put(f, 'subscription_override', 's1', { payload: { hidden: false }, clientEditedAt: T(1) });
  assert.equal(old.code, 200); assert.equal(old.body.superseded, true);
  assert.deepEqual(old.body.item.payload, SUB);
  const newer = await put(f, 'subscription_override', 's1', { payload: { hidden: false }, clientEditedAt: T(9) });
  assert.equal(newer.body.superseded, undefined); assert.deepEqual(newer.body.item.payload, { hidden: false });
});

test('idempotent replay: same body twice leaves one equal row', async () => {
  const f = fixture();
  const body = { payload: { userCardId: CARD, billKey: 'electricity' }, clientEditedAt: T(2) };
  const a = await put(f, 'bill_card_assignment', 'electricity', body);
  const b = await put(f, 'bill_card_assignment', 'electricity', body);
  assert.equal(b.code, 200); assert.equal(f.rows.size, 1);
  assert.deepEqual(a.body.item.payload, b.body.item.payload);
});

test('tombstone: delete is LWW, idempotent, missing key is 200, returned by GET', async () => {
  const f = fixture();
  assert.equal((await del(f, 'subscription_override', 'ghost', T(1))).code, 200);
  await put(f, 'subscription_override', 's1', { payload: SUB, clientEditedAt: T(3) });
  const stale = await del(f, 'subscription_override', 's1', T(1));
  assert.equal(stale.body.superseded, true);
  const ok = await del(f, 'subscription_override', 's1', T(4));
  assert.equal(ok.body.item.deleted, true); assert.equal(ok.body.item.payload, null);
  assert.equal((await del(f, 'subscription_override', 's1', T(4))).code, 200);
  const resurrect = await put(f, 'subscription_override', 's1', { payload: SUB, clientEditedAt: T(2) });
  assert.equal(resurrect.body.superseded, true);
  const l = await list(f);
  assert.ok(l.body.items.find((i) => i.key === 's1' && i.deleted));
});

test('validation errors', async () => {
  const f = fixture();
  assert.equal((await put(f, 'nope', 'k', { payload: {}, clientEditedAt: T(1) })).body.error, 'invalid_kind');
  assert.equal((await put(f, 'subscription_override', 'x'.repeat(201), { payload: {}, clientEditedAt: T(1) })).body.error, 'invalid_key');
  assert.equal((await put(f, 'subscription_override', 'k', { payload: {} })).code, 400);
  assert.equal((await put(f, 'subscription_override', 'k', { payload: [], clientEditedAt: T(1) })).code, 422);
  assert.equal((await put(f, 'subscription_override', 'k', { payload: { hidden: 'yes' }, clientEditedAt: T(1) })).code, 422);
  assert.equal((await put(f, 'subscription_override', 'k', { payload: { displayName: 'y'.repeat(5000) }, clientEditedAt: T(1) })).body.error, 'payload_too_large');
  assert.equal((await put(f, 'bill_card_assignment', 'k', { payload: { userCardId: 'not-uuid', billKey: 'b' }, clientEditedAt: T(1) })).code, 422);
  assert.equal((await put(f, 'bank_balance', 'k', { payload: { amount: '5', accountLabel: 'A' }, clientEditedAt: T(1) })).code, 422);
  assert.equal((await put(f, 'bank_balance', 'k', { payload: { amount: 5 }, clientEditedAt: T(1) })).code, 422);
  assert.equal((await del(f, 'nope', 'k', T(1))).body.error, 'invalid_kind');
  assert.equal((await del(f, 'subscription_override', 'k', 'garbage')).code, 400);
  assert.equal((await list(f, { kind: 'zzz' })).body.error, 'invalid_kind');
  assert.equal((await list(f, { since: 'zzz' })).body.error, 'invalid_since');
  assert.equal(f.rows.size, 0);
});

test('future clientEditedAt is clamped to server time', async () => {
  const f = fixture();
  const r = await put(f, 'subscription_override', 's', { payload: SUB, clientEditedAt: '2099-01-01T00:00:00Z' });
  assert.ok(Date.parse(r.body.item.clientEditedAt) < Date.now() + 1000);
});

test('bank_balance: ciphertext only, SQL params never hold the plaintext, GET decrypts', async () => {
  const f = fixture();
  const r = await put(f, 'bank_balance', 'hdfc', { payload: { amount: 123456.78, accountLabel: 'HDFC Savings' }, clientEditedAt: T(1) });
  assert.equal(r.code, 200); assert.deepEqual(r.body.item.payload, { amount: 123456.78, accountLabel: 'HDFC Savings' });
  const all = JSON.stringify(f.calls.map((c) => c.p));
  assert.ok(!all.includes('123456'), 'plaintext amount reached SQL');
  assert.ok(!all.includes('HDFC Savings'));
  const stored = [...f.rows.values()][0];
  assert.equal(stored.payload, null); assert.match(stored.payload_enc, /^v1:k1:/);
  const l = await list(f, { kind: 'bank_balance' });
  assert.equal(l.body.items[0].payload.amount, 123456.78);
});

test('bank_balance: AAD binds profile/kind/key; rotation reads old key', async () => {
  const f = fixture();
  await put(f, 'bank_balance', 'a', { payload: { amount: 1, accountLabel: 'A' }, clientEditedAt: T(1) });
  const row = [...f.rows.values()][0];
  // Same ciphertext copied under another key name must not decrypt.
  f.rows.set('x', { ...row, state_key: 'b', _d: row._d });
  const l = await list(f);
  assert.equal(l.body.items.find((i) => i.key === 'b').undecryptable, true);
  assert.deepEqual(l.body.items.find((i) => i.key === 'a').payload, { amount: 1, accountLabel: 'A' });
  // Rotate: new current key, old one kept in the previous ring.
  const rotated = loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64(9), IMAP_ENCRYPTION_KEY_ID: 'k2',
    IMAP_ENCRYPTION_PREVIOUS_KEYS: JSON.stringify({ k1: b64(7) }) });
  const g = createUserLocalStateHandlers({ withUserClient: async (_u, fn) => fn({ query: async () => ({ rows: [row].map((r) => ({ ...r, client_edited_at: r._d })) }) }), keyring: rotated });
  const rr = res(); await g.list({ userId: U, query: {} }, rr);
  assert.equal(rr.body.items[0].payload.amount, 1);
  // Ring without the old key cannot read it, and does not throw.
  const gone = createUserLocalStateHandlers({ withUserClient: async (_u, fn) => fn({ query: async () => ({ rows: [{ ...row, client_edited_at: row._d }] }) }), keyring: loadImapKeyring({ IMAP_ENCRYPTION_KEY: b64(9), IMAP_ENCRYPTION_KEY_ID: 'k2' }) });
  const r3 = res(); await gone.list({ userId: U, query: {} }, r3);
  assert.equal(r3.body.items[0].undecryptable, true);
});

test('bank_balance without a key ring: 503 and nothing stored; other kinds and delete still work', async () => {
  const f = fixture(null);
  const r = await put(f, 'bank_balance', 'hdfc', { payload: { amount: 5, accountLabel: 'A' }, clientEditedAt: T(1) });
  assert.equal(r.code, 503); assert.equal(r.body.error, 'encryption_unavailable');
  assert.equal(f.calls.length, 0);
  assert.equal((await put(f, 'subscription_override', 's', { payload: SUB, clientEditedAt: T(1) })).code, 200);
  assert.equal((await del(f, 'bank_balance', 'hdfc', T(2))).code, 200);
});

test('pagination: 500 per page, cursor continues, kind filter', async () => {
  const f = fixture();
  for (let i = 0; i < 503; i++) {
    await put(f, 'subscription_override', `s${i}`, { payload: { hidden: true }, clientEditedAt: T(1) });
  }
  const p1 = await list(f);
  assert.equal(p1.body.items.length, 500); assert.equal(p1.body.hasMore, true);
  const p2 = await list(f, { since: p1.body.cursor });
  assert.equal(p2.body.items.length, 3); assert.equal(p2.body.hasMore, false);
  const p3 = await list(f, { since: p2.body.cursor });
  assert.equal(p3.body.items.length, 0); assert.equal(p3.body.cursor, p2.body.cursor);
  assert.equal((await list(f, { kind: 'bank_balance' })).body.items.length, 0);
});

test('db errors map to stable answers, no payload leak', async () => {
  const h = createUserLocalStateHandlers({ withUserClient: async () => { throw Object.assign(new Error('secret 999'), { code: '23503' }); }, keyring: RING });
  const r = res(); await h.put({ userId: U, params: { kind: 'subscription_override', key: 'k' }, body: { payload: SUB, clientEditedAt: T(1) } }, r);
  assert.equal(r.code, 409); assert.ok(!JSON.stringify(r.body).includes('999'));
  assert.ok(crypto);
});
