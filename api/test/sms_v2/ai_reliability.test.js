"use strict";

// Invented data only. Covers the server side of the 22 Nov 2026 reliability audit that needs no database: the service's
// failure answers, the wait a provider may ask for, the real reason kept on a bad answer, the save that is tried twice,
// and the person's "Try again" endpoint. The SQL (reap counting, the retry and requeue functions) is in ai_reliability_pg.test.js.

const test = require("node:test");
const assert = require("node:assert/strict");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { runWorkerCycle } = require("../../src/sms_v2/jobs/template_worker_main");
const { createPgWorkerStore, providerDelayMs } = require("../../src/sms_v2/template_worker");
const { createAiRetryHandler } = require("../../src/sms_v2/ai_templates");
const { config, template } = require("./fixtures/template_draft");

const env = {
  SMS_V2_AI_SERVICE_URL: "https://ai.internal",
  SMS_V2_AI_SERVICE_TOKEN: "synthetic_service_token_for_testing_only",
};
const promptVersion = "sms-rule-draft-v1.0.0";
const json = (body, options = {}) => Response.json(body, { ...options, headers: { "X-Prompt-Version": promptVersion, ...options.headers } });

function makeStore() {
  const finished = [];
  return {
    finished,
    async claim() { return { ...template }; },
    async settings() {
      return { ai_enabled: true, ai_model: "console-model", ai_max_output_tokens: 128, ai_rpm: 10, ai_tpm: 200000, ai_monthly_budget_usd: 10, ai_use_sample: true };
    },
    async beginAttempt() {},
    async userReports() { return []; },
    async previousMistakes() { return []; },
    async monthSpend() { return 0; },
    async providerFailures() { return 0; },
    async recordAttempt() {},
    async finish(_template, entry) { finished.push(entry); },
  };
}

test("a provider's own wait is passed on but never beyond a day", () => {
  assert.equal(providerDelayMs("", new Headers({ "retry-after": "30" })), 30_000);
  assert.equal(providerDelayMs("", new Headers({ "retry-after": "315360000" })), 86_400_000, "ten years is a day");
  assert.equal(providerDelayMs(JSON.stringify({ error: { details: [{ retryDelay: "99999999s" }] } }), new Headers()), 86_400_000);
});

test("a service that says the layout is too large (413) fails that layout alone and does not rest the worker", async () => {
  const store = makeStore();
  const provider = createAiServiceProvider({ env, fetchImpl: async () => json({ error: { code: "request_too_large" } }, { status: 413 }) });
  const result = await runWorkerCycle({ layoutStore: store, provider, config });
  assert.equal(result.status, "failed");
  assert.equal(store.finished[0].code, "ai_service_layout_too_large");
});

test("a bad answer keeps the reason the service gave instead of 'answer_not_json'", async () => {
  for (const reason of ["truncated", "blocked", "bad_shape"]) {
    const store = makeStore();
    const provider = createAiServiceProvider({
      env,
      fetchImpl: async () => json({ error: { code: "invalid_provider_output", reason } }, { status: 502 }),
    });
    await runWorkerCycle({ layoutStore: store, provider, config });
    assert.deepEqual(store.finished[0].detail, ["json_invalid", reason], reason);
  }
});

test("saving a paid answer is tried once more after a lock timeout, and never twice after another error", async () => {
  const client = { async query() { return { rowCount: 1, rows: [] }; } };
  const transactionFailing = (code) => {
    const calls = { n: 0 };
    return { calls, transaction: async (operation) => {
      calls.n++;
      if (calls.n === 1) throw Object.assign(new Error("boom"), { code });
      return operation(client);
    } };
  };
  const lease = { ...template, lease_id: "lease-1", ai_job_attempts: 1 };
  const transient = transactionFailing("55P03");
  const store = createPgWorkerStore({ transaction: transient.transaction, draftingVersion: null });
  assert.equal(await store.finish(lease, { model: "m", code: "x" }), true);
  assert.equal(transient.calls.n, 2);
  const permanent = transactionFailing("23505");
  const other = createPgWorkerStore({ transaction: permanent.transaction, draftingVersion: null });
  await assert.rejects(other.finish(lease, { model: "m", code: "x" }), { code: "23505" });
  assert.equal(permanent.calls.n, 1);
});

// ---- POST /sms/v2/ai-status/retry
const H = (n) => String(n).padStart(64, "0").replace(/0/g, (_, i) => "abcdef"[i % 6]);
function call(body, { security = {}, store = {} } = {}) {
  const result = {};
  const res = { status(code) { result.status = code; return this; }, json(payload) { result.body = payload; return this; } };
  const retried = [];
  const handler = createAiRetryHandler({
    store: { async retry(profile, hashes) { retried.push([profile, hashes]); return store.retry ? store.retry() : hashes.length; } },
    security: {
      async verifyAttestation() { return security.verify ?? true; },
      async checkRate() { return security.rate ?? true; },
    },
  });
  const req = { userId: "profile-1", body, smsV2Security: { sharedLearningEligible: security.eligible ?? true } };
  return handler(req, res).then(() => ({ ...result, retried }));
}

test("retry: a valid request requeues the person's layouts and answers 202 with how many", async () => {
  const hashes = [H(1), H(2)];
  const out = await call({ templateHashes: hashes });
  assert.equal(out.status, 202);
  assert.deepEqual(out.body, { requeued: 2 });
  assert.deepEqual(out.retried, [["profile-1", hashes]]);
});

test("retry: a malformed request is refused before anything is asked of the database", async () => {
  const good = H(3);
  for (const body of [
    undefined, null, {}, { templateHashes: [] }, { templateHashes: "x" }, { templateHashes: [good, good] },
    { templateHashes: ["abc"] }, { templateHashes: [good.toUpperCase()] }, { templateHashes: [good], extra: 1 },
    { templateHashes: Array.from({ length: 21 }, (_, i) => H(i + 10) + "") }, { templateHashes: [123] },
  ]) {
    const out = await call(body);
    assert.equal(out.status, 400, JSON.stringify(body)?.slice(0, 60));
    assert.deepEqual(out.retried, []);
  }
});

test("retry: attestation, rate limit, consent and database errors have their own answers; an uncounted phone moves nothing", async () => {
  const body = { templateHashes: [H(4)] };
  assert.equal((await call(body, { security: { verify: false } })).status, 403);
  assert.equal((await call(body, { security: { rate: false } })).status, 429);
  const uncounted = await call(body, { security: { eligible: false } });
  assert.deepEqual([uncounted.status, uncounted.body, uncounted.retried], [202, { requeued: 0 }, []]);
  const failing = (code) => call(body, { store: { retry() { throw Object.assign(new Error("db"), { code }); } } });
  assert.equal((await failing("42501")).status, 403);
  assert.equal((await failing("22023")).status, 400);
  assert.equal((await failing("XX000")).status, 503);
});
