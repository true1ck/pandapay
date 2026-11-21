"use strict";
// What real AI answers got wrong (21 Nov 2026, 40 answers replayed for the 21 layouts that had failed): a bare slot name
// instead of {from}, references to slots the layout does not have, a mask taken from a name slot, a bill with no due
// date, an info fact carrying amounts. Each of these is repaired by dropping or converting only what is unambiguous;
// amounts, direction and purpose the model got right are never touched, and nothing is invented.
const test = require("node:test");
const assert = require("node:assert/strict");
const { repairEmit } = require("../../src/sms_v2/draft_repair");
const { buildRule, validateDraft } = require("../../src/sms_v2/template_worker");
const { buildMatcher } = require("../../src/sms_v2/layout_matcher");

const slots = (...pairs) => pairs.map(([name, kind]) => ({ name, kind }));
const SL = slots(["amt1", "amt"], ["date1", "date"], ["mask1", "mask"], ["party1", "party"], ["ref1", "ref"], ["amt2", "amt"]);
const repaired = (emit, s = SL) => repairEmit(emit, s);

test("a bare slot name used as a date or text attribute becomes {from}", () => {
  const { emit, repairs } = repaired([
    { factType: "balance_snapshot", attrs: { asOf: "date1" } },
    { factType: "attempt", attrs: { status: "scheduled", direction: "debit", purpose: "emi", dueAt: "date1" } },
    { factType: "bill_due", attrs: { dueDate: "date1", billerName: "party1" } },
  ]);
  assert.deepEqual(emit[0].attrs.asOf, { from: "date1" });
  assert.deepEqual(emit[1].attrs.dueAt, { from: "date1" });
  assert.deepEqual(emit[2].attrs, { dueDate: { from: "date1" }, billerName: { from: "party1" } });
  assert.equal(emit[1].attrs.status, "scheduled", "an enum value is never read as a slot");
  assert.ok(repairs.includes("attr_slot_name"));
});

test("a date attribute that names a slot that is not a date, or not there, is not repaired into one", () => {
  const { emit } = repaired([{ factType: "balance_snapshot", attrs: { asOf: "amt1" } }]);
  assert.equal(emit[0].attrs.asOf, undefined);
  const gone = repaired([{ factType: "balance_snapshot", attrs: { asOf: "date9" } }]);
  assert.equal(gone.emit[0].attrs.asOf, undefined);
});

test("references, dates, names and masks that point at a slot the layout does not have are dropped", () => {
  const { emit, repairs } = repaired([
    {
      factType: "movement",
      attrs: { direction: "debit", purpose: "purchase", rail: "upi" },
      amounts: [{ role: "posted", from: "amt1", unit: "INR" }],
      occurredAt: { from: "date9" },
      instrument: { kind: "bank_account", maskFrom: "mask9" },
      counterparty: { nameFrom: "bank", kind: "merchant" },
      references: { upiRef: "ref1", txnId: "####", neftUtr: "date1x" },
    },
  ]);
  const fact = emit[0];
  assert.deepEqual(fact.amounts, [{ role: "posted", from: "amt1", unit: "INR" }], "the amount is untouched");
  assert.equal(fact.occurredAt, undefined);
  assert.deepEqual(fact.instrument, { kind: "bank_account" });
  assert.deepEqual(fact.counterparty, { kind: "merchant" });
  assert.deepEqual(fact.references, { upiRef: "ref1" });
  assert.ok(["occurred_at", "instrument_mask", "counterparty_name", "reference"].every((r) => repairs.includes(r)));
});

test("a mask or a name taken from the wrong kind of slot is dropped", () => {
  const { emit } = repaired([
    {
      factType: "movement",
      attrs: { direction: "debit", purpose: "purchase", rail: "upi" },
      amounts: [{ role: "posted", from: "amt1", unit: "INR" }],
      instrument: { kind: "bank_account", maskFrom: "party1" },
      counterparty: { nameFrom: "amt2", kind: "merchant" },
    },
  ]);
  assert.deepEqual(emit[0].instrument, { kind: "bank_account" });
  assert.deepEqual(emit[0].counterparty, { kind: "merchant" });
});

test("an amount wired to the wrong slot is never repaired: the validator names it", () => {
  const input = [{ factType: "movement", attrs: { direction: "debit", purpose: "purchase", rail: "upi" }, amounts: [{ role: "posted", from: "date1", unit: "INR" }] }];
  assert.deepEqual(repaired(input).emit, input);
});

test("a bill with no due date is not a bill: it becomes a plain service notice with no amounts", () => {
  const { emit, repairs } = repaired([
    { factType: "bill_due", attrs: { billerName: { from: "party1" } }, amounts: [{ role: "due_total", from: "amt1", unit: "INR" }] },
  ]);
  assert.equal(emit[0].factType, "info");
  assert.deepEqual(emit[0].attrs, { category: "service" });
  assert.equal(emit[0].amounts, undefined);
  assert.ok(repairs.includes("bill_without_due_date"));
  // with a due date it stays a bill
  assert.equal(repaired([{ factType: "bill_due", attrs: { dueDate: { from: "date1" } }, amounts: [{ role: "due_total", from: "amt1", unit: "INR" }] }]).emit[0].factType, "bill_due");
});

test("an info fact carries no amounts", () => {
  const { emit } = repaired([{ factType: "info", attrs: { category: "other" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }] }]);
  assert.equal(emit[0].amounts, undefined);
});

test("an unknown counterparty kind becomes unknown", () => {
  const { emit } = repaired([{ factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }], counterparty: { nameFrom: "party1", kind: "financial_institution" } }]);
  assert.deepEqual(emit[0].counterparty, { nameFrom: "party1", kind: "unknown" });
});

test("a correct answer is returned untouched, with no repairs", () => {
  const good = [{
    factType: "movement", attrs: { direction: "debit", purpose: "purchase", rail: "upi" },
    amounts: [{ role: "posted", from: "amt1", unit: "INR" }], occurredAt: { from: "date1" },
    instrument: { kind: "bank_account", maskFrom: "mask1" }, counterparty: { nameFrom: "party1", kind: "merchant" }, references: { upiRef: "ref1" },
  }];
  const result = repaired(good);
  assert.deepEqual(result.emit, good);
  assert.deepEqual(result.repairs, []);
  assert.notStrictEqual(result.emit, good, "the input is never modified");
});

test("end to end: answers that used to be rejected now build a rule that passes every check", () => {
  const model = "gemini-3.1-flash-lite";
  const cases = [
    { layout: "Update! <AMT> deposited in HDFC Bank A/c <MASK> on <DATE>. Avl bal <AMT>.", answer: { family: "x", confidence: 0.9, emit: [{ factType: "movement", attrs: { direction: "credit", purpose: "unknown", rail: "unknown" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }], instrument: { kind: "bank_account", maskFrom: "mask1" } }, { factType: "balance_snapshot", attrs: { asOf: "date1" }, amounts: [{ role: "available_balance", from: "amt2", unit: "INR" }], instrument: { sameAs: 0 } }] } },
    { layout: "Your transaction for <AMT> against txn ID abcdefgh#pQ# has been processed successfully. -Kotak", answer: { family: "k", confidence: 0.9, emit: [{ factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }], references: { txnId: "abcdefgh#pQ#" } }] } },
  ];
  for (const { layout, answer } of cases) {
    const template = { template_hash: "a".repeat(64), sender_brand: "TESTBK", redacted_body: layout };
    const rule = buildRule(answer, template, buildMatcher(layout), model);
    assert.deepEqual(validateDraft(rule, template, model, []), [], layout);
  }
});
