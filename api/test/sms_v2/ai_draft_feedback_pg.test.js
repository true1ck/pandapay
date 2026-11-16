"use strict";
// Draft feedback on real Postgres: delivery ids, rejection report, quorum, replacement, guards.
// Synthetic data only.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { createTemplateStore } = require("../../src/sms_v2/ai_templates");
const { createPgWorkerStore } = require("../../src/sms_v2/template_worker");
const { startLoopHarness, registerAllLoopAdminRoutes, skip } = require("./helpers/loop_harness");

const draftOf = (n) => ({ id: `AI-DRAFT-${n}`, version: 1, note: `synthetic draft ${n}` });
const hashOf = (c) => c.repeat(64);

async function rig_(t, profileCount, submitters = profileCount) {
  const rig = await startLoopHarness({ profileCount, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  for (const id of profiles) await rig.consent(id, true);
  const store = createTemplateStore({ withUserClient: rig.withUserClient });
  // A layout already answered by the AI: ready, with a draft, seen by the first `people` people.
  const layout = async (c, { status = "ready", people = submitters } = {}) => {
    const hash = hashOf(c);
    await pool.query(
      "INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK','<AMT> paid to <PARTY>.','queued')",
      [hash]);
    for (const p of profiles.slice(0, people))
      await pool.query("INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible) VALUES($1,$2,true)", [hash, p]);
    await pool.query(
      "UPDATE sms_v2_unknown_templates SET ai_status=$2,ai_draft=$3,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=$1",
      [hash, status, status === "ready" ? draftOf(1) : null]);
    return hash;
  };
  const row = async (hash) => (await pool.query("SELECT * FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash])).rows[0];
  const pull = async (profile, cursor = null, draftFeedback = true) => store.results(profile, cursor, { draftFeedback });
  const idFor = async (profile, hash) => (await pull(profile)).items.find((i) => i.templateHash === hash).draftId;
  const reject = (profile, draftId, reason = "no_match") => store.rejectDraft(profile, draftId, reason);
  // The next draft for a layout, as the worker would store it (the trigger bumps the revision).
  const redraft = (hash, n) => pool.query(
    "UPDATE sms_v2_unknown_templates SET ai_status='ready',ai_draft=$2,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=$1",
    [hash, draftOf(n)]);
  const count = async (table) => (await pool.query(`SELECT count(*) FROM ${table}`)).rows[0].count;
  return { ...rig, store, layout, row, pull, idFor, reject, redraft, count };
}

test("delivery gives one stable draftId per person and revision; old clients get none", { skip }, async (t) => {
  const r = await rig_(t, 2);
  const hash = await r.layout("a");
  const [p0, p1] = r.profiles;
  assert.equal((await r.row(hash)).ai_draft_revision, "1");
  const a = (await r.pull(p0)).items[0];
  const b = (await r.pull(p0)).items[0];
  assert.match(a.draftId, /^[0-9a-f-]{36}$/);
  assert.equal(a.draftId, b.draftId);
  assert.equal(a.status, "ready");
  assert.notEqual((await r.pull(p1)).items[0].draftId, a.draftId);
  // An older phone: same rows as before, no draftId, no delivery row.
  await r.pool.query("DELETE FROM sms_v2_draft_deliveries");
  const old = await r.pull(p0, null, false);
  assert.equal("draftId" in old.items[0], false);
  assert.equal(await r.count("sms_v2_draft_deliveries"), "0");
  // A new revision is a new draftId.
  const first = (await r.pull(p0)).items[0].draftId;
  await r.redraft(hash, 2);
  assert.notEqual((await r.pull(p0)).items[0].draftId, first);
});

test("results for layouts nobody rejected match the previous function exactly (old client)", { skip }, async (t) => {
  const r = await rig_(t, 1);
  await r.layout("a");
  await r.layout("b", { status: "queued" });
  await r.layout("c", { status: "failed" });
  const as = (fn) => r.withUserClient(r.profiles[0], fn);
  const legacy = await r.pool.query(
    `SELECT t.template_hash,t.ai_status,t.ai_draft,greatest(t.result_revision,s.result_revision) AS revision
       FROM sms_v2_template_submitters s JOIN sms_v2_unknown_templates t USING(template_hash)
      WHERE s.profile_id=$1 AND greatest(t.result_revision,s.result_revision)>0 AND s.eligible
        AND pandapay.sms_shared_learning_granted(s.profile_id)
      ORDER BY 4,1 LIMIT 500`, [r.profiles[0]]);
  const now = await as((c) => c.query("SELECT * FROM pandapay.sms_v2_template_results(0,false)"));
  assert.deepEqual(
    now.rows.map(({ template_hash, ai_status, ai_draft, revision }) => ({ template_hash, ai_status, ai_draft, revision })),
    legacy.rows);
  assert.ok(now.rows.every((x) => x.draft_id === null && x.rejected === false));
  assert.equal(await r.count("sms_v2_draft_deliveries"), "0");
});

test("a draft not delivered to the caller answers 404 draft_not_delivered, same as an unknown id", { skip }, async (t) => {
  const r = await rig_(t, 2);
  const hash = await r.layout("a");
  const mine = await r.idFor(r.profiles[0], hash);
  const post = (profile, draftId) => r.asUser(profile).post("/sms/v2/draft-rejections", { draftId, reason: "no_match" });
  const other = await post(r.profiles[1], mine);
  const unknown = await post(r.profiles[1], crypto.randomUUID());
  assert.deepEqual([other.status, other.body], [404, { error: "draft_not_delivered" }]);
  assert.deepEqual([unknown.status, unknown.body], [other.status, other.body]);
  assert.equal(await r.count("sms_v2_draft_rejections"), "0");
  const ok = await post(r.profiles[0], mine);
  assert.deepEqual([ok.status, ok.body], [200, { status: "recorded" }]);
});

test("repeat report is already_recorded; own rejection hides the draft for that person only", { skip }, async (t) => {
  const r = await rig_(t, 5);
  const hash = await r.layout("a");
  const [p0, p1] = r.profiles;
  const id0 = await r.idFor(p0, hash);
  await r.idFor(p1, hash);
  const cursorBefore = (await r.store.results(p0, null)).cursor;
  assert.equal(await r.reject(p0, id0), "recorded");
  assert.equal(await r.reject(p0, id0, "unsafe_rule"), "already_recorded");
  assert.equal(await r.count("sms_v2_draft_rejections"), "1");
  assert.equal((await r.row(hash)).ai_status, "ready", "five people: one rejection does not quarantine");
  assert.deepEqual((await r.pull(p0)).items[0], { templateHash: hash, status: "rejected" });
  assert.equal((await r.pull(p1)).items[0].status, "ready");
  // A phone that already holds the draft learns of it: the reporter's own revision moved past its cursor.
  const again = await r.store.results(p0, cursorBefore, { draftFeedback: false });
  assert.deepEqual(again.items, [{ templateHash: hash, status: "rejected" }]);
  assert.equal((await r.store.results(p1, cursorBefore, { draftFeedback: true })).items.length, 0);
});

test("a layout seen by one person is replaced after that one rejection", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  const id = await r.idFor(r.profiles[0], hash);
  const before = await r.row(hash);
  assert.equal(await r.reject(r.profiles[0], id), "recorded");
  const after = await r.row(hash);
  assert.equal(after.ai_status, "queued");
  assert.equal(after.ai_draft, null);
  assert.equal(after.ai_user_replacements, 1);
  assert.equal(after.lease_id, null);
  assert.equal(after.lease_expires_at, null);
  assert.ok(BigInt(after.result_revision) > BigInt(before.result_revision));
  assert.ok(after.queued_at > before.queued_at);
  // The reporter's own rejection of that revision still hides it from them until a new draft arrives.
  assert.equal((await r.pull(r.profiles[0])).items[0].status, "rejected");
});

test("with several submitters quarantine needs three distinct rejecters", { skip }, async (t) => {
  const r = await rig_(t, 4);
  const hash = await r.layout("a");
  const ids = [];
  for (const p of r.profiles) ids.push(await r.idFor(p, hash));
  await r.reject(r.profiles[0], ids[0]);
  await r.reject(r.profiles[1], ids[1], "invalid_facts");
  await r.reject(r.profiles[1], ids[1]);
  assert.equal((await r.row(hash)).ai_status, "ready", "a repeat is not a third person");
  await r.reject(r.profiles[2], ids[2], "unsafe_rule");
  const after = await r.row(hash);
  assert.deepEqual([after.ai_status, after.ai_user_replacements, after.ai_draft], ["queued", 1, null]);
  assert.equal((await r.pull(r.profiles[3])).items[0].status, "pending");
  await r.redraft(hash, 2);
  assert.notEqual(await r.idFor(r.profiles[3], hash), ids[3]);
});

test("a stale report is recorded and changes nothing", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  const id = await r.idFor(r.profiles[0], hash);
  await r.redraft(hash, 2); // revision moved
  const mid = await r.row(hash);
  assert.equal(await r.reject(r.profiles[0], id), "recorded");
  const after = await r.row(hash);
  assert.deepEqual([after.ai_status, after.ai_user_replacements, after.result_revision], ["ready", 0, mid.result_revision]);
  assert.equal(await r.count("sms_v2_draft_rejections"), "1");
  assert.equal((await r.pull(r.profiles[0])).items[0].status, "ready", "the new draft is not hidden");
  // Row not ready any more.
  const id2 = await r.idFor(r.profiles[0], hash);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='working' WHERE template_hash=$1", [hash]);
  await r.reject(r.profiles[0], id2);
  const w = await r.row(hash);
  assert.deepEqual([w.ai_status, w.ai_user_replacements], ["working", 0]);
});

test("the second replacement is the last: the next quarantine goes to manual review", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  for (const n of [1, 2]) {
    await r.reject(r.profiles[0], await r.idFor(r.profiles[0], hash));
    const q = await r.row(hash);
    assert.deepEqual([q.ai_status, q.ai_user_replacements], ["queued", n]);
    await r.redraft(hash, n + 1);
  }
  await r.reject(r.profiles[0], await r.idFor(r.profiles[0], hash));
  const f = await r.row(hash);
  assert.deepEqual([f.ai_status, f.failure_code, f.ai_user_replacements, f.ai_draft], ["failed", "draft_rejected_by_users", 2, null]);
  assert.equal((await r.pull(r.profiles[0])).items[0].status, "rejected");
});

test("simultaneous rejections never create two replacements", { skip }, async (t) => {
  const r = await rig_(t, 3);
  const hash = await r.layout("a");
  const ids = [];
  for (const p of r.profiles) ids.push(await r.idFor(p, hash));
  const before = await r.row(hash);
  const results = await Promise.all(r.profiles.map((p, i) => r.reject(p, ids[i])));
  assert.deepEqual(results, ["recorded", "recorded", "recorded"]);
  const after = await r.row(hash);
  assert.deepEqual([after.ai_status, after.ai_user_replacements], ["queued", 1]);
  assert.ok(BigInt(after.result_revision) > BigInt(before.result_revision));
});

test("revoked consent: 403 and nothing recorded", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  const id = await r.idFor(r.profiles[0], hash);
  await r.consent(r.profiles[0], false);
  const res = await r.asUser(r.profiles[0]).post("/sms/v2/draft-rejections", { draftId: id, reason: "no_match" });
  assert.deepEqual([res.status, res.body], [403, { error: "sms_shared_learning_consent_required" }]);
  assert.equal(await r.count("sms_v2_draft_rejections"), "0");
  // Revoking removes the person's submissions (and the layout, when they were its only submitter).
});

test("phone rejections never override an admin decision, a block or a cover", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const cases = {
    approved: (h) => r.pool.query("UPDATE sms_v2_unknown_templates SET admin_decision='approved' WHERE template_hash=$1", [h]),
    adminRejected: (h) => r.pool.query("UPDATE sms_v2_unknown_templates SET admin_decision='rejected' WHERE template_hash=$1", [h]),
    blocked: (h) => r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='blocked' WHERE template_hash=$1", [h]),
    covered: (h) => r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='covered' WHERE template_hash=$1", [h]),
  };
  let n = 0;
  for (const [name, change] of Object.entries(cases)) {
    const hash = await r.layout("abcd"[n++]);
    const id = await r.idFor(r.profiles[0], hash);
    await change(hash);
    const before = await r.row(hash);
    assert.equal(await r.reject(r.profiles[0], id), "recorded", name);
    const after = await r.row(hash);
    assert.deepEqual(
      [after.ai_status, after.admin_decision, after.ai_user_replacements, after.failure_code, after.queued_at, after.lease_id],
      [before.ai_status, before.admin_decision, 0, before.failure_code, before.queued_at, before.lease_id], name);
    assert.deepEqual(after.ai_draft, before.ai_draft, name);
  }
  // Nothing was queued for the AI by any of them.
  assert.equal(await createPgWorkerStore({ ...r.helpers, adminId: r.admin }).claim(), null);
});

test("the worker claims a layout the phones sent back", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  await r.reject(r.profiles[0], await r.idFor(r.profiles[0], hash));
  const claimed = await createPgWorkerStore({ ...r.helpers, adminId: r.admin }).claim();
  assert.equal(claimed.template_hash, hash);
  assert.equal((await r.row(hash)).ai_status, "working");
});
