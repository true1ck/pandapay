"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { createAiStatusHandler } = require("../../src/sms_v2/ai_templates");

function run({ summary, counted = true, fail = null, attest = async () => true }) {
  const req = { userId: "p1" };
  const res = {
    code: 200,
    body: null,
    status(code) {
      this.code = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
  const handler = createAiStatusHandler({
    store: {
      summary: async (profile) => {
        assert.equal(profile, "p1");
        if (fail) throw fail;
        return summary;
      },
    },
    security: {
      verifyAttestation: async (r) => {
        r.smsV2Security = { sharedLearningEligible: counted };
        return attest(r);
      },
    },
  });
  return handler(req, res).then(() => res);
}

test("a counted phone with layouts being drafted reports the counts", async () => {
  const res = await run({
    summary: { eligible: true, total: 5, queued: 2, working: 1, ready: 1, failed: 1 },
  });
  assert.equal(res.code, 200);
  assert.deepEqual(res.body, {
    countedNow: true,
    eligible: true,
    total: 5,
    held: 0,
    queued: 2,
    working: 1,
    ready: 1,
    covered: 0,
    failed: 1,
  });
});

test("a phone that is not counted shows its layouts as held, never queued", async () => {
  const res = await run({
    counted: false,
    summary: { eligible: false, total: 12, held: 12 },
  });
  assert.equal(res.body.countedNow, false);
  assert.equal(res.body.eligible, false);
  assert.equal(res.body.held, 12);
  assert.equal(res.body.queued, 0);
});

test("a person with nothing sent gets zeros, not an error", async () => {
  const res = await run({ summary: {} });
  assert.equal(res.code, 200);
  assert.equal(res.body.total, 0);
  assert.equal(res.body.eligible, false);
});

test("only whole non-negative numbers pass through", async () => {
  const res = await run({
    summary: { total: -3, held: "7", queued: 1.5, ready: 4 },
  });
  assert.equal(res.body.total, 0);
  assert.equal(res.body.held, 0);
  assert.equal(res.body.queued, 0);
  assert.equal(res.body.ready, 4);
});

test("no sharing consent is a 403; any other failure is a 503 with no detail", async () => {
  const consent = await run({ summary: {}, fail: Object.assign(new Error("x"), { code: "42501" }) });
  assert.equal(consent.code, 403);
  assert.deepEqual(consent.body, { error: "sms_shared_learning_consent_required" });
  const broken = await run({ summary: {}, fail: new Error("db password is hunter2") });
  assert.equal(broken.code, 503);
  assert.deepEqual(broken.body, { error: "ai_status_unavailable" });
});
