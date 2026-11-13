"use strict";
// "Gemini could not draft N formats": layouts that failed through no fault of
// their own go back in the queue (a few times each); genuine rejections stay
// failed; an admin's rejection is not counted as a Gemini failure.
// Needs the loop harness' URLs and SMS_V2_TEST_AI_WORKER_DATABASE_URL.
const test = require("node:test");
const assert = require("node:assert/strict");
const { template } = require("./fixtures/template_draft");
const { createPgWorkerStore } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;

test("failed layouts that were not their fault are queued again, a few times, and the bar stops counting rejections", { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 1, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const worker = createPgWorkerStore({ transaction: opened.transaction });

  await rig.consent(profiles[0], true);
  const item = {
    templateHash: template.template_hash,
    senderBrand: template.sender_brand,
    redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(),
  };
  assert.equal((await rig.asUser(profiles[0]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);
  const state = async () =>
    (await pool.query("SELECT ai_status,failure_code,ai_retries FROM sms_v2_unknown_templates WHERE template_hash=$1", [template.template_hash])).rows[0];
  const fail = (code) =>
    pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2,admin_decision=NULL WHERE template_hash=$1", [template.template_hash, code]);
  const barFailed = async () => (await rig.asUser(profiles[0]).get("/sms/v2/ai-status")).body.failed;

  // A worker that crashed or was restarted: retried.
  for (const code of ["worker_failed", "worker_interrupted", "provider_unavailable"]) {
    await fail(code);
    assert.equal(await barFailed(), 1);
    assert.equal(await worker.requeueFailed(), 1, code);
    assert.equal((await state()).ai_status, "queued");
    assert.equal((await state()).failure_code, null);
    assert.equal(await barFailed(), 0);
  }
  // Three retries used: it now stays failed.
  assert.equal((await state()).ai_retries, 3);
  await fail("worker_failed");
  assert.equal(await worker.requeueFailed(), 0);
  assert.equal((await state()).ai_status, "failed");

  // The model never answered (every try came back empty): retried.
  await pool.query("UPDATE sms_v2_unknown_templates SET ai_retries=0 WHERE template_hash=$1", [template.template_hash]);
  await pool.query(
    "INSERT INTO sms_v2_template_attempts(template_hash,attempt,model,capacity_minute,reserved_tokens,job_id,outcome,total_tokens) VALUES($1,1,'m',date_trunc('minute',now()),1,gen_random_uuid(),'rejected',0)",
    [template.template_hash],
  );
  await fail("draft_validation_failed");
  assert.equal(await worker.requeueFailed(), 1);

  // The model answered and the draft was bad: a genuine failure, left alone.
  await pool.query("UPDATE sms_v2_template_attempts SET total_tokens=900 WHERE template_hash=$1", [template.template_hash]);
  await pool.query("UPDATE sms_v2_unknown_templates SET ai_retries=0 WHERE template_hash=$1", [template.template_hash]);
  await fail("draft_validation_failed");
  assert.equal(await worker.requeueFailed(), 0);
  assert.equal((await state()).ai_status, "failed");
  assert.equal(await barFailed(), 1);

  // An admin's rejection is a decision: never retried, never shown as a Gemini failure.
  await fail("admin_rejected");
  await pool.query("UPDATE sms_v2_unknown_templates SET admin_decision='rejected' WHERE template_hash=$1", [template.template_hash]);
  assert.equal(await worker.requeueFailed(), 0);
  assert.equal(await barFailed(), 0);

  // The worker also reports whether the provider has answered anything lately.
  assert.equal(await worker.providerRecentlyWorked(), true);
  await pool.query("DELETE FROM sms_v2_template_attempts");
  assert.equal(await worker.providerRecentlyWorked(), false);
});
