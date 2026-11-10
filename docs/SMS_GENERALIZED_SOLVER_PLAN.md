# SMS generalized solver: analysis and plan

**Status:** plan only. Nothing here is built. Written 9 Nov 2026 after reading the SMS v2 code, `SMS_V2_STATUS.md` and `docs/sms-pipeline-v2/security-audit-2026-11.md`.
**Labels used below:** **[verified]** = read in code or docs. **[hypothesis]** = believed, to be measured in Phase 0.

## 1. Why this exists

Different users hold different banks (one person has 4 or 5 accounts, the next person has 4 or 5 other banks). We cannot hand-write a rule per bank per layout, and banks change wording without notice. The product needs a second tier that reads a message the way a person does, instead of recognising a known layout.

Two constraints from the owner:
1. **Generalised**: works on unseen banks and unseen wording.
2. **Not reverse-engineerable**: the know-how must not be extractable from the app. Rules come from the server, only to registered, attested installs.

## 2. How the pipeline works today **[verified]**

```
SMS -> triage gate (keyword lists compiled into the app)
    -> sender normalisation (+ sender registry)
    -> rule engine: first matching regex rule by priority; rules scoped to sender brand or "*"
    -> facts -> linker (link rules) -> events -> ledger / projections
    unknown -> redacted skeleton -> server AI worker (Gemini) drafts a rule -> admin approves -> next signed bundle
    still unresolved -> Needs review
```

- The signed bundle (Ed25519) has 1,099 rules and is served from `GET /sms/v2/rules` with attestation, entitlement and rate checks. Cohorts: all, 25%, 5%, testers. The bundle shipped inside the app is empty (`baseline_bundle.json`, version 0, no rules).
- "Generalization" today means `rules/sms/v2/generalization/*`: regex rules with sender `*`, each a **wording guess for one layout**. A single layout becomes about 6 rules (credit/debit/none times the `-B` variant). This is still template matching with a wider net, not reading.
- The linker joins facts into events with legs. It has 11 link rules (IPO, mandate charge, card bill, wallet top-up, fee, refund, own transfer, receipt, duplicates). `billDue` exists as a fact type.

## 3. Gap inventory

| # | Gap | Evidence | Why it breaks a new user |
|---|---|---|---|
| G1 | **Matching is per layout.** An unseen phrasing matches nothing (`no_rule_matched`). | [verified] engine and GENZ notes ("wording guess") | Every new bank or reworded alert is a hole until a rule ships. |
| G2 | **Rule count explodes.** Variants multiply (direction x instrument x A/B). | [verified] GENZ table | Bundle growth, slower matching, shadowing risk, hard to lint. |
| G3 | **Triage vocabulary is hard-coded in the app** (`sms_gate_filter.dart`, `sms_text_hint.dart`, `intake_gate.dart` lifecycle regex, `template/vocabulary.dart`, `redact.dart`). | [verified] | (a) A transaction with unfamiliar wording never reaches the engine; the status doc already records 43 real messages dropped this way. (b) The vocabulary is readable from the binary, which defeats goal 2. |
| G4 | **Sender-dependent resolution.** Issuer and instrument kind come from the sender registry; unregistered handles lose that. The status doc lists 7 unregistered handles. Normalisation only strips `XX-` and `-S/-T/-P/-G`. | [verified] | New banks and new DLT headers. |
| G5 | **Gate vetoes by sender shape.** Senders that look like a contact name or end in `-P` are rejected. | [verified] `intake_gate.dart` | Some banks and brokers send transactional text on promotional headers. [hypothesis] |
| G6 | **No story state beyond pairs.** Link rules join two or three legs. A bill with reminders, a payment, a failed or overdue notice has no lifecycle object. | [verified] 11 link rules, no obligation entity. How `billDue` is projected: [hypothesis], check first. | Reminders after payment stay "open"; the same story shows up as several unrelated items. |
| G7 | **Multi-account users.** Instrument resolution relies on masks and the seeded instruments. Mask formats vary (`XX1234`, `ending 1234`, `A/c *1234`, 3-digit, 6-digit). | [verified] mask regex in `skeleton.dart`; real coverage [hypothesis] | The 4 to 5 accounts per person is the normal case, so wrong instrument attribution is common. |
| G8 | **Language.** Hindi, Marathi, Hinglish and other regional alerts. | [hypothesis] | Only English wording is covered by rules and gate. |
| G9 | **Counterparty extraction** depends on each layout. Person vs merchant vs VPA vs own name. | [verified] partial (`person_name.dart`, merchant aliases) | New banks put the payee in new positions. |
| G10 | **Long or split SMS**, concatenated parts, forwarded or quoted text. | [hypothesis] | Amount and instrument can land in different parts. |
| G11 | **Phone-side ReDoS exposure.** Signed bundles are not re-linted on the phone and there is no match timeout (LO-14, open). | [verified] security audit | Any new pattern pack widens this surface. The solver must not use unbounded user-facing regex. |
| G12 | **No measurement of "why not matched".** Engine records `unknownReasons`, but there is no per-sender-family view of gate-dropped vs unmatched vs matched-unknown-purpose. | [verified] stats exist, report [hypothesis] | We cannot rank gaps or prove the solver helps. |

## 4. Design: the evidence solver (tier 2)

### 4.1 Position in the flow

```
safety gate (OTP/PIN/credentials dropped; stays in the binary, fail closed)
  -> tier 1: existing rules (FROZEN, always first, untouched)
  -> only if tier 1 says no_rule_matched (or the gate rejected a bank-like sender):
       tier 2: evidence solver
         accept     -> same Fact objects, same validation, same linker
         candidate  -> AI worker (redacted layout) -> admin-approved rule -> becomes tier 1 or a pack update
         reject     -> ignored, with a stored reason code
  -> Needs review
```

Rules for the boundary:
- Tier 2 never sees a message tier 1 matched. Enforced in the engine, not by convention.
- Solver facts carry `provenance: solver`, `solverVersion`, per-field confidence, and a **confidence cap below any specific rule**. When a specific rule later covers the layout, "Refresh rules and re-sort" replaces the solver result.
- Gemini never decides a single message and never receives raw text; it drafts rules from redacted layouts, as today. Every Gemini rule an admin approves removes a future Gemini call.

### 4.2 How a message is read (the puzzle)

A person decides in this order, and so does the solver:

1. **Triage**: money, bill/obligation, balance info, promo, security, or other.
2. **Direction and completion**: did money actually move? ("debited", "spent", "credited", "received", "paid") versus not yet or not at all ("will be", "request", "failed", "declined", "if", "offer").
3. **Amount and its role**: paid amount vs available balance vs limit vs minimum due vs total due, from the cue words next to each number.
4. **Instrument**: masked account or card, wallet, UPI handle, matched against the user's known instruments.
5. **Counterparty**: the noun phrase after the payee cue (`to`, `at`, `towards`, `from`, `by`, `info`), a VPA, or a biller.
6. **Date and reference**; the received time is the fallback.
7. **Type**: rail and purpose (UPI, IMPS, NEFT, ATM, POS, EMI, mandate, refund, bill, SIP).
8. **Verify**: single consistent direction, amount is not a balance, not conditional, not promotional, mask belongs to a known instrument (boost), balance arithmetic when a previous balance is known.

Decision per message:
- **Auto-accept** needs all of: a completed-movement cue, one clear paid amount, one direction, and an instrument or counterparty. Everything else is a **candidate**.
- Priority of failure modes: a false count corrupts totals; a miss only costs a review. The thresholds favour the miss. The current standard is **0 false counts**, and tier 2 must keep it.

### 4.3 What lives in the app and what comes from the server

| In the binary (cheap to reveal) | In the signed `solverPack` from the server (the know-how) |
|---|---|
| Tokenizer, windowing, scoring arithmetic, verification plumbing, fact emit | Cue lexicons (direction, completion, balance, limit, payee, rail, biller, language packs) |
| The OTP/PIN safety gate and nothing else | Triage lexicon (replaces the hard-coded keyword lists, G3) |
| | Detector weights, thresholds, per-family accept rules |
| | Sender and issuer hints, mask grammar variants |

The kernel does nothing without a pack. The pack is a new signed section of the existing bundle (same signature, same cohorts, same rollback, same hourly re-sign), gated by `minEngineVersion`. A separate kill switch turns tier 2 off without touching tier 1.
Detectors use bounded token and window matching, not user-facing regex with unbounded quantifiers, so G11 does not grow.

## 5. Protecting the rules (goal 2) **[verified]** state, then actions

Already in place: Ed25519 signed bundles; empty baseline in the binary; `/sms/v2/rules` requires login, attestation, entitlement and rate limit; stored pre-signed copy only, fail closed; release builds obfuscated; per-profile and per-installation counters.

Gaps against the goal:
- **S1**: attestation `monitor` mode admits callers with no token at half limits, by design (LO-10). A script with a registered account can still download the bundle. Action: move `/sms/v2/rules` and the pack to `enforce` once the testers' devices attest.
- **S2**: the hard-coded vocabulary in the binary (G3). Action: Phase 2.
- **S3**: unknown whether the downloaded bundle is encrypted at rest on the phone. Receipts are (`PPRC`), the bundle was not found encrypted. Action: wrap it with a Keystore/Keychain-held key; decrypt into memory only.
- **S4**: AI-drafted provisional rules are delivered by sync and are not covered by the bundle signature (security audit). Action: sign them, or fold them into the signed pack.
- **S5**: no leak tracing. Action: per-account **canary entries** (harmless decoy cue words or decoy rules unique per account), so a leaked copy identifies its source.
- **S6**: no anomaly detection on rule fetches. Action: alert on many accounts per device, per IP or per attestation, and on abnormal fetch frequency.
- **S7**: repo-side exposure. `rules/` and golden fixtures live in git. Action: confirm they are never packaged into any app asset or public image, and keep the real sample private.

Honest limit: a determined person with a registered, attested, rooted device can eventually extract what the phone can read. These steps raise the cost, force registration, and make leaks traceable. The durable advantage is the learning loop and the corpus behind it, not the secrecy of one pack version, so the pack should be refreshed often.

## 6. Phases

**Phase 0: measure (no behaviour change).**
- Replay harness classifies every message: gate-dropped, no_rule_matched, rule_emitted_invalid, matched-with-unknown purpose, matched. Output per sender family. This produces the real gap list for G1, G3, G4, G5, G12.
- Build a **synthetic cross-bank corpus** (top issuers, wallets, brokers, billers, telcos; reordered, abbreviated, Hinglish variants). We do not own other users' banks, so this stands in for them. A held-out part is never used to author the pack.
- Verify G6: how `billDue` and reminders are projected today.
- Done when: a ranked gap table exists and a baseline recall/precision is recorded.

**Phase 1: schema and kernel, shadow mode.**
- Add `solverPack` to the bundle schema and the Dart kernel. Tier 2 runs and logs the decision; it changes nothing.
- Differential test: every message tier 1 matches produces byte-identical output with the solver on or off.
- Done when: shadow decisions on the replay and synthetic corpora meet the accept gate in section 7.

**Phase 2: triage lexicon to the server.**
- Move the keyword gate vocabulary into the pack; keep only the OTP/PIN safety check in the binary. Fix G5 (bank-like senders get one pass).
- Done when: the 43-message class of gate drops is recovered and no promo or OTP leaks into review.

**Phase 3: enable auto-accept (testers, then 5%, 25%, all).**
- Candidates go to the AI worker and then review. Every correction feeds learning signals and the pack.
- Done when: the live false-count metric stays at 0 across a full cohort step.

**Phase 4: chains and the tree.**
- Add an **obligation** object (instrument + billing cycle + counterparty) with a small state machine: bill, reminder, payment, failed, overdue, closed. Reminders attach to it; a settlement closes it; stale reminders close.
- The tree stays a **read model** over events and obligations: instruments and counterparties as roots, chains as branches, spending, bills, splits and subscriptions as views. Splits link by suggestion only, confirmed by the user.
- Deliberately generic and designed from the Phase 0 gap table, not from one product (cards are one lifecycle of several: utilities, insurance, EMI, subscriptions).

**Phase 5: security actions S1 to S7**, in parallel from Phase 1.

## 7. Gates (every phase)

- Golden gate and rules lint stay green; **no row that is correct today becomes wrong**.
- False counts: **0** on the existing corpora; solver auto-accept precision is held to at least 99% on the synthetic held-out set before any cohort sees it.
- Differential identity for tier-1-matched messages.
- Performance: per-message budget measured with `test/performance_guards_test.dart` and the Android smoke script; the solver runs off the UI isolate, uses `cachedRegExp`, and does no whole-history reads. Chain lookups use indexed instrument + date-window queries.
- Kill switch per tier; rollback by bundle version.

## 8. Open questions for the owner

1. **Auto-count or hold?** Should a solver "accept" count in totals immediately (shown as "guessed", editable), or wait for one tap of confirmation? Recommendation: count only the strict accept set, hold everything else.
2. **Languages**: is English + Hinglish enough for the first release, or must Hindi/Marathi script be in scope?
3. **Own-account detection**: can we rely on the profile name and the user's registered instruments to recognise "to my own account"?
4. **Attestation `enforce`**: is it acceptable to enforce on `/sms/v2/rules` before the wider tester group is on attested builds? (Closes S1, but unattested testers stop receiving rules.)
5. **Synthetic corpus**: are you comfortable with me authoring synthetic layouts for other banks from public knowledge of how they phrase alerts, flagged as wording guesses (as in the GENZ notes)?

## 9. Progress, 9 Nov 2026 (Phase 0 done, Phase 1 kernel built, offline only)

Security work is deferred by the owner; the pack currently lives in the repo (`rules/sms/solver/pack.json`) and is **not** in any signed bundle, and nothing in the app calls the solver yet. Tier 1 is untouched (all new files; no existing file changed).

**Built**
- `packages/pandapay_domain/lib/src/sms_v2/solver/`: `solver_text.dart` (typed tokens, phrase matcher), `solver_pack.dart` (pack model and validation), `evidence_solver.dart` (the solver). Public entry: `lib/sms_v2_solver.dart`.
- `rules/sms/solver/pack.json`: the vocabulary (26 lexicons). Kept outside `rules/sms/v2` so the existing bundle builder never reads it.
- `tools/sms_rules_cli/tool/solver_baseline.dart` (what tier 1 does), `solver_eval.dart` (scores the solver, splits out the messages tier 1 did not match), `solver_bench.dart`.
- Synthetic corpora in `tools/sms_golden/solver/`: `held_out.jsonl` (60), `blind_1.jsonl` (47), `blind_2.jsonl` (40). Invented messages only, labelled by hand.
- `packages/pandapay_domain/test/sms_v2/solver/solver_test.dart`: 29 tests (text layer, phrases, pack validation, safety properties, hostile input, all three corpora with zero false counts).

**Measured**
- Tier 1 on the varied held-out set: 17 of 40 money messages left unmatched (`no_rule_matched`). This set is deliberately varied wording, so it overstates the gap on a real inbox (the 6-month replay in `SMS_V2_STATUS.md` found about 11 real gaps in 649 transactions); it shows what a new bank or reworded alert looks like.
- Solver speed: about 0.3 ms per message after warm-up (JIT). It only runs on messages tier 1 did not match.
- **Honest first pass on fresh wording (`blind_2`, scored before any tuning to it), messages tier 1 did not match (22):** 7 auto-accepted, 15 sent to review, **1 false count** (a transfer between two of the user's own accounts read as a spend). After a general fix plus vocabulary growth the same set is clean (18 accepted, 4 to review, 0 false counts), but that set is now tuned against and cannot be quoted as accuracy.
- The earlier blind set (`blind_1`) found two critical errors on its first pass: a card bill payment read as a purchase (would double-count spending) and a person-to-person credit read as a wallet top-up (income hidden). Both are now fixed by general rules, not message patches: a biller receiving a payment on the user's card is a card payment; wording that points the other way from a stated credit is not trusted; two of the user's own accounts in one message is an own transfer.

**What the numbers do and do not say**
- All three sets have now been tuned against. They are regression gates (zero false counts, zero silent misses), not accuracy claims. A fresh set (`blind_3`) must be written before any accuracy figure is quoted.
- Safety held across rounds, but recall on unseen wording is limited by vocabulary: the review queue shrinks as the pack grows. Each new blind set found about 4 to 8 new wording families (abbreviations such as "Recd" and "Dr.", noun forms such as "Fuel purchase Rs 2,000", notices such as "is scheduled").
- Design choice that paid off: accepting a non-money reading needs positive evidence (a cue), and an amount with no known cue goes to review. That is why no round produced a silent drop.

**Known gaps in the solver itself**
- Counterparty names: 12 of 13 on right counts in the last blind set; slash narrations and "for ... - NAME" styles are fragile.
- Loan disbursals, reversals and disputes are always review-only by design.
- Foreign-currency spends are accepted only when the INR amount is printed.
- English only. No multi-part SMS reassembly.
- `billerReceived` ("payment received") is the riskiest phrase family: it is ambiguous between "the biller got your payment" and "you got paid". It is now anchored on "payment of <amount> ... received".

**Not done yet (next steps, in order)**
1. Fact output: convert an accepted decision into the real `Fact` types (needs a new provenance engine value `solver`, a contract and schema change, and the server contract tests).
2. Shadow mode in the app: run the solver after tier 1 on `no_rule_matched`, log the decision, change nothing; add the pack to the bundle schema and builder (signed section, minimum engine version, kill switch).
3. Real-data replay: run the 6-month private corpus through the harness (counts only) to size the real gaps and check for false counts. Needs `SMS_PRIVATE_DIR`; I have not used any private data.
4. Triage lexicon move (Phase 2) and the obligation lifecycle (Phase 4).
5. Pack lint on the server (phrase safety, duplicate and shadowing checks), and a `blind_3` set.
6. Pre-existing: `hardcoded_logic_guard_test.dart` fails on Windows because of path separators in its allow-list (it reports only existing files); worth fixing separately.

## 10. Integration, 9 Nov 2026 (decision: no shadow mode, integrated directly)

The owner decided to integrate directly (two users, not published). Security hardening stays deferred. Nothing is committed yet.

**What now exists end to end**
- **Where it runs:** inside `RuleEngine.interpretDetailed`, after every rule and ignore rule has failed (`no_rule_matched`). A message a rule matches never reaches it. The solver returns facts with engine `rules` and rule id `SOLVER-<READ>` (no contract change needed), confidence capped at 0.9, so everything downstream (instruments, linker, ledger, bills, review, sync, stats) treats it like a rule reading.
- **Where the vocabulary lives:** `rules/sms/solver/pack.json`, shipped as one optional signed section `solverPack` of the rule bundle (schema, Dart model, server bundle parts, CLI build). A bundle without a pack is byte-identical to before (`toJson` omits the key). Bundles that carry a pack need engine 2.4.0 (`meta.json` and `smsEngineVersion` bumped); older apps refuse such a bundle and keep their current one.
- **Kill switch:** `params.enabled: false` in the pack, or any pack that fails to load, turns the solver off without refusing the bundle.
- **Reads, and the fact each becomes:** counted spend/income → `movement`; a bank debit alert is the real debit; a biller's receipt, e-bill or renewal notice → `movement` with `evidenceOnly` (never counted by itself, same policy as the existing receipt rules); card bill payment → credit leg `card_payment` (not income); own transfer; wallet top-up; investment; bill or statement or reminder → `bill_due` with total, minimum, due date and statement date; upcoming debit → `attempt` (scheduled, with the date); mandate created/revoked/expired/paused → `mandate` with phase, frequency and merchant; subscription charge → movement plus a `mandate`; failed payment → `attempt`; balance → `balance_snapshot`; promotions, OTP/security and order notices → `info` (ignored).
- **Dates:** printed in any common form, Indian order; "due today/tomorrow" is read against the message's arrival day; a date with no year is placed ahead of the message.

**Findings from the tests (all fixed by general rules)**
- A card bill payment read as a purchase; a person's credit read as a wallet top-up; a transfer between two of the user's own accounts read as a spend.
- Stress test on the repo's own rule examples (including the negative examples rule authors wrote as traps): a promise ("Get Rs 150 cashback credited when you spend Rs 5,000") counted as income; "will be Dr. ... and Cr. ..." read as a credit; "request" messages read as events; a one-time (IPO-style) mandate debit counted as a spend; "transferred to your bank account" read as a debit; "already paid" read as a debit; a security footer swallowing a real notice; a failed-payment notice with no amount ignored instead of reviewed (the golden set records that as a product decision). Each now has a rule and a test.
- A golden gate that failed (ignore precision 0.973 vs 0.995) was the solver ignoring that failed-payment notice; fixed and the gate is green again.

**Proof that existing behaviour is untouched**
- `tools/sms_rules_cli/test/solver_integration_test.dart`: every rule example (2,376) and every golden message (284) produces byte-identical outcomes and facts with and without the pack; the full release gate (`tool/check_pipeline.dart`) passes with the pack in the bundle.
- A reviewed snapshot (`tools/sms_golden/solver/rule_example_counts.expected.txt`): the 20 rule-example messages the solver would count as money, each checked by hand. Any change to that set fails the test and must be reviewed.
- Corpora (all invented): `held_out`, `blind_1`, `blind_2` (dev sets now), `bills_subs_dev`, `non_financial` (30 promos, OTPs, offers, notices): zero false counts, zero silent misses, zero wrong facts on all of them. These are regression gates, not accuracy claims.

**Open items**
1. Emulator verification and a real-phone replay (counts only) are the remaining checks before this is trusted on real inboxes.
2. A fresh, never-tuned corpus is still needed for an honest accuracy figure.
3. The review queue will carry the wording the pack does not know yet (abbreviations, unusual layouts, regional wording). That is by design; the Gemini draft loop and pack growth shrink it.
4. A "paid + new bill in one message" statement goes to review; handling it as two facts is a possible later improvement.
5. IPO/one-time mandate holds are sent to review rather than read as `hold` facts.

## 11. Real-inbox replay, 9 Nov 2026 (counts only)

The owner's phone (wireless debugging) was read **read-only**: 6,019 inbox messages exported to a private folder outside the repository and replayed on the computer with `tools/sms_rules_cli/tool/solver_replay.dart`. Nothing was installed on the phone. The tool prints counts and redacted layouts only and refuses an export path inside the repo. The app's intake gate is approximated (numeric senders and security wording skipped: 225 and 876 messages), so 4,918 messages were considered.

| | |
| --- | --- |
| Existing rules matched | 1,982 |
| Existing rules ignored | 1,872 |
| Rules left unknown | 1,064 |
| **Rule-matched messages whose result changed with the solver present** | **0** |
| Solver accepted (of the 1,064) | 889 |
| Still unknown, for review / Gemini | 175 |
| Solver accepted, by kind | 573 non-financial notices, 181 promotions, 86 debits, 21 receipts, 10 credits, 8 bills, 8 mandates, 2 failed |
| Money the solver would newly count | 86 debits, 10 credits |

Findings from reading the redacted layouts of everything it would count:
- About 60 of the 86 debits are one real card-spend layout that the existing rules did not match (the "Spent Rs X <bank> Card no. XX1234 ... Avl Limit" layout). They are correct spends that were previously not counted at all.
- Three real mistakes, now fixed by general rules and pinned by tests: a broker payout "transferred Rs X to your bank account" read as a debit (it is money back from investments, as the broker rules read it); a loan promotion "get a voucher when your loan is credited" read as income (a cue after "when" or "if" is now a promise, and promotional wording beside a cue needs a bank-voice alert); a money request "Fund requested by X. On approval Rs X will be debited" read as an upcoming debit (now a notice).
- The largest group the solver would silently ignore (573 notices) was checked layout by layout: orders, deliveries, prescriptions, marketing, security notices, a few amount-less acknowledgements. No financial message with an amount was among the top 45 layouts.
- The 8 bills are real utility and card bills with due dates, correctly read.

This is a check of the real pipeline's behaviour on one person's inbox, not an accuracy figure: nobody has labelled these messages. The remaining unknowns by sender (Axis, NSE, and a few billers) are the next pack-growth targets.

## 12. Generalization, app audit and the real-gate count, 10 Nov 2026

**Measured with the app's real intake gate** (a temporary, uncommitted test running the private export through `classifySmsV2Intake` and the engine; counts only). Of 6,019 inbox messages: 935 security wording (dropped), 2,525 dropped by the gate, 247 let through because a rule reads them, 2,559 reach the engine.

| | Without the solver | With the solver |
| --- | --- | --- |
| Matched | 2,050 | 2,198 |
| Ignored | 269 | 325 |
| **Unknown (Needs Review)** | **240** | **36** |

0 rule-matched messages changed. The solver resolved 204 of the 240.

**Generalizing to other banks and wording (all general rules, none tied to one message)**
- Issuer identity: a sender the registry does not know gets a plain issuer slug from its header ("NEWBNK" -> "newbnk"; digit-only short codes get none), as the app already does for unrecognised issuers. Without it the app's bill logic could neither match a reminder to its statement nor a bill to its payment.
- Bill generated date: a "ready / generated" notice with no printed date was generated the day it arrived. Reminders get none. A printed statement date always wins.
- "Due in N days", "payable in N days", "expires in N days" are counted from the arrival day.
- A subscription or mandate debit names its merchant (otherwise the subscriptions list merges every unnamed one into "Unknown service"); a mandate carries its own reference so a later charge quoting it joins it.
- Biller name falls back to the sender header so bills from one biller share an identity.
- Plain money-in and refund wording ("Received Rs X in your A/c", "received by your wallet", "processed to your ...", "recharged with Rs X"), "purchase of X" payee, Pay Later "credit of Rs X using Pay Later", broker "traded value" notices.
- A failure with no payment wording ("couldn't deliver your package"), "receipt of your application", and a due/renewal reminder with no amount are no longer left in review: they hold no money.
- A credit that mentions a loan is reviewed (it may be a disbursal); loan EMI debits still count.

**App audit (subscriptions, bills)**
- Subscriptions are built from mandate facts plus subscription-charge events, one series per merchant name. Fixed above: solver charges and mandates now carry the merchant name and reference.
- Bills are grouped by issuer identity (or biller name) and due date, and paid by matching card-payment events on the same issuer and card mask. Fixed above: solver bills now carry an issuer identity even for unknown senders.
- Upcoming-debit notices ("will renew on 12 Nov for Rs 99") were stored but never used. The subscription list now takes an announced future date as the next expected charge. It still adds no charge and no amount, matching the existing rule that attempts are not money.
- Still pending (not done): a screen for upcoming debits that are not subscriptions; bills read by rules still carry no generated date; the receipts review (a biller's receipt with no bank debit asks the user in the current month) will ask about solver receipts too, which is the existing policy.

**The 36 still in Needs Review, and why**
- EMI nudges with an amount but no due date (6); coin redemptions (3); loan-sounding wallet credits (6, held on purpose); dividends that state only a per-share amount (6); foreign-currency card spends with no rupee amount (2); IPO "no shares allotted, blocked amount available" (2, existing hold logic); wallet top-up via UPI with long wording (2); refund wording with no named account (3); a mutual-fund purchase request acknowledgement; a deposit received; an AutoPay mandate request whose verb is not recognised; a "payment could not be completed" notice; interest-cycle notice; a few others.
- Owner help wanted on: the Axis "Processed payment of Rs X for XX1234 ... instant cashback" family (15 messages, counted in the earlier replay but filtered by the gate in the real app) and the refund-to-wallet family: is each a card bill payment, a purchase, or a refund credit?

## 13. Owner direction, 10 Nov 2026 (second pass): what was built and what needs a history chain

**Old filters checked:** the app's intake gate drops 2,525 non-security messages on the real inbox (526 promotional, 524 numeric senders, 1,387 with no financial words, 246 no financial signal, 38 promotional-message, 51 demat). Among everything it drops, none from a sender the gate hard-drops is read as money by the rules or the solver; the 247 that rules do read as financial come from bank-like senders and the gate already lets them through. The old filters are effective and are not duplicated in the solver.

**Built from the owner's direction (all general rules):**
- Coin / reward redemption: shown in activity, never counted. Written as a `transfer` movement (the existing non-counting kind), so it never reaches spending or income.
- Dividend announcement with only per-share amounts: not money (the amount received arrives in the bank's own credit alert, which counts as dividend income). A per-share amount is now never picked as the money, even when a message also states a total.
- IPO not allotted ("blocked amount ... now available"): a released `hold` (purpose ipo_asba), so it appears as history next to the original block and links through the existing IPO link rule.
- "We have received your request ... Purchase of Rs X": a pending attempt (investment when fund words are present), counted nowhere until the confirmation arrives.
- "Your request to cancel / pause / resume / modify the AutoPay mandate ... is successful": a mandate update with the right phase. A request that is only acknowledged is not.
- Wallet identification from the header: a credit or debit from a sender the registry knows as a wallet is attributed to that wallet (instrument kind wallet), so a refund with no account named can be accepted and then joined to the matching purchase by the existing refund link rule (same instrument and amount). From an unregistered sender it stays in review.
- Wallet top-up with long wording, and a currency written after the number ("12345INR").

**Result with the app's real gate on the real inbox:** reach the engine 2,559; Needs Review 240 without the solver, **20** with it; 0 rule-matched messages changed.

**Still in Needs Review (20) and why:** six EMI nudges with an amount but no due date; four wallet credits from a "Loans" brand (held: may be a loan disbursal); two foreign-currency spends with no rupee amount; two refund notices with no wallet identified; one deposit received; one "payment could not be completed"; a few single notices.

**Needs a history chain (not built yet, designed):** the pipeline would give the solver a small read-only context of what it has already stored, and a date-less message would be completed from its own past.
1. EMI nudge with no date: find the earlier bill or EMI message from the same biller identity (issuer or biller name, same amount) that has a due date; infer the same day of month on or after the arrival day; emit the bill with confidence below 0.7 so it also lands as a one-tap review item ("due on the 5th like last month?").
2. Refund with no account: if the sender is not a registered wallet, find an earlier spend of the same amount in the last 90 days; if exactly one matches, take its instrument and let the refund link rule join them.
3. A bank "deposit received" or a mutual-fund purchase confirmation: join to the pending request or deposit by amount and date within a short window.
This needs a new read-only argument on the engine and a store lookup in the app pipeline, so it is a separate piece of work with its own tests.

## 14. Bill chain, money in, ads (done)

- A biller's "processed payment of X for CONSUMER_NO" is an evidence-only bill payment; the consumer number rides in the counterparty name. The bill build chains it to a bill of the same amount in its cycle: same number, or (when the bill printed none) only when no other bill could take it.
- A credit with no stated reason is money in; loans paid out and wallet credits count; wallet top-up stays a transfer. Coin redemption is an own transfer (activity only). Ads (loan offers, job ads, recharge-plan notices, in English, Hindi and Marathi) are recognised by wording and ignored.

## 15. History chain (done)

One mechanism, three uses. The engine returns the unresolved reading with what it did learn (`PendingBill`, `PendingRefund`); the pipeline looks back in a bounded window of stored facts and completes it only when exactly ONE earlier fact fits. The completed fact is written at confidence 0.6, below the review bar, so a person is asked to confirm; otherwise nothing changes and the message stays in Needs Review.
- Bill or EMI reminder with an amount and no due date: borrows the due date, instrument and biller of the one earlier statement of the same sender whose total or minimum equals the amount (75-day window, 20-day grace). It copies the statement's identity, so it cannot make a second bill or change an amount.
- Refund with no account: accepted when exactly one same-amount spend (90 days) whose merchant the refund mentions exists. A refund or reversal word right before the amount makes the reading a credit even when the verb says transferred.
- A newer statement of the same card or biller marks an unpaid older one "payment not detected": kept in history, removed from upcoming lists and totals (the newer one carries what is owed).

## 16. Subscriptions (done)

- Name variants of one service ("SPOTIFY" / "SPOTIFY SI") merge when they share an instrument or either names none; the shorter name is shown.
- Three or more equal charges at one merchant on a steady monthly or weekly rhythm, with no mandate message, are listed under Possible subscriptions (a review candidate): never counted in totals, never reminded about, never duplicated when a mandate exists.
- IPO lifecycles (apply, allot, partial, not allotted, same-amount IPOs, company-less messages, UPI-mandate route) are covered by tests on the real rules.
- Known limit: wording only the generic "debited from A/c" rule matches carries no merchant or purpose, so it never reaches the solver and cannot join a mandate.

## 17. Generic-rule refinement, IPO notice, deposits (done)

- A generic catch-all rule (id starts `GEN-`) that read a plain debit or credit with purpose unknown may be enriched by the solver, and only when the solver independently read the SAME amount in the SAME direction and has something to add (a purpose, a merchant, a mandate or recurring wording). The rule's account and date are kept. A specific rule's result is never changed: the integration test fails on any other change and lists the reviewed set of enriched rule examples.
- An exchange "no allotment" notice appears on the one IPO application still waiting (blocked, not older than 60 days); with two waiting it is not guessed onto either.
- A provider's confirmation ("deposit of Rs X was processed", "fixed deposit of Rs X has been created") is read as evidence-only investment. The existing receipt link joins it to the same-amount bank debit within 72 hours; with no debit it is never counted and the receipt sweep asks later.
- Not measured on the real inbox yet: the phone was not reachable for wireless debugging.

## 18. Real-inbox measurement, 10 Nov 2026 (counts only, export deleted)

Phone read read-only (6,019 messages). Through the app's real intake gate: 935 sensitive dropped, 2,507 dropped by the gate, 2,577 reach the engine. End to end through the real pipeline (history chain included): 16 messages have no reading at all (was 20), 1 refund inference waits for confirmation, 42 are low-confidence readings of the existing rules (unchanged by this work), 44 event questions and 3 instrument questions are the existing ones. At engine level the unresolved count went 73 -> 51 and the money counted did not change (100 debits, 18 credits), the strict invariant held (0 changed rule results), and 1 generic autopay debit was enriched. Credits are enriched only by a real purpose; a payer word alone ("by CASH") is not an improvement. Credit reports and card-application status notices are ignored as non-money.
