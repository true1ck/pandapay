const test = require('node:test');
const assert = require('node:assert');
const {
  GeminiProvider,
  GeminiProviderError,
  nextAdaptiveBatchSize,
  runWorkerOnce,
} = require('../src/gemini_worker');

function response(body, status = 200, headers = {}) {
  return {
    ok: status >= 200 && status < 300,
    status,
    headers: { get: (name) => headers[name.toLowerCase()] || null },
    async json() { return body; },
  };
}

test('Gemini provider requests JSON and parses the model fact envelope', async () => {
  let request;
  let requestUrl;
  let requestHeaders;
  const provider = new GeminiProvider({
    apiKey: 'test-key',
    model: 'test-model',
    endpointBase: 'https://example.test/models',
    fetchImpl: async (url, options) => {
      requestUrl = url;
      requestHeaders = options.headers;
      request = JSON.parse(options.body);
      return response({ candidates: [{ content: { parts: [{ text: '{"facts":[]}' }] } }] });
    },
  });
  const facts = await provider.classify({ payload: { sender: 'BANK', body: 'Card XXXX1234 paid Rs 100' } });
  assert.deepEqual(facts, []);
  assert.equal(request.generationConfig.responseMimeType, 'application/json');
  assert.equal(Object.hasOwn(request.generationConfig, 'temperature'), false,
    'Gemini 3.8 Flash rejects deprecated sampling parameters');
  assert.match(request.contents[0].parts[0].text, /Card XXXX1234/);
  assert.equal(requestUrl, 'https://example.test/models/test-model:generateContent');
  assert.equal(requestHeaders['x-goog-api-key'], 'test-key');
  assert.equal(requestUrl.includes('test-key'), false);
});

test('Gemini worker defaults to the supported Flash model unless configured', () => {
  const provider = new GeminiProvider({ apiKey: 'test-key', fetchImpl: async () => response({}) });
  assert.equal(provider.model, process.env.GEMINI_MODEL || 'gemini-3.8-flash');
});

test('worker posts the leased result with the profile and lease token', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    if (url.endsWith('/ai/jobs/lease')) {
      return response({
        leased: true,
        job: {
          id: 'job-1', profileId: 'profile-1', leaseToken: 'a'.repeat(64),
          payload: { sender: 'BANK', body: 'safe' },
        },
      });
    }
    return response({ jobStatus: 'done' });
  };
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test',
    workerToken: 'worker-token',
    fetchImpl,
    provider: { classify: async () => [] },
    reserveCapacity: async () => ({ allowed: true }),
  });
  assert.equal(result.completed, true);
  assert.deepEqual(calls[1].body, {
    facts: [], profileId: 'profile-1', leaseToken: 'a'.repeat(64),
    batchId: calls[1].body.batchId, batchSize: 1,
  });
  assert.match(calls[1].body.batchId, /^[0-9a-f-]{36}$/i);
});

test('provider 429 releases the same leased job for retry', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    if (url.endsWith('/ai/jobs/lease')) {
      return response({ leased: true, job: {
        id: 'job-2', profileId: 'profile-2', leaseToken: 'b'.repeat(64), payload: {},
      } });
    }
    return response({ jobStatus: 'queued' });
  };
  const error = new GeminiProviderError('quota', { retryable: true, retryAfterMs: 60000, status: 429 });
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test',
    workerToken: 'worker-token',
    fetchImpl,
    provider: { classify: async () => { throw error; } },
    reserveCapacity: async () => ({ allowed: true }),
  });
  assert.equal(result.retried, true);
  assert.equal(calls[1].url, 'http://worker.test/ai/jobs/job-2/retry');
  assert.equal(calls[1].body.retryAfterMs, 60000);
});

test('malformed provider output immediately fails the leased job', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push(url);
    if (url.endsWith('/lease')) return response({ leased: true, job: {
      id: 'bad-job', profileId: 'profile-1', leaseToken: 'c'.repeat(64), payload: {},
    } });
    return response({ jobStatus: 'failed' });
  };
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token', fetchImpl,
    provider: { classify: async () => { throw new GeminiProviderError('invalid JSON'); } },
    reserveCapacity: async () => ({ allowed: true }),
  });
  assert.equal(result.failed, true);
  assert.equal(calls[1], 'http://worker.test/ai/jobs/bad-job/fail');
});

test('adaptive group sends one provider call and lands items independently', async () => {
  const calls = [];
  const bodies = [];
  let leases = 0;
  const jobs = ['a', 'b'].map((id) => ({
    id, profileId: 'profile-1', leaseToken: id.repeat(64), payload: { body: `Rs ${id === 'a' ? 1 : 2} debited` },
  }));
  const fetchImpl = async (url, options) => {
    calls.push(url);
    if (options?.body) bodies.push(JSON.parse(options.body));
    if (url.endsWith('/lease')) return leases < jobs.length
      ? response({ leased: true, job: jobs[leases++] })
      : response({ leased: false });
    return response({ jobStatus: 'done' });
  };
  let batches = 0;
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token', fetchImpl,
    maxBatch: 4, batchWindowMs: 0,
    provider: {
      classifyBatch: async (items) => {
        batches += 1;
        return new Map(items.map((job) => [job.id, []]));
      },
    },
    reserveCapacity: async () => ({ allowed: true }),
  });
  assert.equal(result.batchSize, 2);
  assert.equal(batches, 1);
  assert.equal(calls.filter((url) => url.endsWith('/result')).length, 2);
  const resultBodies = bodies.filter((body) => Array.isArray(body.facts));
  assert.equal(resultBodies.length, 2);
  assert.equal(resultBodies[0].batchId, resultBodies[1].batchId);
  assert.equal(resultBodies[0].batchSize, 2);
});

test('worker waits for shared capacity before calling Gemini', async () => {
  const sequence = [];
  let leases = 0;
  const jobs = [
    { id: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', profileId: 'profile-1', leaseToken: '1'.repeat(64), payload: { body: 'Rs 100 debited' } },
    { id: 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', profileId: 'profile-1', leaseToken: '2'.repeat(64), payload: { body: 'Rs 100 debited' } },
  ];
  const fetchImpl = async (url) => {
    if (url.endsWith('/lease')) {
      if (leases >= jobs.length) return response({ leased: false });
      return response({ leased: true, job: jobs[leases++] });
    }
    return response({ jobStatus: 'done' });
  };
  let reservations = 0;
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token',
    batchWindowMs: 0, maxBatch: 2,
    waitImpl: async (ms) => { assert.equal(ms, 250); sequence.push('wait'); },
    // Override just the reservation endpoint response; queue/result endpoints
    // retain their normal test behavior.
    fetchImpl: async (url, options) => {
      if (url.endsWith('/ai/provider/reserve')) {
        reservations += 1;
        sequence.push(`reserve-${reservations}`);
        return response(reservations === 1
          ? { allowed: false, waitMs: 250 }
          : { allowed: true });
      }
      if (url.endsWith('/heartbeat')) {
        sequence.push(`heartbeat-${url.includes(jobs[0].id) ? 'one' : 'two'}`);
        return response({ renewed: true });
      }
      return fetchImpl(url, options);
    },
    provider: { classifyBatch: async () => {
      sequence.push('provider');
      return new Map(jobs.map((job) => [job.id, []]));
    } },
  });
  assert.equal(result.completed, true);
  assert.deepEqual(sequence, [
    'reserve-1', 'heartbeat-one', 'heartbeat-two', 'wait', 'reserve-2', 'provider',
  ]);
});

test('adaptive batch size ramps up after success and backs off after provider failures', () => {
  assert.equal(nextAdaptiveBatchSize(1, 4, { completed: true }), 2);
  assert.equal(nextAdaptiveBatchSize(3, 4, { completed: true }), 4);
  assert.equal(nextAdaptiveBatchSize(4, 4, { completed: true }), 4);
  assert.equal(nextAdaptiveBatchSize(4, 4, { retried: true }), 2);
  assert.equal(nextAdaptiveBatchSize(2, 4, { failed: true }), 1);
});
