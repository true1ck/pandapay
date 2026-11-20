"use strict";
// Pipeline v3 on a fully migrated Postgres, through the least-privilege `sms_ai_worker` login: the swapped-number
// sample lives only while a layout waits, the queue is first in first out, failure reasons are kept, layouts that
// failed under an older prompt are tried again once, and Gemini is called once per layout however many people
// send it. Needs SMS_V2_TEST_AI_WORKER_DATABASE_URL as well as the loop harness' URLs
// (scripts/test_postgres_suites.sh sets all of them).
const test = require("node:test");
const assert = require("node:assert/strict");
const { config, answer } = require("./fixtures/template_draft");
const { createPgWorkerStore, runTemplateWorkerOnce, PROMPT_VERSION } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
// The server recomputes templateHash from the brand and body, so a layout's hash follows the body uploaded for it.
const { layoutHash } = require("./fixtures/template_draft");
const uploaded = {};
const defaultBody = (c) => (c === "a" ? "<AMT> paid to <PARTY>." : `<AMT> paid to <PARTY> ${c}.`);
const hash = (c) => layoutHash("TESTBK", uploaded[c] ?? defaultBody(c));
const SAMPLE = "Rs.4821.50 paid to ZAZA SHOP.";
const item = (c, body = defaultBody(c), extra = {}) => ({
  templateHash: layoutHash("TESTBK", (uploaded[c] = body)),
  senderBrand: "TESTBK",
  redactedBody: body,
  observedAt: new Date().toISOString(),
  ...extra,
});

async function rigAndWorker(t, profileCount = 3) {
  const rig = await startLoopHarness({ profileCount, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  for (const id of rig.profiles) await rig.consent(id, true);
  return { rig, worker: createPgWorkerStore({ transaction: opened.transaction }), opened };
}
const rowOf = (rig, c) =>
  rig.pool.query("SELECT ai_status,sample,queued_at,failure_code,failure_detail,ai_retries FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash(c)]).then((r) => r.rows[0]);

test("the sample is kept only while the layout waits, one call serves every person, and the answer reaches both", { skip }, async (t) => {
  const { rig, worker } = await rigAndWorker(t);
  const [p0, p1] = rig.profiles;
  assert.equal((await rig.asUser(p0).post("/sms/v2/unknown-templates", { items: [item("a", undefined, { sample: SAMPLE })] })).status, 202);
  // A second person's sample for the same layout changes nothing: one row, the first sample, two submitters.
  assert.equal((await rig.asUser(p1).post("/sms/v2/unknown-templates", { items: [item("a", undefined, { sample: "Rs.99 paid to OTHER SHOP." })] })).status, 202);
  const waiting = await rowOf(rig, "a");
  assert.equal(waiting.sample, SAMPLE);
  assert.equal(waiting.ai_status, "queued");
  assert.ok(waiting.queued_at);
  const counts = (await rig.pool.query("SELECT seen_count,distinct_profiles FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash("a")])).rows[0];
  assert.deepEqual([Number(counts.seen_count), counts.distinct_profiles], [2, 2]);

  // A sample with an address in it is refused; so is one that is too long.
  const bad = await rig.asUser(p0).post("/sms/v2/unknown-templates", { items: [item("b", undefined, { sample: "Rs.1 paid to a@b.com" })] });
  assert.equal(bad.status, 400);
  assert.equal(bad.body.error, "template_sample_invalid");
  assert.equal((await rig.asUser(p0).post("/sms/v2/unknown-templates", { items: [item("b", undefined, { sample: "x".repeat(2001) })] })).status, 400);

  let calls = 0;
  let asked;
  const provider = {
    generate: async ({ prompt }) => {
      calls++;
      asked = JSON.parse(prompt);
      return { answer: answer(), inputTokens: 100, outputTokens: 50, totalTokens: 150 };
    },
  };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "idle");
  assert.equal(calls, 1, "one Gemini call, however many people sent the layout");
  assert.deepEqual(asked.slotValues, { amt1: "Rs.4821.50", party1: "ZAZA SHOP" });

  // The answer is final: the wording is deleted, nothing is left that says why it failed.
  const done = await rowOf(rig, "a");
  assert.equal(done.ai_status, "ready");
  assert.equal(done.sample, null);
  assert.equal(done.failure_detail, null);
  const attempt = (await rig.pool.query("SELECT outcome,error_kind,error_codes,http_status,prompt_version FROM sms_v2_template_attempts")).rows;
  assert.deepEqual(attempt, [{ outcome: "valid", error_kind: null, error_codes: null, http_status: null, prompt_version: PROMPT_VERSION }]);

  // Both people get the same private rule from sync.
  for (const id of [p0, p1]) {
    const ready = (await rig.asUser(id).get("/sms/v2/sync")).body.aiResults.find((entry) => entry.templateHash === hash("a"));
    assert.equal(ready.status, "ready");
    assert.equal(ready.rule.status, "provisional");
  }
});

test("the queue is first in, first out; a busy answer keeps a layout's place; failure reasons are stored; the wording goes with a final answer", { skip }, async (t) => {
  const { rig, worker } = await rigAndWorker(t, 2);
  const [p0] = rig.profiles;
  const bodies = { a: "<AMT> paid to <PARTY>.", b: "<AMT> credited to your account.", c: "Your OTP is <REF>." };
  for (const c of ["a", "b", "c"])
    assert.equal((await rig.asUser(p0).post("/sms/v2/unknown-templates", { items: [item(c, bodies[c], { sample: SAMPLE })] })).status, 202);

  const first = await worker.claim();
  assert.equal(first.template_hash, hash("a"));
  // Gemini was busy: the layout goes back where it was, and keeps its wording.
  await worker.finish(first, { model: "m", requeue: true });
  const again = await worker.claim();
  assert.equal(again.template_hash, hash("a"), "a busy answer does not send the layout to the back");
  assert.equal(again.sample, SAMPLE);
  await worker.finish(again, { model: "m", code: "draft_validation_failed", detail: ["validation", "example_mismatch"] });
  const failed = await rowOf(rig, "a");
  assert.equal(failed.ai_status, "failed");
  assert.deepEqual(failed.failure_detail, ["validation", "example_mismatch"]);
  assert.equal(failed.sample, null, "a final answer, even a failure, deletes the wording");

  const second = await worker.claim();
  assert.equal(second.template_hash, hash("b"));
  const third = await worker.claim();
  assert.equal(third.template_hash, hash("c"));
  assert.equal(await worker.claim(), null);

  // The attempt row keeps the kind, codes and HTTP status of a failure.
  const claimedForAttempt = { ...second };
  await worker.beginAttempt(claimedForAttempt, 1, "synthetic prompt", { ...config, rpm: 30, tpm: 100000 });
  await worker.recordAttempt(claimedForAttempt, 1, {
    inputTokens: 0, outputTokens: 0, totalTokens: 0, latencyMs: 5, promptVersion: PROMPT_VERSION, outcome: "rejected",
    errorKind: "provider_busy", errorCodes: ["template_provider_busy"], httpStatus: 503, costUsd: null,
  });
  const attempt = (await rig.pool.query("SELECT error_kind,error_codes,http_status FROM sms_v2_template_attempts WHERE template_hash=$1", [hash("b")])).rows[0];
  assert.deepEqual(attempt, { error_kind: "provider_busy", error_codes: ["template_provider_busy"], http_status: 503 });
});

test("layouts that failed under an older prompt are tried again once, at the back of the queue; the current prompt's failures stay failed", { skip }, async (t) => {
  const { rig, worker } = await rigAndWorker(t, 2);
  const [p0] = rig.profiles;
  for (const c of ["a", "b", "c", "d"]) await rig.asUser(p0).post("/sms/v2/unknown-templates", { items: [item(c, undefined, { sample: SAMPLE })] });
  const attempt = (c, version) =>
    rig.pool.query(
      "INSERT INTO sms_v2_template_attempts(template_hash,attempt,model,capacity_minute,reserved_tokens,job_id,outcome,total_tokens,prompt_version) VALUES($1,1,'m',date_trunc('minute',now()),1,gen_random_uuid(),'rejected',500,$2)",
      [hash(c), version],
    );
  const fail = (c, code) => rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2,failure_detail=ARRAY['validation'],sample=NULL WHERE template_hash=$1", [hash(c), code]);
  await fail("a", "draft_validation_failed"); await attempt("a", "tpl-old");           // older prompt: retried
  await fail("b", "draft_validation_failed"); await attempt("b", PROMPT_VERSION);       // this prompt already failed it
  await fail("c", "capacity");                                                         // a leftover code: retried
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='queued' WHERE template_hash=$1", [hash("d")]);
  const dBefore = (await rowOf(rig, "d")).queued_at;

  assert.equal(await worker.requeueFailed(), 1, "without a prompt version only the leftover code moves");
  assert.equal((await rowOf(rig, "c")).ai_status, "queued");
  await fail("c", "capacity");
  assert.equal(await worker.requeueFailed(PROMPT_VERSION), 2, "the old-prompt failure and the leftover code");
  const [a, b, c, d] = await Promise.all(["a", "b", "c", "d"].map((x) => rowOf(rig, x)));
  assert.deepEqual([a.ai_status, a.failure_code, a.failure_detail, a.ai_retries], ["queued", null, null, 1]);
  assert.equal(b.ai_status, "failed", "this prompt already failed it");
  assert.equal(c.ai_status, "queued");
  assert.ok(a.queued_at > dBefore && c.queued_at > dBefore, "retried layouts go to the back");
  // Three retries at most.
  await rig.pool.query("UPDATE sms_v2_unknown_templates SET ai_retries=3,ai_status='failed',failure_code='draft_validation_failed' WHERE template_hash=$1", [hash("a")]);
  assert.equal(await worker.requeueFailed(PROMPT_VERSION), 0);
});
