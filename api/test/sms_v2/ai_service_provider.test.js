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
    },
    async userReports() {
      assert.fail("service mode should not read correction reports");
    },
    async previousMistakes() {
      assert.fail("service mode should not read admin decisions");
    },
    async providerFailures() {
      assert.fail("service outages must not count against layouts");
    },
    async recordAttempt(_template, _attempt, entry) { attempts.push(entry); },
    async finish(_template, entry) { finished.push(entry); },
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
    assert.equal(new Headers(options.headers).get("x-prompt-version"), promptVersion);
    assert.equal(new Headers(options.headers).get("x-expected-model"), config.model);
    assert.equal(new Headers(options.headers).get("x-expected-max-output-tokens"), String(config.maxOutputTokens));
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
  assert.equal(store.attempts[0].costUsd, 0.0001);
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

test("worker holds mismatched models and incompatible service responses safely", async () => {
  for (const response of [
    serviceJson({ answer: answer(), ...usage, model: "different-model" }),
    serviceJson({ answer: answer(), ...usage, totalTokens: -1 }),
    serviceJson({ error: { code: "wrong_token" } }, { status: 401 }),
    serviceJson({ error: { code: "config_mismatch" } }, { status: 412 }),
    serviceJson({ answer: answer(), ...usage }, { headers: { "X-Prompt-Version": "sms-rule-draft-v2.0.0" } }),
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

test("worker rejects invalid drafts and accounts for billed invalid provider output", async () => {
  const store = makeStore();
  let calls = 0;
  const invalid = answer();
  invalid.emit[0].attrs.direction = "sideways";
  const provider = createAiServiceProvider({ env, fetchImpl: async () => ++calls === 1
    ? serviceJson({ answer: invalid, ...usage })
    : serviceJson({ error: { code: "invalid_provider_output" }, ...usage }, { status: 502 }) });
  assert.equal((await runWorkerCycle({ layoutStore: store, provider, config })).status, "failed");
  assert.equal(store.finished[0].code, "draft_validation_failed");
  assert.deepEqual(store.attempts.map((a) => [a.errorKind, a.costUsd]), [["validation", 0.0001], ["json_invalid", 0.0001]]);
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
