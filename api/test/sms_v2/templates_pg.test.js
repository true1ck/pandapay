"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { template, config, rule } = require("./fixtures/template_draft");
const { createTemplateStore } = require("../../src/sms_v2/ai_templates");
const {
  createPgWorkerStore,
  runTemplateWorkerOnce,
} = require("../../src/sms_v2/template_worker");
const { validateResponse } = require("../../src/sms_v2/contracts");
const {
  startLoopHarness,
  registerAllLoopAdminRoutes,
  skip: loopSkip,
} = require("./helpers/loop_harness");

test(
  "template submission, worker, owner sync and private draft on fully migrated Postgres",
  { skip: loopSkip },
  async (t) => {
    const rig = await startLoopHarness({
      profileCount: 4,
      registerAdmin: registerAllLoopAdminRoutes,
    });
    t.after(() => rig.close());
    const { pool, profiles, withUserClient } = rig;
    const consent = (id, granted) => rig.consent(id, granted);
    const store = createTemplateStore({ withUserClient });
    const item = {
      templateHash: template.template_hash,
      senderBrand: template.sender_brand,
      redactedBody: template.redacted_body,
      observedAt: new Date().toISOString(),
    };
    await assert.rejects(store.submit(profiles[0], [item], true), {
      code: "42501",
    });
    for (const id of profiles) await consent(id, true);
    await assert.rejects(
      store.submit(
        profiles[0],
        [{ ...item, redactedBody: "call 9876543210" }],
        true,
      ),
      { code: "22023" },
    );
    assert.equal(
      (
        await withUserClient(profiles[0], (client) =>
          client.query("SELECT * FROM sms_v2_unknown_templates"),
        )
      ).rows.length,
      0,
    );
    const submit = async (profile, verified, items = [item]) =>
      rig
        .asUser(profile, { verified })
        .post("/sms/v2/unknown-templates", { items });
    assert.equal((await submit(profiles[0], false)).status, 202);
    assert.equal(
      (await pool.query("SELECT ai_status FROM sms_v2_unknown_templates"))
        .rows[0].ai_status,
      "held",
    );
    const worker = createPgWorkerStore({
      ...rig.helpers,
      adminId: rig.admin,
    });
    let calls = 0;
    const provider = {
      generate: async ({ prompt }) => {
        calls++;
        assert.equal(JSON.parse(prompt).redactedBody, template.redacted_body);
        return {
          rule: rule(),
          inputTokens: 100,
          outputTokens: 150,
          totalTokens: 250,
        };
      },
    };
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "idle",
    );
    assert.equal((await submit(profiles[0], true)).status, 202);
    assert.equal((await submit(profiles[1], true)).status, 202);
    const shared = (
      await pool.query(
        "SELECT seen_count,distinct_profiles FROM sms_v2_unknown_templates",
      )
    ).rows[0];
    assert.equal(Number(shared.seen_count), 2);
    assert.equal(shared.distinct_profiles, 2);
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "ready",
    );
    assert.equal(
      (await runTemplateWorkerOnce({ store: worker, provider, config })).status,
      "idle",
    );
    assert.equal(calls, 1);
    const owner = rig.asUser(profiles[0]);
    const sync = await owner.get("/sms/v2/sync");
    assert.equal(sync.status, 200);
    const response = sync.body;
    assert.equal(validateResponse("sync", response).ok, true);
    assert.equal(
      response.aiResults[0].rule.match.templateHash,
      item.templateHash,
    );
    assert.equal(response.aiResults[0].status, "ready");
    // Another account that never submitted the layout gets nothing.
    assert.equal((await store.results(profiles[2], null)).items.length, 0);
    const savedCursor = response.cursor;
    assert.equal(
      (await owner.get(`/sms/v2/sync?cursor=${encodeURIComponent(savedCursor)}`))
        .body.aiResults.length,
      0,
    );
    // Submitting a ready template after a previous sync still returns the rule.
    const empty = await store.results(profiles[2], null);
    await store.submit(profiles[2], [item], true);
    assert.equal(
      (await store.results(profiles[2], empty.cursor)).items[0].status,
      "ready",
    );
    const batch = Array.from({ length: 48 }, () => item);
    assert.equal((await submit(profiles[0], true, batch)).status, 202);
    assert.equal((await submit(profiles[0], true)).status, 429);
    await consent(profiles[0], false);
    assert.equal((await store.results(profiles[0], null)).items.length, 0);
    assert.equal((await submit(profiles[0], true)).status, 403);

    const admin = rig.asAdmin();
    const promotion = await admin.post(
      `/admin/sms/v2/templates/${item.templateHash}/draft`,
    );
    assert.equal(promotion.status, 200, JSON.stringify(promotion.body));
    const storedDraft = (
      await pool.query(
        "SELECT body FROM sms_v2_rules WHERE rule_id=$1 AND status='draft'",
        [`AI-${template.template_hash}`],
      )
    ).rows[0].body;
    assert.equal(storedDraft.status, "draft");
    assert.equal(storedDraft.match.templateHash, undefined);
    const metrics = (await admin.get("/admin/sms/v2/metrics")).body;
    assert.equal(metrics.ai[0].calls, 1);
    assert.equal(Number(metrics.ai[0].total_tokens), 250);
    // Popular templates win, and a single queued job cannot be leased twice.
    const unpopular = { ...item, templateHash: "b".repeat(64) };
    const popular = { ...item, templateHash: "c".repeat(64) };
    await store.submit(profiles[3], [unpopular, popular], true);
    await store.submit(profiles[1], [popular], true);
    const claimed = await worker.claim();
    assert.equal(claimed.template_hash, popular.templateHash);
    const second = await worker.claim();
    assert.equal(second.template_hash, unpopular.templateHash);
    assert.equal(await worker.claim(), null);
    assert.equal(
      await worker.beginAttempt(claimed, 1, "synthetic prompt", {
        ...config,
        rpm: 2,
      }),
      null,
    );
    assert.equal(
      await worker.beginAttempt(second, 1, "synthetic prompt", {
        ...config,
        rpm: 2,
      }),
      "capacity",
    );
    // Revocation removes the owner association and cancels unstarted work.
    await consent(profiles[1], false);
    await consent(profiles[3], false);
    assert.equal(
      await worker.beginAttempt(second, 1, "synthetic prompt", config),
      "consent_or_lease_lost",
    );
  },
);

// ---- learning loop B3: approve or reject an AI draft with a reason

test("rejecting a draft needs a reason, withdraws the private rule and teaches the next prompt", { skip: loopSkip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 3, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const admin = rig.asAdmin();
  for (const id of profiles) await rig.consent(id, true);
  const worker = createPgWorkerStore({ ...rig.helpers, adminId: rig.admin });
  const phone = rig.asUser(profiles[0]);
  const body = { items: [{ templateHash: template.template_hash, senderBrand: template.sender_brand, redactedBody: template.redacted_body, observedAt: new Date().toISOString() }] };
  assert.equal((await phone.post("/sms/v2/unknown-templates", body)).status, 202);
  const provider = { generate: async () => ({ rule: rule(), inputTokens: 10, outputTokens: 10, totalTokens: 20 }) };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  const hash = template.template_hash;
  const state = async () => (await pool.query("SELECT ai_status,ai_draft,failure_code,admin_decision,admin_reason,admin_note,decided_by,result_revision FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash])).rows[0];
  const before = await state();
  assert.equal(before.ai_status, "ready");
  // Every sync body must satisfy the contract the phone validates: one status
  // outside pending, ready and rejected makes the phone drop the whole response.
  const sync = async () => {
    const body = (await phone.get("/sms/v2/sync")).body;
    assert.equal(validateResponse("sync", body).ok, true, JSON.stringify(validateResponse("sync", body).errors));
    return body.aiResults.find((entry) => entry.templateHash === hash);
  };
  assert.equal((await sync()).status, "ready");

  const path = `/admin/sms/v2/templates/${hash}/reject`;
  // An approved layout is final here: it cannot be rejected afterwards.
  await pool.query("UPDATE sms_v2_unknown_templates SET admin_decision='approved' WHERE template_hash=$1", [hash]);
  assert.equal((await admin.post(path, { reason: "overmatches" })).status, 409);
  await pool.query("UPDATE sms_v2_unknown_templates SET admin_decision=NULL WHERE template_hash=$1", [hash]);
  assert.equal((await admin.post(path, {})).body.error, "reject_reason_invalid");
  assert.equal((await admin.post(path, { reason: "because" })).body.error, "reject_reason_invalid");
  assert.equal((await admin.post(path, { reason: "other" })).body.error, "reject_note_required");
  assert.equal((await admin.post(path, { reason: "other", note: "x" })).body.error, "reject_note_required");
  assert.equal((await admin.post(path, { reason: "overmatches", note: "n".repeat(301) })).body.error, "reject_note_invalid");
  assert.equal((await admin.post(`/admin/sms/v2/templates/${"f".repeat(64)}/reject`, { reason: "overmatches" })).status, 404);
  assert.equal((await admin.post("/admin/sms/v2/templates/nothex/reject", { reason: "overmatches" })).status, 400);
  rig.setFreshMfa(false);
  assert.equal((await admin.post(path, { reason: "overmatches" })).status, 403, "rejecting needs fresh MFA");
  rig.setFreshMfa(true);
  assert.equal((await state()).ai_status, "ready", "refused requests change nothing");

  const rejected = await admin.post(path, { reason: "overmatches", note: "It also read card bills" });
  assert.equal(rejected.status, 200, JSON.stringify(rejected.body));
  const after = await state();
  assert.equal(after.ai_status, "failed");
  assert.equal(after.ai_draft, null);
  assert.equal(after.failure_code, "admin_rejected");
  assert.deepEqual([after.admin_decision, after.admin_reason, after.admin_note, after.decided_by], ["rejected", "overmatches", "It also read card bills", rig.admin]);
  assert.ok(BigInt(after.result_revision) > BigInt(before.result_revision), "the revision moves so phones fetch the change");
  assert.equal((await sync()).status, "rejected", "the sender's next sync replaces the private rule with 'rejected'");
  assert.equal((await admin.post(path, { reason: "overmatches" })).status, 409, "already rejected");
  const audited = (await pool.query("SELECT action,reason FROM admin_audit_log WHERE admin_id=$1 AND action='sms_v2_template_reject'", [rig.admin])).rows;
  assert.deepEqual(audited, [{ action: "sms_v2_template_reject", reason: "It also read card bills" }]);

  // The list filters: rejected is its own state, and failed excludes it.
  const listed = async (status) => (await admin.get(`/admin/sms/v2/templates?status=${status}`)).body.templates.map((row) => row.template_hash);
  assert.deepEqual(await listed("rejected"), [hash]);
  assert.deepEqual(await listed("failed"), []);
  assert.equal((await admin.get("/admin/sms/v2/templates?status=nonsense")).status, 400);
  const row = (await admin.get("/admin/sms/v2/templates?status=rejected")).body.templates[0];
  assert.deepEqual([row.admin_decision, row.admin_reason, row.admin_note], ["rejected", "overmatches", "It also read card bills"]);

  // The next layout from this sender gets the rejection in its prompt.
  const sibling = { template_hash: "c".repeat(64), sender_brand: template.sender_brand, redacted_body: "<AMT> debited at <PARTY>." };
  assert.deepEqual(await worker.previousMistakes(sibling), [{ redactedBody: template.redacted_body, reason: "overmatches" }]);
  assert.deepEqual(await worker.previousMistakes({ ...sibling, template_hash: hash }), [], "never its own rejection");
  assert.deepEqual(await worker.previousMistakes({ ...sibling, sender_brand: "OTHERBK" }), []);

  // Only a finished draft can be rejected.
  const queued = "d".repeat(64);
  await pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status) VALUES($1,'TESTBK',$2,'queued')", [queued, "<AMT> queued layout."]);
  assert.equal((await admin.post(`/admin/sms/v2/templates/${queued}/reject`, { reason: "overmatches" })).body.error, "template_not_rejectable");

  // "Create draft" is the approval, and --eval can read approved drafts back.
  const approved = "e".repeat(64);
  const draft = rule();
  draft.id = `AI-${approved}`;
  draft.match.templateHash = approved;
  await pool.query("INSERT INTO sms_v2_unknown_templates(template_hash,sender_brand,redacted_body,ai_status,ai_draft) VALUES($1,'TESTBK',$2,'ready',$3)", [approved, template.redacted_body, JSON.stringify(draft)]);
  const made = await admin.post(`/admin/sms/v2/templates/${approved}/draft`);
  assert.equal(made.status, 200, JSON.stringify(made.body));
  const decided = (await pool.query("SELECT admin_decision,decided_by FROM sms_v2_unknown_templates WHERE template_hash=$1", [approved])).rows[0];
  assert.deepEqual([decided.admin_decision, decided.decided_by], ["approved", rig.admin]);
  const { loadApprovedFromDb } = require("../../scripts/dry_run_sms_v2_templates");
  const loaded = await loadApprovedFromDb({ env: { ADMIN_API_DATABASE_URL: process.env.SMS_V2_TEST_ADMIN_DATABASE_URL, DB_SSL: "false", NODE_ENV: "test" }, adminId: rig.admin, limit: 10 });
  assert.deepEqual(loaded.approved.map((entry) => entry.template_hash), [approved]);
  assert.equal(loaded.approved[0].ai_draft.id, `AI-${approved}`);
});

// ---- learning loop B7: requeue and block

test("a failed or rejected layout can be requeued, and a blocked one never reaches the AI", { skip: loopSkip }, async (t) => {
  const rig = await startLoopHarness({ profileCount: 2, registerAdmin: registerAllLoopAdminRoutes });
  t.after(() => rig.close());
  const { pool, profiles } = rig;
  const admin = rig.asAdmin();
  for (const id of profiles) await rig.consent(id, true);
  const worker = createPgWorkerStore({ ...rig.helpers, adminId: rig.admin });
  const phone = rig.asUser(profiles[0]);
  const hash = template.template_hash;
  const body = { items: [{ templateHash: hash, senderBrand: template.sender_brand, redactedBody: template.redacted_body, observedAt: new Date().toISOString() }] };
  assert.equal((await phone.post("/sms/v2/unknown-templates", body)).status, 202);
  let calls = 0;
  const provider = { generate: async () => { calls++; return { rule: rule(), inputTokens: 1, outputTokens: 1, totalTokens: 2 }; } };
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "ready");
  const row = async () => (await pool.query("SELECT ai_status,ai_draft,failure_code,admin_decision,admin_reason,lease_id,result_revision FROM sms_v2_unknown_templates WHERE template_hash=$1", [hash])).rows[0];
  const sync = async () => (await phone.get("/sms/v2/sync")).body.aiResults.find((entry) => entry.templateHash === hash);

  const requeue = `/admin/sms/v2/templates/${hash}/requeue`;
  const block = `/admin/sms/v2/templates/${hash}/block`;
  // Reasons, fresh MFA, hash shape and unknown layouts.
  assert.equal((await admin.post(requeue, {})).body.error, "reason_required");
  assert.equal((await admin.post(requeue, { reason: "x" })).body.error, "reason_required");
  assert.equal((await admin.post(block, {})).body.error, "reason_required");
  assert.equal((await admin.post(`/admin/sms/v2/templates/${"f".repeat(64)}/requeue`, { reason: "try again" })).status, 404);
  assert.equal((await admin.post(`/admin/sms/v2/templates/${"f".repeat(64)}/block`, { reason: "unwanted" })).status, 404);
  assert.equal((await admin.post("/admin/sms/v2/templates/nothex/block", { reason: "unwanted" })).status, 400);
  rig.setFreshMfa(false);
  assert.equal((await admin.post(requeue, { reason: "try again" })).status, 403);
  assert.equal((await admin.post(block, { reason: "unwanted" })).status, 403);
  rig.setFreshMfa(true);

  // Only a failed layout (including a rejected one) goes back in the queue.
  const ready = await row();
  assert.equal((await admin.post(requeue, { reason: "try again" })).body.error, "template_not_requeueable", "a ready draft is not requeued");
  assert.equal((await admin.post(`/admin/sms/v2/templates/${hash}/reject`, { reason: "misses_fields" })).status, 200);
  assert.equal((await row()).admin_decision, "rejected");
  const requeued = await admin.post(requeue, { reason: "Prompt improved" });
  assert.equal(requeued.status, 200, JSON.stringify(requeued.body));
  const after = await row();
  assert.deepEqual([after.ai_status, after.failure_code, after.admin_decision, after.admin_reason], ["queued", null, null, null]);
  assert.ok(BigInt(after.result_revision) > BigInt(ready.result_revision));
  assert.equal((await sync()).status, "pending", "the phone sees it pending again");
  const claimed = await worker.claim();
  assert.equal(claimed.template_hash, hash, "the worker takes it again");
  await worker.finish(claimed, { model: "test-model", code: "worker_failed" });
  assert.equal((await row()).ai_status, "failed");
  assert.equal((await admin.post(requeue, { reason: "Once more" })).status, 200, "a plain failure can be requeued too");

  // Block: the draft goes, the revision moves, the worker never claims it, and it stays blocked.
  const callsBefore = calls;
  const blocked = await admin.post(block, { reason: "Looks like marketing" });
  assert.equal(blocked.status, 200, JSON.stringify(blocked.body));
  const gone = await row();
  assert.deepEqual([gone.ai_status, gone.ai_draft, gone.lease_id, gone.admin_reason], ["blocked", null, null, "Looks like marketing"]);
  assert.equal((await sync()).status, "pending", "blocked is shown to phones as pending");
  assert.equal(await worker.claim(), null);
  assert.equal((await runTemplateWorkerOnce({ store: worker, provider, config })).status, "idle");
  assert.equal(calls, callsBefore, "the provider is never called for a blocked layout");
  assert.equal((await rig.asUser(profiles[1]).post("/sms/v2/unknown-templates", body)).status, 202);
  assert.equal((await row()).ai_status, "blocked", "submitting it again keeps it blocked");
  assert.equal((await admin.post(block, { reason: "again" })).body.error, "template_already_blocked");
  assert.equal((await admin.post(requeue, { reason: "unblock" })).body.error, "template_not_requeueable", "a block is final until an admin changes it directly");
  assert.deepEqual((await admin.get("/admin/sms/v2/templates?status=blocked")).body.templates.map((entry) => entry.template_hash), [hash]);
  const actions = (await pool.query("SELECT action,reason FROM admin_audit_log WHERE admin_id=$1 AND action IN ('sms_v2_template_requeue','sms_v2_template_block') ORDER BY id", [rig.admin])).rows;
  assert.deepEqual(actions, [
    { action: "sms_v2_template_requeue", reason: "Prompt improved" },
    { action: "sms_v2_template_requeue", reason: "Once more" },
    { action: "sms_v2_template_block", reason: "Looks like marketing" },
  ]);
});
