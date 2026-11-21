"use strict";

const vocabulary = require("./fact_vocabulary.json");

// Makes a model's answer fit the fact vocabulary before it goes to PandaPay, without changing what it means:
//  - an attribute the fact type does not have is dropped (a model that has just written a movement tends to add
//    `rail` to an attempt too);
//  - an enum value with the wrong case or stray spaces is put right;
//  - an enum value that is not in the list becomes the neutral member (`unknown`, else `other`) when the list has
//    one, so one stray label no longer fails the whole draft.
// Structure is never touched (amounts, counterparty, instrument, references, slot names): a wrong structure is
// a real problem for PandaPay's validator to report. The input is not modified. `changes` is a count by kind, for
// the log, never any text.
const NEUTRAL = ["unknown", "other"];

function conformAnswer(answer) {
  const changes = { droppedAttrs: 0, fixedCase: 0, neutralised: 0 };
  if (!answer || typeof answer !== "object" || !Array.isArray(answer.emit)) return { answer, changes };
  const emit = answer.emit.map((fact) => {
    const spec = fact && typeof fact === "object" ? vocabulary.factTypes[fact.factType] : undefined;
    if (!spec || !fact.attrs || typeof fact.attrs !== "object" || Array.isArray(fact.attrs)) return fact;
    const attrs = {};
    for (const [name, value] of Object.entries(fact.attrs)) {
      const rule = spec.attrs[name];
      if (!rule) { changes.droppedAttrs++; continue; }
      if (rule.enum && typeof value === "string" && !rule.enum.includes(value)) {
        const folded = value.trim().toLowerCase().replace(/[\s-]+/g, "_");
        if (rule.enum.includes(folded)) { attrs[name] = folded; changes.fixedCase++; continue; }
        const neutral = NEUTRAL.find((member) => rule.enum.includes(member));
        if (neutral) { attrs[name] = neutral; changes.neutralised++; continue; }
      }
      attrs[name] = value;
    }
    return { ...fact, attrs };
  });
  const total = changes.droppedAttrs + changes.fixedCase + changes.neutralised;
  return { answer: total ? { ...answer, emit } : answer, changes: total ? changes : undefined };
}

module.exports = { conformAnswer };
