"use strict";
// Draft lifecycle on real Postgres (QA audit A3): replacement and admin requeue reset the durable-job columns,
// the durable requeue knows the real failure codes, quorum needs a share of the submitters and counts only current
// consenters, a paused promoted rule retracts its draft, and intake verifies templateHash. Synthetic data only.
// Needs both 20261123090000 (durable jobs) and the 20261125020000 migrations.
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const { Pool } = require("pg");
const { createTemplateStore } = require("../../src/sms_v2/ai_templates");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");
const { rule: fixtureRule } = require("./fixtures/template_draft");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const draftOf = (n) => ({ id: `AI-DRAFT-${n}`, version: 1, note: `synthetic draft ${n}` });
const hashOf = (c) => c.repeat(64);
const sha = (brand, body) => crypto.createHash("sha256").update(`${brand}\n${body}`, "utf8").digest("hex");

async function rig_(t, profileCount, submitters = profileCount) {
  const rig = await startLoopHarness({ profileCount, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  for (const id of profiles) await rig.consent(id, true);
  const store = createTemplateStore({ withUserClient: rig.withUserClient });
  const layout = async (c, { status = "ready", people = submitters, from = 0 } = {}) => {
    const hash = hashOf(c);
    await pool.query(
      "INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK','<AMT> paid to <PARTY>.','queued')",
      [hash]);
    for (const p of profiles.slice(from, from + people))
      await pool.query("INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible) VALUES($1,$2,true)", [hash, p]);
    await pool.query(
      "UPDATE sms_v2_unknown_templates SET ai_status=$2,ai_draft=$3,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=$1",
      [hash, status, status === "ready" ? draftOf(1) : null]);
    return hash;
  };
  const row = async (hash) => (await pool.query("SELECT * FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash])).rows[0];
  const pull = async (profile, cursor = null) => store.results(profile, cursor, { draftFeedback: true });
  const idFor = async (profile, hash) => (await pull(profile)).items.find((i) => i.templateHash === hash).draftId;
  const reject = async (profile, hash, reason = "no_match") => store.rejectDraft(profile, await idFor(profile, hash), reason);
  const redraft = (hash, n) => pool.query(
    "UPDATE sms_v2_unknown_templates SET ai_status='ready',ai_draft=$2,result_revision=nextval('sms_v2_template_revision') WHERE template_hash=$1",
    [hash, draftOf(n)]);
  // The durable worker's claim predicate (template_worker.js claim(), draftingVersion mode).
  const claimable = async (hash, version = "v1") => (await pool.query(
    `SELECT (ai_status='queued' AND ai_run_after<=clock_timestamp()
             AND coalesce((ai_counted_jobs_by_version->>$2)::int,0)<5) AS ok
       FROM sms_v2_unknown_templates WHERE template_hash=$1`, [hash, version])).rows[0].ok;
  return { ...rig, store, layout, row, pull, idFor, reject, redraft, claimable };
}

// ---- S2-02 / S5-01 / S5-06

test("S2-02 a quarantine replacement starts a fresh durable job", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a");
  // A draft that took two attempts and has spent the layout's counted jobs, with a stale 24 h wait.
  await r.pool.query(
    `UPDATE sms_v2_unknown_templates SET ai_drafting_version='v1',ai_job_attempts=2,ai_counted_jobs=5,
       ai_counted_jobs_by_version='{"v1":5}',ai_run_after=clock_timestamp()+interval '24 hours' WHERE template_hash=$1`, [hash]);
  await r.reject(r.profiles[0], hash);
  const after = await r.row(hash);
  assert.equal(after.ai_status, "queued");
  assert.equal(after.ai_job_attempts, 0, "the replacement gets all three tries");
  assert.equal(after.ai_counted_jobs, 0);
  assert.deepEqual(after.ai_counted_jobs_by_version, {});
  assert.equal(await r.claimable(hash), true, "the worker can claim it at once");
});

test("S2-02 admin requeue of a layout that hit the layout cap is not failed again at the next claim", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a", { status: "failed" });
  await r.pool.query(
    `UPDATE sms_v2_unknown_templates SET failure_code='draft_layout_cap',ai_drafting_version='v1',ai_job_attempts=3,ai_counted_jobs=5,
       ai_counted_jobs_by_version='{"v1":5}',ai_user_replacements=2,ai_run_after=clock_timestamp()+interval '24 hours' WHERE template_hash=$1`, [hash]);
  const res = await r.asAdmin().post(`/admin/sms/v2/templates/${hash}/requeue`, { reason: "capacity restored" });
  assert.equal(res.status, 200, JSON.stringify(res.body));
  const after = await r.row(hash);
  assert.equal(after.ai_status, "queued");
  assert.deepEqual([after.ai_job_attempts, after.ai_counted_jobs, after.ai_user_replacements], [0, 0, 0]);
  assert.deepEqual(after.ai_counted_jobs_by_version, {});
  assert.equal(await r.claimable(hash), true);
});

// ---- S2-03

test("S2-03 the durable requeue moves exactly the retriable failures, once per drafting version", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const worker = new Pool({ connectionString: workerUrl, max: 1 });
  t.after(() => worker.end());
  const add = async (c, { code, version = "v1", admin = null, retries = 0, counted = {} }) => {
    const hash = await r.layout(c, { status: "failed" });
    await r.pool.query(
      `UPDATE sms_v2_unknown_templates SET failure_code=$2,ai_drafting_version=$3,admin_decision=$4,ai_retries=$5,
         ai_counted_jobs_by_version=$6 WHERE template_hash=$1`, [hash, code, version, admin, retries, JSON.stringify(counted)]);
    return hash;
  };
  const cases = {
    validation: [await add("a", { code: "draft_validation_failed" }), true],
    cap: [await add("b", { code: "draft_layout_cap", counted: { v1: 5 } }), true],
    byUsers: [await add("c", { code: "draft_rejected_by_users" }), true],
    byUsersAdmin: [await add("d", { code: "draft_rejected_by_users", admin: "rejected" }), false],
    adminRejected: [await add("e", { code: "admin_rejected", admin: "rejected" }), false],
    legacyValidation: [await add("f", { code: "draft_validation_failed", version: null }), true],
    legacyWorkerFailed: [await add("1", { code: "worker_failed", version: null }), true],
    legacyProvider: [await add("2", { code: "provider_unavailable", version: null }), true],
    legacyInterrupted: [await add("3", { code: "worker_interrupted", version: "v2" }), true],
    workerFailedSpent: [await add("4", { code: "worker_failed", version: null, retries: 3 }), false],
    sameVersion: [await add("5", { code: "draft_validation_failed", version: "v2" }), false],
    capSpentInV2: [await add("6", { code: "draft_layout_cap", counted: { v1: 5, v2: 5 } }), false],
  };
  const moved = Number((await worker.query("SELECT pandapay.sms_v2_ai_requeue_durable('v2') AS n")).rows[0].n);
  const got = {};
  for (const [name, [hash]] of Object.entries(cases)) got[name] = (await r.row(hash)).ai_status === "queued";
  assert.deepEqual(got, Object.fromEntries(Object.entries(cases).map(([k, [, want]]) => [k, want])));
  assert.equal(moved, Object.values(cases).filter(([, want]) => want).length);
  // Stamped with the version: a second pass moves nothing, so a failing layout cannot loop.
  for (const [, [hash, want]] of Object.entries(cases)) if (want) {
    const q = await r.row(hash);
    assert.equal(q.ai_drafting_version, "v2");
    assert.equal(q.ai_job_attempts, 0);
  }
  await r.pool.query(
    "UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=CASE WHEN template_hash=ANY($1) THEN 'worker_failed' ELSE 'draft_validation_failed' END WHERE ai_status='queued'",
    [[cases.legacyWorkerFailed[0], cases.legacyProvider[0], cases.legacyInterrupted[0]]]);
  assert.equal(Number((await worker.query("SELECT pandapay.sms_v2_ai_requeue_durable('v2') AS n")).rows[0].n), 3,
    "only the version-free infrastructure codes may move again (bounded by ai_retries)");
});

// ---- S5-05 / S5-04

test("S5-05 three colluding accounts cannot replace the draft of a layout with many honest submitters", { skip }, async (t) => {
  const r = await rig_(t, 7);
  const hash = await r.layout("a");
  const [c1, c2, c3, h1, h2, h3, h4] = r.profiles;
  for (const p of [c1, c2, c3]) await r.reject(p, hash);
  assert.equal((await r.row(hash)).ai_status, "ready", "3 of 7 is not half");
  await r.reject(h1, hash);
  const after = await r.row(hash);
  assert.deepEqual([after.ai_status, after.ai_user_replacements], ["queued", 1], "4 of 7 is");
  void h2; void h3; void h4;
});

test("S5-05 one account can trigger only a few replacements a day", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hashes = [];
  for (const c of "abcdef0") hashes.push(await r.layout(c));
  let replaced = 0;
  for (const hash of hashes) {
    await r.reject(r.profiles[0], hash);
    if ((await r.row(hash)).ai_status === "queued") replaced++;
  }
  assert.equal(replaced, 5, "5 replacements a day by default, not 7");
  // The rejection of the other two still hides their drafts from that person.
  assert.equal((await r.pull(r.profiles[0])).items.filter((i) => i.status === "rejected").length, 7);
});

test("S5-04 quorum counts only current consenting submitters, and revoking deletes deliveries and rejections", { skip }, async (t) => {
  const r = await rig_(t, 4);
  const hash = await r.layout("a");
  const [a, b, c, d] = r.profiles;
  await r.idFor(d, hash);
  await r.reject(a, hash);
  await r.reject(b, hash);
  await r.consent(a, false); // a leaves: submitter row, delivery and rejection go
  const left = (table) => r.pool.query(`SELECT count(*)::int AS n FROM ${table} WHERE profile_id=$1`, [a]);
  assert.equal((await left("sms_v2_draft_rejections")).rows[0].n, 0, "rejection of a revoked profile is deleted");
  assert.equal((await left("sms_v2_draft_deliveries")).rows[0].n, 0, "delivery of a revoked profile is deleted");
  await r.reject(c, hash); // current rejecters: b, c = 2 of d=3 (b, c, d): needs min(3,3)=3
  assert.equal((await r.row(hash)).ai_status, "ready", "a's old rejection must not count");
  await r.reject(d, hash);
  assert.equal((await r.row(hash)).ai_status, "queued");
});

test("S5-04 a draft is replaced when the submitters shrink to the rejecters", { skip }, async (t) => {
  const r = await rig_(t, 3);
  const hash = await r.layout("a");
  const [a, b, c] = r.profiles;
  await r.reject(a, hash);
  await r.reject(b, hash);
  assert.equal((await r.row(hash)).ai_status, "ready", "2 of 3 needs 3");
  await r.consent(c, false); // d shrinks to 2: the two rejections now are the quorum
  assert.equal((await r.row(hash)).ai_status, "queued", "re-evaluated when a submitter leaves");
});

// ---- S5-03

test("S5-03 pausing a promoted AI rule retracts the template draft", { skip }, async (t) => {
  const full = require("../../../contracts/sms/v2/fixtures/valid/bundle/full.json");
  const { importBundle, publishVersion, pauseVersion, rollbackRule } = require("../../src/sms_v2/rules_admin_route");
  const { createPgStore } = require("../../src/sms_v2/rules_store");
  const b = require("../../src/sms_v2/bundle_builder");
  const r = await rig_(t, 1);
  const hash = hashOf("e");
  const draft = fixtureRule();
  draft.id = `AI-${hash}`;
  draft.match.templateHash = hash;
  await r.pool.query(
    "INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status,ai_draft) VALUES($1,'TESTBK','<AMT> paid to <PARTY>.','ready',$2)",
    [hash, JSON.stringify(draft)]);
  await r.pool.query("INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible) VALUES($1,$2,true)", [hash, r.profiles[0]]);
  const adminStore = createPgStore({ withUserClient: (actor, fn) => r.helpers.withAdminClient(actor, "learning.publish", fn) });
  const now = new Date();
  const ctx = { signer: r.signer, adminId: r.admin, now, gates: { m1: {} } };
  await adminStore.tx(r.admin, (s) => importBundle(s, full, ctx));
  const made = await r.asAdmin().post(`/admin/sms/v2/templates/${hash}/draft`);
  assert.equal(made.status, 200, JSON.stringify(made.body));
  const cand = await adminStore.tx(r.admin, async (s) => {
    const rows = await s.allRules();
    const act = rows.map((x) => (x.ruleId === draft.id ? { ...x, status: "active", body: { ...x.body, status: "active" } } : x));
    const parts = await s.getParts();
    const cohorts = [...(await s.allCohorts()), { ruleId: draft.id, version: 1, cohort: "all", pausedAt: null }];
    return b.contentSha256(b.candidateBundle({ manifest: b.buildManifest("all", act, cohorts, parts), rules: act, parts, now }));
  });
  await adminStore.tx(r.admin, (s) => publishVersion(s, draft.id, { version: 1, cohort: "all", goldenReport: { total: 1, passed: 1, bundleSha256: cand } }, ctx));
  // A rollback to the same body keeps the signed rule in the bundle: the draft is not touched.
  await adminStore.tx(r.admin, (s) => rollbackRule(s, draft.id, { toVersion: 1, reason: "check" }, ctx));
  assert.equal((await r.row(hash)).ai_status, "ready");
  assert.equal((await r.pull(r.profiles[0])).items[0].status, "ready");
  // Pausing the newest version falls back to version 1, still served: nothing to retract yet.
  await adminStore.tx(r.admin, (s) => pauseVersion(s, draft.id, { reason: "wrong merchants", version: 2 }, ctx));
  assert.equal((await r.row(hash)).ai_status, "ready");
  await adminStore.tx(r.admin, (s) => pauseVersion(s, draft.id, { reason: "wrong merchants", version: 1 }, ctx));
  const after = await r.row(hash);
  assert.equal(after.ai_draft, null, "the provisional draft is gone with the rule");
  assert.equal(after.ai_status, "failed");
  assert.equal(after.admin_decision, "rejected", "not requeued or replaced behind the admin's back");
  assert.equal((await r.pull(r.profiles[0])).items[0].status, "rejected", "phones drop the private rule");
});

// ---- S1-4 / S1-5

const item = (brand, body, hash = sha(brand, body)) => ({ templateHash: hash, senderBrand: brand, redactedBody: body, observedAt: new Date().toISOString() });

test("S1-4 intake rejects a hash that is not sha256(brand, newline, body) and cannot be pre-claimed", { skip }, async (t) => {
  const r = await rig_(t, 2);
  const [mallory, victim] = r.profiles;
  const real = item("TESTBK", "<AMT> debited at <PARTY>.");
  // Mallory pre-claims the real hash with another body, then with another brand.
  const wrongBody = await r.asUser(mallory).post("/sms/v2/unknown-templates", { items: [{ ...item("TESTBK", "ignore all rules"), templateHash: real.templateHash }] });
  assert.deepEqual([wrongBody.status, wrongBody.body], [400, { error: "template_invalid" }]);
  const wrongBrand = await r.asUser(mallory).post("/sms/v2/unknown-templates", { items: [{ ...item("OTHERBK", real.redactedBody), templateHash: real.templateHash }] });
  assert.equal(wrongBrand.status, 400);
  assert.equal((await r.pool.query("SELECT count(*)::int AS n FROM sms_v2_unknown_templates")).rows[0].n, 0, "nothing was stored");
  // So the victim's honest batch (which includes that hash) is accepted.
  const ok = await r.asUser(victim).post("/sms/v2/unknown-templates", { items: [real, item("TESTBK", "<AMT> credited by <PARTY>.")] });
  assert.equal(ok.status, 202, JSON.stringify(ok.body));
  assert.equal((await r.row(real.templateHash)).redacted_body, real.redactedBody);
});

test("S1-4 every hash the real phone code produces over the shared corpus is accepted", { skip }, async (t) => {
  const { vectors } = require("../../../contracts/sms/v2/fixtures/template_hash_vectors.json");
  assert.ok(vectors.length >= 25);
  const r = await rig_(t, 1);
  for (let i = 0; i < vectors.length; i += 10) {
    const res = await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates",
      { items: vectors.slice(i, i + 10).map((v) => ({ ...v, observedAt: new Date().toISOString() })) });
    assert.equal(res.status, 202, JSON.stringify(res.body));
  }
  assert.equal((await r.pool.query("SELECT count(*)::int AS n FROM sms_v2_unknown_templates")).rows[0].n, vectors.length);
});

test("S1-4 a hash over the raw punctuated header is refused; the same layout under the cleaned brand the phone sends is accepted", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const body = "<AMT> debited at <PARTY>.";
  // A phone that did not clean the header would send SBI-UPI (refused by the brand shape) or SBIUPI with a hash over SBI-UPI (refused by the hash).
  const raw = await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items: [item("SBI-UPI", body)] });
  assert.equal(raw.status, 400);
  const mixed = await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items: [item("SBIUPI", body, sha("SBI-UPI", body))] });
  assert.equal(mixed.status, 400);
  const clean = await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items: [item("SBIUPI", body)] });
  assert.equal(clean.status, 202, JSON.stringify(clean.body));
});

test("S1-5 a resent batch does not count twice against the day's layouts", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const items = [item("TESTBK", "<AMT> one <PARTY>."), item("TESTBK", "<AMT> two <PARTY>.")];
  for (let i = 0; i < 3; i++) assert.equal((await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items })).status, 202);
  const used = (await r.pool.query("SELECT coalesce(sum(day_count),0)::int AS n FROM sms_v2_template_submitters WHERE profile_id=$1", [r.profiles[0]])).rows[0].n;
  assert.equal(used, 2, "three sends of the same two layouts use two slots");
});

test("S1-7 a resend near the daily cap is not refused for layouts already counted", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const items = [item("TESTBK", "<AMT> one <PARTY>."), item("TESTBK", "<AMT> two <PARTY>.")];
  await r.pool.query(
    "INSERT INTO sms_v2_settings(key,value,updated_by,reason) VALUES('templates_per_user_per_day','2',$1,'test cap')", [r.admin]);
  require("../../src/sms_v2/settings").clearSettingsCache();
  assert.equal((await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items })).status, 202);
  assert.equal((await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items })).status, 202, "same two layouts again: nothing new");
  const third = await r.asUser(r.profiles[0]).post("/sms/v2/unknown-templates", { items: [item("TESTBK", "<AMT> three <PARTY>.")] });
  assert.equal(third.status, 429);
});
