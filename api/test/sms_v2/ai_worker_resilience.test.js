"use strict";

// In-memory companions to ai_worker_resilience_pg.test.js: what the worker asks its store to do (the SQL
// outcome is proven in the PostgreSQL file).
const test = require("node:test");
const assert = require("node:assert/strict");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { runTemplateWorkerOnce } = require("../../src/sms_v2/template_worker");
const { backoffMs } = require("../../src/sms_v2/jobs/worker_resilience");
const { answer, config, template } = require("./fixtures/template_draft");

const env = { SMS_V2_AI_SERVICE_URL: "https://ai.internal", SMS_V2_AI_SERVICE_TOKEN: "synthetic_service_token_for_testing_only" };
const usage = { model: config.model, inputTokens: 20, outputTokens: 30, totalTokens: 60 };
const promptVersion = "sms-rule-draft-v1.0.0";
const json = (body, options = {}) => Response.json(body, { ...options, headers: { "X-Prompt-Version": promptVersion, ...options.headers } });

function durableStore(claimed = {}, { capacityAt = 0 } = {}) {
  const finished = [];
  return {
    finished,
    async claim() {
      return { ...template, ai_drafting_version: "v1", ai_job_attempts: 1, ai_counted_jobs: 0, ai_excluded_providers: [], lease_id: "lease", ...claimed };
    },
    async settings() {
      return { ai_enabled: true, ai_model: "m", ai_max_output_tokens: 128, ai_rpm: 10, ai_tpm: 200000, ai_monthly_budget_usd: 10, ai_use_sample: false };
    },
    async beginAttempt(_t, attempt) { return attempt === capacityAt ? "capacity" : null; },
    async recordAttempt() {},
    async finish(_t, entry) { finished.push(entry); return true; },
  };
}

const run = (store, provider, extra = {}) => runTemplateWorkerOnce({ store, provider, config, ...extra });

test("a cycle that throws is backed off 5 s, doubling (the shared resilient loop, not a worker-local copy)", () => {
  assert.deepEqual([1, 2, 3, 4].map((n) => backoffMs(n, { random: () => 0.5 })), [5000, 10000, 20000, 40000]);
});

test("a misconfigured service hands the attempt back and rests the worker; an outage keeps the attempt spent", async () => {
  for (const [status, kind, rescheduled] of [[401, "refund", false], [409, "refund", false], [412, "refund", false], [503, "infrastructure", true]]) {
    const store = durableStore();
    const provider = createAiServiceProvider({ env, fetchImpl: async () => json({ error: { code: "x" } }, { status }) });
    const result = await run(store, provider);
    assert.equal(store.finished[0].retryKind, kind, String(status));
    assert.equal(result.rescheduled, rescheduled, String(status));
    assert.equal(result.status, "provider_busy");
  }
});

test("a capacity block hands the attempt back on any try", async () => {
  for (const attempt of [1, 2, 3]) {
    const store = durableStore({}, { capacityAt: attempt });
    const bad = answer();
    bad.emit[0].attrs.direction = "sideways";
    const provider = createAiServiceProvider({
      env,
      fetchImpl: async (_url, { headers }) => new Headers(headers).get("x-ai-after-provider") === null
        ? json({ answer: bad, ...usage, provider: "gemini", routeHadInfrastructureFailure: false }, { headers: { "x-ai-routing": "ordered-v1" } })
        : json({ answer: bad, ...usage, provider: "groq", model: "openai/gpt-oss-20b", routeHadInfrastructureFailure: false }, { headers: { "x-ai-routing": "ordered-v1" } }),
    });
    assert.equal((await run(store, provider)).status, "capacity");
    assert.equal(store.finished.at(-1).retryKind, "capacity", `attempt ${attempt}`);
  }
});

test("a layout whose jobs keep ending in provider trouble fails on the third exhausted cycle", async () => {
  const bad = answer();
  bad.emit[0].attrs.direction = "sideways";
  for (const [counted, expected] of [[0, "retry_scheduled"], [1, "retry_scheduled"], [2, "failed"]]) {
    const store = durableStore({ ai_job_attempts: 3, ai_counted_jobs: counted });
    const provider = createAiServiceProvider({
      env, fetchImpl: async (_url, { headers }) => new Headers(headers).get("x-ai-after-provider") === null
        ? json({ answer: bad, ...usage, provider: "gemini", routeHadInfrastructureFailure: true }, { headers: { "x-ai-routing": "ordered-v1" } })
        : json({ error: { code: "invalid_provider_output" } }, { status: 502, headers: { "x-ai-routing": "ordered-v1" } }),
    });
    const result = await run(store, provider);
    assert.equal(result.status, expected, `counted ${counted}`);
    assert.equal(store.finished.at(-1).retryKind, "infrastructure");
    assert.equal(store.finished.at(-1).evidence, true);
  }
});

test("shutdown aborts the provider call and hands the attempt back", async () => {
  const store = durableStore();
  const shutdown = new AbortController();
  let started;
  const sent = new Promise((resolve) => { started = resolve; });
  const provider = createAiServiceProvider({
    env,
    fetchImpl: (_url, { signal }) => new Promise((_resolve, reject) => {
      started();
      signal.addEventListener("abort", () => reject(signal.reason ?? new DOMException("aborted", "AbortError")));
    }),
  });
  const running = run(store, provider, { shutdown: shutdown.signal });
  await sent;
  shutdown.abort();
  assert.equal((await running).status, "shutdown");
  assert.equal(store.finished[0].retryKind, "refund");
  assert.equal(store.finished[0].code, "worker_interrupted");
});

test("providers excluded by earlier retries are skipped unless that would skip every route the service has answered with", async () => {
  const seen = [];
  const fetchImpl = async (url, { headers }) => {
    const h = new Headers(headers);
    seen.push([new URL(url).pathname, h.get("x-ai-skip-providers")]);
    return json({ answer: answer(), ...usage, provider: "groq", model: "openai/gpt-oss-20b", routeHadInfrastructureFailure: false }, { headers: { "x-ai-routing": "ordered-v1" } });
  };
  const provider = createAiServiceProvider({ env, fetchImpl });
  await run(durableStore({ ai_excluded_providers: ["gemini"] }), provider); // answered by groq: the service has groq
  await run(durableStore({ ai_excluded_providers: ["groq"] }), provider); // every route seen (groq) excluded: start again
  assert.deepEqual(seen, [["/v1/sms-rule-drafts/ordered", "gemini"], ["/v1/sms-rule-drafts", null]]);
});
