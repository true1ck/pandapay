# Panda Voice — a smarter voice, fully on the phone

**Date:** 2026-11-10
**Status:** Draft for owner review. Nothing is built.
**Decisions recorded by the owner, 2026-11-10:**

- **On-device only.** Audio, transcript and what Panda understood never leave the phone automatically.
- **No on-device recognition on a phone → typed box only.** No silent fallback to Apple or Google recognition, and no opt-in server path.
- **V0 speech spike skipped.** V1 proceeds without measurements on the owner's phones; accuracy is judged by using the real voice sheet.
- **English only for now.** Hinglish, Hindi and other languages come later as language packs. This reverses the earlier choice of English, Roman Hinglish and Devanagari Hindi.
- **Work lands on `dev`.** Batch 1 grew during planning: understanding, on-device recognition with the typed box, money in, refunds and foreign amounts with follow-up questions, twelve kinds of shown-and-spoken answers from on-phone data, and a generated test set, with one phone checkpoint at the end. Usual-card suggestion, amount read-back, learning from edits and Undo are batch two. Detail: [voice-batch1-plan-2026-11-10.md](voice-batch1-plan-2026-11-10.md).
**Scope:** the mic on Home (`app/lib/features/voice/`), what it can understand, what it can do, and how it gets smarter without a server model.

---

## 0. Summary

Today's voice turns a sentence into one editable "spent ₹X on Y" draft. It cannot answer a question, cannot read many ordinary ways of saying an amount, and cannot learn. This design turns it into **Panda**: a voice layer over everything the app already knows (spend, bills, caps, points, card choice, review queues), built so that:

> **The phone understands, the app's own engines compute, and you confirm.**

The understanding step is deterministic Dart code plus the user's own data, not a language model. That keeps it private, offline-capable, and testable against a fixed set of sentences. A device-model tier is possible later, but it is optional and never the floor (section 6).

## 1. Where today's voice stands (verified in code, 2026-11-10)

| Finding | Evidence |
|---|---|
| Three intents only: expense, points redemption, unsupported. A question ("how much did I spend on dining") becomes an empty expense draft. | `voice_action_parser.dart:5`, `parse()` |
| Amounts are read wrongly or not at all. The amount pattern, run on sample phrases, gave: "spent 1.5k on groceries" → ₹1; "spent 2 lakh on a laptop" → ₹2; "spent 2k on fuel", "spent two fifty", and a Hinglish sentence → no amount. (Checked by running the same pattern in Node; the Dart tests were not run.) | `voice_action_parser.dart:210-217` |
| A card is never preselected unless the user names it, and the instrument defaults to credit card, so "Spent ₹250 on groceries" (the app tour's own example) cannot be saved until a card is picked by hand. | `parse()` lines 140-159; `_VoiceDraftEditor` (`voice_input_sheet.dart:769`) |
| The saved time is always "now"; "yesterday" is ignored. | `voice_input_sheet.dart:395` |
| Vocabulary is fixed: 9 merchants, 6 category keyword lists. Edits in the review sheet teach it nothing. | `voice_action_parser.dart:323-333, 365-372` |
| The speech recognizer is not told to stay on the device. Depending on platform and language packs, audio may be processed by Apple or Google. | `voice_input_sheet.dart:180` has no `onDevice`; `speech_to_text` 7.5.0 supports `SpeechListenOptions.onDevice` |
| Navigation commands exist only through Android App Actions and open a screen; they answer nothing. | `docs/android-assistant-integration.md` |

## 2. What "on-device only" means here

- **Ears:** `speech_to_text` with `onDevice: true`. Per the plugin docs, listening fails if it cannot recognize locally. Panda then says so and offers a typed box that goes through the same understanding. It never silently falls back to server recognition. The typed box is also where Roman Hinglish typing ("swiggy pe 250 kharch") works. `SpeechListenOptions.contextualPhrases` (speech_to_text 7.5.0) can bias recognition toward the user's own merchants, card names and tags; whether it takes effect on-device on each platform is unverified.
- **Brain:** Dart code in a background isolate. No transcript, no card list, no totals are sent anywhere.
- **Hands:** local repositories and the recommendation engine. Where a number today comes from the app's own authenticated API (the spend report), the call is the same one the Spending screen already makes, with only period and date parameters. The spoken text is never part of it. If a number needs a connection, Panda says "I need a connection for that".
- **Mouth:** a visual answer card; optional on-device text-to-speech.
- **Memory:** learned vocabulary and habits live in the local database, are never uploaded, and are not logged to analytics (counts only, no text).

Costs of this choice, stated plainly:

1. **No open-ended understanding.** Panda answers a catalogue of question types (about 25 in V2), not anything. An unknown question gets "I can't do that yet" plus buttons for what it can do.
2. **On-device recognizers are generally less accurate than server ones**, especially for Indian names and Hindi-English mixing, and may need a downloaded language pack. Hence read-back of amounts (batch two), a typed fallback, and a measured pass on real phones after batch one, because the V0 spike was skipped.
3. **A device language model cannot be the floor.** Apple's on-device model is limited to Apple Intelligence devices (iPhone 15 Pro and later) and requires a supported system language; I found no source listing Hindi. Android's Gemini Nano Prompt API has a short, shifting device list, with Pixel 10 best. See section 6.

## 3. Architecture

```
mic ─► Ears ─► Brain (background isolate) ─► Action catalogue ─► Hands ─► Mouth
       on-device  Normalizer                  typed, risk-tiered   local repos   answer card
       STT /      Intent matcher              (one list)           + engines     + optional
       typed box  Entity resolver                                                 on-device TTS
                  Dialog manager
```

### 3.1 Brain modules

1. **Normalizer.** Turns words into typed spans.
   - Amounts: digits, English number words, `k`, `lakh/lac`, `crore`, "1.5k", "two and a half thousand", Roman Hindi ("do sau pachaas", "dedh sau", "dhai hazaar") and, after V0, Devanagari.
   - Dates: today, yesterday, last Friday, "on the 3rd", "last month". Hindi "kal" means both yesterday and tomorrow, so the verb tense decides ("kharch kiya" = past).
2. **Intent matcher.** Scored patterns over the normalized spans. A small trained classifier is added only if the golden set (section 8) shows the patterns plateau.
3. **Entity resolver.** Finds merchants, cards, categories, tags and people in the user's own data.
   - Merchants: reuse `FlashTextMerchantExtractor` (`app/lib/data/flashtext_merchant_extractor.dart`) plus the user's own merchant history and edit-distance matching on a simplified spelling, so "sweegy" finds Swiggy.
   - Cards: keep today's rules (name words, last four digits) and add brand words ("the Swiggy card") and a usual-card prior.
   - Categories: existing merchant-category rules first, then learned corrections.
   - When the top two candidates are close, ask. Otherwise pick the first.
4. **Habit priors.** A small indexed local table keyed by merchant or category: last-used card, instrument, typical amount range, with time decay. The usual card is **preselected as a suggestion with a reason** ("Swiggy: 6 of your last 7"), and the review sheet still shows it for confirmation. This is history, not the "best card" recommendation: logging records what you used, not what you should have used. Today's rule against guessing between look-alike cards stays: a tie means no preselection.
5. **Dialog manager.** Session memory for period, category, card and merchant, so "and last month?" and "only Amex" work. It handles spoken corrections ("no, make that 300", "actually the Axis one"), asks one question at a time with tappable choices, and resets after a pause.
6. **Plan.** The brain's only output: `VoicePlan { intent, slots, confidence, riskTier }`. It never does arithmetic and never writes.

### 3.2 Action catalogue

One typed list is the single place that says what voice can do. Each entry has a schema, a risk tier, and an executor that calls existing code. The same list can later back Android App Actions and Siri, replacing the separate allowlist behind `pandapay://assistant/...`.

| Tier | Meaning | Actions |
|---|---|---|
| **R0 read / navigate** | Answer or open a screen at once | spend total and comparison, top merchants, bill due, cap left, points balance and expiry, milestone progress, best card for a merchant or amount, subscriptions, last transactions, duplicate check, open any allowlisted screen |
| **R1 new entry** | Shown as a review card; nothing saved until confirmed | log spend (several at once), log points redemption, log foreign spend, split an expense, record a points balance you read from your bank app, add tag or note, set a reminder, set a budget |
| **R2 change existing** | Explicit confirm naming the item | edit last entry, recategorize, delete, resolve a Needs Review item, resolve a duplicate |
| **R3 never by voice** | Refused with a reason | add or link a card (today's rule stays), move or pay money, security, sign-in or recovery settings, data export |

## 4. Capabilities

| Capability | Examples | Builds on |
|---|---|---|
| **Capture** | "Swiggy pe do sau pachaas, yesterday, Swiggy card"; "1.5k fuel and 600 lunch"; "no, make that 300"; "split dinner 1,200 with Rahul"; "₹500 refund from Amazon"; "50 dollars in Dubai"; "Axis Atlas balance is 14,200 points" | quick add, `logTransaction` (supports `entryKind`), splits, foreign payments, points ledger |
| **Ask** | "dining this month vs last?", "when is my HDFC bill due?", "cap left on Swiggy HDFC?", "points expiring soon?", "any duplicate charges?" | `spendReportsRepositoryProvider`, `commitmentsProvider`, `dueDateRemindersProvider`, `cardSpendSummaryProvider`, caps and points screens |
| **Advise** | "₹4,500 at Croma, which card?"; "if I put 50k on Amex do I hit the milestone?"; "is this card worth keeping?" | `RecommendationEngine` (`packages/pandapay_domain`), `bestCardForMerchantProvider`, milestones, portfolio audit |
| **Fix and triage** | "change the last one to dining"; Panda reads each Needs Review item aloud: "₹1,240 at Reliance, dining or groceries?" | Needs Review and duplicate review screens, corrections flow |
| **Act** | "open caps", "scan a UPI QR", "remind me before the Amex due date", "set dining budget 8,000" | `AppRoute` destinations, reminders, budgets |
| **Converse** | "and last month?", "only Amex", spoken replies if turned on | dialog manager, on-device text-to-speech |
| **Learn** | your merchant words, card nicknames, usual card per merchant; every edit in the review sheet teaches it | override and merchant-category stores (reuse them rather than add a new one; confirm their shape in V1) |

Further additions worth keeping on the list:

- **Voice and SMS together.** Say it before the bank SMS arrives and the SMS should enrich the same entry, not duplicate it. Cross-source duplicate detection exists (`spend-tracking-and-caps-plan.md` at the repo root), but `logTransaction` has no source argument, so how a voice entry is tagged must be checked first (V1).
- **Points balance as a reconciliation input.** Banks do not SMS points (`docs/card-rewards-intelligence-feature-spec-2026-11-05.md`), so a spoken balance is a real source of truth.
- **Photo plus voice:** snap a bill, say "split with the team".
- **Weekly spoken recap**, 30 seconds, only when the user asks for it.
- **Report a wrong card rule by voice**, routed to the existing report-wrong-data queue, never into the catalogue directly.

## 5. Safety and privacy

- Reads are answered immediately. New entries keep today's promise: **nothing is saved until you confirm.** A later opt-in "quick save with 10-second Undo" is limited to small, high-confidence amounts; the default stays review.
- **Amounts are the main risk** (recognizers confuse "fifteen" and "fifty"). Show the amount large, read it back, and flag one that is far from your usual for that merchant or category ("₹2,50,000 for chai?").
- **Spoken replies are off by default** and meant for headphones, so totals are not read aloud in public.
- Voice works only inside the unlocked app, never from the lock screen.
- The transcript is untrusted text. Merchant names and SMS text are only ever matched against, never interpreted as instructions.
- No audio is stored. Transcripts are kept only as the review note, as today.
- Update the privacy screen and legal text to say voice is processed on the phone. The `NSSpeechRecognitionUsageDescription` text should say the same once `onDevice` is enforced.

## 6. Optional device-model tier (V4, only if earned)

A language model on the phone could cover the long tail of phrasings. It is not planned before the golden set shows the pattern matcher missing too much. If built, it is capability-detected, cannot write, and returns a `VoicePlan` like every other path.

| Platform | Option | Reach |
|---|---|---|
| iPhone | Apple Foundation Models | Apple Intelligence devices only; needs a supported system language ([forum report](https://developer.apple.com/forums/thread/805378), [announcement](https://appleinsider.com/articles/25/06/09/apple-intelligence-opened-up-to-all-developers-with-foundation-models-framework)) |
| Android | Gemini Nano through the ML Kit GenAI Prompt API | Short, changing device list; best on Pixel 10 ([overview](https://developers.google.com/ml-kit/genai), [alpha post](https://android-developers.googleblog.com/2025/10/ml-kit-genai-prompt-api-alpha-release.html)) |

Both need native bridge work in Swift and Kotlin. Treat the device lists as unverified until checked on the live pages and on the owner's real phones.

## 7. Phases

| Phase | Content | Needs |
|---|---|---|
| **V0 spike** | Skipped by the owner on 2026-11-10. A scaffold of the test app was started in `tools/speech_spike` (untracked) and can be finished later if recognition quality needs measuring. | None |
| **V1 batch 1, understand** | `onDevice` enforced with the typed box; contextual phrases from the user's merchants and cards; English-only understanding (fixes the ₹1 bug); money in, refunds and foreign amounts with follow-up questions; twelve kinds of answers from on-phone data with buttons and a spoken reply (this pulls most of V2 forward); kind chips and a date field in the review sheet; generated tests. Full detail: [voice-batch1-plan-2026-11-10.md](voice-batch1-plan-2026-11-10.md) | No server, no model |
| **V1 batch 2, trust** | Usual-card suggestion with its reason; amount read-back and sanity flag; learn from edits; Undo; investigate the voice-to-SMS match | Batch 1 |
| **V2 Ask Panda** | R0 questions, follow-ups, answer card showing its evidence ("23 transactions, 1–10 Nov, bill payments excluded"), navigation commands, optional spoken replies | Check per source whether data is local or needs a connection |
| **V3 Panda agent** | Edit and triage by voice, split, points balance, reminders and budgets, what-if questions through the engine, opt-in quick save | V1 and V2 metrics |
| **V4 beyond the app** | Siri and Android App Actions from the same catalogue; device-model tier only if section 6 is earned | Owner call |

## 8. How we know it works

A golden file of utterances with the expected plan, in three groups: Indian English, roman Hinglish, Devanagari Hindi. A negative group (questions, noise, "add a card", "pay my bill") that must write nothing.

- Plan accuracy on supported intents: **95% or better**, matching the SMS accuracy goal.
- Wrong saves on the negative group: **zero**.
- Speed: understanding finishes in under 100 ms at p95 on a mid-range Android, in a background isolate, with no dropped UI frames in `scripts/perf_smoke_android.sh`.
- Product measures: seconds from tap to saved entry, share of entries saved without any edit, share of review sheets that need a manual card pick (should fall sharply).

New voice code follows `docs/PERFORMANCE_RULEBOOK.md`: `cachedRegExp`, no whole-table reads, indexed priors, heavy work off the UI isolate. Run `flutter test test/performance_guards_test.dart` before calling it done.

## 9. Decisions (open ones show a default in bold)

1. **Resolved 2026-11-10, V1 languages:** English only; other languages come later as language packs.
2. **Spoken replies:** **off by default, switch in Settings.**
3. **Quick save with Undo:** **later, opt-in; review stays the default.**
4. **A "Send this phrase to improve Panda" button:** **not in V1.** Possible later as one phrase, user-tapped, redacted. It would be the only thing that ever leaves the phone, so it needs the owner's explicit yes.
5. **Learned vocabulary and backup:** **local only, rebuilt from history on a new phone**, rather than added to the portable backup.

## 10. Risks

- On-device recognition may be weak for some accents on some phones, and the V0 spike that would have measured it was skipped. Batch 1 relies on the typed box and the review sheet as the safety net, and ends with a measured read-aloud pass on real phones. Batch 1 is also large (understanding, answers and text-to-speech together), so commits are staged to keep a problem traceable.
- A pattern matcher can plateau. The golden set shows it early, and section 6 is the answer if it does.
- A usual-card suggestion could be wrong. It is shown with its reason, and a tie suppresses it.
- A voice entry may duplicate its SMS. Investigated in V1 before voice is advertised as complete.
