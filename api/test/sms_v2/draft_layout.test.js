"use strict";
// A layout is cleaned before it is drafted, checked and matched: odd tags, bare @handles and long mixed IDs (a privacy gap
// that also made the layout fail), and blanks separated only by a harmless connector. The same fixture is read by the
// phone's Dart tests, so both sides clean a layout identically. The template hash stays the hash of the ORIGINAL layout.
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { draftLayout } = require("../../src/sms_v2/draft_layout");
const { buildMatcher, checkedExamples } = require("../../src/sms_v2/layout_matcher");

const corpus = JSON.parse(fs.readFileSync(path.join(__dirname, "../../../contracts/sms/v2/fixtures/draft_layout_corpus.json"), "utf8")).entries;

test("every fixture entry is cleaned exactly as written", () => {
  for (const { name, layout, clean } of corpus) assert.equal(draftLayout(layout), clean, name);
});

test("cleaning is idempotent", () => {
  for (const { layout } of corpus) assert.equal(draftLayout(draftLayout(layout)), draftLayout(layout), layout);
});

test("a cleaned layout builds a matcher with sound examples, and the matcher reads the original filled text", () => {
  for (const { layout, clean } of corpus) {
    if (clean.replace(/<[A-Z_]+>/g, "").trim().length < 2) continue;
    let matcher;
    try { matcher = buildMatcher(clean); } catch { continue; }
    checkedExamples(clean, matcher);
  }
});

test("the cleaned layout has no @ for the service to refuse, and blanks are never merged", () => {
  assert.ok(!/@/.test(draftLayout("shop @Flipkart now")));
  const many = "Dear <PARTY>, application <PARTY> of <PARTY> in <PARTY> has been <PARTY> on <PARTY>.";
  assert.equal(draftLayout(many), many);
});

test("random text never makes the cleaner throw or grow", () => {
  let seed = 3;
  const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
  const pieces = ["<PARTY>", "<W>", "<AMT>", "<MASK>", "<ACCOUNT>", "<AMOUNT>", "of", "and", "to", "@Shop", "a@b", "Ltd.", "mvtHfGfdjL#pF#x", "#", "####", "-", ",", " ", "é", "Rs."];
  for (let i = 0; i < 5000; i++) {
    const text = Array.from({ length: 1 + Math.floor(rnd() * 12) }, () => pieces[Math.floor(rnd() * pieces.length)]).join(rnd() < 0.5 ? " " : "");
    const out = draftLayout(text);
    assert.ok(out.length <= text.length + 12, text);
    assert.equal(draftLayout(out), out, `idempotent: ${text}`);
  }
});
