const test = require('node:test');
const assert = require('node:assert');
const {
  GeminiProvider,
  GeminiProviderError,
  UNIVERSAL_SYSTEM_INSTRUCTION,
  UNIVERSAL_RESPONSE_SCHEMA,
  FEW_SHOT_EXAMPLES,
  buildGeminiPrompt,
  buildGeminiBatchPrompt,
  nextAdaptiveBatchSize,
  runWorkerOnce,
} = require('../src/gemini_worker');
const smsFacts = require('../src/sms_facts');

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
  const result = await provider.classify({ payload: { sender: 'BANK', body: 'Card XXXX1234 paid Rs 100' } });
  assert.deepEqual(result.facts, []);
  assert.equal(typeof result.decision, 'object');
  assert.equal(request.generationConfig.responseMimeType, 'application/json');
  assert.equal(request.generationConfig.maxOutputTokens, 2048);
  assert.equal(Object.hasOwn(request.generationConfig, 'temperature'), false,
    'Gemini 3.8 Flash rejects deprecated sampling parameters');
  assert.equal(request.systemInstruction.parts[0].text, UNIVERSAL_SYSTEM_INSTRUCTION);
  assert.deepEqual(request.generationConfig.responseSchema, UNIVERSAL_RESPONSE_SCHEMA);
  assert.match(request.contents[0].parts[0].text, /Card XXXX1234/);
  assert.equal(requestUrl, 'https://example.test/models/test-model:generateContent');
  assert.equal(requestHeaders['x-goog-api-key'], 'test-key');
  assert.equal(requestUrl.includes('test-key'), false);
});

test('Gemini worker defaults to the supported Flash model unless configured', () => {
  const provider = new GeminiProvider({ apiKey: 'test-key', fetchImpl: async () => response({}) });
  assert.equal(provider.model, process.env.GEMINI_MODEL || 'gemini-3.5-flash-lite');
});

test('universal system instruction and schema cover movements, categories and completeness', () => {
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /ZERO HALLUCINATION/);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /PandaPay's SMS classification and structured-decision engine/);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /broker funds payout/i);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /Pay Later repayment/i);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /Do not write a summary/i);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /mandate_lifecycle/);
  assert.match(UNIVERSAL_SYSTEM_INSTRUCTION, /isComplete/);

  const item = UNIVERSAL_RESPONSE_SCHEMA.properties.facts.items;
  assert.ok(item.required.includes('factType'));
  assert.ok(item.required.includes('payload'));
  assert.deepEqual(item.properties.payload.properties.amountRole.enum, [
    'posted', 'due_total', 'due_minimum', 'outstanding', 'ceiling', 'proposed',
  ]);
  assert.equal(item.properties.payload.required, undefined,
    'amountRole is per fact type; a blanket requirement forces invalid balance snapshots');
  assert.deepEqual(item.properties.payload.properties.category.enum, [
    'groceries', 'fuel', 'dining', 'online', 'travel', 'bills', 'rent',
    'insurance', 'education', 'government', 'wallet', 'entertainment',
    'health', 'emi', 'other',
  ]);
  assert.equal(item.properties.payload.properties.isComplete.type, 'BOOLEAN');
  assert.equal(item.properties.payload.properties.confidence.type, 'NUMBER');
});

test('few-shot scenarios are exported and rendered into the prompt', () => {
  assert.equal(FEW_SHOT_EXAMPLES.length, 18);
  const labels = FEW_SHOT_EXAMPLES.map((example) => example.label).join(' | ');
  for (const scenario of [
    'Swiggy', 'Flipkart', 'Axis', 'BESCOM', 'Pay Later', 'credit card bill paid',
    'Kotak Neo', 'Zerodha', 'salary credit', 'Loan EMI', 'Netflix',
    'ATM cash withdrawal', 'Partial',
  ]) {
    assert.match(labels, new RegExp(scenario, 'i'));
  }
  const prompt = buildGeminiPrompt({ payload: { body: 'synthetic fixture' } });
  assert.match(prompt, /Example \d+ \(Partial/);
  assert.match(prompt, /"category":"dining"/);
  assert.match(prompt, /"isComplete":false/);
  assert.match(prompt, /groceries, fuel, dining, online, travel, bills, rent/);
  // Keep the prompt bounded even with every example rendered.
  assert.ok(prompt.length < 30000, `prompt length ${prompt.length}`);
});

test('every few-shot output satisfies the fact contract the result route enforces', () => {
  for (const example of FEW_SHOT_EXAMPLES) {
    const validation = smsFacts.validateFactSet(example.output.facts);
    assert.equal(
      validation.valid,
      true,
      `${example.label}: ${validation.errors.join('; ')}`,
    );
    for (const fact of example.output.facts) {
      for (const field of ['instrument', 'category']) {
        const allowed = field === 'instrument'
          ? smsFacts.INSTRUMENTS
          : smsFacts.SPEND_CATEGORIES;
        if (fact.payload[field] !== undefined) {
          assert.ok(
            allowed.includes(fact.payload[field]),
            `${example.label}: ${field} '${fact.payload[field]}' is outside the contract`,
          );
        }
      }
    }
  }
});

test('Gemini batch generation has a bounded output token limit', async () => {
  let request;
  const provider = new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async (_url, options) => {
      request = JSON.parse(options.body);
      return response({ candidates: [{ content: { parts: [{ text: '{"items":[]}' }] } }] });
    },
  });
  const result = await provider.classifyBatch([
    { id: 'a', payload: { body: 'synthetic fixture A' } },
    { id: 'b', payload: { body: 'synthetic fixture B' } },
  ]);
  assert.deepEqual(result, new Map());
  assert.equal(request.generationConfig.maxOutputTokens, 2048);
  assert.equal(Object.hasOwn(request.generationConfig, 'temperature'), false);
  assert.equal(request.systemInstruction.parts[0].text, UNIVERSAL_SYSTEM_INSTRUCTION);
  const batchSchema = request.generationConfig.responseSchema;
  assert.equal(batchSchema.type, 'OBJECT');
  assert.ok(batchSchema.properties.items.items.required.includes('id'));
  assert.ok(batchSchema.properties.items.items.required.includes('facts'));
  assert.equal(
    batchSchema.properties.items.items.properties.facts.items.properties.payload
      .properties.category.enum.length,
    15,
  );
});

test('Gemini prompt states required fact fields and fail-closed abstention rules', () => {
  const prompt = buildGeminiPrompt({ payload: { body: 'synthetic fixture' } });
  assert.match(prompt, /balance_snapshot = availableBalanceInr, asOfAt/);
  assert.match(prompt, /due_minimum=minimumDueInr\/dueDate/);
  assert.match(prompt, /never omit required fields or invent values/i);
  assert.match(prompt, /leave this SMS's facts array empty/);
  const batch = buildGeminiBatchPrompt([{ id: 'one' }, { id: 'two' }]);
  assert.match(batch, /"items":\[/);
  assert.match(batch, /If shouldConsider=false, set facts: \[\]/);
  assert.doesNotMatch(batch, /Return JSON only in the form \{"facts"/);
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
    decision: null,
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
  assert.equal(calls[1].body.reason, 'provider_rate_limited');
  assert.equal(calls[1].body.retryAfterMs, 60000);
});

test('provider 403 quota response is classified as rate limited without exposing provider text', async () => {
  const provider = new GeminiProvider({
    apiKey: 'synthetic-key',
    endpointBase: 'https://example.test/models',
    fetchImpl: async () => response({ error: { message: 'Resource has been exhausted (e.g. check quota).' } }, 403),
  });
  await assert.rejects(
    provider.classify({ payload: { sender: 'BANK', body: 'synthetic fixture' } }),
    (error) => error instanceof GeminiProviderError && error.retryable === true
      && error.status === 403 && error.rateLimited === true,
  );

  const { providerRetryReason } = require('../src/gemini_worker');
  assert.equal(providerRetryReason(new GeminiProviderError('Gemini HTTP 403', {
    retryable: true, status: 403, rateLimited: true,
  })), 'provider_rate_limited');
});

test('provider 503 releases the same leased job and preserves retry-after', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: JSON.parse(options.body) });
    if (url.endsWith('/ai/jobs/lease')) return response({ leased: true, job: {
      id: 'job-503', profileId: 'profile-503', leaseToken: '5'.repeat(64), payload: {},
    } });
    return response({ jobStatus: 'queued' });
  };
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token', fetchImpl,
    provider: {
      classify: async () => {
        throw new GeminiProviderError('temporary provider outage', {
          retryable: true, retryAfterMs: 3500, status: 503,
        });
      },
    },
    reserveCapacity: async () => ({ allowed: true }),
  });

  assert.equal(result.retried, true);
  assert.equal(calls[1].url, 'http://worker.test/ai/jobs/job-503/retry');
  assert.equal(calls[1].body.reason, 'provider_http_503');
  assert.equal(calls[1].body.retryAfterMs, 3500);
  assert.equal(calls[1].body.profileId, 'profile-503');
});

test('capacity API failure records its stage and does not call Gemini', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    if (url.endsWith('/ai/jobs/lease')) return response({ leased: true, job: {
      id: 'job-capacity', profileId: 'profile-capacity',
      leaseToken: 'c'.repeat(64), payload: { body: 'Rs 100 debited' },
    } });
    if (url.endsWith('/ai/provider/reserve')) return response({ error: 'capacity unavailable' }, 503);
    calls.push({ url, body: JSON.parse(options.body) });
    return response({ jobStatus: 'queued' });
  };
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token', fetchImpl,
    provider: { classify: async () => assert.fail('Gemini must not run without capacity') },
  });
  assert.equal(result.retried, true);
  assert.equal(calls[0].body.reason, 'provider_capacity_unavailable');
});

test('provider transport failures keep a safe diagnostic class without leaking text', async () => {
  const calls = [];
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test', workerToken: 'worker-token',
    reserveCapacity: async () => ({ allowed: true }),
    provider: { classify: async () => {
      throw new GeminiProviderError('Gemini request failed or timed out', { retryable: true });
    } },
    fetchImpl: async (url, options) => {
      calls.push({ url, body: options?.body ? JSON.parse(options.body) : null });
      if (url.endsWith('/lease')) return response({ leased: true, job: {
        id: 'job-transport', profileId: 'profile-transport',
        leaseToken: 't'.repeat(64), payload: {},
      } });
      return response({ jobStatus: 'queued' });
    },
  });
  assert.equal(result.retried, true);
  assert.equal(calls[1].body.reason, 'provider_transport_error');
  assert.equal(JSON.stringify(calls[1].body).includes('request failed or timed out'), false);
});

test('missing Gemini key fails before opening a provider request', async () => {
  let called = false;
  const provider = new GeminiProvider({
    apiKey: '',
    fetchImpl: async () => {
      called = true;
      return response({ candidates: [] });
    },
  });

  await assert.rejects(
    provider.classify({ payload: { body: 'synthetic fixture' } }),
    (error) => error instanceof GeminiProviderError && error.retryable === false,
  );
  assert.equal(called, false);
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

test('provider 422 settles the lease while API validation 422 is already terminal', async () => {
  for (const providerRefused of [true, false]) {
    const calls = [];
    const result = await runWorkerOnce({
      apiBaseUrl: 'http://worker.test', workerToken: 'worker-token',
      reserveCapacity: async () => ({ allowed: true }),
      provider: {
        classify: async () => {
          if (providerRefused) throw new GeminiProviderError('Gemini HTTP 422', { status: 422 });
          return [];
        },
      },
      fetchImpl: async (url) => {
        calls.push(url);
        if (url.endsWith('/lease')) return response({ leased: true, job: {
          id: 'job-422', profileId: 'profile-422', leaseToken: '4'.repeat(64), payload: {},
        } });
        return url.endsWith('/result') ? response({ error: 'result facts refused' }, 422)
          : response({ jobStatus: 'failed' });
      },
    });
    assert.equal(result.failed, true);
    assert.equal(calls.filter((url) => url.endsWith('/fail')).length, providerRefused ? 1 : 0);
    assert.equal(calls.filter((url) => url.endsWith('/result')).length, providerRefused ? 0 : 1);
  }
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

test('provider 429 extracts retryDelay from JSON error body or defaults to 30s+', async () => {
  const providerWithDetails = new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async () => response({
      error: {
        code: 429,
        status: 'RESOURCE_EXHAUSTED',
        details: [{ retryDelay: '45s' }],
      },
    }, 429),
  });

  await assert.rejects(
    async () => providerWithDetails.classify({ payload: { body: 'text' } }),
    (err) => err instanceof GeminiProviderError && err.retryAfterMs === 45000 && err.retryable === true,
  );

  const providerWithoutDelay = new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async () => response({ error: { code: 429 } }, 429),
  });

  await assert.rejects(
    async () => providerWithoutDelay.classify({ payload: { body: 'text' } }),
    (err) => err instanceof GeminiProviderError && err.retryAfterMs >= 30000 && err.retryable === true,
  );
});

test('Gemini batch response preserves ids and rejects cross-job, duplicate, or malformed items', async () => {
  const jobs = [
    { id: 'job-a', payload: { sender: 'BANK', body: 'Rs 100 debited' } },
    { id: 'job-b', payload: { sender: 'BANK', body: 'Rs 200 credited' } },
  ];
  const providerFor = (items) => new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async (_url, options) => {
      const request = JSON.parse(options.body);
      assert.match(request.contents[0].parts[0].text, /ITEM job-a/);
      assert.match(request.contents[0].parts[0].text, /ITEM job-b/);
      return response({ candidates: [{ content: { parts: [{ text: JSON.stringify({ items }) }] } }] });
    },
  });

  const valid = await providerFor([
    { id: 'job-a', facts: [] },
    { id: 'job-b', facts: [] },
  ]).classifyBatch(jobs);
  assert.deepEqual([...valid.keys()], ['job-a', 'job-b']);

  // Omission is reported per item to runWorkerOnce, so one malformed batch
  // member cannot make another member's result land under the wrong job.
  const partial = await providerFor([{ id: 'job-a', facts: [] }]).classifyBatch(jobs);
  assert.equal(partial.has('job-a'), true);
  assert.equal(partial.has('job-b'), false);

  for (const items of [
    [{ id: 'foreign-job', facts: [] }, { id: 'job-b', facts: [] }],
    [{ id: 'job-a', facts: [] }, { id: 'job-a', facts: [] }],
    [{ id: 'job-a', facts: 'not-an-array' }, { id: 'job-b', facts: [] }],
  ]) {
    await assert.rejects(
      providerFor(items).classifyBatch(jobs),
      (error) => error instanceof GeminiProviderError && error.retryable === false,
    );
  }
});

test('provider maps permanent 4xx separately from retryable 429 and 5xx', async () => {
  for (const [status, retryable] of [[400, false], [401, false], [429, true], [503, true]]) {
    const provider = new GeminiProvider({
      apiKey: 'test-key',
      fetchImpl: async () => response({ error: { code: status } }, status),
    });
    await assert.rejects(
      provider.classify({ payload: { body: 'synthetic fixture' } }),
      (error) => error instanceof GeminiProviderError &&
        error.status === status && error.retryable === retryable,
    );
  }
});

test('batch omission fails only the omitted job while preserving the valid result', async () => {
  const jobs = ['a', 'b'].map((id) => ({
    id,
    profileId: `profile-${id}`,
    leaseToken: id.repeat(64),
    payload: { body: `synthetic ${id}` },
  }));
  let leases = 0;
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url, body: options?.body ? JSON.parse(options.body) : null });
    if (url.endsWith('/lease')) {
      return leases < jobs.length
        ? response({ leased: true, job: jobs[leases++] })
        : response({ leased: false });
    }
    return response({ jobStatus: url.endsWith('/fail') ? 'failed' : 'done' });
  };
  const result = await runWorkerOnce({
    apiBaseUrl: 'http://worker.test',
    workerToken: 'worker-token',
    fetchImpl,
    maxBatch: 2,
    batchWindowMs: 0,
    reserveCapacity: async () => ({ allowed: true }),
    provider: {
      classifyBatch: async () => new Map([['a', []]]),
    },
  });

  assert.equal(result.completed, false);
  assert.equal(result.batchSize, 2);
  assert.equal(calls.filter((call) => call.url.endsWith('/result')).length, 1);
  assert.equal(calls.filter((call) => call.url.endsWith('/fail')).length, 1);
  assert.equal(calls.find((call) => call.url.endsWith('/result')).body.profileId, 'profile-a');
  assert.equal(calls.find((call) => call.url.endsWith('/fail')).body.profileId, 'profile-b');
});

test('Gemini provider automatically rotates to fallback API key on HTTP 429 quota exhaustion', async () => {
  const attempts = [];
  const provider = new GeminiProvider({
    apiKey: 'primary-key',
    fallbackApiKey: 'fallback-lab-key',
    endpointBase: 'https://example.test/models',
    fetchImpl: async (url, options) => {
      const key = options.headers['x-goog-api-key'];
      attempts.push(key);
      if (key === 'primary-key') {
        return response({ error: { message: 'Resource has been exhausted (e.g. check quota).' } }, 429);
      }
      return response({ candidates: [{ content: { parts: [{ text: '{"facts":[]}' }] } }] }, 200);
    },
  });

  const result = await provider.classify({ payload: { sender: 'BANK', body: 'Card XXXX1234 spent Rs 100' } });
  assert.deepEqual(result.facts, []);
  assert.equal(typeof result.decision, 'object');
  assert.deepEqual(attempts, ['primary-key', 'fallback-lab-key']);
  assert.equal(provider.apiKey, 'fallback-lab-key');
});

test('Gemini provider automatically switches to fallback model on HTTP 404 model retirement', async () => {
  const modelsRequested = [];
  const provider = new GeminiProvider({
    apiKey: 'test-key',
    model: 'deprecated-model',
    fallbackModel: 'gemini-flash-lite-latest',
    endpointBase: 'https://example.test/models',
    fetchImpl: async (url) => {
      const modelName = url.split('/models/')[1].split(':')[0];
      modelsRequested.push(modelName);
      if (modelName === 'deprecated-model') {
        return response({ error: { message: 'Model no longer available' } }, 404);
      }
      return response({ candidates: [{ content: { parts: [{ text: '{"facts":[]}' }] } }] }, 200);
    },
  });

  const result = await provider.classify({ payload: { sender: 'BANK', body: 'Spent Rs 100' } });
  assert.deepEqual(result.facts, []);
  assert.equal(typeof result.decision, 'object');
  assert.deepEqual(modelsRequested, ['deprecated-model', 'gemini-flash-lite-latest']);
  assert.equal(provider.model, 'gemini-flash-lite-latest');
});

test('UNIVERSAL_RESPONSE_SCHEMA requires decision and facts', () => {
  assert.deepEqual(UNIVERSAL_RESPONSE_SCHEMA.required, ['decision', 'facts']);
  assert.equal(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.type, 'OBJECT');
  assert.deepEqual(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.required, [
    'topic', 'shouldConsider', 'rejectionReason',
  ]);
  assert.equal(UNIVERSAL_RESPONSE_SCHEMA.properties.facts.type, 'ARRAY');
  assert.ok(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties.topic.enum.includes('telecom_carrier_deduction'));
  assert.ok(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties.topic.enum.includes('loan_upsell_or_offer'));
  assert.ok(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties.topic.enum.includes('otp_or_security_code'));
  assert.ok(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties.topic.enum.includes('pay_later_due_notice'));
  assert.ok(UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties.topic.enum.includes('pay_later_drawdown'));
  assert.equal('summary' in UNIVERSAL_RESPONSE_SCHEMA.properties.decision.properties, false);
});

test('telecom carrier deduction, loan offer, and OTP noise return shouldConsider: false and empty facts', async () => {
  const noiseScenarios = [
    {
      topic: 'telecom_carrier_deduction',
      shouldConsider: false,
      rejectionReason: 'telecom_carrier_deduction',
    },
    {
      topic: 'loan_upsell_or_offer',
      shouldConsider: false,
      rejectionReason: 'loan_upsell',
    },
    {
      topic: 'otp_or_security_code',
      shouldConsider: false,
      rejectionReason: 'security_otp',
    },
  ];

  for (const scenario of noiseScenarios) {
    const provider = new GeminiProvider({
      apiKey: 'test-key',
      fetchImpl: async () => response({
        candidates: [{
          content: {
            parts: [{
              text: JSON.stringify({
                decision: scenario,
                facts: [],
              }),
            }],
          },
        }],
      }),
    });
    const result = await provider.classify({ payload: { sender: 'TEST', body: scenario.topic } });
    assert.equal(result.decision.shouldConsider, false, `${scenario.topic} must have shouldConsider: false`);
    assert.equal(result.decision.topic, scenario.topic);
    assert.equal(result.decision.rejectionReason, scenario.rejectionReason);
    assert.deepEqual(result.facts, [], `${scenario.topic} must have empty facts array`);
  }
});

test('valid spend returns shouldConsider: true and populated facts', async () => {
  const spendDecision = {
    topic: 'card_spend',
    shouldConsider: true,
    rejectionReason: 'none',
  };
  const spendFacts = [
    {
      factType: 'posted_movement',
      payload: {
        amountRole: 'posted',
        entryKind: 'spend',
        amountInr: 2499.0,
        occurredAt: '2026-10-25T00:00:00.000Z',
        instrument: 'credit_card',
        last4: '4002',
        issuerName: 'ICICI Bank',
        merchant: 'Flipkart',
        category: 'online',
        isComplete: true,
        confidence: 0.99,
      },
    },
  ];

  const provider = new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async () => response({
      candidates: [{
        content: {
          parts: [{
            text: JSON.stringify({
              decision: spendDecision,
              facts: spendFacts,
            }),
          }],
        },
      }],
    }),
  });
  const result = await provider.classify({
    payload: { sender: 'ICICIB', body: 'INR 2,499.00 spent on ICICI Bank Credit Card ending XX4002 at FLIPKART' },
  });

  assert.equal(result.decision.shouldConsider, true);
  assert.equal(result.decision.topic, 'card_spend');
  assert.equal(result.decision.rejectionReason, 'none');
  assert.equal(result.facts.length, 1);
  assert.equal(result.facts[0].factType, 'posted_movement');
  assert.equal(result.facts[0].payload.amountInr, 2499.0);
  assert.equal(result.facts[0].payload.merchant, 'Flipkart');
  assert.equal(result.facts[0].payload.category, 'online');
});

test('Pay Later due is a trackable obligation decision, not a loan offer', async () => {
  const decision = {
    topic: 'pay_later_due_notice',
    shouldConsider: true,
    rejectionReason: 'none',
  };
  const facts = [{
    factType: 'bill_obligation',
    payload: {
      amountRole: 'due_total',
      amountDueInr: 5300,
      dueDate: '2026-11-05T00:00:00.000Z',
      billerName: 'Axio Pay Later',
      category: 'emi',
      targetKind: 'utility_or_other_bill',
      isComplete: true,
      confidence: 0.98,
    },
  }];
  const provider = new GeminiProvider({
    apiKey: 'test-key',
    fetchImpl: async () => response({
      candidates: [{ content: { parts: [{ text: JSON.stringify({ decision, facts }) }] } }],
    }),
  });
  const result = await provider.classify({
    payload: {
      sender: 'AXIO',
      body: 'Axio Pay Later: Your bill amount of INR 5,300.00 is due on 05-Nov-2026. Auto debit will be processed on the due date.',
    },
  });
  assert.equal(result.decision.topic, 'pay_later_due_notice');
  assert.equal(result.decision.shouldConsider, true);
  assert.equal(result.facts[0].factType, 'bill_obligation');
  assert.equal(result.facts[0].payload.amountDueInr, 5300);
  assert.equal(result.facts[0].payload.billerName, 'Axio Pay Later');
  assert.equal('summary' in result.decision, false);
});
