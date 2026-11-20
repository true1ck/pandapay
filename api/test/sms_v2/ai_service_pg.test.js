"use strict";

// Runs in the disposable, fully migrated cluster provisioned by
// scripts/test_postgres_suites.sh. Never use the loop harness on live data.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createServer } = require("node:http");
const { once } = require("node:events");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { createPgWorkerStore, runTemplateWorkerOnce } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");
const { template, config, answer } = require("./fixtures/template_draft");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const token = "synthetic_database_service_token_for_testing";
const promptVersion = "sms-rule-draft-v1.0.0";

async function setup(t, respond, draftingVersion) {
  // This harness clears shared SMS tables, so require the throwaway loopback DB.
  for (const key of ["SMS_V2_TEST_DATABASE_URL", "SMS_V2_TEST_ADMIN_DATABASE_URL", "SMS_V2_TEST_AI_WORKER_DATABASE_URL"]) {
    const url = new URL(process.env[key]);
    assert.ok(["localhost", "127.0.0.1", "[::1]"].includes(url.hostname), `${key} must use a local test cluster`);
    assert.match(url.pathname, /test|suites/i, `${key} must name a test database`);
  }
  const rig = await startLoopHarness({ profileCount: 2, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const worker = createPgWorkerStore({ transaction: opened.transaction, draftingVersion });
  const requests = [];
  const server = createServer(async (request, response) => {
    try {
      const resume = request.headers["x-ai-after-provider"] || request.headers["x-ai-skip-providers"];
      assert.equal(request.url, resume ? "/v1/sms-rule-drafts/ordered" : "/v1/sms-rule-drafts");
      assert.equal(request.headers.authorization, `Bearer ${token}`);
      assert.equal(request.headers["x-expected-model"], undefined);
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      assert.deepEqual(body, { senderBrand: template.sender_brand, redactedBody: template.redacted_body });
      requests.push(body);
      await respond({ request, response, rig });
    } catch (error) {
      response.writeHead(500, { "content-type": "application/json" });
      response.end(JSON.stringify({ error: { code: "test_server_failed" } }));
      t.diagnostic(error.stack);
    }
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  t.after(async () => {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  });
  const provider = createAiServiceProvider({ env: {
    SMS_V2_AI_SERVICE_URL: `http://127.0.0.1:${server.address().port}`,
    SMS_V2_AI_SERVICE_TOKEN: token,
  } });
  for (const id of rig.profiles) await rig.consent(id, true);
  const item = {
    templateHash: template.template_hash,
    senderBrand: template.sender_brand,
    redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(),
    sample: "Rs.4821.50 paid to LOCAL WORDING ONLY.",
  };
  assert.equal((await rig.asUser(rig.profiles[0]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);
  const row = async () => (await rig.pool.query(
    "SELECT ai_status,ai_draft,lease_id,failure_code,sample FROM sms_v2_unknown_templates WHERE template_hash=$1",
    [template.template_hash],
  )).rows[0];
  return { rig, worker, provider, requests, row,
    workerFor: (version) => createPgWorkerStore({ transaction: opened.transaction, draftingVersion: version }) };
}

test("durable jobs count claims, jitter retries, and exclude outage exhaustion from the layout cap", { skip }, async (t) => {
  let online = false;
  const { rig, worker, provider, row } = await setup(t, ({ response }) => {
    if (online) return ready(response);
    response.writeHead(503, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { code: "provider_unavailable" } }));
  }, "routing-v1");
  const cycle = () => runTemplateWorkerOnce({ store: worker, provider, config });
  const makeDue = () => rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
  const schedule = async () => (await rig.pool.query(
    "SELECT ai_job_attempts,ai_counted_jobs,extract(epoch FROM ai_run_after-clock_timestamp())::integer AS seconds FROM sms_v2_unknown_templates",
  )).rows[0];
  assert.equal((await cycle()).status, "idle");
  for (const [number, min, max] of [[1, 239, 361], [2, 1439, 2161], [3, 86399, 86401]]) {
    await makeDue();
    const retry = await cycle();
    assert.equal(retry.status, "provider_busy");
    assert.equal(retry.rescheduled, true);
    const state = await schedule();
    assert.equal(state.ai_job_attempts, number);
    assert.equal(state.ai_counted_jobs, 0);
    assert.ok(state.seconds >= min && state.seconds <= max, JSON.stringify(state));
    assert.equal((await row()).lease_id, null);
    assert.equal((await cycle()).status, "idle");
  }
  assert.equal((await row()).ai_status, "queued");
  assert.equal((await row()).failure_code, "draft_infrastructure_exhausted");
  online = true;
  await makeDue();
  assert.equal((await cycle()).status, "ready");
  assert.equal((await schedule()).ai_job_attempts, 1);
  assert.equal((await schedule()).ai_counted_jobs, 1);
});

test("an expired lease discards a late draft and the reaper schedules its next attempt", { skip }, async (t) => {
  const { rig, worker, provider, row } = await setup(t, async ({ response, rig: state }) => {
    await state.pool.query("UPDATE sms_v2_unknown_templates SET lease_expires_at=clock_timestamp()-interval '1 second'");
    ready(response);
  }, "routing-v1");
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
  const result = await runTemplateWorkerOnce({ store: worker, provider, config });
  assert.equal(result.status, "lease_lost");
  assert.equal((await row()).ai_draft, null);
  assert.equal(await worker.claim(), null);
  assert.equal((await row()).ai_status, "queued");
  assert.equal((await row()).lease_id, null);
});

test("a rejected candidate resumes at the next provider and all-content exhaustion consumes one job", { skip }, async (t) => {
  const { rig, worker, provider, row } = await setup(t, ({ request, response }) => {
    assert.equal(request.headers["x-ai-routing"], "ordered-v1");
    if (request.headers["x-ai-after-provider"] === undefined) {
      const invalid = answer();
      invalid.emit[0].attrs.direction = "sideways";
      return ready(response, { answer: invalid, provider: "gemini", routeHadInfrastructureFailure: false });
    }
    assert.equal(request.headers["x-ai-after-provider"], "gemini");
    response.writeHead(502, { "content-type": "application/json", "x-prompt-version": promptVersion, "x-ai-routing": "ordered-v1" });
    response.end(JSON.stringify({ error: { code: "invalid_provider_output" } }));
  }, "routing-v1");
  for (const expected of ["retry_scheduled", "retry_scheduled", "failed"]) {
    await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
    assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, expected);
  }
  assert.equal((await row()).failure_code, "draft_validation_failed");
  const budget = await rig.pool.query("SELECT ai_counted_jobs_by_version FROM sms_v2_unknown_templates");
  assert.deepEqual(budget.rows[0].ai_counted_jobs_by_version, { "routing-v1": 1 });
  const usage = await rig.pool.query("SELECT count(*)::int AS attempts, sum(total_tokens)::int AS tokens, sum(cost_usd) AS cost FROM sms_v2_template_attempts");
  // Three rejected drafts (39 tokens each) were billed; the three "exhausted" answers carry no usage.
  assert.equal(usage.rows[0].attempts, 6);
  assert.equal(usage.rows[0].tokens, 117);
  assert.equal(usage.rows[0].cost, null); // the service owns the price
  assert.equal(await worker.requeueFailed(), 0);
});

test("a version change permits work again without resetting an older version's spent cap", { skip }, async (t) => {
  const { rig, worker, workerFor, provider, requests, row } = await setup(t, ({ response }) => ready(response),
    "routing-v1");
  await rig.pool.query(`UPDATE sms_v2_unknown_templates
    SET ai_drafting_version='routing-v1',ai_counted_jobs=5,ai_counted_jobs_by_version='{"routing-v1":5}',
        ai_run_after=clock_timestamp()`);
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "idle");
  assert.equal((await row()).failure_code, "draft_layout_cap");
  assert.equal(requests.length, 0);
  assert.equal(await worker.requeueFailed(), 0);
  const nextWorker = workerFor("routing-v2");
  assert.equal(await nextWorker.requeueFailed(), 1);
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
  assert.equal((await runTemplateWorkerOnce({ store: nextWorker, provider, config })).status, "ready");
  const budget = await rig.pool.query("SELECT ai_counted_jobs_by_version FROM sms_v2_unknown_templates");
  assert.deepEqual(budget.rows[0].ai_counted_jobs_by_version, { "routing-v1": 5, "routing-v2": 1 });
});

function ready(response, overrides = {}) {
  response.writeHead(200, {
    "content-type": "application/json", "x-prompt-version": promptVersion,
    ...(typeof overrides.routeHadInfrastructureFailure === "boolean" ? { "x-ai-routing": "ordered-v1" } : {}),
  });
  response.end(JSON.stringify({ answer: answer(), model: config.model, inputTokens: 27, outputTokens: 12, totalTokens: 39, ...overrides }));
}

test("remote outage keeps the PostgreSQL job queued, recovery stores one validated result and private sync", { skip }, async (t) => {
  let available = false;
  const { rig, worker, provider, requests, row } = await setup(t, async ({ response }) => {
    if (available) return ready(response);
    response.writeHead(503, { "content-type": "application/json", "retry-after": "17" });
    response.end(JSON.stringify({ error: { code: "provider_unavailable" } }));
  });
  const outage = await runTemplateWorkerOnce({ store: worker, provider, config });
  assert.equal(outage.status, "provider_busy");
  assert.equal(outage.retryAfterMs, 17000);
  assert.equal((await row()).ai_status, "queued");
  assert.equal((await row()).lease_id, null);
  assert.equal((await row()).ai_draft, null);
  available = true;
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  const result = await row();
  assert.equal(result.ai_status, "ready");
  assert.equal(result.ai_draft.status, "provisional");
  assert.equal(result.sample, null);
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "idle");
  assert.equal(requests.length, 2);
  const attempts = (await rig.pool.query("SELECT outcome,prompt_version,total_tokens FROM sms_v2_template_attempts ORDER BY started_at")).rows;
  assert.deepEqual(attempts.map((entry) => entry.outcome), ["provider_error", "valid"]);
  assert.ok(attempts.every((entry) => entry.prompt_version === promptVersion));
  assert.equal(attempts[1].total_tokens, 39);
  const visible = (await rig.asUser(rig.profiles[0]).get("/sms/v2/sync")).body.aiResults;
  assert.equal(visible[0].status, "ready");
  assert.deepEqual((await rig.asUser(rig.profiles[1]).get("/sms/v2/sync")).body.aiResults, []);
});

test("revoking the last submitter during remote generation fences the late draft", { skip }, async (t) => {
  const { rig, worker, provider, requests, row } = await setup(t, async ({ response, rig: state }) => {
    await state.consent(state.profiles[0], false);
    ready(response);
  });
  await runTemplateWorkerOnce({ store: worker, provider, config });
  const result = await row();
  // Revocation removes the last submitter and may delete the shared row.
  assert.equal(result?.ai_draft ?? null, null);
  assert.equal(result?.lease_id ?? null, null);
  assert.notEqual(result?.ai_status, "ready");
  assert.equal(requests.length, 1);
  assert.equal(await worker.claim(), null);
  assert.deepEqual((await rig.asUser(rig.profiles[0]).get("/sms/v2/sync")).body.aiResults, []);
});

test("a superseded PostgreSQL lease cannot store a returned remote draft", { skip }, async (t) => {
  const { worker, provider, row, rig } = await setup(t, async ({ response, rig }) => {
    await rig.pool.query(
      "UPDATE sms_v2_unknown_templates SET lease_id=gen_random_uuid() WHERE template_hash=$1",
      [template.template_hash],
    );
    ready(response);
  });
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "lease_lost");
  const result = await row();
  assert.equal(result.ai_draft, null);
  assert.equal(result.ai_status, "working");
  assert.ok(result.lease_id);
  const attempts = await rig.pool.query("SELECT outcome, total_tokens, cost_usd FROM sms_v2_template_attempts");
  assert.deepEqual(attempts.rows, [{ outcome: "discarded", total_tokens: 0, cost_usd: null }]);
});
