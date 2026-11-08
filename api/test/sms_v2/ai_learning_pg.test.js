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
  assert.deepEqual(seen.items.map((entry) => [entry.templateHash, entry.status]), [[template.template_hash, "pending"]]);
});

test("the worker store counts distinct reporters per kind and finds sibling layouts", { skip: !url || !adminUrl }, async (t) => {
  const pool = new Pool({ connectionString: url });
  const privatePool = new Pool({ connectionString: adminUrl });
  const people = [crypto.randomUUID(), crypto.randomUUID(), crypto.randomUUID()];
  const admin = crypto.randomUUID();
  const other = { hash: "d".repeat(64), body: "<AMT> credited to your account." };
  t.after(async () => {
    await pool.query("DELETE FROM profiles WHERE id=ANY($1::uuid[])", [people]);
    await pool.query("DELETE FROM sms_v2_unknown_templates WHERE template_hash=ANY($1::text[])", [[template.template_hash, other.hash]]);
    await pool.query("DELETE FROM admin_users WHERE id=$1", [admin]);
    await Promise.all([pool.end(), privatePool.end()]);
  });
  for (const id of people) await pool.query("INSERT INTO profiles(id) VALUES($1)", [id]);
  await pool.query("INSERT INTO admin_users(id,email,role) VALUES($1,$2,'owner')", [admin, `${admin}@example.invalid`]);
  const report = (profile, kind, eligible = true, repeat = 0) => pool.query(
    `INSERT INTO sms_v2_correction_cases(profile_id,source_key,fact_ids,correction_kind,stage,trace,template_hash,sender_brand,redacted_template,shared_learning_eligible,request_hash)
     VALUES($1,$2,'{}',$3,'gate','{}'::jsonb,$4,'TESTBK',$5,$6,$7)`,
    [profile, `sms:synthetic:${repeat}`, kind, template.template_hash, template.redacted_body, eligible, crypto.randomUUID()]);
  await report(people[0], "not_financial");
  await report(people[0], "not_financial", true, 1); // the same person twice is one person
  await report(people[1], "not_financial");
  await report(people[2], "wrong_amount");
  await report(people[2], "wrong_date", false); // not shared: never counted
  const worker = createPgWorkerStore({ ...createAdminDbHelpers(privatePool), adminId: admin });
  const row = { template_hash: template.template_hash, sender_brand: template.sender_brand };
  assert.deepEqual(await worker.userReports(row), { not_financial: 2, wrong_amount: 1 });
  assert.deepEqual(await worker.userReports({ ...row, template_hash: "e".repeat(64) }), {});

  // Siblings: another layout of the sender with a ready rule counts; a queued one does not.
  await pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK',$2,'ready')", [other.hash, other.body]);
  await pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK',$2,'ready')", [template.template_hash, template.redacted_body]);
  const siblings = await worker.siblingLayouts(row);
  assert.deepEqual(siblings.map((entry) => entry.template_hash), [other.hash]);
  await pool.query("UPDATE sms_v2_unknown_templates SET ai_status='queued' WHERE template_hash=$1", [other.hash]);
  assert.deepEqual(await worker.siblingLayouts(row), []);
  assert.ok((await worker.ruleCandidates()).every((body) => body && body.id));
});

// ---- learning loop B6: how a private AI rule fares on phones, shown on its draft

const { startLoopHarness: startRig, registerAllLoopAdminRoutes: registerAll, skip: rigSkip } = require("./helpers/loop_harness");
const { runRuleJobs } = require("../../src/sms_v2/rule_stats");
const { createPgStore } = require("../../src/sms_v2/rules_store");

test("phones report a private AI rule, and its draft shows the 30-day totals", { skip: rigSkip }, async (t) => {
  const rig = await startRig({ profileCount: 3, registerAdmin: registerAll });
  t.after(() => rig.close());
  const hash = "a".repeat(64);
  const quiet = "b".repeat(64);
  await rig.pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status,ai_draft) VALUES($1,'TESTBK',$2,'ready',$3)",
    [hash, template.redacted_body, JSON.stringify(rule())]);
  await rig.pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK',$2,'queued')", [quiet, "<AMT> credited."]);
  const today = new Date().toISOString().slice(0, 10);
  const report = (profile, stats) => rig.asUser(profile).post("/sms/v2/rule-stats:batch", { day: today, appVersion: "2.0.0", bundleVersion: 1, stats });
  // The rule is not in sms_v2_rules: the server stores the counts all the same.
  for (const [profile, hits, corrected] of [[rig.profiles[0], 5, 1], [rig.profiles[1], 4, 0], [rig.profiles[2], 3, 1]]) {
    assert.equal((await report(profile, [{ ruleId: `AI-${hash}`, ruleVersion: 1, hits, toReview: hits, corrected }])).status, 202);
  }
  assert.equal((await rig.pool.query("SELECT count(*)::int AS n FROM sms_v2_rule_stats_profile_daily WHERE rule_id=$1", [`AI-${hash}`])).rows[0].n, 3);
  const adminStore = createPgStore({ withUserClient: (admin, fn) => rig.helpers.withAdminClient(admin, "learning.publish", fn) });
  await runRuleJobs({ store: adminStore, signer: rig.signer, adminId: rig.admin, now: new Date() });
  const listed = (await rig.asAdmin().get("/admin/sms/v2/templates")).body.templates;
  const byHash = Object.fromEntries(listed.map((row) => [row.template_hash, row]));
  assert.deepEqual([byHash[hash].privateHits, byHash[hash].privateCorrected, byHash[hash].privatePhones], [12, 2, 3]);
  assert.deepEqual([byHash[quiet].privateHits, byHash[quiet].privateCorrected, byHash[quiet].privatePhones], [null, null, null], "no reports, no line");
  // Auto-pause never touches a private rule: it is in no cohort.
  assert.deepEqual((await rig.pool.query("SELECT 1 FROM sms_v2_rule_cohorts")).rows, []);
});
