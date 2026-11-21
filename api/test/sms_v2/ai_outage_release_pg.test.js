"use strict";
// After an AI service outage the worker makes the layouts that failed ONLY because the service was down due at once,
// instead of leaving them on the 24 h back-off (owner, 21 Nov 2026). Run as the restricted sms_ai_worker login, so the
// column grants and consent rules apply. A layout whose drafts were bad keeps its back-off; failed and almost-due
// layouts are not touched. Needs the loop harness' URLs and SMS_V2_TEST_AI_WORKER_DATABASE_URL.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { createPgWorkerStore } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const sha = (brand, body) => crypto.createHash("sha256").update(`${brand}\n${body}`, "utf8").digest("hex");

test("only layouts held back by a service outage are released, and only by the worker's own login", { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 1, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const worker = createPgWorkerStore({ transaction: opened.transaction, draftingVersion: "v1" });
  await rig.consent(profiles[0], true);

  const bodies = {
    outage: "<AMT> paid to <PARTY>. Outage case.",
    badDraft: "<AMT> paid to <PARTY>. Bad draft case.",
    failed: "<AMT> paid to <PARTY>. Failed case.",
    almostDue: "<AMT> paid to <PARTY>. Almost due case.",
  };
  const hash = Object.fromEntries(Object.entries(bodies).map(([k, b]) => [k, sha("TESTBK", b)]));
  const items = Object.values(bodies).map((redactedBody) => ({
    templateHash: sha("TESTBK", redactedBody), senderBrand: "TESTBK", redactedBody, observedAt: new Date().toISOString(),
  }));
  assert.equal((await rig.asUser(profiles[0]).post("/sms/v2/unknown-templates", { items })).status, 202);

  const set = (h, status, code, detail, runAfter) => pool.query(
    `UPDATE sms_v2_unknown_templates SET ai_status=$2, failure_code=$3, failure_detail=$4::text[], ai_job_attempts=3,
       ai_drafting_version='v1', ai_run_after=clock_timestamp()+$5::interval WHERE template_hash=$1`,
    [h, status, code, detail, runAfter]);
  await set(hash.outage, "queued", "draft_infrastructure_exhausted", ["systemic", "ai_service_unavailable"], "24 hours");
  await set(hash.badDraft, "queued", "draft_validation_failed", ["validation", "example_mismatch"], "24 hours");
  await set(hash.failed, "failed", "draft_infrastructure_exhausted", ["systemic", "ai_service_unavailable"], "24 hours");
  await set(hash.almostDue, "queued", "provider_unavailable", ["systemic", "ai_service_unreachable"], "30 seconds");
  const runAfter = async (h) => (await pool.query(
    "SELECT ai_run_after <= clock_timestamp() AS due, ai_status FROM sms_v2_unknown_templates WHERE template_hash=$1", [h])).rows[0];

  assert.equal(await worker.outageDeferredCount(), 1, "only the outage layout is held back for long");
  assert.equal(await worker.releaseAfterOutage(), 1);
  assert.deepEqual(await runAfter(hash.outage), { due: true, ai_status: "queued" });
  assert.deepEqual(await runAfter(hash.badDraft), { due: false, ai_status: "queued" }, "a bad draft keeps its back-off");
  assert.deepEqual(await runAfter(hash.failed), { due: false, ai_status: "failed" });
  assert.deepEqual(await runAfter(hash.almostDue), { due: false, ai_status: "queued" });
  assert.equal(await worker.outageDeferredCount(), 0);
  assert.equal(await worker.releaseAfterOutage(), 0, "nothing left to release");

  // Without current consent a layout is not released (the worker never touches it).
  await set(hash.outage, "queued", "draft_infrastructure_exhausted", ["systemic", "ai_service_unavailable"], "24 hours");
  await rig.consent(profiles[0], false);
  assert.equal(await worker.releaseAfterOutage(), 0);
});
