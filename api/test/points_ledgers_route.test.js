'use strict';
// The app opened with one GET /user-cards/:id/points-ledger per card (about 10 at once on every app open, 3.6-5 s each
// on the 1 GB host, 21 Nov 2026). GET /points-ledgers?userCardIds=a,b,c answers all of them in one request. Each card's
// list is exactly what the per-card route returns; the per-card route stays for older app builds.
//   Real-Postgres check: SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/postgres
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const express = require('express');
const { registerPointsLedgersRoute, MAX_CARDS } = require('../src/points_ledgers_route');

const A = '11111111-1111-4111-8111-111111111111';
const B = '22222222-2222-4222-8222-222222222222';
const C = '33333333-3333-4333-8333-333333333333';

async function call(path, client, userId = 'user-1') {
  const app = express();
  const requireAuth = (req, _res, next) => { req.userId = userId; next(); };
  const withUserClient = async (_userId, operation) => operation(client);
  registerPointsLedgersRoute(app, { requireAuth, withUserClient });
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    return await new Promise((resolve, reject) => {
      http.get(`http://127.0.0.1:${server.address().port}${path}`, (res) => {
        const chunks = []; res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, body: JSON.parse(Buffer.concat(chunks).toString() || 'null') }));
      }).on('error', reject);
    });
  } finally { await new Promise((r) => server.close(r)); }
}

function fakeClient({ owned, rows }) {
  const queries = [];
  return {
    queries,
    async query(text, values) {
      queries.push({ text, values });
      if (/FROM user_cards/.test(text)) return { rows: owned.filter((id) => values[0].includes(id)).map((id) => ({ id })) };
      return { rows: rows.filter((r) => values[0].includes(r.user_card_id)) };
    },
  };
}

test('one request returns each owned card its own list, newest first, in the per-card shape', async () => {
  const rows = [
    { user_card_id: A, id: 'a2', delta_points: 50, reason: 'manual', state: 'confirmed', expires_on: null, occurred_at: '2026-11-20T00:00:00.000Z' },
    { user_card_id: A, id: 'a1', delta_points: 10, reason: 'manual', state: 'confirmed', expires_on: null, occurred_at: '2026-11-01T00:00:00.000Z' },
    { user_card_id: B, id: 'b1', delta_points: -5, reason: 'redeem', state: 'confirmed', expires_on: '2027-01-01', occurred_at: '2026-11-10T00:00:00.000Z' },
  ];
  const client = fakeClient({ owned: [A, B, C], rows });
  const r = await call(`/points-ledgers?userCardIds=${A},${B},${C}`, client);
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body.pointsLedgers).sort(), [A, B, C].sort());
  assert.deepEqual(r.body.pointsLedgers[A].map((e) => e.id), ['a2', 'a1']);
  assert.deepEqual(r.body.pointsLedgers[B], [{ id: 'b1', delta_points: -5, reason: 'redeem', state: 'confirmed', expires_on: '2027-01-01', occurred_at: '2026-11-10T00:00:00.000Z' }]);
  assert.deepEqual(r.body.pointsLedgers[C], [], 'an owned card with no rows gets an empty list');
  assert.equal(client.queries.length, 2, 'one ownership query and one ledger query for all cards');
  assert.match(client.queries[0].text, /profile_id = \$2/);
  assert.equal(client.queries[0].values[1], 'user-1');
  assert.match(client.queries[1].text, /ORDER BY p\.user_card_id, p\.occurred_at DESC/);
});

test('a card that is not the person\'s is left out, as the per-card route answers 404 for it', async () => {
  const r = await call(`/points-ledgers?userCardIds=${A},${B}`, fakeClient({ owned: [A], rows: [] }));
  assert.equal(r.status, 200);
  assert.deepEqual(Object.keys(r.body.pointsLedgers), [A]);
});

test('bad input is refused with 400 before the database is touched', async () => {
  const client = fakeClient({ owned: [A], rows: [] });
  for (const q of ['', '?userCardIds=', '?userCardIds=not-a-uuid', `?userCardIds=${A},x`, `?userCardIds=${Array.from({ length: MAX_CARDS + 1 }, (_, i) => `${String(i).padStart(8, '0')}-1111-4111-8111-111111111111`).join(',')}`]) {
    const r = await call(`/points-ledgers${q}`, client);
    assert.equal(r.status, 400, q.slice(0, 40));
  }
  assert.equal(client.queries.length, 0);
});

test('repeated ids are asked for once', async () => {
  const client = fakeClient({ owned: [A], rows: [] });
  await call(`/points-ledgers?userCardIds=${A},${A}`, client);
  assert.deepEqual(client.queries[0].values[0], [A]);
});

test('a database failure answers 500 like the per-card route', async () => {
  const r = await call(`/points-ledgers?userCardIds=${A}`, { async query() { throw Object.assign(new Error('x'), { code: '57014' }); } });
  assert.equal(r.status, 500);
  assert.deepEqual(r.body, { error: 'internal_error' });
});

const url = process.env.SMS_V2_TEST_DATABASE_URL;
test('on real Postgres each list equals what the per-card query returns', { skip: url ? false : 'SMS_V2_TEST_DATABASE_URL not set' }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`CREATE TEMP TABLE user_cards (id uuid PRIMARY KEY, profile_id text NOT NULL)`);
    await client.query(`CREATE TEMP TABLE points_ledger (id uuid PRIMARY KEY DEFAULT gen_random_uuid(), user_card_id uuid NOT NULL, delta_points integer, reason text, state text, expires_on date, occurred_at timestamptz)`);
    await client.query(`INSERT INTO user_cards VALUES ($1,'user-1'),($2,'user-1'),($3,'someone-else')`, [A, B, C]);
    await client.query(`INSERT INTO points_ledger (user_card_id, delta_points, reason, state, expires_on, occurred_at)
      SELECT (ARRAY[$1,$2,$3]::uuid[])[1 + g % 3], g * 7, 'r' || g, 'confirmed', CASE WHEN g % 4 = 0 THEN date '2027-03-01' END,
             timestamptz '2026-11-01 00:00:00+00' + g * interval '7 hours'
        FROM generate_series(1, 40) g`, [A, B, C]);
    const r = await call(`/points-ledgers?userCardIds=${A},${B},${C}`, client);
    assert.deepEqual(Object.keys(r.body.pointsLedgers).sort(), [A, B].sort(), 'the other person\'s card is left out');
    for (const id of [A, B]) {
      const single = await client.query(`SELECT id, delta_points, reason, state, expires_on, occurred_at FROM points_ledger WHERE user_card_id = $1 ORDER BY occurred_at DESC`, [id]);
      assert.equal(JSON.stringify(r.body.pointsLedgers[id]), JSON.stringify(single.rows), `card ${id}`);
    }
    await client.query('ROLLBACK');
  } finally { client.release(); await pool.end(); }
});

test('the API registers the batched route next to the per-card one', () => {
  const source = require('node:fs').readFileSync(require('node:path').join(__dirname, '../src/index.js'), 'utf8');
  assert.match(source, /registerPointsLedgersRoute\(app, \{ requireAuth, withUserClient \}\);/);
  assert.match(source, /app\.get\('\/user-cards\/:id\/points-ledger'/, 'the per-card route stays for older app builds');
});
