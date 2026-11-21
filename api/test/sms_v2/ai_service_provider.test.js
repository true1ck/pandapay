"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { runWorkerCycle } = require("../../src/sms_v2/jobs/template_worker_main");
const { answer, config, template } = require("./fixtures/template_draft");

const env = {
  SMS_V2_AI_SERVICE_URL: "https://ai.internal",
  SMS_V2_AI_SERVICE_TOKEN: "synthetic_service_token_for_testing_only",
};
const usage = { model: config.model, inputTokens: 20, outputTokens: 30, totalTokens: 60 };
const promptVersion = "sms-rule-draft-v1.0.0";

function serviceJson(body, options = {}) {
  return Response.json(body, { ...options, headers: { "X-Prompt-Version": promptVersion, ...options.headers } });
}

function makeStore() {
  const finished = [];
  const attempts = [];
  return {
    finished,
    attempts,
    async claim() {
      return { ...template, sample: "Rs. 127.45 paid to SOME PERSON." };
    },
    async settings() {
      return {
        ai_enabled: true,
        ai_model: "console-model",
        ai_max_output_tokens: 128,
        ai_rpm: 10,
        ai_tpm: 200000,
        ai_monthly_budget_usd: 10,
        ai_use_sample: true,
      };
    },
    async beginAttempt(_template, _attempt, prompt, attemptConfig) {
      assert.doesNotMatch(prompt, /SOME PERSON/);
      assert.equal(attemptConfig.model, config.model);
      assert.equal(attemptConfig.maxOutputTokens, config.maxOutputTokens);
      assert.equal(attemptConfig.rpm, Infinity); // the service, not the worker, limits its own rate
    },
    async userReports() {
      assert.fail("service mode should not read correction reports");
    },
    async previousMistakes() {
      assert.fail("service mode should not read admin decisions");
    },
    async monthSpend() {
      return 1e9; // a spent budget must not stop service mode: the service owns cost
    },
    async providerFailures() {
      assert.fail("service outages must not count against layouts");
    },
    async recordAttempt(_template, _attempt, entry) { attempts.push(entry); },
    async finish(_template, entry) {
      if (entry.acceptedAttempt) attempts.push(entry.acceptedAttempt.usage);
      finished.push(entry);
    },
  };
}

test("AI service is opt-in and rejects incomplete or invalid service configuration", () => {
  assert.equal(createAiServiceProvider({ env: {} }), null);
  assert.equal(createAiServiceProvider({ env: { SMS_V2_AI_SERVICE_URL: "", SMS_V2_AI_SERVICE_TOKEN: "" } }), null);
  for (const [url, token] of [
    [env.SMS_V2_AI_SERVICE_URL, "too-short"],
    [undefined, env.SMS_V2_AI_SERVICE_TOKEN],
    ["http://ai.internal", env.SMS_V2_AI_SERVICE_TOKEN],
    ["https://name:secret@ai.internal", env.SMS_V2_AI_SERVICE_TOKEN],
    ["https://ai.internal/app", env.SMS_V2_AI_SERVICE_TOKEN],
    ["https://ai.internal?x=1", env.SMS_V2_AI_SERVICE_TOKEN],
  ]) assert.throws(() => createAiServiceProvider({ env: { SMS_V2_AI_SERVICE_URL: url, SMS_V2_AI_SERVICE_TOKEN: token } }), /SMS_V2_AI_SERVICE_/);
  assert.ok(createAiServiceProvider({ env: { ...env, SMS_V2_AI_SERVICE_URL: "http://127.0.0.1:8080" } }));
});

test("worker sends only the layout and accepts a draft after the usual validation and accounting", async () => {
  const store = makeStore();
  const logs = [];
  let requestId;
  const provider = createAiServiceProvider({ env, logger: (entry) => logs.push(entry), fetchImpl: async (url, options) => {
    assert.equal(String(url), "https://ai.internal/v1/sms-rule-drafts");
    assert.equal(options.method, "POST");
    assert.equal(options.redirect, "error");
    assert.equal(new Headers(options.headers).get("authorization"), `Bearer ${env.SMS_V2_AI_SERVICE_TOKEN}`);
    requestId = new Headers(options.headers).get("x-request-id");
    assert.match(requestId, /^[0-9a-f-]{36}$/);
    // No model, output cap or prompt version is sent unless a version is pinned: the service owns them.
    for (const name of ["x-prompt-version", "x-expected-model", "x-expected-max-output-tokens"])
      assert.equal(new Headers(options.headers).get(name), null);
    assert.deepEqual(JSON.parse(options.body), { senderBrand: template.sender_brand, redactedBody: template.redacted_body });
    return serviceJson({ answer: answer(), ...usage });
  } });
  const result = await runWorkerCycle({ layoutStore: store, provider, config });
  assert.equal(result.status, "ready");
  assert.equal(store.finished[0].rule.status, "provisional");
  assert.equal(store.finished[0].rule.createdBy, `ai:${config.model}`);
  assert.equal(store.attempts[0].outcome, "valid");
  assert.equal(store.attempts[0].promptVersion, promptVersion);
  assert.equal(store.attempts[0].totalTokens, 60);
  assert.equal(store.attempts[0].costUsd, null);
  assert.deepEqual(logs, [{ event: "sms_v2_ai_service_request", entryPoint: "template_worker", requestId, outcome: "ok", httpStatus: 200, latencyMs: logs[0].latencyMs }]);
  assert.ok(Number.isInteger(logs[0].latencyMs));
});

test("worker requeues service outages with Retry-After and resumes when available", async () => {
  let down = true;
  const store = makeStore();
  const provider = createAiServiceProvider({ env, fetchImpl: async () => down
    ? serviceJson({ error: { code: "provider_unavailable" } }, { status: 503, headers: { "Retry-After": "21" } })
    : serviceJson({ answer: answer(), ...usage }) });
  const first = await runWorkerCycle({ layoutStore: store, provider, config });
  assert.equal(first.status, "provider_busy");
  assert.equal(first.retryAfterMs, 21000);
  assert.equal(store.finished[0].requeue, true);
  assert.equal(store.attempts[0].errorKind, "systemic");
  down = false;
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
});

test("ordered routing resumes after a backend-rejected draft on the capability-only endpoint", async () => {
  const store = makeStore();
  store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 1, ai_excluded_providers: ["experiential"] });
  const calls = [];
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (url, options) => {
      const headers = new Headers(options.headers);
      calls.push({
        path: url.pathname, after: headers.get("x-ai-after-provider"), skip: headers.get("x-ai-skip-providers"),
        timeout: Number(headers.get("x-ai-timeout-ms")),
      });
      const draft = answer();
      if (calls.length === 1) draft.emit[0].attrs.direction = "sideways";
      const identity = calls.length === 1
        ? { provider: "gemini", model: config.model }
        : { provider: "groq", model: "openai/gpt-oss-20b" };
      return serviceJson({ answer: draft, ...usage, ...identity, routeHadInfrastructureFailure: false }, {
        headers: { "x-ai-routing": "ordered-v1" },
      });
    },
  });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.finished[0].model, "openai/gpt-oss-20b");
  assert.deepEqual(store.attempts.map((entry) => [entry.outcome, entry.totalTokens, entry.costUsd]), [
    // A rejected draft was billed: its tokens are recorded (outcome stays "rejected", not "valid"); the service owns the price.
    ["rejected", 60, null],
    ["valid", 60, null],
  ]);
  assert.deepEqual(calls.map(({ path, after, skip }) => [path, after, skip]), [
    ["/v1/sms-rule-drafts/ordered", null, "experiential"],
    ["/v1/sms-rule-drafts/ordered", "gemini", "experiential"],
  ]);
  assert.ok(calls[0].timeout > 0 && calls[0].timeout <= 90000);
  assert.ok(calls[1].timeout <= calls[0].timeout);
});

test("an infrastructure failure earlier in the route stays retryable after all remaining candidates fail", async () => {
  const store = makeStore();
  store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 3 });
  const calls = [];
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, { headers }) => {
      calls.push(new Headers(headers));
      const options = { headers: { "x-ai-routing": "ordered-v1" } };
      if (calls.length === 2) {
        return serviceJson({ error: { code: "invalid_provider_output" } }, { ...options, status: 502 });
      }
      const badDraft = answer();
      badDraft.emit[0].attrs.direction = "sideways";
      return serviceJson({
        ...usage, answer: badDraft, provider: "groq", model: "openai/gpt-oss-20b", routeHadInfrastructureFailure: true,
      }, options);
    },
  });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "retry_scheduled");
  assert.equal(calls[1].get("x-ai-prior-unavailable"), "true");
  assert.equal(store.finished[0].retryKind, "infrastructure");
});

test("a service that does not speak ordered routing is the last route: its rejected draft is a content failure", async () => {
  for (const legacyDraft of [true, false]) {
    const store = makeStore();
    store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 3 });
    const draft = answer();
    draft.emit[0].attrs.direction = "sideways";
    const provider = createAiServiceProvider({
      env,
      fetchImpl: async () => legacyDraft
        ? serviceJson({ ...usage, answer: draft })
        : serviceJson({ error: { code: "invalid_provider_output" } }, { status: 502 }),
    });
    const result = await runWorkerCycle({ layoutStore: store, provider, config });
    assert.equal(result.status, "failed");
    assert.equal(store.finished[0].retryKind, "content");
  }
});

test("worker holds mismatched models and incompatible service responses safely", async () => {
  for (const response of [
    serviceJson({ answer: answer(), ...usage, model: "bad model!" }),
    serviceJson({ error: { code: "bad_gateway_timeout" } }, { status: 524 }),
    serviceJson({ answer: answer(), ...usage, totalTokens: -1 }),
    serviceJson({ error: { code: "wrong_token" } }, { status: 401 }),
    serviceJson({ error: { code: "config_mismatch" } }, { status: 412 }),
  ]) {
    const store = makeStore();
    const provider = createAiServiceProvider({ env, fetchImpl: async () => response });
    assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "provider_busy");
    assert.equal(store.finished[0].requeue, true);
    assert.equal(store.attempts[0].costUsd, null);
  }
});

test("a configured prompt version is sent and recorded for the matching service response", async () => {
  const store = makeStore();
  const customVersion = "sms-rule-draft-v2.0.0";
  const provider = createAiServiceProvider({
    env: { ...env, SMS_V2_AI_SERVICE_PROMPT_VERSION: customVersion },
    fetchImpl: async (_url, options) => {
      assert.equal(new Headers(options.headers).get("x-prompt-version"), customVersion);
      return serviceJson({ answer: answer(), ...usage }, { headers: { "X-Prompt-Version": customVersion } });
    },
  });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.attempts[0].promptVersion, customVersion);
});

test("worker rejects an invalid draft after one paid call and books its tokens (a retry would repeat the same request)", async () => {
  const store = makeStore();
  let calls = 0;
  const invalid = answer();
  invalid.emit[0].attrs.direction = "sideways";
  const provider = createAiServiceProvider({ env, fetchImpl: async () => (++calls, serviceJson({ answer: invalid, ...usage })) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "failed");
  assert.equal(store.finished[0].code, "draft_validation_failed");
  assert.equal(calls, 1);
  // The rejected draft was billed: its tokens are kept; the service owns the price, so the cost stays empty.
  assert.deepEqual(store.attempts.map((a) => [a.errorKind, a.totalTokens, a.costUsd]), [["validation", 60, null]]);
});

test("worker accounts for billed invalid provider output", async () => {
  const store = makeStore();
  let calls = 0;
  const provider = createAiServiceProvider({ env, fetchImpl: async () => (++calls,
    serviceJson({ error: { code: "invalid_provider_output" }, ...usage }, { status: 502 })) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "failed");
  assert.equal(calls, 1);
  assert.deepEqual(store.attempts.map((a) => [a.errorKind, a.totalTokens, a.costUsd]), [["json_invalid", 60, null]]);
});

test("unsafe sender and wording cannot cross the service boundary", async () => {
  for (const change of [{ sender_brand: "9876543210" }, { redacted_body: "<AMT> paid to <PARTY> at 1234." }]) {
    const store = makeStore();
    store.claim = async () => ({ ...template, ...change });
    const provider = createAiServiceProvider({ env, fetchImpl: async () => assert.fail("private layout was sent") });
    assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "failed");
    assert.equal(store.finished[0].code, "ai_service_invalid_layout");
    assert.equal(store.attempts.length, 0);
  }
});

test("service rejection of a layout is terminal and lets the worker move on", async () => {
  const store = makeStore();
  const provider = createAiServiceProvider({ env, fetchImpl: async () =>
    serviceJson({ error: { code: "invalid_layout" } }, { status: 422 }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "failed");
  assert.equal(store.finished[0].code, "ai_service_invalid_layout");
  assert.equal(store.attempts.length, 1);
});

test("layout-only service cannot be used for merchant suggestions", async () => {
  const provider = createAiServiceProvider({ env, fetchImpl: async () => assert.fail("no request") });
  const result = await runWorkerCycle({
    layoutStore: { claim: async () => null },
    suggestionStore: { settings: async () => assert.fail("no merchant lookup") },
    provider,
    config,
  });
  assert.deepEqual(result, { status: "idle" });
});

test("a fallback AI may answer: its model is accepted and recorded, and cost is not guessed", async () => {
  const store = makeStore();
  const provider = createAiServiceProvider({ env, fetchImpl: async () => serviceJson({ answer: answer(), ...usage, model: "openai/gpt-oss-20b" }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.finished[0].model, "openai/gpt-oss-20b");
  assert.equal(store.finished[0].rule.createdBy, "ai:openai/gpt-oss-20b");
  assert.equal(store.attempts[0].costUsd, null);
});

test("a timeout puts the layout back in the queue and is named as a timeout", async () => {
  const store = makeStore();
  const logs = [];
  const provider = createAiServiceProvider({
    env,
    logger: (entry) => logs.push(entry),
    fetchImpl: async () => { throw new DOMException("timed out", "TimeoutError"); },
  });
  const result = await runWorkerCycle({ layoutStore: store, provider, config });
  assert.equal(result.status, "provider_busy");
  assert.equal(store.finished[0].requeue, true);
  assert.equal(logs[0].outcome, "ai_service_timeout");
});

test("the wait is configurable (5-170 s, default 100 s) and every request carries an idempotency key", async () => {
  for (const bad of ["1000", "171000", "abc"])
    assert.throws(() => createAiServiceProvider({ env: { ...env, SMS_V2_AI_SERVICE_TIMEOUT_MS: bad } }), /TIMEOUT_MS_invalid/);
  let key;
  const provider = createAiServiceProvider({
    env: { ...env, SMS_V2_AI_SERVICE_TIMEOUT_MS: "150000" },
    fetchImpl: async (_url, options) => {
      key = new Headers(options.headers).get("x-idempotency-key");
      return serviceJson({ answer: answer(), ...usage });
    },
  });
  await runWorkerCycle({ layoutStore: makeStore(), provider, config });
  assert.match(key, /^[a-f0-9]{64}$/);
});

test("an unpinned prompt version is accepted and recorded; a pinned one must match", async () => {
  const store = makeStore();
  const unpinned = createAiServiceProvider({ env, fetchImpl: async () => serviceJson({ answer: answer(), ...usage }, { headers: { "X-Prompt-Version": "sms-rule-draft-v9.9.9" } }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider: unpinned, config })).status, "ready");
  assert.equal(store.attempts[0].promptVersion, "sms-rule-draft-v9.9.9");
  assert.equal(unpinned.promptVersion, "sms-rule-draft-v9.9.9");
  const pinned = createAiServiceProvider({
    env: { ...env, SMS_V2_AI_SERVICE_PROMPT_VERSION: "sms-rule-draft-v1.0.0" },
    fetchImpl: async () => serviceJson({ answer: answer(), ...usage }, { headers: { "X-Prompt-Version": "sms-rule-draft-v2.0.0" } }),
  });
  const held = makeStore();
  assert.equal((await runWorkerCycle({ layoutStore: held, provider: pinned, config })).status, "provider_busy");
  assert.equal(held.finished[0].requeue, true);
});

test("provider model ids with an @ prefix (Cloudflare) are accepted and recorded", async () => {
  const store = makeStore();
  const model = "@cf/meta/llama-3.1-8b-instruct";
  const provider = createAiServiceProvider({ env, fetchImpl: async () => serviceJson({ answer: answer(), ...usage, model, provider: "cloudflare", routeHadInfrastructureFailure: false }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.finished[0].model, model);
});

test("isUp asks the service's /healthz, without the token, and is true only for a 200", async () => {
  const seen = [];
  const make = (answer) => createAiServiceProvider({ env, fetchImpl: async (url, options = {}) => {
    seen.push({ url: String(url), headers: options.headers ?? {} });
    if (answer instanceof Error) throw answer;
    return new Response("ok", { status: answer });
  } });
  assert.equal(await make(200).isUp(), true);
  assert.equal(new URL(seen[0].url).pathname, "/healthz");
  assert.equal(new URL(seen[0].url).origin, new URL(env.SMS_V2_AI_SERVICE_URL).origin);
  assert.equal(JSON.stringify(seen[0].headers).includes(env.SMS_V2_AI_SERVICE_TOKEN), false, "the token is never sent to the health check");
  assert.equal(await make(503).isUp(), false);
  assert.equal(await make(404).isUp(), false);
  assert.equal(await make(new Error("ECONNRESET")).isUp(), false);
});

// 21 Nov 2026: after Gemini's draft was rejected the worker asked for "a later route than gemini". The service had only
// Gemini, so it answered 502 invalid_provider_output at once with nothing billed, and that was stored as "answer_not_json"
// (23 attempts, 272 ms each, 0 tokens). It is the service saying there is no route left, not a model that wrote bad JSON.
test("a routed call with no route left is named so, not stored as a bad JSON answer", async () => {
  const store = makeStore();
  store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 1 });
  let calls = 0;
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async () => {
      calls += 1;
      const options = { headers: { "x-ai-routing": "ordered-v1" } };
      if (calls === 1) {
        const draft = answer();
        draft.emit[0].attrs.direction = "sideways";
        return serviceJson({ answer: draft, ...usage, provider: "gemini", model: config.model, routeHadInfrastructureFailure: false }, options);
      }
      return serviceJson({ error: { code: "invalid_provider_output" } }, { ...options, status: 502 });
    },
  });
  await runWorkerCycle({ layoutStore: store, provider, config });
  const noRoute = store.attempts.find((entry) => entry.errorKind === "no_route_left");
  assert.ok(noRoute, `attempts: ${JSON.stringify(store.attempts.map((a) => [a.outcome, a.errorKind, a.errorCodes]))}`);
  assert.deepEqual(noRoute.errorCodes, ["ai_service_no_route_left"]);
  assert.equal(store.attempts.some((entry) => entry.errorCodes?.includes("answer_not_json")), false);
});

test("a real bad-JSON answer (a draft was billed) is still stored as one", async () => {
  const store = makeStore();
  store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 3 });
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async () => serviceJson({ error: { code: "invalid_provider_output" }, ...usage }, { status: 502, headers: { "x-ai-routing": "ordered-v1" } }),
  });
  await runWorkerCycle({ layoutStore: store, provider, config });
  assert.ok(store.attempts.some((entry) => entry.errorKind === "json_invalid" && entry.errorCodes?.includes("answer_not_json")));
});

test("the service's own error code is logged when it answers an error, so an outage can be told from a bad key or model", async () => {
  const logs = [];
  const provider = createAiServiceProvider({
    env,
    logger: (entry) => logs.push(entry),
    fetchImpl: async () => Response.json({ error: { code: "provider_misconfigured" } }, { status: 503, headers: { "Retry-After": "300" } }),
  });
  await assert.rejects(provider.generateLayout({ senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." }), /ai_service_unavailable/);
  assert.equal(logs.at(-1).httpStatus, 503);
  assert.equal(logs.at(-1).serviceError, "provider_misconfigured");
  assert.equal(JSON.stringify(logs).includes(env.SMS_V2_AI_SERVICE_TOKEN), false);
});

test("a draft that needed a repair is accepted, and the attempt records which repair (so its effect can be measured)", async () => {
  const store = makeStore();
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async () => {
      const draft = answer();
      draft.emit[0].references = { txnId: "ghost1" }; // a slot the layout does not have
      return serviceJson({ answer: draft, ...usage });
    },
  });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.finished[0].rule.emit[0].references, undefined, "the reference to a slot that is not there was dropped");
  const valid = store.attempts.find((entry) => entry.outcome === "valid");
  assert.deepEqual(valid.errorCodes, ["repaired_reference"]);
  assert.equal(valid.errorKind, null);
});

test("a draft that needed no repair records nothing extra", async () => {
  const store = makeStore();
  const provider = createAiServiceProvider({ env, fetchImpl: async () => serviceJson({ answer: answer(), ...usage }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(store.attempts.find((entry) => entry.outcome === "valid").errorCodes, null);
});

// Feedback to the AI (owner, 21 Nov 2026): a retry used to carry nothing about why the last draft was refused. The service
// takes only {senderBrand, redactedBody} today (it answers 422 to anything else), so the validator's codes are sent as an
// optional `fix` field ONLY after the service has announced `x-ai-features: fix-v1`. Either side can be deployed first.
test("feedback codes are sent only once the service has announced it understands them", async () => {
  const bodies = [];
  let announce = false;
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return serviceJson({ answer: answer(), ...usage }, { headers: announce ? { "x-ai-features": "other-feature, fix-v1" } : {} });
    },
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  const fix = ["emitted_attrs_invalid", "attrs_balance_snapshot/asOf: pattern"];
  await provider.generateLayout({ ...layout, fix });
  assert.deepEqual(Object.keys(bodies[0]).sort(), ["redactedBody", "senderBrand"], "an older service never sees the extra field");
  announce = true;
  await provider.generateLayout({ ...layout });
  assert.deepEqual(Object.keys(bodies[1]).sort(), ["redactedBody", "senderBrand"], "no codes, no field");
  await provider.generateLayout({ ...layout, fix });
  assert.deepEqual(bodies[2].fix, fix);
});

test("only well-formed codes are sent, at most 8, each at most 160 characters", async () => {
  const bodies = [];
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return serviceJson({ answer: answer(), ...usage }, { headers: { "x-ai-features": "fix-v1" } });
    },
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  await provider.generateLayout(layout); // learns the feature
  const long = `slot_not_in_layout: ${"x".repeat(200)}`;
  const codes = ["capture_group_missing", "has a secret: Rs 5,000 to RAHUL", "ok_code", long, "example_mismatch", ...Array.from({ length: 10 }, (_, i) => `code_${i}`)];
  await provider.generateLayout({ ...layout, fix: codes });
  const sent = bodies.at(-1).fix;
  assert.ok(sent.length <= 8);
  assert.ok(sent.every((code) => code.length <= 160 && /^[a-z][a-z0-9_]*/.test(code)));
  assert.ok(!sent.some((code) => /RAHUL|Rs 5/.test(code)), "a code with message-like text is never sent");
  assert.ok(sent.includes("capture_group_missing") && sent.includes("example_mismatch"));
});

test("the worker passes the last refusal to the next call", async () => {
  const store = makeStore();
  store.claim = async () => ({ ...template, ai_drafting_version: "test-v1", ai_job_attempts: 1 });
  const bodies = [];
  let call = 0;
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      call += 1;
      const draft = answer();
      if (call === 1) draft.emit[0].attrs.direction = "sideways";
      return serviceJson({ answer: draft, ...usage, provider: "gemini", model: config.model, routeHadInfrastructureFailure: false }, { headers: { "x-ai-routing": "ordered-v1", "x-ai-features": "fix-v1" } });
    },
  });
  await runWorkerCycle({ layoutStore: store, provider, config });
  assert.equal(bodies[0].fix, undefined, "the first call has nothing to correct");
  assert.ok(Array.isArray(bodies[1]?.fix) && bodies[1].fix.length > 0, `second body: ${JSON.stringify(bodies[1])}`);
});

// 21 Nov 2026: a layout holding a literal "@handle" or a long mixed ID was refused by the service (422 invalid_layout) or
// drafted with the ID as a "slot". The worker now cleans the layout first (draft_layout.js): the service and the AI see the
// cleaned layout, the rule is built from it, and the template hash stays that of the original.
test("a layout with an @handle is cleaned before the service sees it, and the format is drafted", async () => {
  const store = makeStore();
  const original = "<AMT> paid to <PARTY> at @Shop_<PARTY>.";
  store.claim = async () => ({ ...template, redacted_body: original });
  const seen = [];
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => { seen.push(JSON.parse(options.body)); return serviceJson({ answer: answer(), ...usage }); },
  });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "ready");
  assert.equal(seen[0].redactedBody, "<AMT> paid to <PARTY> at <W>.");
  assert.ok(!/@/.test(seen[0].redactedBody));
  const rule = store.finished[0].rule;
  assert.equal(rule.match.templateHash, template.template_hash, "the hash is still the original layout's");
  assert.ok(new RegExp(rule.match.pattern, rule.match.flags).test("Rs. 10 paid to RAHUL at @Shop_Name."));
});

// 21 Nov 2026: the validator's own codes carry an array index ("emit[0].instrument.maskFrom"), and the first version of the
// filter did not allow brackets, so the most useful feedback (a slot of the wrong kind) was silently dropped before it was sent.
test("the validator's real codes, brackets included, are sent as they are", async () => {
  const { sanityErrors } = require("../../src/sms_v2/draft_sanity");
  const emit = [{
    factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" },
    amounts: [{ role: "posted", from: "amt1", unit: "INR" }],
    instrument: { kind: "bank_account", maskFrom: "party1" }, counterparty: { nameFrom: "amt1" },
  }];
  const real = sanityErrors({ emit }, "<AMT> debited from A/c <PARTY> on <DATE>.");
  assert.ok(real.length >= 2 && real.every((code) => code.includes("emit[0]")), real.join(" | "));
  const bodies = [];
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => {
      bodies.push(JSON.parse(options.body));
      return serviceJson({ answer: answer(), ...usage }, { headers: { "x-ai-features": "fix-v1" } });
    },
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  await provider.generateLayout({ ...layout });
  await provider.generateLayout({ ...layout, fix: real });
  assert.deepEqual(bodies[1].fix, real);
});

// A route that answered with a draft the checker refused is asked AGAIN with the reasons (the service's `x-ai-rerun`),
// but only a service that announced it can do that; otherwise the old rule stands: the cursor means a LATER route.
test("a rerun is requested only of a service that announced it, and its same-route answer is accepted", async () => {
  const sent = [];
  let features = "fix-v1";
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async (_url, options) => {
      sent.push({ headers: options.headers, body: JSON.parse(options.body) });
      return serviceJson({ answer: answer(), provider: "gemini", routeHadInfrastructureFailure: false, ...usage }, { headers: { "x-ai-routing": "ordered-v1", "x-ai-features": features } });
    },
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  const routing = { afterProvider: "gemini", skipProviders: [], timeoutMs: 1000 };
  const fix = ["amount_missing"];
  // Not yet announced (and only fix-v1 is): a plain later-route call. The old service would answer a later route.
  await assert.rejects(provider.generateLayout({ ...layout, fix, routing: { ...routing, rerun: true } }), { message: "ai_service_route_mismatch" });
  assert.equal(sent[0].headers["X-AI-Rerun"], undefined);
  features = "fix-v1,rerun-v1";
  await provider.generateLayout({ ...layout }); // any answer teaches the worker what the service can do
  const again = await provider.generateLayout({ ...layout, fix, routing: { ...routing, rerun: true } });
  assert.equal(sent[2].headers["X-AI-Rerun"], "true");
  assert.equal(again.routeProvider, "gemini", "the same route answered again: not a mismatch when a rerun was asked");
  assert.notEqual(sent[2].headers["X-Idempotency-Key"], sent[0].headers["X-Idempotency-Key"]);
  // Without a rerun the same answer is still a mismatch.
  await assert.rejects(provider.generateLayout({ ...layout, fix, routing }), { message: "ai_service_route_mismatch" });
  assert.equal(sent[3].headers["X-AI-Rerun"], undefined);
  // No codes to send, nothing to re-ask with.
  await assert.rejects(provider.generateLayout({ ...layout, routing: { ...routing, rerun: true } }), { message: "ai_service_route_mismatch" });
  assert.equal(sent[4].headers["X-AI-Rerun"], undefined);
});

test("a service that names 'no route left' is believed, with or without usage", async () => {
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async () => serviceJson({ error: { code: "invalid_provider_output", reason: "no_route_left" }, ...usage }, { status: 502, headers: { "x-ai-routing": "ordered-v1" } }),
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  await assert.rejects(provider.generateLayout({ ...layout, routing: { afterProvider: "gemini", skipProviders: [], timeoutMs: 1000 } }), (error) => error.noRouteLeft === true);
});

test("a service that names a real bad answer is never taken for 'no route left'", async () => {
  const provider = createAiServiceProvider({
    env,
    fetchImpl: async () => serviceJson({ error: { code: "invalid_provider_output", reason: "truncated" } }, { status: 502, headers: { "x-ai-routing": "ordered-v1" } }),
  });
  const layout = { senderBrand: "TESTBK", redactedBody: "<AMT> paid to <PARTY>." };
  await assert.rejects(provider.generateLayout({ ...layout, routing: { afterProvider: "gemini", skipProviders: [], timeoutMs: 1000 } }), (error) => error.noRouteLeft === false && error.serviceReason === "truncated");
});
