"use strict";

// Cleans a layout before it is drafted, checked and matched. The phone's smsDraftLayout
// (packages/pandapay_domain/lib/src/sms_v2/template/skeleton.dart) must give the same result: both read the fixture
// contracts/sms/v2/fixtures/draft_layout_corpus.json. The template hash is always the hash of the ORIGINAL layout.
//
//  1. Odd tags a phone once wrote (<AMOUNT>, <ACCOUNT>) become <AMT> and <MASK>.
//  2. A bare @handle ("@Flipkart", "@UPI_<PARTY>"; not an e-mail, which has a word character before the @) becomes <W>. The
//     service refuses any "@" in a layout, so such a format could never be drafted.
//  3. A long token that mixes letters with # digits (a transaction or reference ID such as "mvtHfGfdjLvdwwKyVa#pF#") becomes
//     <W>: it was a privacy gap (an ID reached the AI) and it made the AI call it a slot that does not exist.
// Blanks are NOT merged (tried 21 Nov 2026: a safe merge rescued 3 of 40 layouts over the blank limit, and a merged blank
// covers only 60 characters, so the rule could never match). A layout over the limit stays refused, by name.
// Idempotent. Never throws.

const ALIASES = { AMOUNT: "AMT", ACCOUNT: "MASK" };
const HANDLE = /(?<![\w>])@[A-Za-z_]\w*(?:<[A-Z_]+>)?/g;
const MIXED_ID = /(?<![\w<#>])(?=[A-Za-z#]*#)(?=(?:[^A-Za-z]*[A-Za-z]){6})[A-Za-z#]{12,}(?![\w>])/g;

function draftLayout(layout) {
  if (typeof layout !== "string") return layout;
  let text = layout.replace(/<([A-Z][A-Z_]*)>/g, (whole, name) => (ALIASES[name] ? `<${ALIASES[name]}>` : whole));
  text = text.replace(HANDLE, "<W>").replace(MIXED_ID, "<W>");
  return text;
}

module.exports = { draftLayout };
