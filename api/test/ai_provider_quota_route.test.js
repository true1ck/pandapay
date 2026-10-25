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

test('provider reservation validates token estimates and applies the Free RPM, TPM, and RPD caps', async () => {
  let args;
  const call = routeHarness(async (userId, fn) => {
    assert.equal(userId, null);
    return fn({ query: async (sql, params) => {
      assert.match(sql, /ai_reserve_provider_capacity\(\$1, \$2, \$3, \$4\)/);
      args = params;
      return { rows: [{ reservation: { allowed: false, waitMs: 900 } }] };
    } });
  });
  const bad = await call({ estimatedTokens: 0 });
  assert.equal(bad.statusCode, 400);
  const ok = await call({ estimatedTokens: 450 });
  assert.deepEqual(args, [5, 12000, 20, 450]);
  assert.deepEqual(ok.body, { allowed: false, waitMs: 900 });
});

test('provider reservation returns a safe unavailable response on database errors', async () => {
  const call = routeHarness(async () => { throw new Error('database unavailable'); });
  const res = await call({ estimatedTokens: 450 });
  assert.equal(res.statusCode, 503);
  assert.deepEqual(res.body, { error: 'provider capacity reservation unavailable' });
});

test('Free-tier daily exhaustion releases capacity once with the next reset delay', async () => {
  const { reserveProviderCapacity } = require('../src/gemini_worker');
  let calls = 0;
  await assert.rejects(
    reserveProviderCapacity({
      jobs: [{ id: 'job', payload: { body: 'synthetic fixture' } }],
      apiBaseUrl: 'http://api.test',
      workerToken: 'worker-token',
      fetchImpl: async () => {
        calls++;
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: async () => ({ allowed: false, dailyLimitReached: true, retryAfterMs: 60000 }),
        };
      },
      waitImpl: async () => assert.fail('daily exhaustion must not poll in a tight loop'),
    }),
    (error) => error.retryable === true && error.retryAfterMs === 60000,
  );
  assert.equal(calls, 1);
});

test('Gemini Free-tier limits cap configured settings at 15 RPM and 1500 RPD', () => {
  const { providerLimits } = require('../src/ai_provider_quota_route');
  process.env.GEMINI_REQUESTS_PER_MINUTE = '12';
  process.env.GEMINI_TOKENS_PER_MINUTE = '500000';
  process.env.GEMINI_REQUESTS_PER_DAY = '200';
  assert.deepEqual(providerLimits(), {
    requestsPerMinute: 12,
    tokensPerMinute: 500000,
    requestsPerDay: 200,
  });
  process.env.GEMINI_REQUESTS_PER_MINUTE = '20';
  process.env.GEMINI_REQUESTS_PER_DAY = '2000';
  assert.equal(providerLimits().requestsPerMinute, 15);
  assert.equal(providerLimits().requestsPerDay, 1500);
  process.env.GEMINI_REQUESTS_PER_MINUTE = '0';
  assert.equal(providerLimits().requestsPerMinute, 5);
  process.env.GEMINI_REQUESTS_PER_DAY = '0';
  assert.equal(providerLimits().requestsPerDay, 20);
  delete process.env.GEMINI_REQUESTS_PER_MINUTE;
  delete process.env.GEMINI_TOKENS_PER_MINUTE;
  delete process.env.GEMINI_REQUESTS_PER_DAY;
});
