"use strict";

// Repairs what real AI answers got wrong, before the draft is checked, so a draft that means the right thing is not
// thrown away for a slip in how it is written. Measured 21 Nov 2026 by replaying the 21 layouts that had failed (40
// answers): 30 were rejected, almost all for the slips below.
//
// Only the unambiguous is touched. Amounts are never repaired: an amount wired to the wrong slot is a wrong reading, and the
// validator names it. A bare slot name where {from} belongs is converted; a reference to a slot the
// layout does not have, or to a slot of the wrong kind, is dropped (the fact is then read without that optional
// detail); a bill with no printed due date becomes a plain service notice (the model's own rule: "a reminder that
// prints an amount but no due date is not a bill_due"); an info fact carries no amounts. Amounts, direction, purpose
// and every value the model got right are never changed, and nothing is invented. A repair that leaves a fact
// without what it needs (a movement with no amount) leaves it to the validator, which still rejects it.
//
// repairEmit(emit, slots) -> { emit, repairs }. `slots` is the layout's [{ name, kind }] (layout_matcher). The input is
// not modified; `repairs` lists, once each, what was done (codes, never text), so how often it rescues a draft is visible.

const DATE_ATTRS = new Set(["dueDate", "statementDate", "asOf", "dueAt", "expiresAt"]);
const TEXT_SLOT_ATTRS = new Set(["billerName", "merchantName", "issueName", "program"]);
const COUNTERPARTY_KINDS = new Set(["merchant", "person", "own", "bank", "unknown"]);

// Which slot kinds may feed which field (the same table draft_sanity.js uses to judge a draft).
const NAME_KINDS = new Set(["party", "w", "vpa", "email"]);
const VPA_KINDS = new Set(["vpa", "email", "w", "party"]);
const MASK_KINDS = new Set(["mask", "ref"]);
const REFERENCE_KINDS = new Set(["ref", "w", "mask"]);
const slotName = (value) => String(value).replace(/[<>\s]/g, "").toLowerCase();
const looksLikeSlot = (value) => /^[a-z]+\d+$/.test(value);

function repairEmit(emit, slots) {
  const kinds = new Map((slots ?? []).map((slot) => [slot.name, slot.kind]));
  const repairs = new Set();
  const done = (code) => repairs.add(code);
  const kindOk = (name, allowed) => typeof name === "string" && kinds.has(name) && allowed(kinds.get(name));
  const isDate = (k) => k === "date";
    const isText = (k) => k !== "amt" && k !== "date";

  function repairFact(input) {
    if (!input || typeof input !== "object" || Array.isArray(input)) return input;
    const fact = structuredClone(input);

    if (fact.attrs && typeof fact.attrs === "object" && !Array.isArray(fact.attrs)) {
      for (const [key, value] of Object.entries(fact.attrs)) {
        const slotKind = DATE_ATTRS.has(key) ? isDate : TEXT_SLOT_ATTRS.has(key) ? isText : null;
        if (!slotKind) continue;
        if (typeof value === "string") {
          const name = slotName(value);
          if (kindOk(name, slotKind)) {
            fact.attrs[key] = { from: name };
            done("attr_slot_name");
          } else if (looksLikeSlot(name)) {
            delete fact.attrs[key];
            done("attr_dropped");
          }
        } else if (value && typeof value === "object" && "from" in value && !kindOk(value.from, slotKind)) {
          delete fact.attrs[key];
          done("attr_dropped");
        }
      }
    }

    if (fact.occurredAt && typeof fact.occurredAt === "object" && "from" in fact.occurredAt && !kindOk(fact.occurredAt.from, isDate)) {
      delete fact.occurredAt;
      done("occurred_at");
    }

    if (fact.instrument && typeof fact.instrument === "object") {
      for (const [key, ok] of [["maskFrom", (k) => MASK_KINDS.has(k)], ["maskLengthFrom", (k) => MASK_KINDS.has(k)], ["issuerSlugFrom", isText], ["productNameFrom", isText]]) {
        if (key in fact.instrument && !kindOk(fact.instrument[key], ok)) {
          delete fact.instrument[key];
          done(key.startsWith("mask") ? "instrument_mask" : "instrument_text");
        }
      }
      if (!Object.keys(fact.instrument).length) delete fact.instrument;
    }

    if (fact.counterparty && typeof fact.counterparty === "object") {
      for (const [key, ok] of [["nameFrom", (k) => NAME_KINDS.has(k)], ["vpaFrom", (k) => VPA_KINDS.has(k)], ["accountMaskFrom", (k) => MASK_KINDS.has(k)]]) {
        if (key in fact.counterparty && !kindOk(fact.counterparty[key], ok)) {
          delete fact.counterparty[key];
          done("counterparty_name");
        }
      }
      if ("kind" in fact.counterparty && !COUNTERPARTY_KINDS.has(fact.counterparty.kind)) {
        fact.counterparty.kind = "unknown";
        done("counterparty_kind");
      }
      if (!Object.keys(fact.counterparty).length) delete fact.counterparty;
    }

    if (fact.references && typeof fact.references === "object" && !Array.isArray(fact.references)) {
      for (const [key, value] of Object.entries(fact.references)) {
        if (!kindOk(value, (k) => REFERENCE_KINDS.has(k))) {
          delete fact.references[key];
          done("reference");
        }
      }
      if (!Object.keys(fact.references).length) delete fact.references;
    }

    // A bill with no printed due date is not a bill; an info fact carries no amounts.
    if (fact.factType === "bill_due") {
      const due = fact.attrs?.dueDate;
      if (!(due && typeof due === "object" && "from" in due)) {
        done("bill_without_due_date");
        return { factType: "info", attrs: { category: "service" } };
      }
    }
    if (fact.factType === "info" && fact.amounts) {
      delete fact.amounts;
      done("info_amounts");
    }
    return fact;
  }

  const repaired = Array.isArray(emit) ? emit.map(repairFact) : emit;
  return { emit: repaired, repairs: [...repairs] };
}

module.exports = { repairEmit };
