'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { registerAdminReferralOperationsRoutes } = require('../src/admin_referral_operations');

function createHarness() {
  const routes = {};
  const state = { calls: [], queryResult: { operations: { access: { admissionMode: 'open' } } }, queryError: null };
  const adminGate = () => {};
  const client = {
    async query(sql, values) {
      state.calls.push({ sql, values });
      if (state.queryError) throw state.queryError;
      return { rows: [state.queryResult] };
    },
  };
  registerAdminReferralOperationsRoutes({
    get: (path, gate, handler) => { routes[`GET ${path}`] = { gate, handler }; },
    put: (path, gate, handler) => { routes[`PUT ${path}`] = { gate, handler }; },
  }, {
    requireAdmin: adminGate,
    withUserClient: async (userId, action) => {
      state.userId = userId;
      return action(client);
    },
  });
  return {
    routes,
    state,
    async call(key, { params = {}, body = {}, userId = 'admin-id' } = {}) {
      const response = {
        statusCode: 200,
        status(code) { this.statusCode = code; return this; },
        json(value) { this.body = value; return this; },
      };
      await routes[key].handler({ params, body, userId }, response);
      return response;
    },
  };
}

test('admin status is served through the audited RPC behind requireAdmin', async () => {
  const h = createHarness();
  const response = await h.call('GET /admin/referrals/operations');
  assert.equal(h.routes['GET /admin/referrals/operations'].gate.name, 'adminGate');
  assert.deepEqual(response.body, { operations: h.state.queryResult.operations });
  assert.equal(h.state.userId, 'admin-id');
  assert.match(h.state.calls[0].sql, /get_admin_referral_operations/);
});

test('hold endpoint validates scope, boolean state, and reason before touching the DB', async () => {
  const h = createHarness();
  for (const [scope, body] of [
    ['invented', { paused: true, reason: 'a valid incident reason' }],
    ['admission', { paused: 'true', reason: 'a valid incident reason' }],
    ['admission', { paused: true, reason: 'too short' }],
    ['admission', { paused: true, reason: 'x'.repeat(501) }],
  ]) {
    const response = await h.call('PUT /admin/referrals/holds/:scope', { params: { scope }, body });
    assert.equal(response.statusCode, 400);
    assert.deepEqual(response.body, { error: 'invalid_referral_hold_request' });
  }
  assert.equal(h.state.calls.length, 0);
});

test('hold endpoint calls the narrow RPC with normalized values and hides DB errors', async () => {
  const h = createHarness();
  h.state.queryResult = { hold: { scope: 'fulfillment', paused: true } };
  const response = await h.call('PUT /admin/referrals/holds/:scope', {
    params: { scope: 'fulfillment' },
    body: { paused: true, reason: '  delivery incident hold  ' },
  });
  assert.deepEqual(response.body, { hold: h.state.queryResult.hold });
  assert.deepEqual(h.state.calls[0].values, ['fulfillment', true, 'delivery incident hold']);
  assert.equal(h.routes['PUT /admin/referrals/holds/:scope'].gate.name, 'adminGate');

  h.state.queryError = Object.assign(new Error('private database detail'), { code: 'XX000' });
  const failed = await h.call('PUT /admin/referrals/holds/:scope', {
    params: { scope: 'admission' },
    body: { paused: true, reason: 'pilot incident pause' },
  });
  assert.equal(failed.statusCode, 500);
  assert.deepEqual(failed.body, { error: 'referral_hold_unavailable' });
  assert.equal(JSON.stringify(failed.body).includes('private database detail'), false);
});

test('hold endpoint maps known conflict errors without exposing internals', async () => {
  const h = createHarness();
  h.state.queryError = Object.assign(new Error('campaign_unavailable'), { code: 'P0001' });
  const response = await h.call('PUT /admin/referrals/holds/:scope', {
    params: { scope: 'enrollment' },
    body: { paused: false, reason: 'release after review' },
  });
  assert.equal(response.statusCode, 409);
  assert.deepEqual(response.body, { error: 'campaign_unavailable' });
});
