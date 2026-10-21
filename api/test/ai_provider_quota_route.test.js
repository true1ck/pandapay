const test = require('node:test');
const assert = require('node:assert/strict');
const { registerProviderQuotaRoute, boundedEnvInt } = require('../src/ai_provider_quota_route');

function responseRecorder() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

function routeHarness(withUserClient) {
  const routes = new Map();
  const app = { post(path, ...middleware) { routes.set(path, middleware.at(-1)); } };
  registerProviderQuotaRoute(app, { requireWorkerAuth: () => {}, withUserClient });
  return async (body) => {
    const res = responseRecorder();
    await routes.get('/ai/provider/reserve')({ body }, res);
    return res;
  };
}

test('provider reservation validates token estimates and uses the shared SQL gate', async () => {
  let args;
  const call = routeHarness(async (userId, fn) => {
    assert.equal(userId, null);
    return fn({ query: async (sql, params) => {
      assert.match(sql, /ai_reserve_provider_capacity/);
      args = params;
      return { rows: [{ reservation: { allowed: false, waitMs: 900 } }] };
    } });
  });
  const bad = await call({ estimatedTokens: 0 });
  assert.equal(bad.statusCode, 400);
  const ok = await call({ estimatedTokens: 450 });
  assert.deepEqual(args, [10, 12000, 450]);
  assert.deepEqual(ok.body, { allowed: false, waitMs: 900 });
});

test('provider reservation returns a safe unavailable response on database errors', async () => {
  const call = routeHarness(async () => { throw new Error('database unavailable'); });
  const res = await call({ estimatedTokens: 450 });
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'provider capacity reservation unavailable' });
});

test('Gemini quota environment limits are bounded and fall back safely', () => {
  process.env.GEMINI_REQUESTS_PER_MINUTE = '12';
  assert.equal(boundedEnvInt('GEMINI_REQUESTS_PER_MINUTE', 10, 1, 1000), 12);
  process.env.GEMINI_REQUESTS_PER_MINUTE = '0';
  assert.equal(boundedEnvInt('GEMINI_REQUESTS_PER_MINUTE', 10, 1, 1000), 10);
  delete process.env.GEMINI_REQUESTS_PER_MINUTE;
});
