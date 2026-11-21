"use strict";
// Reliability SQL on real Postgres (22 Nov 2026 audit), migration 20261127000300: the attempts limit, failed_at, the person's
// "Try again", the slow automatic requeue. Synthetic data only.
const test = require("node:test");
const assert = require("node:assert/strict");
const { Pool } = require("pg");
const { startLoopHarness, registerAllLoopAdminRoutes, skip: loopSkip } = require("./helpers/loop_harness");
const { createPgWorkerStore } = require("../../src/sms_v2/template_worker");

const workerUrl = process.env.SMS_V2_TEST_AI_WORKER_DATABASE_URL;
const skip = loopSkip || !workerUrl;
const hashOf = (c) => c.repeat(Math.floor(64 / c.length));
const RETRYABLE = "draft_validation_failed";

async function rig_(t, profileCount = 2) {
  const rig = await startLoopHarness({ profileCount, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  for (const id of profiles) await rig.consent(id, true);
  // A layout submitted by `people` profiles and left in `status` (a failure gets its code).
  const layout = async (c, { status = "failed", code = RETRYABLE, people = 1, from = 0 } = {}) => {
    const hash = hashOf(c);
    await pool.query(
      "INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK','<AMT> paid to <PARTY>.','queued')",
      [hash]);
    for (const p of profiles.slice(from, from + people))
      await pool.query("INSERT INTO sms_v2_template_submitters(template_hash,profile_id,eligible) VALUES($1,$2,true)", [hash, p]);
    await pool.query(
      "UPDATE sms_v2_unknown_templates SET ai_status=$2,failure_code=$3,ai_drafting_version='v1',ai_job_attempts=3,ai_counted_jobs=5,ai_counted_jobs_by_version=$4::jsonb WHERE template_hash=$1",
      [hash, status, status === "failed" ? code : null, JSON.stringify({ v1: 5 })]);
    return hash;
  };
  const row = async (hash) => (await pool.query("SELECT * FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash])).rows[0];
  const press = (profile, hashes) =>
    rig.withUserClient(profile, (client) => client.query("SELECT pandapay.sms_v2_ai_retry_mine($1::text[]) AS n", [hashes]))
      .then((x) => Number(x.rows[0].n));
  return { ...rig, layout, row, press };
}

test("R-1 the attempts table takes the 15 attempts a job may make, and no more than 16", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a", { status: "queued" });
  const insert = (attempt) => r.pool.query(
    `INSERT INTO sms_v2_template_attempts(template_hash,job_id,attempt,model,capacity_minute,reserved_tokens,outcome)
     VALUES($1,gen_random_uuid(),$2,'synthetic-model',date_trunc('minute',clock_timestamp()),1,'rejected')`,
    [hash, attempt],
  );
  for (const attempt of [1, 8, 9, 15, 16]) await insert(attempt).catch((error) => assert.fail(`attempt ${attempt}: ${error.message}`));
  await assert.rejects(insert(17), { code: "23514" });
});

test("R-2 failed_at is stamped when a layout becomes failed, once, and not moved by other updates", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("b", { status: "queued" });
  assert.equal((await r.row(hash)).failed_at, null);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2 WHERE template_hash=$1", [hash, RETRYABLE]);
  const first = (await r.row(hash)).failed_at;
  assert.ok(first instanceof Date);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_detail=ARRAY['x'] WHERE template_hash=$1", [hash]);
  assert.equal((await r.row(hash)).failed_at.getTime(), first.getTime(), "a repeat of failed does not move it");
});

test("R-3 Try again: only the person's own failed layouts that can pass move, to the back of the queue with fresh tries", { skip }, async (t) => {
  const r = await rig_(t, 2);
  const mine = await r.layout("c", { people: 1, from: 0 });
  const theirs = await r.layout("d", { people: 1, from: 1 });
  const refused = await r.layout("e", { people: 1, from: 0, code: "layout_too_many_wildcards" });
  const ready = await r.layout("f", { people: 1, from: 0, status: "ready" });
  assert.equal(await r.press(r.profiles[0], [mine, theirs, refused, ready, hashOf("9")]), 1);
  const after = await r.row(mine);
  assert.deepEqual([after.ai_status, after.failure_code, after.ai_job_attempts, after.ai_counted_jobs], ["queued", null, 0, 0]);
  assert.equal(after.ai_counted_jobs_by_version.v1, undefined, "the per-version count is cleared so the cap does not return it at once");
  assert.equal(after.ai_user_retries, 1);
  assert.equal((await r.row(theirs)).ai_status, "failed");
  assert.equal((await r.row(refused)).ai_status, "failed", "a refusal by the matcher is not retried");
  assert.equal((await r.row(ready)).ai_status, "ready");
});

test("R-4 Try again is bounded per layout: one an hour, three in seven days, and it needs consent", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("a1", { people: 1 });
  const fail = (hoursAgo) => r.pool.query(
    "UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2,ai_user_retry_at=CASE WHEN $3::int IS NULL THEN ai_user_retry_at ELSE clock_timestamp()-$3::int*interval '1 hour' END WHERE template_hash=$1",
    [hash, RETRYABLE, hoursAgo]);
  assert.equal(await r.press(r.profiles[0], [hash]), 1);
  await fail(null);
  assert.equal(await r.press(r.profiles[0], [hash]), 0, "not within the hour");
  for (const n of [2, 3]) {
    await fail(2);
    assert.equal(await r.press(r.profiles[0], [hash]), 1, `press ${n}`);
  }
  await fail(2);
  assert.equal(await r.press(r.profiles[0], [hash]), 0, "the fourth press in seven days");
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_user_retry_at=clock_timestamp()-interval '8 days' WHERE template_hash=$1", [hash]);
  assert.equal(await r.press(r.profiles[0], [hash]), 1, "a week later the budget is fresh");
  await r.consent(r.profiles[0], false);
  await fail(null);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_user_retry_at=NULL WHERE template_hash=$1", [hash]);
  await assert.rejects(r.press(r.profiles[0], [hash]), { code: "42501" });
});

test("R-5 the endpoint end to end: 202 with the count, 400 for a bad body, nothing moves for a phone that is not counted", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const hash = await r.layout("b1", { people: 1 });
  const verified = r.asUser(r.profiles[0], { verified: true });
  assert.equal((await verified.post("/sms/v2/ai-status/retry", { templateHashes: ["nope"] })).status, 400);
  const uncounted = await r.asUser(r.profiles[0], { verified: false }).post("/sms/v2/ai-status/retry", { templateHashes: [hash] });
  assert.deepEqual([uncounted.status, uncounted.body], [202, { requeued: 0 }]);
  assert.equal((await r.row(hash)).ai_status, "failed");
  const ok = await verified.post("/sms/v2/ai-status/retry", { templateHashes: [hash] });
  assert.deepEqual([ok.status, ok.body], [202, { requeued: 1 }]);
  assert.equal((await r.row(hash)).ai_status, "queued");
});

test("R-6 the slow automatic requeue: 1, 3, 9 and 27 days, four times at most, only for failures that can pass, only with consent", { skip }, async (t) => {
  const r = await rig_(t, 1);
  const worker = new Pool({ connectionString: workerUrl });
  t.after(() => worker.end());
  const workerStore = createPgWorkerStore({
    transaction: async (operation) => {
      const client = await worker.connect();
      try {
        await client.query("BEGIN");
        const out = await operation(client);
        await client.query("COMMIT");
        return out;
      } catch (error) {
        await client.query("ROLLBACK");
        throw error;
      } finally {
        client.release();
      }
    },
    draftingVersion: "v1",
  });
  const old = await r.layout("c1", { people: 1 });
  const fresh = await r.layout("d1", { people: 1 });
  const refused = await r.layout("e1", { people: 1, code: "layout_too_many_wildcards" });
  const admin = await r.layout("f1", { people: 1 });
  await r.pool.query("UPDATE sms_v2_unknown_templates SET admin_decision='rejected' WHERE template_hash=$1", [admin]);
  const noConsent = await r.layout("a2", { people: 0 });
  await r.pool.query("UPDATE sms_v2_unknown_templates SET failed_at=clock_timestamp()-interval '2 days' WHERE template_hash = ANY($1::text[])", [[old, refused, admin, noConsent]]);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET failed_at=clock_timestamp()-interval '1 hour' WHERE template_hash=$1", [fresh]);
  assert.equal(await workerStore.requeueStale(), 1);
  const moved = await r.row(old);
  assert.deepEqual([moved.ai_status, moved.ai_auto_retries, moved.ai_job_attempts, moved.ai_counted_jobs], ["queued", 1, 0, 0]);
  for (const hash of [fresh, refused, admin, noConsent]) assert.equal((await r.row(hash)).ai_status, "failed");
  // It failed again 2 days later: the second retry waits 3 days, so not yet.
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2,failed_at=clock_timestamp()-interval '2 days' WHERE template_hash=$1", [old, RETRYABLE]);
  assert.equal(await workerStore.requeueStale(), 0);
  await r.pool.query("UPDATE sms_v2_unknown_templates SET failed_at=clock_timestamp()-interval '4 days' WHERE template_hash=$1", [old]);
  assert.equal(await workerStore.requeueStale(), 1);
  // Four automatic retries and it stays failed.
  await r.pool.query("UPDATE sms_v2_unknown_templates SET ai_status='failed',failure_code=$2,ai_auto_retries=4,failed_at=clock_timestamp()-interval '365 days' WHERE template_hash=$1", [old, RETRYABLE]);
  assert.equal(await workerStore.requeueStale(), 0);
});
