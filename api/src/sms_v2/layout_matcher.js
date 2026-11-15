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
const MAX_WILDCARDS = 3;
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

// Two bodies the pattern must read and two it must not: the same text with the first, and then the last,
// word of the layout changed. A layout with no letters at all cannot be learned.
function exampleBodies(layout) {
  const positives = [fillWith(layout, FILLS[0]), fillWith(layout, FILLS[1])];
  // A layout with no values prints the same text twice; stray spaces are allowed around a message.
  if (positives[1] === positives[0]) positives[1] = `${positives[0]} `;
  const words = (layout.replace(/<[A-Z][A-Z_]*>/g, " ").match(/[A-Za-z]{2,}/g) || []).filter(Boolean);
  if (!words.length) throw new LayoutError("layout_has_no_words");
  const swap = (word, to) => positives[0].replace(new RegExp(`\\b${word}\\b`, "gi"), to);
  const negatives = [swap(words[0], "zqx"), swap(words.at(-1), "zqy")];
  return { positives, negatives };
}

module.exports = {
  LayoutError,
  MAX_WILDCARDS,
  SLOT_PATTERNS,
  FILLS,
  parseLayout,
  buildMatcher,
  slotValues,
  fillWith,
  fillSynthetic,
  fillTags,
  exampleBodies,
};
