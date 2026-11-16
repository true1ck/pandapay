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

async function setup(t, respond, fallbackModel) {
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
  const worker = createPgWorkerStore({ transaction: opened.transaction });
  const requests = [];
  const server = createServer(async (request, response) => {
    try {
      assert.equal(request.url, "/v1/sms-rule-drafts");
      assert.equal(request.headers.authorization, `Bearer ${token}`);
      assert.equal(request.headers["x-prompt-version"], promptVersion);
      assert.equal(request.headers["x-allow-experiential-free"], fallbackModel);
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      assert.deepEqual(body, { senderBrand: template.sender_brand, redactedBody: template.redacted_body });
      requests.push(body);
      await respond({ response, rig });
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
    SMS_V2_AI_EXPERIENTIAL_FREE_MODEL: fallbackModel,
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
    "SELECT ai_status,ai_draft,ai_model,lease_id,failure_code,sample FROM sms_v2_unknown_templates WHERE template_hash=$1",
    [template.template_hash],
  )).rows[0];
  return { rig, worker, provider, requests, row };
}

function ready(response, overrides = {}) {
  response.writeHead(200, { "content-type": "application/json", "x-prompt-version": promptVersion });
  response.end(JSON.stringify({ answer: answer(), model: config.model, inputTokens: 27, outputTokens: 12, totalTokens: 39, ...overrides }));
}

test("the dedicated PostgreSQL worker records the free fallback model and cost", { skip }, async (t) => {
  const model = "clef:free";
  const { rig, worker, provider, row } = await setup(t, async ({ response }) =>
    ready(response, { model, provider: "experiential" }), model);
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  const result = await row();
  assert.equal(result.ai_model, "experiential:clef:free");
  assert.equal(result.ai_draft.createdBy, "ai:experiential:clef:free");
  const attempts = (await rig.pool.query("SELECT model,cost_usd,total_tokens FROM sms_v2_template_attempts")).rows;
  assert.equal(attempts.length, 1);
  assert.equal(attempts[0].model, result.ai_model);
  assert.equal(Number(attempts[0].cost_usd), 0);
  assert.equal(attempts[0].total_tokens, 39);
});

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
  const { worker, provider, row } = await setup(t, async ({ response, rig }) => {
    await rig.pool.query(
      "UPDATE sms_v2_unknown_templates SET lease_id=gen_random_uuid() WHERE template_hash=$1",
      [template.template_hash],
    );
    ready(response);
  });
  await runTemplateWorkerOnce({ store: worker, provider, config });
  const result = await row();
  assert.equal(result.ai_draft, null);
  assert.equal(result.ai_status, "working");
  assert.ok(result.lease_id);
});
