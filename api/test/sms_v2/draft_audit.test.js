"use strict";
// 21 Nov 2026: 15 of the 123 "ready" AI drafts in production fail today's validator (they were accepted before the
// sanity checks existed; most read an account mask from a name slot). They are the rules phones apply. This job re-checks
// every ready draft with today's checks, repairs the ones that can be repaired (draft_repair.js) and replaces them when
// the repaired draft passes; the rest are left alone and counted, never changed or deleted.
const test = require("node:test");
const assert = require("node:assert/strict");
const { createDraftAudit } = require("../../src/sms_v2/jobs/draft_audit");

const SLOTS_LAYOUT = "<AMT> debited from A/c <PARTY> on <DATE>.";
const row = (hash, emit, extra = {}) => ({
  template_hash: hash.repeat(64).slice(0, 64), sender_brand: "TESTBK", redacted_body: SLOTS_LAYOUT, ai_model: "m",
  ai_draft: { version: 1, emit, match: { pattern: "x" }, createdBy: "ai:m" }, ...extra,
});
const goodEmit = [{ factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" }, amounts: [{ role: "posted", from: "amt1", unit: "INR" }] }];
const badEmit = [{ ...goodEmit[0], instrument: { kind: "bank_account", maskFrom: "party1" } }]; // a mask from a name slot

function rig(rows) {
  const replaced = [];
  const lines = [];
  const clock = { t: 0 };
  const audit = createDraftAudit({
    store: {
      readyDraftsForAudit: async () => rows,
      replaceReadyDraft: async (hash, before, after) => { replaced.push({ hash, before, after }); return true; },
    },
    // stands in for validateDraftSafely: invalid while a mask is still taken from party1, or a movement has no amount
    validate: async (rule) => [
      ...(JSON.stringify(rule.emit).includes('"maskFrom":"party1"') ? ["slot_kind_mismatch: party1 is a party, emit[0].instrument.maskFrom needs a mask"] : []),
      ...(JSON.stringify(rule.emit).includes('"amounts"') ? [] : ["amount_missing: movement needs a posted amount"]),
    ],
    now: () => clock.t,
    log: (line) => lines.push(line),
  });
  return { audit, replaced, lines, clock };
}

test("a draft that passes today's checks is left alone", async () => {
  const { audit, replaced } = rig([row("a", goodEmit)]);
  assert.deepEqual(await audit.run(), { checked: 1, valid: 1, repaired: 0, unrepairable: 0 });
  assert.equal(replaced.length, 0);
});

test("a draft that fails but can be repaired is replaced by the repaired one, which keeps everything the model got right", async () => {
  const { audit, replaced, lines } = rig([row("b", badEmit)]);
  assert.deepEqual(await audit.run(), { checked: 1, valid: 0, repaired: 1, unrepairable: 0 });
  assert.equal(replaced.length, 1);
  const { before, after } = replaced[0];
  assert.deepEqual(before.emit, badEmit, "the compare-and-set value is the draft as it was read");
  assert.deepEqual(after.emit[0].amounts, goodEmit[0].amounts);
  assert.deepEqual(after.emit[0].attrs, goodEmit[0].attrs);
  assert.deepEqual(after.emit[0].instrument, { kind: "bank_account" });
  assert.deepEqual(lines.at(-1), { event: "sms_v2_ai_draft_audit", checked: 1, valid: 0, repaired: 1, unrepairable: 0 });
});

test("a draft that fails and cannot be repaired is left alone and counted", async () => {
  const noAmount = [{ factType: "movement", attrs: { direction: "debit", purpose: "unknown", rail: "unknown" }, instrument: { kind: "bank_account", maskFrom: "party1" } }];
  const { audit, replaced } = rig([row("c", noAmount)]);
  const result = await audit.run();
  assert.equal(result.unrepairable, 1);
  assert.equal(replaced.length, 0);
});

test("a repair that does not pass the validator is not stored", async () => {
  const rejectEverything = createDraftAudit({
    store: { readyDraftsForAudit: async () => [row("d", badEmit)], replaceReadyDraft: async () => assert.fail("must not replace") },
    validate: async () => ["still_invalid"],
    now: () => 0,
    log: () => {},
  });
  assert.equal((await rejectEverything.run()).unrepairable, 1);
});

test("a draft changed by someone else between the read and the replace is not overwritten", async () => {
  const lines = [];
  const audit = createDraftAudit({
    store: { readyDraftsForAudit: async () => [row("e", badEmit)], replaceReadyDraft: async () => false },
    validate: async (rule) => (JSON.stringify(rule.emit).includes('"maskFrom":"party1"') ? ["x"] : []),
    now: () => 0,
    log: (line) => lines.push(line),
  });
  const result = await audit.run();
  assert.equal(result.repaired, 0);
  assert.equal(result.skipped, 1);
});

test("check() runs at most once an hour, never throws, and does nothing for a store without the methods", async () => {
  const { audit, clock } = rig([row("f", goodEmit)]);
  assert.ok(await audit.check());
  assert.equal(await audit.check(), null, "too soon");
  clock.t += 61 * 60_000;
  assert.ok(await audit.check());
  const broken = createDraftAudit({ store: { readyDraftsForAudit: async () => { throw Object.assign(new Error("x"), { code: "57P01" }); }, replaceReadyDraft: async () => true }, validate: async () => [], now: () => 0, log: () => {} });
  assert.equal(await broken.check(), null);
  assert.equal(await createDraftAudit({ store: {}, validate: async () => [], now: () => 0, log: () => {} }).check(), null);
});
