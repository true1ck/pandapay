"use strict";
process.env.JWT_ACCESS_SECRET ||= "ci_only_not_a_real_secret";
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { Pool } = require("pg");
const { template, config, rule } = require("./fixtures/template_draft");
const { createTemplateStore } = require("../../src/sms_v2/ai_templates");
const { createPgWorkerStore, runTemplateWorkerOnce, PROMPT_VERSION } = require("../../src/sms_v2/template_worker");
const { createAdminDbHelpers } = require("../../src/admin/server");

const url = process.env.SMS_V2_TEST_DATABASE_URL;
const adminUrl = process.env.SMS_V2_TEST_ADMIN_DATABASE_URL;

test("prompt versions are stored and a covered layout reaches phones as queued", { skip: !url || !adminUrl }, async (t) => {
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const profile = crypto.randomUUID();
  const admin = crypto.randomUUID();
  t.after(async () => {
    await pool.query("DELETE FROM profiles WHERE id=$1", [profile]);
    await pool.query("DELETE FROM sms_v2_unknown_templates WHERE template_hash=$1", [template.template_hash]);
    await pool.query("DELETE FROM sms_v2_template_attempts");
    await pool.query("DELETE FROM sms_v2_ai_capacity");
    await pool.query("DELETE FROM sms_v2_rules WHERE rule_id='TESTBK-PAID'");
    await pool.query("DELETE FROM admin_users WHERE id=$1", [admin]);
    await Promise.all([pool.end(), privatePool.end()]);
  });
  await pool.query("INSERT INTO profiles(id) VALUES($1)", [profile]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  await pool.query("INSERT INTO user_consents(profile_id,purpose,policy_version,granted,granted_at) VALUES($1,'sms_shared_learning','sms-shared-learning-v3',true,clock_timestamp())", [profile]);
  const withUserClient = async (id, operation) => {
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query("SET LOCAL ROLE app_user");
      await client.query("SELECT set_config('app.user_id',$1,true)", [id]);
      const out = await operation(client);
      await client.query("COMMIT");
      return out;
    } catch (error) { await client.query("ROLLBACK"); throw error; } finally { client.release(); }
  };
  const phone = createTemplateStore({ withUserClient });
  const item = { templateHash: template.template_hash, senderBrand: template.sender_brand, redactedBody: template.redacted_body, observedAt: new Date().toISOString() };
  const worker = createPgWorkerStore({ ...createAdminDbHelpers(privatePool), adminId: admin });

  // First: the provider is called and the attempt carries the prompt version.
  await phone.submit(profile, [item], true);
  const provider = { generate: async () => ({ rule: rule(), inputTokens: 100, outputTokens: 50, totalTokens: 150 }) };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  const attempt = (await pool.query("SELECT prompt_version, outcome FROM sms_v2_template_attempts")).rows;
  assert.deepEqual(attempt, [{ prompt_version: PROMPT_VERSION, outcome: "valid" }]);

  // Then an active rule appears; a re-queued layout is covered without a call.
  const active = { ...rule(), id: "TESTBK-PAID", version: 1, status: "active" };
  delete active.match.templateHash;
  await pool.query("INSERT INTO sms_v2_rules(rule_id,version,status,family,senders,body,created_by) VALUES($1,1,'active',$2,$3,$4,'admin')",
    ["TESTBK-PAID", active.family, active.senders, JSON.stringify(active)]);
  await pool.query("UPDATE sms_v2_unknown_templates SET ai_status='queued', ai_draft=NULL WHERE template_hash=$1", [template.template_hash]);
  let calls = 0;
  const noCalls = { generate: async () => { calls++; return { rule: rule() }; } };
  const result = await runTemplateWorkerOnce({ store: worker, provider: noCalls, config });
  assert.deepEqual(result, { status: "covered", templateHash: template.template_hash, covered: "TESTBK-PAID@1" });
  assert.equal(calls, 0);
  const row = (await pool.query("SELECT ai_status, covered_by, ai_draft, lease_id FROM sms_v2_unknown_templates WHERE template_hash=$1", [template.template_hash])).rows[0];
  assert.deepEqual(row, { ai_status: "covered", covered_by: "TESTBK-PAID@1", ai_draft: null, lease_id: null });
  assert.equal((await pool.query("SELECT 1 FROM sms_v2_template_attempts")).rows.length, 1, "no new attempt");
  // The worker never claims a covered layout again.
  assert.equal(await worker.claim(), null);
  // Phones see it as queued, never as a new status.
  const seen = await phone.results(profile, null);
  assert.deepEqual(seen.items.map((entry) => [entry.templateHash, entry.status]), [[template.template_hash, "queued"]]);
});

