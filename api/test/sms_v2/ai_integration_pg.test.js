"use strict";

// The merge of the durable draft worker (20261123090000 + its hardening, 20261125010000) with the draft
// lifecycle (20261125020000): the REAL worker claim must pick up the jobs the lifecycle code queues, and the
// durable requeue must know the failure code the worker now writes. Runs in the disposable, fully migrated
// cluster of scripts/test_postgres_suites.sh. Synthetic data only.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createServer } = require("node:http");
const { once } = require("node:events");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { createPgWorkerStore, runTemplateWorkerOnce } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { createTemplateStore } = require("../../src/sms_v2/ai_templates");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");
const { template, config, answer } = require("./fixtures/template_draft");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const token = "synthetic_database_service_token_for_testing";
const promptVersion = "sms-rule-draft-v1.0.0";

async function setup(t, respond, draftingVersion = "v1") {
  for (const key of ["SMS_V2_TEST_DATABASE_URL", "SMS_V2_TEST_ADMIN_DATABASE_URL", "SMS_V2_TEST_AI_WORKER_DATABASE_URL"]) {
    const url = new URL(process.env[key]);
    assert.ok(["localhost", "127.0.0.1", "[::1]"].includes(url.hostname), `${key} must use a local test cluster`);
    assert.match(url.pathname, /test|suites/i, `${key} must name a test database`);
  }
  const rig = await startLoopHarness({ profileCount: 2, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const workerFor = (version) => createPgWorkerStore({ transaction: opened.transaction, draftingVersion: version });
  const requests = [];
  const server = createServer(async (request, response) => {
    try {
      for await (const _chunk of request) { /* the body is not needed */ }
      requests.push({ url: request.url, headers: request.headers });
      await respond({ request, response, count: requests.length });
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
    SMS_V2_AI_SERVICE_URL: `http://127.0.0.1:${server.address().port}`, SMS_V2_AI_SERVICE_TOKEN: token,
  } });
  for (const id of rig.profiles) await rig.consent(id, true);
  const item = {
    templateHash: template.template_hash, senderBrand: template.sender_brand, redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(), sample: "Rs.4821.50 paid to LOCAL WORDING ONLY.",
  };
  assert.equal((await rig.asUser(rig.profiles[0]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);
  const row = async () => (await rig.pool.query(
    `SELECT ai_status,ai_draft,failure_code,lease_id,ai_job_attempts,ai_counted_jobs,ai_counted_jobs_by_version,
            ai_drafting_version,ai_run_after<=clock_timestamp() AS due
       FROM sms_v2_unknown_templates WHERE template_hash=$1`, [template.template_hash])).rows[0];
  const makeDue = () => rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
  const worker = workerFor(draftingVersion);
  const cycle = (store = worker) => runTemplateWorkerOnce({ store, provider, config });
  const templates = createTemplateStore({ withUserClient: rig.withUserClient });
  return { rig, row, makeDue, cycle, workerFor, requests, templates };
}

function ready(response, overrides = {}) {
  response.writeHead(200, { "content-type": "application/json", "x-prompt-version": promptVersion });
  response.end(JSON.stringify({ answer: answer(), model: config.model, inputTokens: 27, outputTokens: 12, totalTokens: 39, ...overrides }));
}

function unavailable(response) {
  response.writeHead(503, { "content-type": "application/json" });
  response.end(JSON.stringify({ error: { code: "provider_unavailable" } }));
}

// Quarantine by the phones (lifecycle, 20261125020000) hands the layout to the real worker claim.
test("INT: a draft rejected by quorum is replaced: the real worker claims the replacement job and saves a new draft", { skip }, async (t) => {
  let calls = 0;
  const { rig, row, makeDue, cycle, templates } = await setup(t, ({ response }) => (++calls === 1 ? unavailable(response) : ready(response)));
  // First job: one outage then success, so the draft is stored at attempt 2 with one counted job.
  await makeDue();
  assert.equal((await cycle()).status, "provider_busy");
  await makeDue();
  assert.equal((await cycle()).status, "ready");
  const first = await row();
  assert.equal(first.ai_status, "ready");
  assert.deepEqual([first.ai_job_attempts, first.ai_counted_jobs], [2, 1]);
  // The only consenting submitter rejects the draft: quorum (1 of 1) replaces it.
  const delivered = (await templates.results(rig.profiles[0], null, { draftFeedback: true })).items.find((i) => i.templateHash === template.template_hash);
  assert.ok(delivered.draftId, "the person can see the draft");
  assert.ok(await templates.rejectDraft(rig.profiles[0], delivered.draftId, "no_match"));
  const queued = await row();
  assert.equal(queued.ai_status, "queued");
  assert.equal(queued.ai_draft, null);
  assert.deepEqual([queued.ai_job_attempts, queued.ai_counted_jobs, queued.due], [0, 0, true]);
  // The real claim()+run saves the replacement without any manual makeDue().
  assert.equal((await cycle()).status, "ready");
  const second = await row();
  assert.equal(second.ai_status, "ready");
  assert.equal(second.ai_job_attempts, 1);
  const again = (await templates.results(rig.profiles[0], null, { draftFeedback: true })).items.find((i) => i.templateHash === template.template_hash);
  assert.notEqual(again.draftId, delivered.draftId, "a new draft, not the rejected one");
  assert.equal(calls, 3);
});

test("INT: an admin requeue of a layout that hit the cap is claimed by the real worker, not failed again", { skip }, async (t) => {
  const { rig, row, cycle } = await setup(t, ({ response }) => ready(response));
  await rig.pool.query(
    `UPDATE sms_v2_unknown_templates SET ai_status='failed',ai_draft=NULL,failure_code='draft_layout_cap',ai_drafting_version='v1',
       ai_job_attempts=3,ai_counted_jobs=5,ai_counted_jobs_by_version='{"v1":5}',ai_run_after=clock_timestamp()+interval '24 hours'`);
  const res = await rig.asAdmin().post(`/admin/sms/v2/templates/${template.template_hash}/requeue`, { reason: "capacity restored" });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  assert.equal((await cycle()).status, "ready");
  assert.equal((await row()).ai_status, "ready");
});

// 20261125030000: the worker's terminal failure is retried once per new drafting version.
test("INT: draft_infrastructure_exhausted is retried once per drafting version, with a fresh budget, and never loops", { skip }, async (t) => {
  // A layout that always comes back rejected after "some route had trouble": the third exhausted cycle fails it.
  const { rig, row, makeDue, cycle, workerFor, requests } = await setup(t, ({ response, request }) => {
    if (request.headers["x-ai-after-provider"] === undefined) {
      const bad = answer();
      bad.emit[0].attrs.direction = "sideways";
      response.writeHead(200, { "content-type": "application/json", "x-prompt-version": promptVersion, "x-ai-routing": "ordered-v1" });
      return response.end(JSON.stringify({ answer: bad, model: config.model, provider: "gemini", routeHadInfrastructureFailure: true,
        inputTokens: 27, outputTokens: 12, totalTokens: 39 }));
    }
    response.writeHead(502, { "content-type": "application/json", "x-prompt-version": promptVersion, "x-ai-routing": "ordered-v1" });
    response.end(JSON.stringify({ error: { code: "invalid_provider_output" } }));
  });
  let jobs = 0;
  while ((await row()).ai_status !== "failed" && jobs < 14) {
    await makeDue();
    await cycle();
    jobs++;
  }
  const failed = await row();
  assert.equal(failed.ai_status, "failed");
  assert.equal(failed.failure_code, "draft_infrastructure_exhausted");
  assert.ok(requests.length > 0);
  // Same drafting version: not requeued (the version is the operator's signal that something changed).
  assert.equal(await workerFor("v1").requeueFailed(), 0);
  assert.equal((await row()).ai_status, "failed");
  // A new drafting version gives it one more go with a fresh budget, stamped so it cannot loop.
  const v2 = workerFor("v2");
  assert.equal(await v2.requeueFailed(), 1);
  const requeued = await row();
  assert.equal(requeued.ai_status, "queued");
  assert.deepEqual([requeued.ai_drafting_version, requeued.ai_job_attempts, requeued.ai_counted_jobs], ["v2", 0, 0]);
  assert.equal(await v2.requeueFailed(), 0);
  // ... and the real claim takes it again.
  await makeDue();
  assert.notEqual((await cycle(v2)).status, "idle");
  assert.ok(rig);
});
