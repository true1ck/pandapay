'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { registerInlineAdminRoutes } = require('../src/admin/inline_routes');

// The whole card catalogue (about 14 MB for 376 cards) takes several seconds to read. Every other admin read keeps the
// 5 s database limit, but this one read must be allowed longer, both on the database side and on the client side.
test('the card catalogue read asks for a longer database time limit than the 5 s default', async () => {
  const handlers = new Map();
  const app = new Proxy({}, { get: (_target, method) => (path, ...args) => { handlers.set(`${String(method).toUpperCase()} ${path}`, args[args.length - 1]); } });
  const statements = [];
  const client = { async query(statement) { statements.push(statement); return { rows: [{ id: 'card-1', name: 'Card' }] }; } };
  registerInlineAdminRoutes(app, { withUserClient: async (_actorId, operation) => operation(client), requireAdmin: () => {}, requireAuth: () => {} });

  const handler = handlers.get('GET /admin/cards');
  assert.equal(typeof handler, 'function');
  let body;
  await handler({ userId: 'actor-1' }, { json(value) { body = value; }, status() { return this; } });

  assert.deepEqual(body, { cards: [{ id: 'card-1', name: 'Card' }] });
  assert.equal(statements.length, 2);
  assert.equal(statements[0], "SET LOCAL statement_timeout = '30s'");
  assert.match(statements[1].text, /FROM v_admin_card_catalogue_export ORDER BY name/);
  assert.equal(statements[1].query_timeout, 30_000);
});
