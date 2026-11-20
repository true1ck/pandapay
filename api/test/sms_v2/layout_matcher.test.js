"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const {
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
  exampleBodies,
} = require("../../src/sms_v2/layout_matcher");
const { lintPattern } = require("../../src/sms_v2/rules_admin_route");

const corpus = JSON.parse(
  fs.readFileSync(path.join(__dirname, "../../../contracts/sms/v2/fixtures/layout_corpus.json"), "utf8"),
).entries;
const reads = (matcher, text) => new RegExp(matcher.pattern, matcher.flags).test(text);
const throwsCode = (fn, code) => assert.throws(fn, (error) => error instanceof LayoutError && error.code === code);

test("every corpus message is read by the matcher of its layout (the phone's own skeleton agrees: see layout_corpus_test.dart)", () => {
  for (const { layout, messages } of corpus) {
    const matcher = buildMatcher(layout);
    for (const message of messages) assert.ok(reads(matcher, message), `${layout} <= ${message}`);
  }
});

test("a matcher passes the pattern lint the phone applies, stays under the rule size limit, and reads every way of writing the values", () => {
  for (const { layout } of corpus) {
    const matcher = buildMatcher(layout);
    assert.deepEqual(lintPattern(matcher.pattern, matcher.flags), [], layout);
    assert.ok(matcher.pattern.length <= 1900, layout);
    for (const fill of FILLS) assert.ok(reads(matcher, fillWith(layout, fill)), `${layout} with ${fill.AMT}`);
  }
});

test("each kind of value is read in the forms real messages print it", () => {
  const amt = buildMatcher("Paid <AMT> now");
  for (const text of ["Rs.450", "Rs 450.00", "INR 1,23,456.78", "₹450.5", "450.00", "Rs. 99/-", "rs.5"])
    assert.ok(reads(amt, `Paid ${text} now`), text);
  const date = buildMatcher("On <DATE> done");
  for (const text of ["20-11-26", "20/11/2026", "2026-11-20", "2026-11-20 14:05:09", "20-Nov-2026", "20Nov26", "20 November 2026", "Nov 20, 2026", "20.11.26 14:05"])
    assert.ok(reads(date, `On ${text} done`), text);
  const mask = buildMatcher("Card <MASK> used");
  for (const text of ["XX1234", "x1234", "*1234", "XXXX1234", "••1234", "ending 1234", "ending with 123456"]) assert.ok(reads(mask, `Card ${text} used`), text);
  assert.equal(reads(mask, "Card 1234 used"), false, "a bare number is not a mask");
  assert.equal(reads(buildMatcher("Ref <REF>."), "Ref 12345."), false, "a reference has 6 or more digits");
});

test("slots are numbered in reading order, per kind, and the indexed layout names them", () => {
  const { slots } = parseLayout("<AMT> to <PARTY> on <DATE>, bal <AMT>, ref <REF> <AMT>");
  assert.deepEqual(slots.map((s) => s.name), ["amt1", "party1", "date1", "amt2", "ref1", "amt3"]);
  assert.equal(buildMatcher("<AMT> to <PARTY>. Code ####").indexed, "<amt1> to <party1>. Code ####");
  assert.equal(buildMatcher("  spaced   out  ").indexed, "spaced out");
});

test("slotValues gives the value of each slot of a sample, or null when the sample is another layout", () => {
  const matcher = buildMatcher("<AMT> paid to <PARTY> on <DATE>.");
  assert.deepEqual(slotValues(matcher, "Rs.4821.50 paid to ZAZA SHOP on 20-Nov-26."), { amt1: "Rs.4821.50", party1: "ZAZA SHOP", date1: "20-Nov-26" });
  assert.equal(slotValues(matcher, "Something else entirely."), null);
  assert.equal(slotValues(matcher, 42), null);
  assert.equal(slotValues(matcher, undefined), null);
});

test("refusals are named: empty layouts, too many name slots, a pattern too long for a rule, no words to learn from", () => {
  throwsCode(() => buildMatcher(""), "layout_empty");
  throwsCode(() => buildMatcher("   "), "layout_empty");
  const names = Array(MAX_WILDCARDS + 1).fill("<PARTY>").join(" x ");
  throwsCode(() => buildMatcher(names), "layout_too_many_wildcards");
  // An unknown tag is a wildcard too, so it counts.
  throwsCode(() => buildMatcher(`<MERCHANT> a ${Array(MAX_WILDCARDS).fill("<W>").join(" c ")}`), "layout_too_many_wildcards");
  assert.doesNotThrow(() => buildMatcher(Array(MAX_WILDCARDS).fill("<PARTY>").join(" x ")));
  throwsCode(() => buildMatcher(Array(30).fill("<DATE>").join(" x ")), "layout_pattern_too_long");
  throwsCode(() => exampleBodies("<AMT> <DATE> ####"), "layout_has_no_words");
});

test("examples: two different bodies the pattern reads and two it does not, even for a layout with no values", () => {
  for (const layout of ["<AMT> paid to <PARTY>.", "Your account has been updated.", "<AMT>", "Hello"].filter((l) => /[A-Za-z]{2}/.test(l.replace(/<[A-Z]+>/g, "")))) {
    const matcher = buildMatcher(layout);
    const { positives, negatives } = exampleBodies(layout);
    assert.equal(new Set(positives).size, 2, layout);
    assert.equal(new Set(negatives).size, 2, layout);
    for (const body of positives) assert.ok(reads(matcher, body), `${layout} should read: ${body}`);
    for (const body of negatives) assert.equal(reads(matcher, body), false, `${layout} should not read: ${body}`);
  }
});

test("a message that is not the layout is turned away fast, even with every name slot used and a hostile text", () => {
  const matcher = buildMatcher("<PARTY> sent <PARTY> money to <PARTY> today.");
  const hostile = `${"sent ".repeat(200)}money to ${"x ".repeat(300)}never ends`;
  const started = Date.now();
  assert.equal(reads(matcher, hostile), false);
  assert.ok(Date.now() - started < 500, `took ${Date.now() - started} ms`);
});

test("fillSynthetic is stable (the worker's first check and the covered check depend on it)", () => {
  assert.equal(fillSynthetic("<AMT> paid to <PARTY>."), "Rs. 127.45 paid to SYNTHETIC STORE.");
  assert.equal(fillSynthetic("Code ####"), "Code 4444");
  assert.equal(fillSynthetic("<NEW_TAG> x"), "SYNTHETIC x");
});

test("the rules built for the prompt's worked examples are the fixture the phone's engine is tested with", () => {
  const { buildRule } = require("../../src/sms_v2/template_worker");
  const { EXAMPLES } = require("../../src/sms_v2/ai_prompt");
  const file = path.join(__dirname, "../../../contracts/sms/v2/fixtures/built_rules.json");
  const built = EXAMPLES.map((example) => {
    const layout = example.layout.replace(/<([a-z]+)\d>/g, (_m, kind) => `<${kind.toUpperCase()}>`);
    const template = { template_hash: "a".repeat(64), sender_brand: "HDFCBK", redacted_body: layout };
    const rule = buildRule(example.answer, template, buildMatcher(layout), "test-model");
    return { layout, rule: { ...rule, updatedAt: "2026-11-20T00:00:00Z" } };
  });
  // After a change to the matcher or the examples: UPDATE_FIXTURES=1 node --test api/test/sms_v2/layout_matcher.test.js
  if (process.env.UPDATE_FIXTURES) fs.writeFileSync(file, JSON.stringify(built, null, 2) + "\n");
  assert.deepEqual(built, JSON.parse(fs.readFileSync(file, "utf8")), "run with UPDATE_FIXTURES=1 to refresh built_rules.json, then run the Dart built_rule_engine_test");
});

test("the phone's wildcard limit and count agree with the matcher (the phone skips such layouts before they use an upload slot)", () => {
  const { wildcardLimit, adjacentLooseLimit, entries } = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../../../contracts/sms/v2/fixtures/layout_corpus.json"), "utf8"),
  );
  // packages/pandapay_domain/lib/src/sms_v2/template/skeleton.dart: smsMaxLayoutWildcards, smsLayoutWildcards.
  // Lowering MAX_WILDCARDS here means changing wildcardLimit in the fixture and that constant on the phone.
  assert.equal(wildcardLimit, MAX_WILDCARDS);
  assert.equal(adjacentLooseLimit, MAX_ADJACENT_LOOSE);
  for (const { layout, wildcards } of entries) {
    const wild = parseLayout(layout).slots.filter((slot) => slot.kind === "party" || slot.kind === "w" || !SLOT_PATTERNS[slot.kind]);
    assert.equal(wild.length, wildcards, layout);
  }
});

// qa-bug-hunt S3-2: 8 name slots, or 3 in a row, let a message that is NOT the layout (a sender's other SMS, or a crafted
// one) take seconds. The worst accepted layout must now turn such a message away within a small budget.
test("a layout is either refused, or turns a hostile near-miss message away fast (the old limits took 2 to 4+ seconds)", async () => {
  const { Worker } = require("node:worker_threads");
  const source = path.join(__dirname, "../../src/sms_v2/layout_matcher.js");
  const run = (layout, text, limitMs) =>
    new Promise((resolve) => {
      const worker = new Worker(
        "const { workerData, parentPort } = require('node:worker_threads');" +
          "const { buildMatcher } = require(workerData.source);" +
          "(() => { let m; try { m = buildMatcher(workerData.layout); } catch (e) { parentPort.postMessage({ refused: e.code }); return; }" +
          "const re = new RegExp(m.pattern, m.flags); const t = process.hrtime.bigint(); re.test(workerData.text);" +
          "parentPort.postMessage({ ms: Number(process.hrtime.bigint() - t) / 1e6 }); })();",
        { eval: true, workerData: { source, layout, text } },
      );
      const timer = setTimeout(() => (worker.terminate(), resolve({ ms: Infinity })), limitMs);
      worker.on("message", (message) => (clearTimeout(timer), worker.terminate(), resolve(message)));
    });
  const repeat = (unit, length) => unit.repeat(Math.ceil(length / unit.length)).slice(0, length) + " nope";
  const P = "<PARTY>";
  const hostile = [
    ["8 name slots joined by ' and '", Array(8).fill(P).join(" and ") + " ok.", "x and "],
    ["6 name slots, the joining word repeated", Array(6).fill(P).join(" a ") + " ok.", "a "],
    ["5 name slots, the joining word repeated", Array(5).fill(P).join(" a ") + " ok.", "a "],
    ["8 name slots in a row", Array(8).fill(P).join(" ") + " ok.", "a "],
    ["5 name slots in a row", Array(5).fill(P).join(" ") + " ok.", "a "],
    ["3 phone numbers in a row", "Call <PHONE> <PHONE> <PHONE> now", "1 "],
    ["4 name slots, the joining word repeated (the most that is accepted)", Array(MAX_WILDCARDS).fill(P).join(" a ") + " ok.", "a "],
    ["2 pairs of touching name slots", `${P} ${P} a ${P} ${P} ok.`, "a "],
  ];
  const slow = [];
  for (const [name, layout, unit] of hostile) {
    const result = await run(layout, repeat(unit, 640), 3000);
    if (!result.refused && !(result.ms < 400)) slow.push(`${name}: ${result.ms === Infinity ? "over 3000" : Math.round(result.ms)} ms`);
  }
  assert.deepEqual(slow, []);
});

test("touching loose slots (names, words, phone numbers) are refused beyond two in a row; a literal between them lifts that", () => {
  throwsCode(() => buildMatcher("Call <PHONE> <PHONE> <PHONE> now"), "layout_adjacent_wildcards");
  throwsCode(() => buildMatcher("<PARTY> <W> <PARTY> sent money"), "layout_adjacent_wildcards");
  assert.doesNotThrow(() => buildMatcher("Call <PHONE> <PHONE> now"));
  assert.doesNotThrow(() => buildMatcher("Call <PHONE> or <PHONE> or <PHONE> now"));
  assert.doesNotThrow(() => buildMatcher("<PARTY> <W> paid <AMT> to <PARTY> <W> today"));
  assert.ok(MAX_WILDCARDS <= 4, "raise the limit only with new near-miss timings (see the test above)");
});

test("a realistic bank layout (one name, one phone number) is read fast and far inside the limits", () => {
  const layout = "Rs <AMT> debited from A/c <MASK> to <PARTY> on <DATE>. UPI Ref <REF>. If not you, call <PHONE>";
  const matcher = buildMatcher(layout);
  const started = Date.now();
  assert.equal(reads(matcher, "Rs 1 debited from A/c xx12 to a on 1/1/26. ".repeat(40) + "end"), false);
  assert.ok(Date.now() - started < 100, `took ${Date.now() - started} ms`);
});
