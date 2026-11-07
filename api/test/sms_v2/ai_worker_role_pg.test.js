"use strict";
// The AI drafts worker running through the least-privilege `sms_ai_worker`
// login on a fully migrated Postgres. Needs SMS_V2_TEST_AI_WORKER_DATABASE_URL
// as well as the loop harness' URLs (scripts/test_postgres_suites.sh sets all).
const test = require("node:test");
const assert = require("node:assert/strict");
const { template, config, rule } = require("./fixtures/template_draft");
const { createPgWorkerStore, runTemplateWorkerOnce } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;

test("the worker drafts, sees only consenting submitters and cannot touch anything else, as sms_ai_worker", { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 3, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const worker = createPgWorkerStore({ transaction: opened.transaction });

  const item = {
    templateHash: template.template_hash,
    senderBrand: template.sender_brand,
    redactedBody: template.redacted_body,
    observedAt: new Date().toISOString(),
  };
  for (const id of profiles) await rig.consent(id, true);
  assert.equal((await rig.asUser(profiles[0]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);
  assert.equal((await rig.asUser(profiles[1]).post("/sms/v2/unknown-templates", { items: [item] })).status, 202);

  // Settings, spend and the read-only context queries all work for this login.
  assert.equal(typeof (await worker.settings()), "object");
  assert.equal(await worker.monthSpend(), 0);
  assert.deepEqual(await worker.userReports(template), {});
  assert.deepEqual(await worker.activeRules(template), []);

  let prompts = 0;
  const provider = {
    generate: async ({ prompt }) => {
      prompts++;
      assert.equal(JSON.parse(prompt).redactedBody, template.redacted_body);
      return { rule: rule(), inputTokens: 100, outputTokens: 150, totalTokens: 250 };
    },
  };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "idle");
  assert.equal(prompts, 1, "one Gemini call per layout, however many people submitted it");

  const row = (await pool.query("SELECT ai_status, ai_model, ai_draft FROM sms_v2_unknown_templates")).rows[0];
  assert.equal(row.ai_status, "ready");
  assert.equal(row.ai_draft.id, `AI-${template.template_hash}`);
  const attempt = (await pool.query("SELECT outcome, total_tokens, cost_usd FROM sms_v2_template_attempts")).rows[0];
  assert.equal(attempt.outcome, "valid");
  assert.equal(attempt.total_tokens, 250);
  assert.ok(Number(attempt.cost_usd) > 0);

  // A submitter gets the draft back on sync; a profile that never submitted does not.
  const sync = await rig.asUser(profiles[0]).get("/sms/v2/sync");
  assert.equal(sync.body.aiResults[0].status, "ready");
  assert.deepEqual((await rig.asUser(profiles[2]).get("/sms/v2/sync")).body.aiResults, []);

  // Revoked consent stops unstarted work: nothing is claimed, nothing is sent.
  const other = { ...item, templateHash: "b".repeat(64) };
  await rig.asUser(profiles[2]).post("/sms/v2/unknown-templates", { items: [other] });
  await rig.consent(profiles[2], false);
  assert.equal(await worker.claim(), null);

  // The login itself cannot read people or consent data.
  for (const table of ["profiles", "user_consents", "sms_v2_template_submitters", "sms_v2_correction_cases"]) {
    await assert.rejects(opened.transaction((client) => client.query(`SELECT 1 FROM ${table} LIMIT 1`)), { code: "42501" }, table);
  }
  await assert.rejects(opened.transaction((client) => client.query("UPDATE sms_v2_unknown_templates SET redacted_body='x'")), { code: "42501" });
});
