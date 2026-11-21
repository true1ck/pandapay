"use strict";
// qa-bug-hunt S3-1: the validator used to check only that slots exist. These tests pin that a draft must also MEAN what
// its layout says (slot kind, balance is not the amount, direction, purpose, units, amount shape), that no correct
// draft is turned away, and that a thin layout is read below the phone's confident line (0.7) instead of rejected.
const test = require("node:test");
const assert = require("node:assert/strict");
const { buildMatcher } = require("../../src/sms_v2/layout_matcher");
const { buildRule, validateDraft } = require("../../src/sms_v2/template_worker");
const { sanityErrors, isDoubtful, DOUBTFUL_CONFIDENCE } = require("../../src/sms_v2/draft_sanity");
const { VALID, WRONG } = require("./fixtures/draft_answers");

const MODEL = "test-model";
const templateFor = (layout) => ({ template_hash: "c".repeat(64), sender_brand: "TESTBK", redacted_body: layout });
const check = ({ layout, answer }) => {
  const template = templateFor(layout);
  // repair: false: this battery proves the validator names each kind of wrong wiring, so it sees the answer as written.
  const rule = buildRule(answer, template, buildMatcher(layout), MODEL, { repair: false });
  return { rule, errors: validateDraft(rule, template, MODEL, []) };
};

test("every correct draft in the battery still passes the whole validator", () => {
  assert.ok(VALID.length >= 25);
  for (const entry of VALID) assert.deepEqual(check(entry).errors, [], entry.name);
});

test("a draft that is well formed but wrong about the layout is refused, with the reason named", () => {
  for (const entry of WRONG) {
    const { errors } = check(entry);
    assert.ok(errors.some((code) => code.startsWith(entry.code)), `${entry.name}: ${JSON.stringify(errors)}`);
  }
});

test("the reason names the slot, so the second try can correct it", () => {
  const wrong = WRONG.find((w) => w.code === "posted_amount_is_balance");
  assert.match(check(wrong).errors.find((c) => c.startsWith("posted_amount_is_balance")), /amt2 follows ".*Bal"/);
  const kind = WRONG.find((w) => w.name.startsWith("amount wired to the date"));
  assert.match(check(kind).errors.find((c) => c.startsWith("slot_kind_mismatch")), /date1 is a date, emit\[0\]\.amounts\.posted needs an amount/);
});

test("a layout with a debit and a credit word, or only a receipt, is not called conflicting", () => {
  const rule = (direction, extra = {}) => ({ emit: [{ factType: "movement", attrs: { direction, purpose: "unknown", rail: "unknown", ...extra }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }] }] });
  const both = "<AMT> debited from A/c <MASK>. <AMT> credited to A/c <MASK>.";
  assert.deepEqual(sanityErrors(rule("credit"), both), []);
  assert.deepEqual(sanityErrors(rule("debit"), both), []);
  // A biller's receipt says "credited to your account" but the user paid: evidenceOnly debit.
  assert.deepEqual(sanityErrors(rule("debit", { evidenceOnly: true }), "<AMT> credited to your <PARTY> account."), []);
  assert.ok(sanityErrors(rule("debit"), "<AMT> credited to your <PARTY> account.").length);
});

test("a layout too thin to be sure of is read below the phone's confident line, a clear one keeps the model's confidence", () => {
  const phoneConfident = 0.7; // kConfidentRead in packages/pandapay_domain/lib/src/sms_v2/contract/fact.dart
  assert.ok(DOUBTFUL_CONFIDENCE < phoneConfident);
  const movement = { emit: [{ factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }] }] };
  const thin = "<AMT> to <PARTY> on <DATE>.";
  const unlabelled = "A/c <MASK> debited today as per your request to us. Amounts <AMT> <AMT>.";
  const clear = "<AMT> debited from A/c <MASK>. Avl Bal <AMT>.";
  assert.equal(isDoubtful(movement, thin), true);
  assert.equal(isDoubtful(movement, unlabelled), true);
  assert.equal(isDoubtful(movement, clear), false);
  // Only a money movement is doubted: an OTP notice has no direction to get wrong.
  assert.equal(isDoubtful({ emit: [{ factType: "info", attrs: { category: "otp" } }] }, "Your code is <REF>."), false);
  const sure = { family: "x", confidence: 0.95, emit: movement.emit };
  assert.equal(buildRule(sure, templateFor(thin), buildMatcher(thin), MODEL).confidence, DOUBTFUL_CONFIDENCE);
  assert.equal(buildRule(sure, templateFor(clear), buildMatcher(clear), MODEL).confidence, 0.95);
  // A model that is itself unsure stays unsure.
  assert.equal(buildRule({ ...sure, confidence: 0.5 }, templateFor(thin), buildMatcher(thin), MODEL).confidence, 0.5);
});

test("no correct draft of the battery is doubted: each keeps the confidence the model gave", () => {
  assert.deepEqual(VALID.filter((entry) => check(entry).rule.confidence !== entry.answer.confidence).map((entry) => entry.name), []);
});

test("the worked examples the prompt shows the model pass the validator, so the model is never taught a refused shape", () => {
  const { EXAMPLES } = require("../../src/sms_v2/ai_prompt");
  for (const example of EXAMPLES) {
    const layout = example.layout.replace(/<([a-z]+)\d+>/g, (_m, kind) => `<${kind.toUpperCase()}>`);
    assert.deepEqual(check({ layout, answer: example.answer }).errors, [], layout);
  }
});
