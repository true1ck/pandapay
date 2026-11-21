"use strict";
// The draft audit's two database operations, as the restricted sms_ai_worker login: reading the ready drafts that still
// have consenting submitters and no admin decision, and replacing one draft only if it is still exactly what was read
// (compare-and-set), bumping its result revision so phones pull the new version. Needs the loop harness' URLs and
// SMS_V2_TEST_AI_WORKER_DATABASE_URL.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { createPgWorkerStore } = require("../../src/sms_v2/template_worker");
const { openAiWorkerStore } = require("../../src/sms_v2/ai_worker_store");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const sha = (brand, body) => crypto.createHash("sha256").update(`${brand}\n${body}`, "utf8").digest("hex");

test("ready drafts are read and replaced only while consented, undecided and unchanged", { skip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 1, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const opened = await openAiWorkerStore({ env: { SMS_AI_WORKER_DATABASE_URL: workerUrl, DB_SSL: "false", NODE_ENV: "test" } });
  t.after(() => opened.pool.end());
  const worker = createPgWorkerStore({ transaction: opened.transaction, draftingVersion: "v1" });
  await rig.consent(profiles[0], true);

  const bodies = ["<AMT> paid to <PARTY>. Ready case.", "<AMT> paid to <PARTY>. Decided case.", "<AMT> paid to <PARTY>. Queued case."];
  const hashes = bodies.map((b) => sha("TESTBK", b));
  const items = bodies.map((redactedBody) => ({ templateHash: sha("TESTBK", redactedBody), senderBrand: "TESTBK", redactedBody, observedAt: new Date().toISOString() }));
  assert.equal((await rig.asUser(profiles[0]).post("/sms/v2/unknown-templates", { items })).status, 202);
  const draft = (n) => ({ id: "AI-DRAFT", version: 1, match: { pattern: "^x$" }, emit: [{ factType: "info", attrs: { category: "other", n } }] });
  const set = (h, status, rule, decision = null) => pool.query(
    "UPDATE sms_v2_unknown_templates SET ai_status=$2, ai_draft=$3::jsonb, admin_decision=$4 WHERE template_hash=$1", [h, status, rule && JSON.stringify(rule), decision]);
  await set(hashes[0], "ready", draft(1));
  await set(hashes[1], "ready", draft(2), "approved");
  const revision = async (h) => (await pool.query("SELECT result_revision::text r FROM sms_v2_unknown_templates WHERE template_hash=$1", [h])).rows[0].r;

  // the worker login still cannot edit a ready row directly: the function is the only way
  await assert.rejects(opened.transaction((client) => client.query("UPDATE sms_v2_unknown_templates SET ai_draft='{}'::jsonb WHERE template_hash=$1", [hashes[0]]).then((r) => { if (r.rowCount) throw new Error("direct update allowed"); throw new Error("no rows"); })), /no rows/);
  const rows = await worker.readyDraftsForAudit();
  assert.deepEqual(rows.map((r) => r.template_hash), [hashes[0]], "only the ready, undecided, consented one");
  assert.equal(rows[0].redacted_body, bodies[0]);
  assert.deepEqual(typeof rows[0].ai_draft === "string" ? JSON.parse(rows[0].ai_draft) : rows[0].ai_draft, draft(1));

  const before = revision(hashes[0]);
  assert.equal(await worker.replaceReadyDraft(hashes[0], draft(1), draft(9)), true);
  assert.deepEqual((await pool.query("SELECT ai_draft FROM sms_v2_unknown_templates WHERE template_hash=$1", [hashes[0]])).rows[0].ai_draft, draft(9));
  assert.notEqual(await revision(hashes[0]), await before, "phones see a new revision");
  assert.equal(await worker.replaceReadyDraft(hashes[0], draft(1), draft(10)), false, "a stale 'before' never overwrites");
  assert.deepEqual((await pool.query("SELECT ai_draft FROM sms_v2_unknown_templates WHERE template_hash=$1", [hashes[0]])).rows[0].ai_draft, draft(9));
  // only the emit may change: a different pattern, id or any other key is refused by the database itself
  await assert.rejects(worker.replaceReadyDraft(hashes[0], draft(9), { ...draft(9), match: { pattern: "^evil$" } }), /only the emit of a draft may change/);
  await assert.rejects(worker.replaceReadyDraft(hashes[0], draft(9), { ...draft(9), extra: 1 }), /only the emit of a draft may change/);
  await assert.rejects(worker.replaceReadyDraft(hashes[0], draft(9), { ...draft(9), emit: "no" }), /only the emit of a draft may change/);
  assert.equal(await worker.replaceReadyDraft(hashes[1], draft(2), draft(11)), false, "an admin-decided draft is never touched");
  assert.equal(await worker.replaceReadyDraft(hashes[2], draft(3), draft(12)), false, "only a ready draft is replaced");

  await rig.consent(profiles[0], false);
  assert.deepEqual(await worker.readyDraftsForAudit(), [], "without consenting submitters nothing is read");
});
