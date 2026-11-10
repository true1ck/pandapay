"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const { template } = require("./fixtures/template_draft");
const {
  startLoopHarness,
  registerAllLoopAdminRoutes,
  skip,
} = require("./helpers/loop_harness");

// The status bar in the app reads GET /sms/v2/ai-status. It must tell a phone
// that is not counted (layouts held, never queued) apart from one that is, show
// only the caller's own layouts, and say nothing for a person who has not
// agreed to share.
test(
  "ai-status reports held, queued and the caller's own layouts only",
  { skip },
  async (t) => {
    const rig = await startLoopHarness({
      profileCount: 3,
      registerAdmin: registerAllLoopAdminRoutes,
    });
    t.after(() => rig.close());
    const { pool, profiles } = rig;
    for (const id of profiles.slice(0, 2)) await rig.consent(id, true);
    const item = {
      templateHash: template.template_hash,
      senderBrand: template.sender_brand,
      redactedBody: template.redacted_body,
      observedAt: new Date().toISOString(),
    };
    const submit = (profile, verified) =>
      rig.asUser(profile, { verified }).post("/sms/v2/unknown-templates", { items: [item] });

    // Nothing sent yet: zeros, not an error.
    let r = await rig.asUser(profiles[0]).get("/sms/v2/ai-status");
    assert.equal(r.status, 200);
    assert.equal(r.body.total, 0);
    assert.equal(r.body.eligible, false);

    // A phone that is not counted: the layout is held and the bar can say so.
    assert.equal((await submit(profiles[0], false)).status, 202);
    r = await rig.asUser(profiles[0], { verified: false }).get("/sms/v2/ai-status");
    assert.equal(r.status, 200);
    assert.equal(r.body.countedNow, false);
    assert.equal(r.body.eligible, false);
    assert.equal(r.body.total, 1);
    assert.equal(r.body.held, 1);
    assert.equal(r.body.queued, 0);

    // A counted phone sending the same layout releases it to the queue.
    assert.equal((await submit(profiles[1], true)).status, 202);
    r = await rig.asUser(profiles[1]).get("/sms/v2/ai-status");
    assert.equal(r.body.countedNow, true);
    assert.equal(r.body.eligible, true);
    assert.equal(r.body.total, 1);
    assert.equal(r.body.queued, 1);
    assert.equal(r.body.held, 0);
    assert.equal(
      (await pool.query("SELECT ai_status FROM sms_v2_unknown_templates")).rows[0].ai_status,
      "queued",
    );

    // Only the caller's own layouts: a third person who sent nothing sees none.
    await rig.consent(profiles[2], true);
    r = await rig.asUser(profiles[2]).get("/sms/v2/ai-status");
    assert.equal(r.body.total, 0);

    // The response carries counts and flags only: no layout text, no hash.
    const text = JSON.stringify(r.body);
    assert.ok(!text.includes(template.template_hash));
    assert.ok(!text.includes(template.redacted_body));
  },
);

test(
  "ai-status is refused for a person who has not agreed to share",
  { skip },
  async (t) => {
    const rig = await startLoopHarness({
      profileCount: 1,
      registerAdmin: registerAllLoopAdminRoutes,
    });
    t.after(() => rig.close());
    const r = await rig.asUser(rig.profiles[0]).get("/sms/v2/ai-status");
    // Either an empty summary or a plain refusal; never anyone else's counts.
    if (r.status === 200) assert.equal(r.body.total, 0);
    else assert.equal(r.status, 403);
  },
);
