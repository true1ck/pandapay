"use strict";

// Does an AI draft MEAN what its layout says? validateDraft proves a draft is well formed (slots exist, the
// pattern reads the layout, the facts match the contract). This proves the model did not wire the wrong slot or
// say the wrong thing: an amount taken from the date, the balance posted as the spend, a debit called a credit.
// The phone applies an accepted draft at the model's confidence and never second-guesses it, so these are checked
// here, from the layout alone (its slot kinds and the words around each slot), before the draft is stored.
//
// sanityErrors(rule, layout) -> codes ([] = nothing wrong). Codes name the slot and the problem so the second try
// can fix them. isDoubtful(rule, layout) -> true when the layout gives too little to be sure (no debit or credit
// word, or two amounts and nothing says which one moved); the caller keeps such a draft below the phone's
// "confident" line (kConfidentRead 0.7) so the person is asked, instead of rejecting a draft that may be right.

const path = require("node:path");
const { SCHEMA_DIR } = require("./contracts");
const { parseLayout } = require("./layout_matcher");
const factSchema = require(path.join(SCHEMA_DIR, "fact.schema.json"));

const DOUBTFUL_CONFIDENCE = 0.69; // just under kConfidentRead (packages/pandapay_domain .../contract/fact.dart)

// Which slot kinds may feed which field. A tag this module does not know is a name (see layout_matcher isWild).
const NAMEY = ["party", "w", "vpa", "email"];
const KINDS = Object.freeze({
  amount: ["amt"],
  date: ["date"],
  mask: ["mask", "ref"],
  name: NAMEY,
  vpa: ["vpa", "email", "w", "party"],
  reference: ["ref", "w", "mask"],
  text: null, // anything but an amount or a date
});
const DATE_ATTRS = new Set(["dueDate", "statementDate", "asOf", "dueAt", "expiresAt"]);
const AMOUNT_ATTRS = new Set(["previousMinor", "amountMinor"]);
const INSTRUMENT_KEYS = { maskFrom: "mask", maskLengthFrom: "mask", issuerSlugFrom: "text", productNameFrom: "text" };
const COUNTERPARTY_KEYS = { nameFrom: "name", vpaFrom: "vpa", accountMaskFrom: "mask" };

const BALANCE = /\b(?:bal(?:ance)?|avl\w*|avbl\w*|avail\w*|limit|lmt|outstanding|remaining|closing|o\/s)\b/i;
const BALANCE_ROLE_CUE = /\b(?:bal(?:ance)?|avl\w*|avbl\w*|avail\w*|limit|lmt|outstanding|remaining|closing|total|net|funds|left|due)\b/i;
const TXN = /\b(?:debit(?:ed)?|credit(?:ed)?|spent|paid|pay|sent|received|withdrawn|purchase[d]?|payment|txn|transaction|transferred|deducted|charged?|fee|refund(?:ed)?|reversed|cashback|deposited)\b/i;
// Strong words only reject a draft; a draft with just weak ones, or none, is only doubted.
const DEBIT_STRONG = /\b(?:debited|withdrawn|spent|deducted)\b/i;
const CREDIT_STRONG = /\b(?:credited|refunded|deposited|reversed)\b/i;
const DEBIT_WEAK = /\b(?:debit|paid|pay|sent|purchase[d]?|payment|txn|transaction|transfer(?:red)?|charged?|fee|withdrawal|dr)\b/i;
const CREDIT_WEAK = /\b(?:credit|received|added|salary|interest|cashback|refund|deposit|reversal|cr)\b/i;
// A purpose that only makes sense with its own wording (and, for pay-ins, a credit).
const PURPOSE_WORDS = Object.freeze({
  salary: { words: /\b(?:salary|sal|payroll|wages?|stipend)\b/i, credit: true },
  interest: { words: /\b(?:interest|int)\b/i, credit: true },
  dividend: { words: /\b(?:dividend|div)\b/i, credit: true },
  atm: { words: /\b(?:atm|cash|withdraw\w*|wdl)\b/i, credit: false },
});


// The literal words of the layout around each slot: up to 5 before and 4 after, stopping at the next slot.
function readLayout(layout) {
  const { parts } = parseLayout(String(layout).trim());
  const slots = new Map();
  const literal = [];
  parts.forEach((part, i) => {
    if (part.text) literal.push(part.text);
    if (!part.slot) return;
    const before = [];
    for (let j = i - 1; j >= 0 && before.length < 5 && !parts[j].slot; j--) if (parts[j].text) before.unshift(parts[j].text);
    const after = [];
    for (let j = i + 1; j < parts.length && after.length < 4 && !parts[j].slot; j++) if (parts[j].text) after.push(parts[j].text);
    slots.set(part.slot.name, { kind: part.slot.kind, before, after });
  });
  return { slots, text: literal.join(" ") };
}

const isKnownKind = (kind) => ["amt", "date", "mask", "ref", "phone", "email", "vpa", "url", "party", "w"].includes(kind);
const kindOk = (want, kind) => {
  if (want === "text") return kind !== "amt" && kind !== "date";
  const allowed = KINDS[want];
  return allowed.includes(kind) || !isKnownKind(kind); // an unknown tag is a name
};

// Where a slot is used: [{ field, want, slot }].
function usages(emit) {
  const out = [];
  const add = (field, want, slot) => typeof slot === "string" && out.push({ field, want, slot });
  emit.forEach((fact, i) => {
    const at = `emit[${i}]`;
    (fact.amounts ?? []).forEach((a) => {
      add(`${at}.amounts.${a?.role}`, "amount", a?.from);
      add(`${at}.amounts.${a?.role}.original`, "amount", a?.original?.from);
    });
    add(`${at}.occurredAt`, "date", fact.occurredAt?.from);
    for (const [key, value] of Object.entries(fact.attrs ?? {}))
      if (value && typeof value === "object") add(`${at}.attrs.${key}`, DATE_ATTRS.has(key) ? "date" : AMOUNT_ATTRS.has(key) ? "amount" : "text", value.from);
    for (const [key, want] of Object.entries(INSTRUMENT_KEYS)) add(`${at}.instrument.${key}`, want, fact.instrument?.[key]);
    for (const [key, want] of Object.entries(COUNTERPARTY_KEYS)) add(`${at}.counterparty.${key}`, want, fact.counterparty?.[key]);
    for (const [key, slot] of Object.entries(fact.references ?? {})) add(`${at}.references.${key}`, "reference", slot);
  });
  return out;
}

// Amount shape rules from the fact contract itself (what the phone enforces when it builds the fact), so a
// draft that could never apply is refused here: roles a type allows, the role it needs, how many amounts.
function amountErrors(emit) {
  const errors = [];
  emit.forEach((fact, i) => {
    const spec = factSchema.$defs[fact.factType]?.properties?.amounts;
    if (!spec) return;
    const amounts = Array.isArray(fact.amounts) ? fact.amounts : [];
    const roles = amounts.map((a) => a?.role);
    const allowed = spec.items?.properties?.role?.enum;
    const needs = spec.contains?.properties?.role?.enum;
    const bad = allowed && roles.filter((role) => !allowed.includes(role));
    if (bad?.length) errors.push(`amount_role_not_allowed: ${fact.factType} takes ${allowed.join("|")}, not ${[...new Set(bad)].join("|")}`);
    if (needs && !roles.some((role) => needs.includes(role))) errors.push(`amount_missing: ${fact.factType} needs a ${needs.join("|")} amount`);
    if (spec.minItems && amounts.length < spec.minItems) errors.push(`amount_missing: ${fact.factType} needs ${spec.minItems} amount`);
    if (spec.maxItems !== undefined && amounts.length > spec.maxItems) errors.push(`amount_count: ${fact.factType} takes at most ${spec.maxItems} amount`);
    if (new Set(roles).size !== roles.length) errors.push(`amount_role_repeated: ${fact.factType} has two ${roles.find((r, k) => roles.indexOf(r) !== k)} amounts`);
    if (fact.factType === "bill_due" && fact.attrs?.dueMonthOnly !== true && !roles.some((r) => r === "due_total" || r === "due_minimum"))
      errors.push("amount_missing: bill_due needs a due_total|due_minimum amount");
  });
  return errors;
}

function unitErrors(emit, text) {
  const errors = [];
  for (const fact of emit)
    for (const a of fact.amounts ?? []) {
      if (!a || typeof a.unit !== "string") continue;
      const points = String(a.role).startsWith("points");
      const named = new RegExp(`\\b${a.unit}\\b`, "i").test(text);
      if (points ? a.unit !== "POINTS" : a.unit === "POINTS" || (a.unit !== "INR" && !named))
        errors.push(`amount_unit_unsupported: ${a.role} is ${a.unit}${points ? ", points are POINTS" : ", the layout is in rupees (INR)"}`);
    }
  return errors;
}

function sanityErrors(rule, layout) {
  const emit = Array.isArray(rule?.emit) ? rule.emit.filter((fact) => fact && typeof fact === "object") : [];
  let info;
  try {
    info = readLayout(layout);
  } catch {
    return [];
  }
  const errors = [...amountErrors(emit), ...unitErrors(emit, info.text)];
  // 1. A slot feeds only the fields its kind fits.
  for (const { field, want, slot } of usages(emit)) {
    const known = info.slots.get(slot);
    if (known && !kindOk(want, known.kind)) errors.push(`slot_kind_mismatch: ${slot} is a ${known.kind}, ${field} needs ${{ text: "text", name: "a name", amount: "an amount" }[want] ?? "a " + want}`.slice(0, 160));
  }
  // 2. The money that moved is not a balance, and a balance is not the money that moved.
  const postedSlots = new Set();
  for (const fact of emit)
    for (const a of fact.amounts ?? []) {
      const known = info.slots.get(a?.from);
      if (!known || known.kind !== "amt") continue;
      const near = known.before.slice(-4).join(" ");
      const labelled = BALANCE.test(near) || (/^(?:is|as|available|avail|avl|balance|bal|remaining|outstanding|left)$/i.test(known.after[0] ?? "") && (known.after[0] !== "is" || BALANCE.test(known.after.slice(1, 4).join(" "))));
      if (a.role === "posted") {
        postedSlots.add(a.from);
        if (labelled) errors.push(`posted_amount_is_balance: ${a.from} follows "${near}", it is a balance or limit, not the amount that moved`.slice(0, 160));
      } else if (["available_balance", "available_credit", "credit_limit"].includes(a.role)) {
        const around = [...known.before, ...known.after.slice(0, 3)].join(" ");
        if (TXN.test(around) && !BALANCE_ROLE_CUE.test(around)) errors.push(`balance_amount_not_balance: ${a.from} is next to "${around}", not a balance`.slice(0, 160));
      }
    }
  // 3. More than one posted amount needs a transaction word beside each of them.
  if (postedSlots.size > 1)
    for (const slot of postedSlots) {
      const known = info.slots.get(slot);
      if (!TXN.test([...known.before.slice(-4), ...known.after.slice(0, 3)].join(" "))) errors.push(`posted_amount_unsupported: ${slot} has no payment word beside it`);
    }
  // 4. Direction and purpose against the layout's words.
  const debit = DEBIT_STRONG.test(info.text);
  const credit = CREDIT_STRONG.test(info.text);
  for (const fact of emit) {
    const direction = fact.attrs?.direction;
    if ((fact.factType === "movement" || fact.factType === "attempt") && fact.attrs?.evidenceOnly !== true) {
      if (direction === "credit" && debit && !credit) errors.push("direction_conflicts_wording: the layout says debited, the draft says credit");
      if (direction === "debit" && credit && !debit) errors.push("direction_conflicts_wording: the layout says credited, the draft says debit");
    }
    const needs = PURPOSE_WORDS[fact.attrs?.purpose];
    if (needs && (fact.factType === "movement" || fact.factType === "attempt")) {
      if (!needs.words.test(info.text)) errors.push(`purpose_unsupported: the layout never says ${fact.attrs.purpose}`);
      else if (needs.credit && direction !== "credit") errors.push(`purpose_unsupported: ${fact.attrs.purpose} is money in, not a ${direction}`);
    }
  }
  return [...new Set(errors)];
}

function isDoubtful(rule, layout) {
  try {
    const emit = Array.isArray(rule?.emit) ? rule.emit : [];
    const money = emit.filter((fact) => fact?.factType === "movement" && fact.attrs?.evidenceOnly !== true);
    if (!money.length) return false;
    const { slots, text } = readLayout(layout);
    // No word says which way the money went.
    if (!DEBIT_STRONG.test(text) && !CREDIT_STRONG.test(text) && !DEBIT_WEAK.test(text) && !CREDIT_WEAK.test(text)) return true;
    // Two amounts, and nothing beside the one posted says it moved while the other says nothing either.
    const amts = [...slots].filter(([, s]) => s.kind === "amt");
    if (amts.length < 2) return false;
    return money.some((fact) =>
      (fact.amounts ?? []).some((a) => {
        if (a?.role !== "posted") return false;
        const own = slots.get(a.from);
        if (!own) return false;
        const cued = TXN.test([...own.before.slice(-4), ...own.after.slice(0, 3)].join(" "));
        const otherLabelled = amts.some(([name, s]) => name !== a.from && BALANCE.test(s.before.slice(-4).join(" ")));
        return !cued && !otherLabelled;
      }),
    );
  } catch {
    return false;
  }
}

module.exports = { sanityErrors, isDoubtful, DOUBTFUL_CONFIDENCE };
