'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const express = require('express');
const { registerInlineAdminRoutes } = require('../src/admin/inline_routes');

// The whole card catalogue (about 14 MB for 376 cards) takes several seconds to read. Every other admin read keeps the
// 5 s database limit, but this one read must be allowed longer, both on the database side and on the client side.
// Since 21 Nov 2026 it is read through a cursor a batch at a time (stream_json_rows.js) instead of being held whole
// in memory; the console still gets exactly { cards: [...] }.

function fakeClient(rows, { fail = false } = {}) {
  const statements = [];
  let pos = 0;
  return {
    statements,
    async query(statement) {
      statements.push(statement);
      const text = typeof statement === 'string' ? statement : statement.text;
      if (fail && text.startsWith('FETCH')) throw Object.assign(new Error('canceling statement due to statement timeout'), { code: '57014' });
      const fetch = text.match(/^FETCH (\d+) FROM/);
      if (fetch) { const out = rows.slice(pos, pos + Number(fetch[1])); pos += out.length; return { rows: out }; }
      return { rows: [] };
    },
  };
}

async function callCards(client) {
  const app = express();
  registerInlineAdminRoutes(app, { withUserClient: async (_actorId, operation) => operation(client), requireAdmin: (req, _res, next) => { req.userId = 'actor-1'; next(); }, requireAuth: (_req, _res, next) => next() });
  const server = http.createServer(app);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  try {
    return await new Promise((resolve, reject) => {
      http.get(`http://127.0.0.1:${server.address().port}/admin/cards`, (res) => {
        const chunks = []; res.on('data', (c) => chunks.push(c));
        res.on('end', () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString('utf8') }));
      }).on('error', reject);
    });
  } finally { await new Promise((r) => server.close(r)); }
}

test('the card catalogue read asks for a longer database time limit than the 5 s default', async () => {
  const cards = Array.from({ length: 30 }, (_, i) => ({ id: `card-${i}`, name: `Card ${i}` }));
  const client = fakeClient(cards);
  const reply = await callCards(client);

  assert.equal(reply.status, 200);
  assert.equal(reply.body, JSON.stringify({ cards }), 'exactly what res.json({ cards }) sent');
  assert.equal(client.statements[0], "SET LOCAL statement_timeout = '30s'");
  const texts = client.statements.slice(1).map((s) => s.text);
  assert.ok(texts.some((t) => /^DECLARE \w+ NO SCROLL CURSOR FOR SELECT \* FROM v_admin_card_catalogue_export ORDER BY name$/.test(t)));
  for (const s of client.statements.slice(1)) assert.equal(s.query_timeout, 30_000, `${s.text}: 30 s on the client side too`);
});

test('a read that fails before anything is sent still answers the usual 500', async () => {
  const reply = await callCards(fakeClient([], { fail: true }));
  assert.equal(reply.status, 500);
  assert.equal(reply.body, '{"error":"internal_error"}');
});
