"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const { buildRule, validateDraft } = require("../../src/sms_v2/template_worker");
const { buildMatcher } = require("../../src/sms_v2/layout_matcher");
const { answer, config, template } = require("./fixtures/template_draft");

// The model leaves the unit out of a points amount (the prompts only show INR): the worker supplies POINTS, so the rule validates.
test("a points amount without a unit gets POINTS and the draft validates", () => {
  const body = "You earned <AMT> reward points on spend at <PARTY>. Total points <AMT>.";
  const tpl = { ...template, redacted_body: body };
  const draftAnswer = {
    family: "reward",
    confidence: 0.9,
    emit: [{ factType: "reward", attrs: {}, amounts: [{ role: "points_earned", from: "amt1" }, { role: "points_balance", from: "amt2" }] }],
  };
  const rule = buildRule(draftAnswer, tpl, buildMatcher(body), config.model);
  assert.deepEqual(rule.emit[0].amounts.map((a) => a.unit), ["POINTS", "POINTS"]);
  assert.ok(!validateDraft(rule, tpl, config.model).includes("bundle.emit.amount_unit_required"));
});

test("a money amount without a unit still gets INR", () => {
  const rule = buildRule(answer(), template, buildMatcher(template.redacted_body), config.model);
  assert.ok(rule.emit[0].amounts.every((a) => a.unit === "INR"));
});
