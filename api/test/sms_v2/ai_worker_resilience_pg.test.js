"use strict";

// Durable-job worker hardening (audit items S2-01, 04, 05, 07, 08, 09, 10, 11). Runs in the disposable,
// fully migrated cluster provisioned by scripts/test_postgres_suites.sh. The harness clears the shared
// SMS tables, so it refuses any database that is not a local test cluster.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createServer } = require("node:http");
const { once } = require("node:events");
const { spawn } = require("node:child_process");
const path = require("node:path");
const { createAiServiceProvider } = require("../../src/sms_v2/ai_service_provider");
const { createPgWorkerStore, runTemplateWorkerOnce } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { JOBS } = require("../../src/admin/system_status");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");
const { template, config, answer } = require("./fixtures/template_draft");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const token = "synthetic_database_service_token_for_testing";
const promptVersion = "sms-rule-draft-v1.0.0";

async function setup(t, respond, { env = {}, draftingVersion = "routing-v1" } = {}) {
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
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      requests.push({ url: request.url, headers: request.headers, body: JSON.parse(Buffer.concat(chunks).toString("utf8")) });
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
  const serviceUrl = `http://127.0.0.1:${server.address().port}`;
  const provider = createAiServiceProvider({ env: {
    SMS_V2_AI_SERVICE_URL: serviceUrl, SMS_V2_AI_SERVICE_TOKEN: token, ...env,
  } });
  for (const id of rig.profiles) await rig.consent(id, true);
  const item = {
    templateHash: template.template_hash, senderBrand: template.sender_brand, redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(), sample: "Rs.4821.50 paid to LOCAL WORDING ONLY.",
  };
  assert.equal((await rig.asUser(rig.profiles[0]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);
  const row = async () => (await rig.pool.query(
    `SELECT ai_status,ai_draft,failure_code,lease_id,ai_job_attempts,ai_counted_jobs,
            extract(epoch FROM ai_run_after-clock_timestamp())::integer AS seconds
       FROM sms_v2_unknown_templates WHERE template_hash=$1`, [template.template_hash])).rows[0];
  const makeDue = () => rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()");
  const cycle = (options = {}) => runTemplateWorkerOnce({ store: worker, provider, config, ...options });
  return { rig, worker, provider, requests, row, makeDue, cycle, serviceUrl };
}

const orderedHeaders = { "content-type": "application/json", "x-prompt-version": promptVersion, "x-ai-routing": "ordered-v1" };

function ready(response, overrides = {}) {
  response.writeHead(200, {
    "content-type": "application/json", "x-prompt-version": promptVersion,
    ...(typeof overrides.routeHadInfrastructureFailure === "boolean" ? { "x-ai-routing": "ordered-v1" } : {}),
  });
  response.end(JSON.stringify({ answer: answer(), model: config.model, inputTokens: 27, outputTokens: 12, totalTokens: 39, ...overrides }));
}

function invalidDraft(response, overrides = {}) {
  const bad = answer();
  bad.emit[0].attrs.direction = "sideways";
  ready(response, { answer: bad, provider: "gemini", routeHadInfrastructureFailure: false, ...overrides });
}

function exhausted(response) {
  response.writeHead(502, orderedHeaders);
  response.end(JSON.stringify({ error: { code: "invalid_provider_output" } }));
}

// S2-01: a wrong token, prompt revision or config says nothing about the layout. It must not use up a job
// attempt, however long the service stays misconfigured.
for (const [name, status, body] of [
  ["a refused token", 401, { error: { code: "wrong_token" } }],
  ["a prompt revision mismatch", 409, { error: { code: "prompt_version_mismatch" } }],
  ["a config mismatch", 412, { error: { code: "config_mismatch" } }],
]) {
  test(`S2-01: ${name} leaves the job attempt unspent and the layout out of the long cooldown`, { skip }, async (t) => {
    let fixed = false;
    const { worker, provider, row, makeDue, cycle } = await setup(t, ({ response }) => {
      if (fixed) return ready(response);
      response.writeHead(status, { "content-type": "application/json" });
      response.end(JSON.stringify(body));
    });
    for (let round = 1; round <= 4; round++) {
      await makeDue();
      const result = await cycle();
      assert.equal(result.status, "provider_busy");
      // The worker must rest (circuit breaker), not walk on to the next layout straight away.
      assert.ok(result.retryAfterMs >= 60000, JSON.stringify(result));
      assert.notEqual(result.rescheduled, true);
      const state = await row();
      assert.equal(state.ai_job_attempts, 0, `round ${round}: ${JSON.stringify(state)}`);
      assert.equal(state.ai_counted_jobs, 0);
      assert.equal(state.ai_status, "queued");
      assert.ok(state.seconds < 3600, `round ${round}: cooldown ${state.seconds}s`);
    }
    fixed = true;
    await makeDue();
    assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
    assert.equal((await row()).ai_job_attempts, 1);
  });
}

// S2-07: waiting for the worker's own RPM/TPM window is never the layout's or the provider's fault, on any try.
test("S2-07: a capacity block after an earlier route call refunds the job attempt", { skip }, async (t) => {
  const { worker, provider, row, makeDue } = await setup(t, ({ response }) => invalidDraft(response));
  const blocked = { ...worker, beginAttempt: (tpl, attempt, ...rest) => attempt === 2 ? "capacity" : worker.beginAttempt(tpl, attempt, ...rest) };
  await makeDue();
  const result = await runTemplateWorkerOnce({ store: blocked, provider, config });
  assert.equal(result.status, "capacity");
  const state = await row();
  assert.equal(state.ai_status, "queued");
  assert.equal(state.ai_job_attempts, 0, JSON.stringify(state));
  assert.ok(state.seconds <= 90, JSON.stringify(state));
});

// S2-04: a layout whose job always ends as "some route had trouble" used to retry three times a day for ever.
test("S2-04: infrastructure-classed exhaustion ends in a terminal failure with its own reason", { skip }, async (t) => {
  const { row, makeDue, cycle } = await setup(t, ({ response, request }) => {
    if (request.headers["x-ai-after-provider"] === undefined) return invalidDraft(response, { routeHadInfrastructureFailure: true });
    exhausted(response);
  });
  let jobs = 0;
  let last;
  while (jobs < 14) {
    await makeDue();
    last = await cycle();
    jobs++;
    if (last.status === "failed") break;
  }
  const state = await row();
  assert.equal(state.ai_status, "failed", `still ${state.ai_status} after ${jobs} jobs`);
  assert.equal(state.failure_code, "draft_infrastructure_exhausted");
  assert.ok(jobs <= 9, `${jobs} jobs`);
});

// A real outage (no evidence about the layout) must still never end a layout.
test("S2-04: an outage that keeps the service down never fails the layout", { skip }, async (t) => {
  const { row, makeDue, cycle } = await setup(t, ({ response }) => {
    response.writeHead(503, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { code: "provider_unavailable" } }));
  });
  for (let job = 0; job < 12; job++) {
    await makeDue();
    assert.equal((await cycle()).status, "provider_busy");
  }
  const state = await row();
  assert.equal(state.ai_status, "queued");
  assert.equal(state.ai_counted_jobs, 0);
});

// S2-08: exclusion of providers whose drafts were rejected must survive to the next retry.
test("S2-08: providers whose draft was rejected are skipped by the next retry, then forgotten on success", { skip }, async (t) => {
  let phase = "reject";
  const { rig, worker, serviceUrl, requests, row, makeDue, cycle } = await setup(t, ({ response, request }) => {
    if (phase === "reject") {
      if (request.headers["x-ai-after-provider"] === undefined) return invalidDraft(response);
      return exhausted(response);
    }
    return ready(response, { provider: "groq", model: "openai/gpt-oss-20b", routeHadInfrastructureFailure: false });
  });
  await makeDue();
  assert.equal((await cycle()).status, "retry_scheduled");
  const stored = (await rig.pool.query("SELECT ai_excluded_providers FROM sms_v2_unknown_templates")).rows[0].ai_excluded_providers;
  assert.deepEqual(stored, ["gemini"]);
  phase = "accept";
  await makeDue();
  const before = requests.length;
  // A restarted worker process: it has not yet learned which routes the service has, so it sends the stored skip list.
  const restarted = createAiServiceProvider({ env: { SMS_V2_AI_SERVICE_URL: serviceUrl, SMS_V2_AI_SERVICE_TOKEN: token } });
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider: restarted, config })).status, "ready");
  assert.equal(requests[before].headers["x-ai-skip-providers"], "gemini");
  assert.equal(requests[before].url, "/v1/sms-rule-drafts/ordered");
  assert.deepEqual((await rig.pool.query("SELECT ai_excluded_providers FROM sms_v2_unknown_templates")).rows[0].ai_excluded_providers, []);
  assert.equal((await row()).ai_status, "ready");
});

test("S2-08: a new cycle (the third job's restart) forgets the rejected providers and starts again from the first", { skip }, async (t) => {
  const { rig, requests, makeDue, cycle } = await setup(t, ({ response, request }) => {
    if (request.headers["x-ai-after-provider"] === undefined) return invalidDraft(response);
    exhausted(response);
  });
  await makeDue();
  assert.equal((await cycle()).status, "retry_scheduled");
  // Three attempts spent: the next claim restarts the cycle, which clears the exclusion list.
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_job_attempts=3, ai_run_after=clock_timestamp()");
  const before = requests.length;
  await cycle();
  assert.equal(requests[before].headers["x-ai-skip-providers"], undefined);
  assert.equal(requests[before].url, "/v1/sms-rule-drafts");
  assert.ok(rig);
});

// S2-11: a rejected draft was still billed: keep what it used and cost, without calling it a valid answer.
test("S2-11: a rejected draft records its tokens (the service owns the price) and does not count as a valid answer", { skip }, async (t) => {
  const { rig, makeDue, cycle } = await setup(t, ({ response }) => invalidDraft(response, { routeHadInfrastructureFailure: undefined, provider: undefined }));
  await makeDue();
  await cycle();
  const rows = (await rig.pool.query("SELECT outcome,total_tokens,cost_usd FROM sms_v2_template_attempts ORDER BY attempt")).rows;
  assert.ok(rows.length >= 1);
  for (const attempt of rows) {
    assert.equal(attempt.outcome, "rejected");
    assert.equal(attempt.total_tokens, 39);
    assert.equal(attempt.cost_usd, null, "the service owns the price in service mode");
  }
  assert.equal((await rig.pool.query("SELECT count(*)::int AS n FROM sms_v2_template_attempts WHERE outcome='valid'")).rows[0].n, 0);
});

// S2-09: a deploy (SIGTERM) must hand the in-flight attempt back, not burn it.
test("S2-09: shutdown aborts the in-flight provider call and refunds the attempt", { skip, timeout: 20000 }, async (t) => {
  const { requests, row, makeDue, cycle } = await setup(t, async ({ request }) => {
    await once(request, "close");
  });
  await makeDue();
  const shutdown = new AbortController();
  const running = cycle({ shutdown: shutdown.signal });
  while (requests.length === 0) await new Promise((resolve) => setTimeout(resolve, 20));
  shutdown.abort();
  const result = await running;
  assert.equal(result.status, "shutdown");
  const state = await row();
  assert.equal(state.ai_status, "queued");
  assert.equal(state.ai_job_attempts, 0, JSON.stringify(state));
  assert.equal(state.lease_id, null);
});

// S2-10: a layout waiting out a legitimate retry delay is not a backlog.
test("S2-10: the AI drafts probe ignores queued layouts that are not yet due", { skip }, async (t) => {
  const { rig } = await setup(t, () => {});
  const probe = JOBS.find((job) => job.key === "sms_v2_ai_drafts");
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET first_seen=clock_timestamp()-interval '3 hours', ai_run_after=clock_timestamp()+interval '30 minutes'");
  assert.equal((await rig.pool.query(probe.sql)).rows[0].last_status, "ok");
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_run_after=clock_timestamp()-interval '2 hours'");
  assert.equal((await rig.pool.query(probe.sql)).rows[0].last_status, "backlog");
});

// S2-05: a lock or statement timeout in one cycle must not take the whole worker process down.
test("S2-05: the worker process survives a lock timeout on the global results lock and carries on", { skip, timeout: 60000 }, async (t) => {
  const { rig, requests, makeDue, serviceUrl } = await setup(t, ({ response }) => {
    response.writeHead(503, { "content-type": "application/json" });
    response.end(JSON.stringify({ error: { code: "provider_unavailable" } }));
  });
  await makeDue();
  const url = new URL(process.env.SMS_V2_TEST_DATABASE_URL);
  assert.equal(url.hostname, "127.0.0.1", "the lock below is taken on the throwaway loopback cluster only");
  const holder = await rig.pool.connect();
  await holder.query("BEGIN");
  await holder.query("SELECT pg_advisory_xact_lock(hashtext('sms_v2_template_results'))");
  let released = false;
  const release = async () => {
    if (released) return;
    released = true;
    try { await holder.query("COMMIT"); } finally { holder.release(); }
  };
  const child = spawn(process.execPath, [path.join(__dirname, "../../src/sms_v2/jobs/template_worker_main.js")], {
    env: {
      ...process.env, SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test",
      SMS_V2_AI_SERVICE_URL: serviceUrl, SMS_V2_AI_SERVICE_TOKEN: token,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let exitCode = null;
  child.on("exit", (code) => { exitCode = code; });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk; });
  child.stderr.on("data", (chunk) => { output += chunk; });
  try {
    // The claim waits one second for the lock and fails with 55P03; a worker that exits here is the bug.
    await new Promise((resolve) => setTimeout(resolve, 4000));
    assert.equal(exitCode, null, `worker exited with ${exitCode}: ${output}`);
    await release();
    const deadline = Date.now() + 30000;
    while (requests.length === 0 && Date.now() < deadline) await new Promise((resolve) => setTimeout(resolve, 250));
    assert.ok(requests.length >= 1, `worker never claimed the job after the lock cleared: ${output}`);
    assert.equal(exitCode, null);
  } finally {
    child.kill("SIGKILL");
    await release();
  }
});

// S2-09 (21 Nov 2026): a draft that is well formed but wrong is only fixed by the model that wrote it, and only if it is told
// what was wrong. A route whose draft the checker refused is therefore asked ONCE more with the reasons (a service that
// announced `rerun-v1`), before the later routes are tried.
test("S2-09: a route whose draft was refused is asked again with the reasons, then accepted", { skip }, async (t) => {
  const send = (response, status, body) => {
    response.writeHead(status, { "content-type": "application/json", "x-prompt-version": promptVersion, "x-ai-routing": "ordered-v1", "x-ai-features": "fix-v1,rerun-v1" });
    response.end(JSON.stringify(body));
  };
  const good = () => ({ answer: answer(), model: config.model, inputTokens: 27, outputTokens: 12, totalTokens: 39, provider: "gemini", routeHadInfrastructureFailure: false });
  const bad = () => {
    const wrong = answer();
    wrong.emit[0].attrs.direction = "sideways";
    return { ...good(), answer: wrong };
  };
  const { requests, row, makeDue, cycle } = await setup(t, ({ request, response }) =>
    request.headers["x-ai-rerun"] === "true" ? send(response, 200, good()) : send(response, 200, bad()));
  await makeDue();
  // One job: the first answer is refused, the same route is asked again with the reasons and its second answer is accepted.
  assert.equal((await cycle()).status, "ready");
  assert.equal((await row()).ai_status, "ready");
  assert.equal(requests.length, 2, requests.map((entry) => entry.headers["x-ai-rerun"] ?? "-").join(","));
  const again = requests.find((entry) => entry.headers["x-ai-rerun"] === "true");
  assert.ok(again, "the worker asked for a re-ask");
  assert.equal(again.headers["x-ai-after-provider"], "gemini");
  assert.ok(Array.isArray(again.body.fix) && again.body.fix.length > 0, JSON.stringify(again.body));
  assert.ok(again.body.fix.every((code) => /^[a-z][a-z0-9_]*/.test(code)));
});
