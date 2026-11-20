'use strict';
// GET /admin/cards built the whole 14 MB catalogue in memory (rows, then one string) on a 1 GB host. It now reads the
// rows through a database cursor a batch at a time and writes each batch as it comes. The reply must be byte for byte
// what res.json({ cards: rows }) sent, so the admin console sees no change.
//   Real-Postgres parity: SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/postgres
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const express = require('express');
const { streamJsonRows } = require('../src/admin/stream_json_rows');

function fakeClient(rows, { failOn = null } = {}) {
  const calls = [];
  let pos = 0;
  return {
    calls,
    async query(q) {
      const text = typeof q === 'string' ? q : q.text;
      calls.push(text);
      if (failOn && failOn(text, calls)) throw Object.assign(new Error('boom'), { code: '57014' });
      const fetch = text.match(/^FETCH (\d+) FROM/);
      if (fetch) { const n = Number(fetch[1]); const out = rows.slice(pos, pos + n); pos += n; return { rows: out }; }
      return { rows: [] };
    },
  };
}

async function serve(handler) {
  const app = express();
  app.get('/x', handler);
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    return await new Promise((resolve) => {
      http.get(`http://127.0.0.1:${server.address().port}/x`, (res) => {
        const chunks = []; res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString('utf8'), complete: res.complete }));
        res.on('error', () => resolve({ status: res.statusCode, complete: false }));
      }).on('error', () => resolve({ status: 0, complete: false }));
    });
  } finally { await new Promise((r) => server.close(r)); }
}

const sample = Array.from({ length: 61 }, (_, i) => ({
  id: `card-${i}`, name: i % 7 === 0 ? 'Same name' : `Card ${i} é "q" <b>`, rate: i / 3, note: i % 5 ? null : 'x\n\ty',
  rules: [{ k: i, nested: { deep: [1, 'two', null, true] } }], updated_at: new Date(Date.UTC(2026, 10, 21, 0, 0, i)),
}));

test('the reply is byte for byte what res.json({ cards: rows }) sent, with the same headers', async () => {
  const expected = await serve((req, res) => res.json({ cards: sample }));
  const streamed = await serve(async (req, res) => { await streamJsonRows(fakeClient(sample), res, { key: 'cards', text: 'SELECT 1', batch: 25 }); });
  assert.equal(streamed.status, 200);
  assert.equal(streamed.body, expected.body);
  assert.equal(streamed.headers['content-type'], expected.headers['content-type']);
});

test('rows are read through a cursor a batch at a time, and the cursor is closed', async () => {
  const client = fakeClient(sample);
  await serve(async (req, res) => { await streamJsonRows(client, res, { key: 'cards', text: 'SELECT * FROM v ORDER BY name', batch: 25 }); });
  assert.match(client.calls[0], /cursor_tuple_fraction/, 'plan for the whole result, as the plain query did');
  assert.match(client.calls[1], /^DECLARE \w+ NO SCROLL CURSOR FOR SELECT \* FROM v ORDER BY name$/);
  assert.equal(client.calls.filter((c) => c.startsWith('FETCH')).length, 3, '25 + 25 + 11: a short batch ends it');
  assert.match(client.calls.at(-1), /^CLOSE \w+$/);
});

test('no rows gives {"key":[]}', async () => {
  const r = await serve(async (req, res) => { await streamJsonRows(fakeClient([]), res, { key: 'cards', text: 'SELECT 1' }); });
  assert.equal(r.body, '{"cards":[]}');
});

test('a failure before the first byte leaves the reply untouched, so the route still answers its own 500', async () => {
  const r = await serve(async (req, res) => {
    try {
      await streamJsonRows(fakeClient(sample, { failOn: (t) => t.startsWith('FETCH') }), res, { key: 'cards', text: 'SELECT 1' });
    } catch {
      assert.equal(res.headersSent, false);
      res.status(500).json({ error: 'internal_error' });
    }
  });
  assert.equal(r.status, 500);
  assert.equal(r.body, '{"error":"internal_error"}');
});

test('a failure after the first batch was sent throws with headers sent (the route then cuts the connection)', async () => {
  let fetches = 0;
  const r = await serve(async (req, res) => {
    try {
      await streamJsonRows(fakeClient(sample, { failOn: (t) => t.startsWith('FETCH') && ++fetches === 2 }), res, { key: 'cards', text: 'SELECT 1', batch: 25 });
    } catch {
      assert.equal(res.headersSent, true);
      res.destroy();
    }
  });
  assert.equal(r.complete, false, 'never a complete-looking short list');
});

const url = process.env.SMS_V2_TEST_DATABASE_URL;
test('on real Postgres the streamed reply equals res.json of the same query, types included', { skip: url ? false : 'SMS_V2_TEST_DATABASE_URL not set' }, async () => {
  const { Pool } = require('pg');
  const pool = new Pool({ connectionString: url });
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    await client.query(`CREATE TEMP TABLE stream_probe AS
      SELECT g AS n, 'Card ' || (g % 9) AS name, (g * 1.25)::numeric(10,2) AS amount, (g::bigint * 10000000000) AS big,
             timestamptz '2026-11-21 01:02:03.456789+05:30' + g * interval '1 hour' AS at, date '2026-11-21' + g AS day,
             jsonb_build_object('g', g, 'list', jsonb_build_array(g, 'é', null)) AS doc, ARRAY[g, g + 1] AS arr,
             CASE WHEN g % 4 = 0 THEN NULL ELSE 'x"y' END AS maybe
        FROM generate_series(1, 137) g`);
    const sql = 'SELECT * FROM stream_probe ORDER BY name, n';
    const rows = (await client.query(sql)).rows;
    const expected = await serve((req, res) => res.json({ cards: rows }));
    const streamed = await serve(async (req, res) => { await streamJsonRows(client, res, { key: 'cards', text: sql, batch: 25 }); });
    assert.equal(streamed.body, expected.body);
    await client.query('ROLLBACK');
  } finally { client.release(); await pool.end(); }
});
