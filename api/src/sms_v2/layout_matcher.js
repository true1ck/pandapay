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
const isWild = (kind) => WILDCARD_KINDS.has(kind) || !SLOT_PATTERNS[kind];
// What a message that is NOT the layout costs grows about 30x per extra wildcard when the text repeats the words between
// them (measured on 160 to 640 characters of "a a a ..." against "<PARTY> a <PARTY> a ...": 3 slots 3 ms, 4 slots 80 ms,
// 5 slots 2.3 s, 6 slots over 4 s). A promoted rule runs on every message of its sender, so at most 4. Touching loose
// slots are worse still (3 phone numbers in a row: 1.7 s on 800 characters), so at most 2 in a row. The phone merges
// neighbouring names into one <PARTY>, so real layouts rarely touch.
const MAX_WILDCARDS = 4;
const MAX_ADJACENT_LOOSE = 2;
const isLoose = (kind) => isWild(kind) || kind === "phone"; // a phone pattern ([\d -]{5,}) backtracks like a name
const MAX_PATTERN = 1900; // the rule schema allows 2,000

class LayoutError extends Error {
  constructor(code) {
    super(code);
    this.name = "LayoutError";
    this.code = code;
  }
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
  if (typeof layout !== "string" || !layout.trim()) throw new LayoutError("layout_empty");
  const { parts, slots } = parseLayout(layout.trim());
  if (slots.filter((s) => isWild(s.kind)).length > MAX_WILDCARDS) throw new LayoutError("layout_too_many_wildcards");
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
      pattern += `(?<${name}>${isWild(kind) ? WILDCARD : SLOT_PATTERNS[kind]})`;
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
  const positives = [fillWith(layout, FILLS[0]), fillWith(layout, FILLS[1])];
  // A layout with no values prints the same text twice; stray spaces are allowed around a message.
  if (positives[1] === positives[0]) positives[1] = `${positives[0]} `;
  const parts = layout.split(/(<[A-Z][A-Z_]*>)/); // odd entries are the tags
  const spots = [];
  parts.forEach((text, index) => {
    if (index % 2 === 1) return;
    for (const match of text.matchAll(/[A-Za-z]{2,}/g)) spots.push({ index, at: match.index, length: match[0].length });
  });
  if (!spots.length) throw new LayoutError("layout_has_no_words");
  const change = (spot, to) =>
    fillWith(
      parts.map((text, index) => (index === spot.index ? text.slice(0, spot.at) + to + text.slice(spot.at + spot.length) : text)).join(""),
      FILLS[0],
    );
  return { positives, negatives: [change(spots[0], "zqx"), change(spots.at(-1), "zqy")] };
}

// The examples of a layout, checked against its own pattern: both positives read, both negatives refused and different
// from the positives. A layout for which that cannot be shown is one our own checks would fail whatever an AI answers,
// so it is refused here, with its own code, before any AI call is spent on it.
function checkedExamples(layout, matcher) {
  const examples = exampleBodies(layout);
  const regex = new RegExp(matcher.pattern, matcher.flags);
  const sound =
    examples.positives.every((body) => regex.test(body)) &&
    examples.negatives.every((body) => !examples.positives.includes(body) && !regex.test(body)) &&
    new Set(examples.negatives).size === 2;
  if (!sound) throw new LayoutError("layout_examples_unsound");
  return examples;
}

module.exports = {
  LayoutError,
  MAX_WILDCARDS,
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
