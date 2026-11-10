# Panda Voice, V1 batch 1 — deep plan (English)

**Date:** 2026-11-10
**Status:** Plan, decisions complete, awaiting the owner's go-ahead to build. No code written. Builds on [voice-panda-design-2026-11-10.md](voice-panda-design-2026-11-10.md), which this plan supersedes where they differ (scope and language).

## Decisions recorded (owner, 2026-11-10)

1. **On-device only.** If a phone cannot recognize speech on-device, Panda offers a typed box. No server fallback.
2. **English only for now** (Indian English: rupees, lakh, crore, "k", "two fifty"). Hinglish, Hindi and other languages come later, so the code is built as **language packs**: a new language is a new table of words, not a rewrite (section 3.6).
3. **Work on `dev`.** One phone test at the end of the batch.
4. **Scope of batch 1:**
   - understanding of what you say;
   - on-device speech with a typed box;
   - logging spends, money in, refunds and foreign amounts, with follow-up questions and the editable confirm form;
   - **answers to twelve kinds of question** from data on the phone, with buttons to the right screen and a spoken reply (Settings switch, on by default);
   - a generated test set.
5. **Also approved:** "heard as" line, leftover-number check, ambiguity chips, spoken self-correction, and questions routed to the right screen.
6. **Generalise, do not enumerate.** Rules describe how language is built (numbers, dates, roles of words), not lists of sentences. Tests are generated, and a blind holdout guards against fitting the rules to the tests.

## 0. Short answers

**Will it miss anything?** Yes. The plan controls how a miss looks:

| Kind | Example | What the user sees |
|---|---|---|
| **Silent wrong** (dangerous) | "spent 1.5k" saved as ₹1; an answer built on missing history | Designed out: "heard as" line, every number accounted for, ambiguity chips, a data-coverage note on every answer. |
| **Loud miss** | no amount found; a question it has no answer for | A plain message, a follow-up question or the typed box. Nothing is saved. |
| **Recognizer error** | "fifteen" heard for "fifty" | Visible in the transcript and the "heard as" line; one tap to fix. |

**Will it tell most things?** Yes for twelve kinds of question (section 5), computed on the phone from the same ledger the screens use, so the numbers match what the user sees elsewhere. Anything outside those twelve gets "I can't answer that yet" and a button to the nearest screen.

## 1. Baseline: today's parser, English only

I ran the real `VoiceActionParser.parseMany` on English phrases I wrote, through a temporary test (deleted, never committed). They are my phrases, not yours.

| Group | Phrases | Exactly right | Loud miss | Silent wrong |
|---|---|---|---|---|
| Amounts | 26 | 9 | 14 | 3 |
| Several spends | 4 | 2 | 1 | 1 |
| **Total** | **30** | **11 (37%)** | **15** | **4** |
| Must not become a spend | 10 | 7 | n/a | **3 wrongly logged** |

Silent errors today: "spent 1.5k" → ₹1; "spent 2.5 lakh" → ₹2.5; "spent on 2 coffees 300" → ₹2; "250 for lunch, 300 for fuel and 150 for chai" → one entry ₹150; "50 dollars" → ₹50; "30 euros" → ₹30; "paid my credit card bill of 12000" → ₹12,000 spend. Of the seven correct refusals, six happen only because the words are not recognized, so the user gets an empty draft instead of a reason. (The same run on 14 Hinglish and 10 Devanagari phrases found 0 right; kept as the starting point for the later language packs.)

## 2. What gets added

**Ears**
- On-device recognition (`onDevice: true`); typed box when unavailable, with a how-to-fix hint.
- Typed box always visible ("or type it"), same understanding.
- Contextual phrases: the user's merchants, card nicknames, tags and categories passed to the recognizer (about 100 at most).

**Understanding** (section 3)
- Amounts, dates and periods, merchants, categories, instruments, cards, tags, kinds (spend, money in, refund, foreign, points, question), self-correction.

**Follow-up questions**
- One targeted question at a time, answered by voice, typing or a tap, at most two per entry (section 6).

**Logging kinds**
- Spend, several spends, points redemption, **money in**, **refund**, **foreign amount** (logged as a rupee spend after a conversion question).

**Review sheet** (the editable form every voice entry already uses, extended)
- Kind chips at the top (Spend / Money in / Refund) so a wrong guess is one tap to fix.
- "Heard as" line per entry, date field, ambiguity chips, leftover warnings, kind-specific fields.

**Answers** (section 5)
- Twelve kinds, an answer card with evidence and buttons, spoken reply.

**Tests** (section 8)
- Generated phrases with noise, a blind holdout, differential checks against the screens.

## 3. How it understands: treat it as a puzzle

The old parser asks "which sentence pattern does this match?" That is why it misses so much. The new one asks "what could each piece be, and which assignment of roles explains the whole sentence best?"

### 3.1 Layers

1. **Normalize.** Lowercase, strip fillers ("um", "like", "you know"), unify symbols (₹, Rs., INR), keep the original text spans.
2. **Tag.** Every word gets every type it could be: number part, magnitude, currency, date word, month or weekday, verb of spending or receiving or returning or moving money, preposition, merchant, category word, card word, instrument, question word, correction cue. Matching tolerates ASR damage: edit distance, sound-alike matching for merchants (a recognizer writes "sweegy"), and number and digit variants.
3. **Build spans.** Small grammars, not sentence templates:
   - *Numbers:* digits with Indian or Western grouping; decimals; words (`fifteen hundred`, `two and a half thousand`); magnitudes (`k`, `lakh`, `lac`, `crore`, `million`); "two fifty" style speech, which is ambiguous and keeps both readings.
   - *Dates and periods:* today, yesterday, weekdays, "last Friday", "on the 3rd", "3 November", "N days ago", "this week", "last month", "this quarter", "in October", "since Monday", "last 30 days".
   - *Names:* merchants, categories, cards, tags, people, from the user's own data plus the built-in merchant catalogue (`FlashTextMerchantExtractor`).
4. **Assign roles by scoring, not by position.** Each span can play several roles; each role gets a score from nearby evidence (a currency word beside a number, "spent" or "got" or "refund" in the clause, "on/at/for/from/to" before a name, a plural noun after a number meaning quantity, "ending" before card digits, a date shape before a number). A small solver picks the assignment with the highest total score under simple constraints: one amount per entry, each span used once, a span cannot be both date and amount. **Word order does not matter**: "250 on groceries yesterday", "yesterday groceries 250" and "groceries, two fifty, yesterday" resolve the same way.
5. **Decide the kind** from the evidence for each: spend, money in, refund, foreign, points redemption, card-bill payment, transfer, question. Strong positive and negative cues compete. A tie or weak winner becomes a follow-up question, never a guess.
6. **Account for everything.** Any number, name or date span not used is a leftover. Leftovers are shown ("I also heard 600. Add it as another spend?") or turned into another entry.
7. **Report confidence per field**, which drives the "heard as" line, ambiguity chips and follow-ups.

### 3.2 Several entries

Split where evidence says a new entry starts: a second amount with its own verb or name, or a conjunction ("and", "then", "also", comma) between two complete clues. A fragment with no amount joins its neighbour. The solver runs per entry, so a date or card said once ("yesterday, 250 for lunch and 300 for fuel") is shared by the entries it plausibly covers and shown on each.

### 3.3 Self-correction

A cue ("no", "sorry", "I mean", "actually", "make that", "wait") followed by a replacement value replaces the previous value of the same role in the same entry.

### 3.4 Kinds, in one table

| Kind | Typical evidence | What happens |
|---|---|---|
| Spend | spent, paid, bought, "for", merchant or category | Review form |
| Money in | received, got, credited, salary, from a person | Follow-ups, review form (Money in) |
| Refund | refund, refunded, returned, cashback, "money back" | Follow-ups including which purchase, review form (Refund) |
| Foreign | dollars, euros, pounds, dirhams, USD, AED, "$" | Asks for the rupee amount, review form (Spend) |
| Points redemption | "points" with redeem, used, spent | Existing flow |
| Card-bill payment, transfer | "credit card bill", "statement", "transferred", "sent to my" | Explained and not logged as a spend (a card-bill payment is not new spending) |
| Question | how much, how many, when, which, what, "?" | Answer card (section 5) |
| Add or link a card | add, link, create with card | Refused, today's rule |

A utility bill ("electricity bill 1200") stays a normal spend in Bills.

### 3.5 Merchants, categories, instruments, cards

- **Merchant:** the user's own merchants and the built-in catalogue, with sound-alike tolerance. An unknown merchant keeps its spoken words as free text, never discarded.
- **Category:** the user's category terms (`SpendCategory.matchTerms`, including custom categories), the merchant's known category, and a bundled English word list. No hit leaves it empty for the user, never silently "Other".
- **Instrument:** cash, UPI apps, debit; otherwise credit card, as today.
- **Card:** name words and last four digits as today, plus spoken digits ("ending four five six seven" is 4567). The usual-card suggestion remains a later batch.

### 3.6 Language packs

All words live in a pack per language: number words and magnitudes, date and period words, kind cues, category words, correction cues, filler words, the recognizer locale (`en_IN` now). Roles, scoring and the solver are language-neutral. Adding Hindi or Marathi later means writing a pack and its tests, plus reviewing it with a speaker of that language, and adding the language chip to the sheet. Batch 1 ships the English pack only and no chip.

## 4. How it behaves: worked examples

| You say | What Panda does |
|---|---|
| "spent two fifty on lunch yesterday" | One entry: ₹250 ← "two fifty" (chip: ₹2.50?), Yesterday, Dining. Card not named, so the form asks you to pick one. |
| "250 for lunch, 300 for fuel and 150 for chai" | "Found 3 spends", three entries. |
| "spent 600 on lunch and 400 on a taxi no sorry 450" | Two entries; the taxi becomes ₹450. |
| "spent on 2 coffees 300" | ₹300; "2" is read as a quantity, shown in the leftover line. |
| "received five thousand from Rahul" | Money in ₹5,000. Asks: "What was it?" (Salary, From a person, Interest, Other) and "Which account did it reach?" (your accounts, or Not sure). Form opens with Kind: Money in. |
| "got a refund of 500 from Amazon" | Refund ₹500. Asks: "Which purchase was this for?" with up to five Amazon purchases from the last 120 days (or None of these). A pick copies merchant, category and card. Form opens with Kind: Refund. |
| "spent 50 dollars in Dubai" | Asks: "How much was that in rupees?" Saves the rupee amount as a spend and keeps "USD 50" in the note. Tells you it will not appear on the Foreign payments screen. |
| "paid my credit card bill of 12000" | "That looks like a card bill payment, not new spending, so I didn't add it." |
| "how much did I spend on dining last month" | Answer card with the amount, the change against the month before, evidence, and buttons. Spoken: one sentence. |
| "when is my HDFC bill due" | Answer card with the due date and amount, and a button to Payments due. |
| "something unrelated" | "I didn't catch an amount or a question. Try 'spent 250 on lunch' or 'how much did I spend this month'." and the typed box. |

Nothing is saved without Confirm. At most two follow-up questions are asked per entry; after that the form opens with the missing fields empty.

## 5. Answers: twelve kinds of question

The spend questions read `LedgerReadModel.spendReport(query, now)` (the on-phone ledger, `app/lib/features/sms_v2/ledger/reports.dart`), the same call behind the Spending screen. A question becomes a **query**: a metric, filters (period, category, merchant, card, instrument), and an optional comparison. These combine freely: "dining at Swiggy last month on my HDFC card".

| # | Kind | Example | Source |
|---|---|---|---|
| 1 | Total spend | "how much did I spend this week" | `spendReport` totals and count |
| 2 | By category | "what did I spend on dining in October" | `byCategory`, `bySubcategory` |
| 3 | At a merchant | "how much on Swiggy this year" | `byMerchant` |
| 4 | On a card | "spend on my Amex last month" | `byCard` |
| 5 | By instrument | "how much by UPI this month" | `byInstrument` |
| 6 | Top spends | "where did I spend the most this month" | top rows of `byCategory` and `byMerchant` |
| 7 | Money in | "how much came in this month" | `income` totals |
| 8 | Compare | "this month versus last month" | totals and `previousSpend` |
| 9 | Bills and due dates | "when is my HDFC bill due, and how much" | the bill ledger (`cardBillLedgerProvider`) |
| 10 | Caps and milestones left | "how much cap is left on my Swiggy card" | card cap and milestone state (`card_snapshots.dart`) |
| 11 | Points balance | "how many points do I have on Amex" | card points balance, marked as an estimate |
| 12 | Best card | "which card for 4,500 at Croma" | the recommendation engine, same as Home |

**Answer card:** a headline number; the comparison; one evidence line ("37 transactions, 1 to 10 Nov, same figures as Spending"); a data-coverage note; and buttons.

**Buttons:** *Show transactions* opens Activity with the same range and category (the route already accepts `from`, `to`, `category`, `spendOnly`); *Open Spending trends*, *Payments due*, *Caps*, *Wallet* or *Home* as fits. Activity has no merchant or card filter, so a small `q` parameter is added so "Show transactions" works for merchant questions.

**Spoken reply:** only when the question was asked by voice and the Settings switch (on by default) is on. One short template sentence, for example "You spent ₹12,400 on dining last month, ₹1,900 more than the month before." Built from the same numbers as the card, never composed by a model. On-device text-to-speech, one new plugin. Tapping or speaking stops it.

**Data honesty, the main way an answer could mislead:**
- If the ledger is not ready, Panda says so instead of answering.
- If the period starts before the earliest transaction on the phone: "History on this phone starts 12 Aug, so earlier spending isn't included."
- Card caps, points and bills show when they were last updated, since they may be as old as the last sync.
- Points are labelled an estimate; banks do not text them.
- "No spending found" is distinguished from "no data".

**Same numbers as the screens** is tested, not assumed: for many generated queries the voice answer must equal the matching row of the Spending report (section 8).

## 6. Follow-up questions

One question at a time, one targeted slot, chips where choices exist, answered by voice, typing or a tap. While a question is open, a bare number or a name is read in that context ("4,200" answers "how much in rupees"). A reply that is not an answer is treated as a fresh request. Slots that trigger a question: missing or ambiguous amount, kind not clear ("got 500 from Amazon": refund or money in?), refund purchase, money-in type and account, foreign rupee amount, card for a credit spend, and a missing filter that changes an answer (for example "how much on my card" with several cards).

## 7. What it can still miss

| Miss | Visible? | Mitigation | Remaining |
|---|---|---|---|
| Recognizer mishears a number or name | Yes: transcript and "heard as" | Large amount, one-tap edit, contextual phrases | The user must glance |
| Accent or noise degrades recognition | Partly | Typed box | Unmeasured on your phones, since V0 was skipped; a measured read-aloud pass follows the build |
| A phrasing no rule describes | Yes: loud miss | Role scoring generalises beyond templates; the holdout finds gaps | Always some |
| A question outside the twelve | Yes | "I can't answer that yet" and the nearest screen | By design |
| History missing on the phone | Yes: coverage note | Warn when the period starts before the first transaction | Cannot invent missing data |
| Stale caps, points, bills | Yes: "updated" time | Shown on the card | Only as fresh as the last sync |
| Refund not tied to the right purchase | Yes: it is a visible choice | Candidate list, "None of these" | Netting details to check (section 10) |
| Foreign spend also arriving later by bank message | No | Flagged as a duplicate risk | Needs the voice-to-message match (section 10) |
| Dictation longer than 45 seconds | Yes: a notice | Keep what was heard | The rest is lost |

I am not promising "never wrong". The promise is that a wrong value does not reach the saved list or a spoken answer without the user seeing where it came from.

## 8. Testing

1. **Generated phrases.** Sample a true frame (kind, amount, merchant, category, date, instrument, card, tags), then say it many ways: free word order, optional parts, synonyms, filler words, every number form. Then apply recognizer-style noise: sound-alike swaps ("for"/"four"), dropped or doubled words, merged or split words, number format changes. The parse must equal the true frame. Many thousands per run with fixed seeds, reported by failure type.
2. **Blind holdout.** About 300 natural phrases written first and frozen before the rules, including the 66-phrase baseline. Rules are never tuned to a holdout phrase; a failure is fixed by a general change or left open. This guards against writing rules that only fit my own tests.
3. **Property tests.** For example: reordering clauses, adding fillers and changing a number's spelling form never changes the result; every integer from 1 to 999,999 survives a round trip through words and back.
4. **Differential tests against the screens.** For many generated single-filter queries the voice answer must equal the Spending report row; bill, cap, points and best-card answers must equal their providers' values on fixtures.
5. **Negative set.** Questions, noise and unsupported requests must log nothing.
6. **Existing tests** stay green or are changed on purpose.

**Acceptance gates (text level, since recognition is unmeasured):**
- At least 95% exact on the holdout's logging phrases, with failures categorised.
- **Zero** silent wrong amounts on the holdout and the generated set (baseline: 4).
- **Zero** wrongly logged spends in the not-a-spend set (baseline: 3).
- Every number in multi-entry phrases accounted for.
- **Zero** mismatches between voice answers and the screens.
- `flutter analyze` shows no errors; `flutter test test/features/voice test/performance_guards_test.dart` passes.

## 9. Build plan

**New:** `app/lib/features/voice/understanding/` (`language_pack.dart`, `en_pack.dart`, `tagger.dart`, `number_grammar.dart`, `date_grammar.dart`, `role_solver.dart`, `kind_decider.dart`, `utterance_reader.dart`), `answers/` (`question_model.dart`, one file per answer family, `answer_card.dart`, `speech_reply.dart`), `follow_up/dialog.dart`, a Settings entry "Speak answers", a text-to-speech plugin.

**Changed:** `voice_action_parser.dart` (delegates), `voice_input_sheet.dart` (on-device, typed box, contextual phrases, kind chips, "heard as", date field, follow-ups, answer card), the Activity route (adds `q`), voice strings.

**Commit order:**
1. Language pack plumbing, tagger, number grammar and tests
2. Date and period grammar
3. Role solver, kind decider, leftover check, ambiguity
4. Parser wiring, merchants and categories, self-correction
5. Follow-up dialog, money in, refund, foreign
6. Sheet: on-device speech, typed box, contextual phrases, kind chips, "heard as"
7. Question model and the spend-family answers
8. Bills, caps, points and best-card answers
9. Answer card, buttons, Activity `q` parameter, spoken reply and Settings switch
10. Generated set, holdout and differential tests, acceptance run

Then one device build with a 30-phrase read-aloud and question checklist on your iPhone and an Android phone, which gives the recognition numbers V0 would have.

## 10. To verify while building (unknown today)

- **Refund netting.** The on-phone ledger maps a manual refund to a refund event and includes it in spend reports (`reports.dart`, around lines 119 to 134, 236 and 341 to 351). Whether it nets against the original purchase's category, and whether copying the purchase's category and card onto the refund is enough without a link field (`logTransaction` has none), needs a read of the report code and a test.
- **Voice entry and the bank message.** `logTransaction` has no source argument. A spoken spend, and especially a foreign one, may later be duplicated by its bank message; how duplicates are detected for manual entries needs checking.
- **Foreign by voice** is stored as an ordinary rupee spend, because the Foreign payments repository has no manual-create call. It will not appear on that screen.
- **Bills, caps and points sources.** Spend questions read the on-phone ledger. The bill ledger appears to read it too, and caps and points read the synced, cached card state; each is confirmed per source.
- **`smsV2ReportingEnabledProvider` gate.** Answers depend on the v2 ledger being ready.
- **Text-to-speech.** Plugin choice, offline voices, and behaviour with the phone's silent switch, checked on both phones.
- **`contextualPhrases`.** Whether it takes effect on-device on each platform.
- **Evidence wording** for exclusions ("excludes transfers and card-bill payments") is copied from what the Spending screen itself says.

## 11. Assumptions I made, open to change

- Past dates are saved at 12:00 local time; future dates are refused.
- "Bucks" means rupees.
- A refund candidate window of 120 days, at most five candidates.
- Spoken replies only when the question was asked by voice.
- Default period for a question with no period is this month, shown as a chip you can change.
- Answers to unsupported questions never guess a number.

---

## 12. Build status, 2026-11-10

**Built on `dev`, local commits, not pushed, not run on a phone.** All ten steps of section 9 are done except the device checkpoint.

### What exists

- `app/lib/features/voice/understanding/`: tokenizer, English language pack, number grammar, date and period grammar, filler and repeated-word cleanup, the role solver and entry reader.
- `voice_action_parser.dart`: reads entries through the reader, then adds merchants, categories, instrument, cards and tags from the user's data. `voice_format.dart` holds shared wording.
- `follow_up/`: the two-question planner, answer reading, refund candidates.
- `answers/`: the question reader, the spend-family answerer (reads `LedgerReadModel.spendReport`, the Spending screen's own call), bills, caps, points and best-card answerers, the answer card, a service that gathers data from the app's providers, and button routes.
- `voice_input_sheet.dart`, `voice_entry_review.dart`, `voice_draft_editor.dart`: on-device recognition with a typed box, contextual phrases, kind chips, "heard as" chips, a date field, follow-up cards, answer view, spoken replies.
- `voice_speaker.dart`, `voice_settings.dart`: on-device text-to-speech (new plugin `flutter_tts`) and Settings > Voice > "Speak answers" (on by default).
- Activity accepts a `q` search parameter, so "Show transactions" works for a merchant.

### Measured

| Measure | Before | After |
|---|---|---|
| English spends exactly right (30 baseline phrases) | 11 (37%) | all, in the holdout |
| Silent wrong amounts (same phrases) | 4 | 0 |
| Wrongly logged as spends (10 must-not-log phrases) | 3 | 0 |
| Understanding time per sentence (debug VM) | n/a | about 0.15 ms |

- **Generated phrases** (about 5,500 per run, fixed seeds, number forms, word orders, dates, instruments, fillers, repeated words): single spends 2,500 of 2,500, lists 800 of 800, money in and refunds, foreign amounts, never-a-spend 400 of 400, questions 1,500 of 1,500, wrong amounts 0.
- **Natural holdout** (129 phrases written after the rules, plus the baseline phrases): **first run** spends 67 of 69, money in 12 of 12, foreign 7 of 7, refused 9 of 11, questions 28 of 30. After general fixes: 69, 12, 7, 11 and 30. The holdout was not blind in the strict sense, since the same person wrote the rules; no rule was written for a single phrase.
- **Generator findings fixed in the engine:** fillers inside numbers and phrases, repeated words, a number from 1990 to 2100 after "for" or "of" read as a year, large plain numbers in lists, "paid me" also counting as spending.
- **Holdout findings fixed in the engine:** "got" alone outweighing spend, a plural noun making the next number a quantity in a list without separators, an amount between "sent" and "to" breaking a transfer cue, a card called "HDFC Swiggy" swallowing the merchant "Swiggy", and "balance" alone meaning points.
- 374 voice tests, the performance guard tests, and `flutter analyze` with no errors across the app.

### Changes from the plan

- **Foreign amounts** are saved as an ordinary rupee spend with the foreign amount in the note. They will not appear on the Foreign payments screen.
- **Refunds** copy the chosen purchase's category, card and shop and note the purchase; there is no link field. Whether the ledger nets a manual refund against the original purchase's category is still to be checked on real data.
- **Milestones:** the caps answer is complete; milestone questions get the caps answer and an "Open Milestones" button.
- **Spend questions with two or more filters** (for example dining on the Amex) add up the matching transactions on the phone and say so, instead of reading one report row.
- **Moved up from batch 2:** "heard as" chips and the date field.

### Not verified, and what could still fail

- **Nothing has run on a phone.** Recognition accuracy for Indian-English accents, `onDevice: true` on the owner's iPhone and an Android phone, and `contextualPhrases` taking effect are all unmeasured (V0 was skipped).
- **Text-to-speech** is a new native plugin: first build runs `pod install`; behaviour with the silent switch, and the Android "voice installed" check, need a device.
- **Answers on real data** were tested on fixtures, not on a live ledger. Bills, caps, points and best card read the app's providers; their wiring compiles but has not been exercised end to end.
- **A voice entry and its bank message** may duplicate each other; not yet investigated.
- A 30-phrase read-aloud and question checklist on both phones is the next step.
