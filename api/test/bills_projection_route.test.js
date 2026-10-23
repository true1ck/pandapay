const test = require('node:test');
const assert = require('node:assert/strict');
const route = require('../src/bills_projection_route');

function harness(queryResult = { rows: [] }, queryError = null) {
  let handler;
  let authRequired = false;
  const fakeApp = {
    get(path, auth, callback) {
      if (path === '/bills/projections') {
        authRequired = Boolean(auth);
        handler = callback;
      }
    },
  };
  const calls = [];
  route.registerBillsProjectionRoutes(fakeApp, {
    requireAuth: () => true,
    withUserClient: async (userId, fn) => fn({
      query: async (sql, params) => {
        calls.push({ sql, params });
        if (queryError) throw queryError;
        // The production route backfills older typed facts before reading the
        // projection table. This harness has no source/fact store, so model an
        // already-caught-up account and let the next query return projections.
        if (sql.includes('FROM sms_sources') && sql.includes('projection_version')) {
          return { rows: [] };
        }
        return queryResult;
      },
    }),
  });
  const invoke = async (req = {}) => {
    let statusCode = 200;
    let body;
    const res = {
      status(code) { statusCode = code; return this; },
      json(value) { body = value; return this; },
    };
    await handler({ userId: 'profile-1', query: {}, ...req }, res);
    return { statusCode, body };
  };
  return { calls, invoke, get authRequired() { return authRequired; } };
}

test('registers the authenticated read route and returns serialized projections', async () => {
  const h = harness({ rows: [{
    id: 'projection-1',
    projection_kind: 'bill_obligation',
    projection_key: 'bill:axis:2026-11-05:due_total',
    status: 'open',
    projection: { amountRole: 'due_total', amountInr: 3000 },
    source_key: 'a'.repeat(64),
    source_fact_ids: ['fact-1'],
    projection_version: 1,
    created_at: '2026-10-23T00:00:00.000Z',
    updated_at: '2026-10-23T00:00:00.000Z',
  }] });
  const result = await h.invoke({ query: { kinds: 'bill_obligation,mandate', limit: '20' } });
  assert.equal(h.authRequired, true);
  assert.equal(result.statusCode, 200);
  assert.equal(result.body.available, true);
  assert.equal(result.body.projections[0].projectionKind, 'bill_obligation');
  assert.equal(h.calls[1].params[0], 'profile-1');
  assert.deepEqual(h.calls[1].params[1], ['bill_obligation', 'mandate']);
  assert.equal(h.calls[1].params[3], 20);
});

test('rejects unknown kinds and invalid limits before touching the database', async () => {
  const h = harness();
  assert.equal((await h.invoke({ query: { kinds: 'subscription' } })).statusCode, 400);
  assert.equal((await h.invoke({ query: { limit: '201' } })).statusCode, 400);
  assert.equal(h.calls.length, 0);
});

test('returns an additive unavailable response when migration is pending', async () => {
  const h = harness(undefined, { code: '42P01', message: 'relation does not exist' });
  const result = await h.invoke();
  assert.equal(result.statusCode, 200);
  assert.deepEqual(result.body, { available: false, projections: [] });
});
