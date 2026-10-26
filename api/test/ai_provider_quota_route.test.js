const test = require('node:test');
const assert = require('node:assert/strict');
const { registerProviderQuotaRoute, providerLimits } = require('../src/ai_provider_quota_route');

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

test('provider reservation validates token estimates and applies minute request/token pacing', async () => {
  let args;
  const call = routeHarness(async (userId, fn) => {
    assert.equal(userId, null);
    return fn({ query: async (sql, params) => {
      assert.match(sql, /ai_reserve_provider_capacity\(\$1, \$2, \$3\)/);
      args = params;
      return { rows: [{ reservation: { allowed: false, waitMs: 900 } }] };
    } });
  });
  const bad = await call({ estimatedTokens: 0 });
  assert.equal(bad.statusCode, 400);
  const ok = await call({ estimatedTokens: 450 });
  assert.deepEqual(args, [30, 24000, 450]);
  assert.deepEqual(ok.body, { allowed: false, waitMs: 900 });
});

test('provider reservation returns a safe unavailable response on database errors', async () => {
  const call = routeHarness(async () => { throw new Error('database unavailable'); });
  const res = await call({ estimatedTokens: 450 });
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'provider capacity reservation unavailable' });
});

test('minute pacing waits and retries without applying a daily request cap', async () => {
  const { reserveProviderCapacity } = require('../src/gemini_worker');
  let calls = 0;
  const permit = await reserveProviderCapacity({
      jobs: [{ id: 'job', payload: { body: 'synthetic fixture' } }],
      apiBaseUrl: 'http://api.test',
      workerToken: 'worker-token',
      fetchImpl: async () => {
        calls++;
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => calls === 1
            ? ({ allowed: false, waitMs: 250 })
            : ({ allowed: true, waitMs: 0 }),
        };
      },
      waitImpl: async (ms) => assert.equal(ms, 250),
    });
  assert.equal(calls, 2);
  assert.deepEqual(permit, { allowed: true, waitMs: 0 });
});

test('provider limits configure minute request/token pacing only', () => {
  const { providerLimits } = require('../src/ai_provider_quota_route');
  process.env.GEMINI_REQUESTS_PER_MINUTE = '12';
  process.env.GEMINI_TOKENS_PER_MINUTE = '500000';
  assert.deepEqual(providerLimits(), {
    requestsPerMinute: 12,
    tokensPerMinute: 500000,
  });
  process.env.GEMINI_REQUESTS_PER_MINUTE = '40';
  assert.equal(providerLimits().requestsPerMinute, 30);
  process.env.GEMINI_REQUESTS_PER_MINUTE = '0';
  assert.equal(providerLimits().requestsPerMinute, 30);
  delete process.env.GEMINI_REQUESTS_PER_MINUTE;
  delete process.env.GEMINI_TOKENS_PER_MINUTE;
});
