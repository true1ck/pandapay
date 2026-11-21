"use strict";

// A "layout" is a message with every changing value replaced by a tag (<AMT>, <DATE>, <MASK>, <REF>,
// <PARTY>, ...) and every other digit by "#". This module turns a layout into the matching pattern, so
// the AI never has to write a regex: it only says what each slot means. The same layout always gives the
// same pattern, so one answer serves every person who sends that layout.
//
// The slot patterns mirror the phone's skeleton in
// packages/pandapay_domain/lib/src/sms_v2/template/skeleton.dart. Keep them in step with it; the corpus
// test in api/test/sms_v2/layout_matcher.test.js reads the contracts fixtures to catch drift.

const SLOT_PATTERNS = Object.freeze({
  // A whole amount as printed: the engine's parseAmountIndian drops "Rs.", "INR", "₹" and "/-" itself.
  amt: String.raw`(?:rs\.?|inr|₹)?\s*\d[\d,]*(?:\.\d+)?(?:\s*/-)?`,
  date: String.raw`\d{4}-\d{2}-\d{2}(?:[:T ]\d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}(?:,? \d{2}:\d{2}(?::\d{2})?)?|\d{1,2}[ -]?[a-z]{3,9}[ ,-]*\d{2,4}(?:,? \d{2}:\d{2}(?::\d{2})?)?|[a-z]{3,9}\.? \d{1,2},? \d{2,4}`,
  mask: String.raw`[x*•●·]{1,12}\d{2,6}|\.{2,}\d{2,6}|\d{2,6}[x*•●·]{2,12}\d{2,6}|ending(?:\s+(?:with|in))?\s+\d{2,6}`,
  ref: String.raw`\d{6,}`,
  phone: String.raw`\+?\d[\d -]{5,}\d`,
  email: String.raw`[\w.\-+*•●]+@[\w.\-]+`,
  vpa: String.raw`[\w.\-+*•●]+@[\w.\-]+`,
  url: String.raw`https?://\S+|www\.\S+|[a-z0-9-]+\.(?:com|in|co|io|ly|me|net|org)(?:/\S*)?`,
});
// Names and removed words: anything, kept short and lazy. Each one multiplies the work a pattern does on a
// message it does not match, so a layout with more than MAX_WILDCARDS of them is refused, not guessed.
const WILDCARD = String.raw`[\s\S]{1,60}?`;
const WILDCARD_KINDS = new Set(["party", "w"]);
// A tag this module does not know (a newer phone) is read as a name too, and counts as one.
const isWild = (kind) => WILDCARD_KINDS.has(kind) || !Object.hasOwn(SLOT_PATTERNS, kind);
// What a message that is NOT the layout costs grows about 30x per extra wildcard when the text repeats the words between
// them (measured on 160 to 640 characters of "a a a ..." against "<PARTY> a <PARTY> a ...": 3 slots 3 ms, 4 slots 80 ms,
// 5 slots 2.3 s, 6 slots over 4 s). A promoted rule runs on every message of its sender, so at most 4. Touching loose
// slots are worse still (3 phone numbers in a row: 1.7 s on 800 characters), so at most 2 in a row. The phone merges
// neighbouring names into one <PARTY>, so real layouts rarely touch.
const MAX_WILDCARDS = 4;
// A layout with MORE than MAX_WILDCARDS name slots (refused before 22 Nov 2026) may have up to MAX_ANCHORED_WILDCARDS,
// provided at most MAX_WILDCARDS of them have no fixed text after them. A slot that is followed by fixed text stops
// where that text begins (see `stopsAt`), so it can only end in one place and the cost does not multiply per slot. Real
// bank texts print many names and words as <PARTY> around fixed words (21 Nov 2026: 17 layouts, 3 of them seen 12
// times, were refused before any AI saw them). A layout with MAX_WILDCARDS or fewer keeps the lazy pattern it always
// had, byte for byte: the stop is stricter than the lazy form (a name that contains the next fixed word, "M.G. Stores"
// before a ".", cannot be read), and no layout that was readable may lose that.
const MAX_ANCHORED_WILDCARDS = 12;
const MAX_ADJACENT_LOOSE = 2;
// The fixed text after a slot that ends it, in characters of the layout. A layout whose pattern comes out too long is built
// again with the next, shorter budget (22 Nov 2026: a 372-character bill notice with 4 dates and 7 name slots, seen 12 times,
// needed 2,098 characters with 40 and 1,905 with 8).
const ANCHOR_BUDGETS = [40, 24, 12, 8];
// One to three blanks, written without a variable quantifier: the phone's regex lint (lint.dart) and the server's
// (lintPattern) both refuse a quantified group that holds a variable quantifier, even inside a lookahead.
const GAP = String.raw`\s\s?\s?`;
const isLoose = (kind) => isWild(kind) || kind === "phone"; // a phone pattern ([\d -]{5,}) backtracks like a name
const MAX_PATTERN = 1990; // the rule schema and the phone lint allow 2,000

class LayoutError extends Error {
  constructor(code) {
    super(code);
    this.name = "LayoutError";
    this.code = code;
  }
}

// Up to 60 characters, none of them the start of what comes next: the wildcard ends where the fixed text begins and is
// never tried at another length (the lazy form is tried at every length on a message that does not fit).
const stopsAt = (next) => String.raw`(?:(?!${next})[\s\S]){1,60}`;

// The fixed run that follows the slot at parts[i] (blanks and text up to the next slot or digit mark, at most
// ANCHOR_CHARS of text, always its first word), as a pattern for a lookahead; null when a slot, a digit mark or the end
// of the layout follows directly (the slot is then not anchored). A run that reaches the end of the layout is closed
// with the end, so a name that merely contains the first word does not stop early.
function stopAfter(parts, i, budget) {
  let j = i + 1;
  let gap = false;
  let chars = 0;
  let out = "";
  let last = "";
  let whole = true;
  for (; j < parts.length; j++) {
    const part = parts[j];
    if (part.space) {
      gap = true;
      continue;
    }
    if (!part.text) break;
    const letters = Array.from(part.text); // by character, so an emoji is never cut in half
    if (out && chars + letters.length > budget) break;
    last = letters.slice(0, budget).join("");
    whole = letters.length <= budget;
    out += (gap ? GAP : "") + escapeText(last);
    chars += letters.length;
    gap = false;
  }
  if (!out) return null;
  if (j >= parts.length) out += String.raw`\s?\s?\s?$`; // the run ends the layout (blanks allowed first)
  // A word-like stop that a blank follows must end at the end of a word, so "s" does not stop a name inside "STORE".
  else if (gap && whole && /[A-Za-z0-9_]$/.test(last)) out += String.raw`\b`;
  return out;
}
const escapeText = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Splits a layout into text, spaces, digits and slots. Slots are numbered per kind: <AMT> twice gives
// amt1 and amt2, in reading order.
function parseLayout(layout) {
  const parts = [];
  const slots = [];
  const seen = {};
  const re = /<([A-Z][A-Z_]*)>|(#)|(\s+)|([^<#\s]+|<)/g;
  let m;
  while ((m = re.exec(layout))) {
    if (m[1]) {
      const kind = m[1].toLowerCase();
      seen[kind] = (seen[kind] || 0) + 1;
      const slot = { name: `${kind}${seen[kind]}`, kind };
      slots.push(slot);
      parts.push({ slot });
    } else if (m[2]) parts.push({ digit: true });
    else if (m[3]) parts.push({ space: true });
    else parts.push({ text: m[4] });
  }
  return { parts, slots };
}

function buildMatcher(layout) {
  for (let i = 0; ; i++) {
    try {
      return buildWithBudget(layout, ANCHOR_BUDGETS[i]);
    } catch (error) {
      // Only a pattern that is too long is tried again, with shorter stops; any other refusal is final.
      if (!(error instanceof LayoutError) || error.code !== "layout_pattern_too_long" || i >= ANCHOR_BUDGETS.length - 1) throw error;
    }
  }
}

function buildWithBudget(layout, budget) {
  if (typeof layout !== "string" || !layout.trim()) throw new LayoutError("layout_empty");
  const { parts, slots } = parseLayout(layout.trim());
  const wild = slots.filter((s) => isWild(s.kind));
  // Which name slots are followed by fixed text, and the text (the whole fixed run after it, up to the budget) that
  // ends each of them. Only a layout over the old limit uses them; see MAX_ANCHORED_WILDCARDS.
  const stops = new Map();
  if (wild.length > MAX_WILDCARDS) {
    parts.forEach((part, i) => {
      if (!part.slot || !isWild(part.slot.kind)) return;
      const stop = stopAfter(parts, i, budget);
      if (stop) stops.set(part.slot.name, stop);
    });
  }
  if (wild.length > MAX_ANCHORED_WILDCARDS || wild.filter((s) => !stops.has(s.name)).length > Math.min(wild.length, MAX_WILDCARDS))
    throw new LayoutError("layout_too_many_wildcards");
  let run = 0;
  for (const part of parts) {
    if (part.slot) run = isLoose(part.slot.kind) ? run + 1 : 0;
    else if (!part.space) run = 0;
    if (run > MAX_ADJACENT_LOOSE) throw new LayoutError("layout_adjacent_wildcards");
  }
  let pattern = "^\\s*";
  let indexed = "";
  for (const part of parts) {
    if (part.slot) {
      const { name, kind } = part.slot;
      // In a layout over the old limit a name never starts with a blank: the blanks belong to the `\s+` before it, and
      // without this each slot could take one to k of them (k to the power of the slots; 12 slots and 5 blanks ran 2+ s).
      // Nor does it end with one: a name that could end anywhere in a run of blanks gives k ends per slot, the same blow-up.
      const noBlankFirst = wild.length > MAX_WILDCARDS ? String.raw`(?!\s)` : "";
      const noBlankLast = wild.length > MAX_WILDCARDS ? String.raw`(?<!\s)` : "";
      pattern += `(?<${name}>${isWild(kind) ? noBlankFirst + (stops.has(name) ? stopsAt(stops.get(name)) : WILDCARD) + noBlankLast : SLOT_PATTERNS[kind]})`;
      indexed += `<${name}>`;
    } else if (part.digit) {
      pattern += "\\d";
      indexed += "#";
    } else if (part.space) {
      pattern += "\\s+";
      indexed += " ";
    } else {
      pattern += escapeText(part.text);
      indexed += part.text;
    }
  }
  pattern += "\\s*$";
  if (pattern.length > MAX_PATTERN) throw new LayoutError("layout_pattern_too_long");
  return { pattern, flags: "i", slots, indexed };
}

// The values each slot of a sample holds, or null when the sample is not this layout.
function slotValues(matcher, sample) {
  if (typeof sample !== "string") return null;
  let match;
  try {
    match = new RegExp(matcher.pattern, matcher.flags).exec(sample);
  } catch {
    return null;
  }
  if (!match) return null;
  return Object.fromEntries(matcher.slots.map((slot) => [slot.name, match.groups[slot.name]]));
}

// What each tag stands for, in the forms real messages print them. SYNTHETIC is what a layout is first
// checked with; the others make sure a pattern is not tied to one way of writing a value.
const FILLS = Object.freeze([
  { AMT: "Rs. 127.45", DATE: "2026-11-20", MASK: "x2468", VPA: "synthetic@bank", REF: "834217", PHONE: "9876501234", EMAIL: "synthetic@example.invalid", URL: "https://example.invalid", PARTY: "SYNTHETIC STORE", W: "SYNTHETIC", digit: "4" },
  { AMT: "Rs.450", DATE: "20-Nov-26", MASK: "XX1234", VPA: "abc@okhdfc", REF: "123456789012", PHONE: "9876543210", EMAIL: "abc@example.co.in", URL: "https://x.in/a", PARTY: "RAHUL SHARMA", W: "dear customer", digit: "7" },
  { AMT: "INR 1,23,456.78", DATE: "20/11/2026 14:05", MASK: "*1234", VPA: "shop.pay@ybl", REF: "4567891234", PHONE: "9123456780", EMAIL: "q@r.co.in", URL: "http://y.com", PARTY: "Amazon Pay India", W: "thank you", digit: "2" },
]);

function fillWith(layout, values) {
  return layout.replace(/<([A-Z][A-Z_]*)>/g, (_text, key) => values[key] || "SYNTHETIC").replace(/#/g, values.digit);
}
const fillSynthetic = (layout) => fillWith(layout, FILLS[0]);

// A sample from a phone keeps the tag of every value the phone never sends (a name, a phone number, a link, an
// address). Fill those with made-up values, so the sample reads like a message and lines up with the layout.
const fillTags = (sample) =>
  typeof sample === "string" ? sample.replace(/<([A-Z][A-Z_]*)>/g, (_text, key) => FILLS[0][key] || "SYNTHETIC") : sample;

// Two bodies the pattern must read and two it must not: the layout with a word of its FIXED text changed, the first
// word and then the last. The change is made in the layout, between the tags, and only then are the values filled in.
// (It was made on the filled text with `\bword\b`, which did nothing when the word touched a value or a blank, as in
// "[IN<REF>]", "#rd" or "##:##PM": the "negative" equalled the positive, the pattern read it, and the layout failed
// example_mismatch for ANY answer. 21 Nov 2026: 4 formats, 47 attempts.) A layout with no letters cannot be learned.
function exampleBodies(layout) {
  const { positives, candidates } = exampleCandidates(layout);
  return { positives, negatives: [candidates[0], candidates.at(-1)].map((c, i) => c.make(i === 0 ? "zqx" : "zqy")) };
}

// Every fixed word of the layout as a candidate for the "must not match" body, in the order they appear.
function exampleCandidates(layout) {
  const positives = [fillWith(layout, FILLS[0]), fillWith(layout, FILLS[1])];
  // A layout with no values prints the same text twice; stray spaces are allowed around a message.
  if (positives[1] === positives[0]) positives[1] = `${positives[0]} `;
  const parts = layout.split(/(<[A-Z][A-Z_]*>)/); // odd entries are the tags
  const candidates = [];
  parts.forEach((text, index) => {
    if (index % 2 === 1) return;
    for (const match of text.matchAll(/[A-Za-z]{2,}/g)) {
      candidates.push({
        make: (to) =>
          fillWith(
            parts.map((part, i) => (i === index ? part.slice(0, match.index) + to + part.slice(match.index + match[0].length) : part)).join(""),
            FILLS[0],
          ),
      });
    }
  });
  if (!candidates.length) throw new LayoutError("layout_has_no_words");
  return { positives, candidates };
}

// The examples of a layout, checked against its own pattern: both positives read, both negatives refused and different
// from the positives. A layout for which that cannot be shown is one our own checks would fail whatever an AI answers,
// so it is refused here, with its own code, before any AI call is spent on it.
function checkedExamples(layout, matcher) {
  const { positives, candidates } = exampleCandidates(layout);
  const regex = new RegExp(matcher.pattern, matcher.flags);
  if (!positives.every((body) => regex.test(body))) throw new LayoutError("layout_examples_unsound");
  // Two different bodies the pattern refuses: from the first fixed word that can break it, then from the last.
  const refuses = (candidate, to) => {
    const body = candidate.make(to);
    return !positives.includes(body) && !regex.test(body) ? body : null;
  };
  const first = candidates.map((c) => refuses(c, "zqx")).find(Boolean);
  const last = [...candidates].reverse().map((c) => refuses(c, "zqy")).find(Boolean);
  if (!first || !last || first === last) throw new LayoutError("layout_examples_unsound");
  return { positives, negatives: [first, last] };
}

module.exports = {
  LayoutError,
  MAX_WILDCARDS,
  MAX_ANCHORED_WILDCARDS,
  MAX_ADJACENT_LOOSE,
  SLOT_PATTERNS,
  FILLS,
  parseLayout,
  buildMatcher,
  slotValues,
  fillWith,
  fillSynthetic,
  fillTags,
  exampleBodies,
  checkedExamples,
};
