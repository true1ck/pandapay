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

test("a failed-payment notice that prints no amount cannot be an attempt: it becomes a plain service notice", () => {
  const noAmounts = slots(["party1", "party"], ["party2", "party"]);
  const { emit, repairs } = repairEmit([{ factType: "attempt", attrs: { status: "failed", direction: "debit", purpose: "purchase" } }], noAmounts);
  assert.deepEqual(emit, [{ factType: "info", attrs: { category: "service" } }]);
  assert.ok(repairs.includes("attempt_without_amount"));
  // with an amount slot in the layout it stays an attempt (the model may simply have forgotten to wire it)
  assert.equal(repairEmit([{ factType: "attempt", attrs: { status: "failed", direction: "debit", purpose: "purchase" } }], SL).emit[0].factType, "attempt");
});

// Property test (fixed seed): over thousands of random answers repairEmit never throws, never modifies its input, never
// changes an amount, a direction, a purpose or a status, and a second pass changes nothing.
test("repairEmit is safe on any input: never throws, never touches amounts/direction/purpose, and is stable", () => {
  let seed = 7;
  const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
  const pick = (list) => list[Math.floor(rnd() * list.length)];
  const names = ["amt1", "amt2", "date1", "date9", "mask1", "party1", "party2", "ref1", "ghost1", "####", "bank", "", "AMT1", "<date1>"];
  const types = ["movement", "attempt", "bill_due", "balance_snapshot", "info", "mandate", "hold", "reward", "limit_change", "instrument_hint", "bogus"];
  const junk = [null, undefined, 5, "text", [], {}, true];
  const randomFact = () => {
    const fact = { factType: pick(types), attrs: {} };
    for (const key of ["direction", "purpose", "status", "category", "rail"]) if (rnd() < 0.5) fact.attrs[key] = pick(["debit", "credit", "salary", "failed", "service", "unknown", "x"]);
    for (const key of ["asOf", "dueAt", "dueDate", "billerName", "merchantName", "program"]) if (rnd() < 0.4) fact.attrs[key] = rnd() < 0.5 ? pick(names) : rnd() < 0.5 ? { from: pick(names) } : pick(junk);
    if (rnd() < 0.7) fact.amounts = [{ role: pick(["posted", "available_balance", "due_total"]), from: pick(names), unit: "INR" }];
    if (rnd() < 0.5) fact.occurredAt = rnd() < 0.7 ? { from: pick(names) } : pick(junk);
    if (rnd() < 0.5) fact.instrument = { kind: "bank_account", ...(rnd() < 0.7 ? { maskFrom: pick(names) } : {}) };
    if (rnd() < 0.5) fact.counterparty = { ...(rnd() < 0.7 ? { nameFrom: pick(names) } : {}), kind: pick(["merchant", "bank", "weird", "unknown"]) };
    if (rnd() < 0.5) fact.references = { upiRef: pick(names), txnId: pick(names) };
    return fact;
  };
  for (let i = 0; i < 4000; i++) {
    const input = Array.from({ length: 1 + Math.floor(rnd() * 4) }, () => (rnd() < 0.05 ? pick(junk) : randomFact()));
    const before = JSON.stringify(input);
    const once = repairEmit(input, rnd() < 0.5 ? SL : slots(["party1", "party"]));
    assert.equal(JSON.stringify(input), before, "the input is never modified");
    const twice = repairEmit(once.emit, rnd() < 0 ? [] : SL);
    input.forEach((fact, index) => {
      const out = once.emit[index];
      if (!fact || typeof fact !== "object" || fact.factType === "bill_due" || !out || out.factType === "info") return; // a downgrade replaces the whole fact
      assert.deepEqual(out.amounts, fact.amounts, "amounts are never changed");
      for (const key of ["direction", "purpose", "status", "category", "rail"]) assert.equal(out.attrs?.[key], fact.attrs?.[key], key);
    });
    void twice;
  }
  // stability, measured separately so the slot table is the same on both passes
  for (let i = 0; i < 2000; i++) {
    const input = [randomFact(), randomFact()];
    const once = repairEmit(input, SL);
    assert.deepEqual(repairEmit(once.emit, SL).emit, once.emit, "a second pass changes nothing");
  }
});
