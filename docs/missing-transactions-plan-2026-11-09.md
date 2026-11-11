# Missing transactions: plan (9 Nov 2026)

Status: plan only, nothing built. Counts only, no merchants, people or amounts from any private corpus.

## What the evidence says

A six-month replay of one owner's real messages (2,613 from institutions) against the phone's own intake records (2,360 captures):

- **Rules are not the main cause.** For all 2,239 messages that reached the phone, the phone's decision equals the replay's. Only 4 messages were left unrecognised.
- **About 14% of messages never reach the phone**, spread over most days. Most are one-time passwords and security notices that the app drops on purpose. **7 counted transactions** (about 1% of 649) are among the dropped ones: 4 on the first day of the import window, 1 wallet spend, and a block of 11 consecutive messages on one day that includes 2 more.
- **Card statements reconcile.** Statement totals due against the spends the messages reported: one card within 0 to 6% for three cycles, another within -8 to +15%. So card coverage from messages is about 93% or better.
- **Own-name transfers are mis-typed.** Debits to the owner's own name are read as transfers when the other account's credit message exists, and as purchases when it does not. That inflated spend by about 1 in 7 of the owner-named volume.
- **Not solved:** one "cluster" the owner could not pin down, and the owner's other-app payment history. It needs a PhonePe export to reconcile (see Open questions).

## Goals

1. Stop losing the first day of a history import and surface what a window could not return.
2. Tell the person, per card and statement, when messages do not explain the bill, so a gap never stays silent.
3. Stop counting own-name transfers as spending, without asking the person to type their name first.

Non-goals: new bank rules, server changes, a rule-bundle release. All three are app changes (one app build).

## A. Import window and completeness (iOS history)

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| A1 | The history start keeps the time of day of the run (`iosSmsMonthsAgo`), so the first day is cut. Start at local midnight of that day. | `app/lib/features/sms_import/ios_sms_intake_service.dart`, callers in `ios_sms_import_screen.dart` (lines 115, 145) | The first day of a 6-month import is complete; a test covers a run at 18:57 and a DST day. |
| A2 | A window that returns 500 or more is already labelled "Shortcuts limit, continued below". Check that the continuation really re-asks by day, and that a day that still returns 500 is split by hour. | `ios_sms_import_screen.dart` (line 528), `ios_sms_intake_service.dart` (`iosSmsWindows`), native spool windows | A test with a fake Shortcut that caps at 500 yields every message. |
| A3 | Understand the block of 11 consecutive messages that never arrived (and scattered single gaps). Add a per-window "found vs already known" count to the import report and a "read this day again" action. Compare two runs on the same range: a rerun that adds nothing means the Shortcut itself hides them, not the app. | native spool report, `ios_sms_import_screen.dart` | We can say, for any day, how many messages the Shortcut returned and how many were new. |
| A4 | Keep dropping one-time passwords and security notices. Show their count on the report so it does not look like loss. | same report | The report separates "left out on purpose" from "found". |

Risk: A3 may show the cause is inside iOS Shortcuts and cannot be fixed in the app. Then B is the safety net.

## B. Statement check ("not explained by your messages")

Idea: a card statement message states the total due. Over a cycle that total should be close to the spends the messages reported on that card. A shortfall means messages are missing. This works however the loss happened.

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| B1 | Reconciler: for each credit-card instrument, take consecutive `bill_due` facts (`due_total`, statement date) and sum counted spends between them. Skip the first statement in the history (its cycle starts before the window), cycles with a refund or EMI that the messages cannot explain, and any gap under the larger of 100 rupees and 3%. | new file in `packages/pandapay_domain/lib/src/sms_v2/ledger/`, pure functions | Unit tests: equal, short, over, partial payment, missing statement, two cards. |
| B2 | Check that every issuer's statement rule captures the statement date and the card mask, not only the total (rules under `rules/sms/v2/subscriptions/`). Edits to existing rules need new versions through the console, so prefer reading the SMS received date. | rules and a golden case per issuer | Each issuer in the golden set yields a usable statement fact. |
| B3 | On the card's page: "Statement 12 Aug to 11 Sep: 44,994. Found 42,190. 2,804 is not explained." with "Add a missing spend". Wording must not accuse; fees, interest and EMI also explain gaps. | `app/lib/features/sms_v2/ui/` | Widget test with a gap and without one. |
| B4 | Count each gap in the import report and, once per statement, in Needs review as one row (not one per missing spend). | review controller | One row, dismissible, reappears only if the gap grows. |

Everything runs on the phone from data it already holds.

## C. Own-name transfers

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| C1 | Learn the owner's name from evidence: a debit naming payee N on one instrument and a credit of the same amount within minutes on another, naming a payer that contains N. Store N as an owner name on the device. | `packages/pandapay_domain/lib/src/sms_v2/linker/rule_driven_linker.dart`, owner names in `capture_executor.dart` and `sms_v2_pipeline.dart` | Unit test: the pair teaches N; a one-sided debit to N is then a transfer. |
| C2 | Re-type earlier one-sided debits and credits that name a learned owner name, through the existing "choose which earlier transactions" checklist (nothing ticked, because it moves money). | `app/lib/features/sms_v2/similar/` | Test: a learned name offers the earlier ones and Undo restores them. |
| C3 | At SMS setup ask "What name do your banks use for you?" (several allowed); skip if C1 already knows. | onboarding screen | Names persist and reach the pipeline. |
| C4 | Keep the manual action "Transfer between my accounts" as the fallback. | exists in build 141 | n/a |

Risk: a common name shared with a relative. The checklist and Undo contain it; never auto-retype without the person's tick.

## D. A bank-agnostic fallback (added 9 Nov after a generality test)

Test: the same six-month replay with only the 96 generic rules (every bank, wallet, broker, subscription and IPO rule removed). Result: 5 of 649 transactions (1%) are recognised and 1,133 messages become "unknown". So today's coverage comes from over a thousand specific rules, not from a general reading of a money message. A person whose bank or wording has no dedicated rule gets close to nothing until a rule is drafted and published.

Prototype: a fallback of about 30 lines with no bank or sender knowledge (an amount, a debit or credit verb, an account, card, UPI or wallet word, and exclusion words for codes, offers, reminders and requests). On the same messages it finds 77% of the 690 counted transactions, with direction right in 100% and amount right in 100% of those it finds, and flags 596 messages of which 28 are not money messages in the full engine's view (several of those 28 are real credits the current rules miss). The misses are wordings such as "debited by 800.00" with no currency word, "added to wallet" and "txn for".

| Step | Change | Where | Done when |
| --- | --- | --- | --- |
| D1 | Add a last-resort layer after the rule engine: a message from any sender that no rule explains and that looks like a money movement becomes a provisional transaction (amount, direction, date, counterparty after "to", "at", "from" or "@"), marked "unconfirmed" and offered in Needs review. | `packages/pandapay_domain/lib/src/sms_v2/` (new layer beside the rule engine and provisional store), `app/lib/features/sms_v2/pipeline/` | The generic-only replay recognises at least 70% of transactions, with 100% direction and amount accuracy on those. |
| D2 | Teach it the three missed wordings and measure again; keep the exclusion words in data, not code. | same | At least 85% recall, false alarms under 5% of flagged. |
| D3 | Person's confirm or "not a transaction" answer feeds the existing correction flow, so a wrong guess is cheap and teaches the rule drafts. Unconfirmed items are NOT counted in totals until the person says yes (changed 9 Nov, see the test beyond one inbox below), except a narrow high-confidence group: debit or credit word, amount, account or card mask, and a transactional sender. | review controller, corrections sync | A rejected message is not flagged again; a scam-shaped message never reaches totals unconfirmed. |
| D4 | Add a generic-only replay to the test suite as a guard, so specific rules can never again hide a general-layer regression. | `app/test/tool/`, golden set | The test reports the generic-only coverage number. |
| D5 | Use signals that do not depend on wording: the regulated sender suffix (-P promotional, -G government: never transactions in the test inbox) and the iOS category tag (promotions and reminders). Keep them as inputs, never as the only test, because a scam can arrive with a transactional-looking tag. | `packages/pandapay_domain/lib/src/sms_v2/template/` (sender normaliser keeps the suffix), iOS filter tag already carried | Promotion-tagged messages produce no provisional transactions; measured loss is zero on the test inbox. |
| D6 | Make the fallback currency-agnostic and teach it the kinds the test inbox lacks: any ISO currency code, "Cr." and "Dr." abbreviations, ATM withdrawals, EMI and loan debits, wallet-balance debits, fund purchases. | same | The golden set recall reaches at least 85% with false alarms under 5%. |

### Testing beyond one inbox (9 Nov)

The six-month test held out banks but still used one person's kinds of transactions and one person's noise. A second test used the repo's golden set: 284 synthetic cases from many banks and kinds, plus 126 "ignore" examples (reminders, receipts, scams). None of it is from the test inbox, but it is synthetic and written by the same team, so it is optimistic about real messages. Results: the fallback found 70% of the 172 transaction cases, flagged 8 to 11% of non-transaction cases and 9% of the ignore examples; a model trained on the one inbox found 90% of transactions but flagged 19 to 35% of non-transaction cases and 23% of ignore examples. Misses: foreign-currency cards (no rupee word), "Cr." abbreviations, ATM withdrawals, EMI and loan debits, wallet debits, fund purchases. False alarms: foreign EMI conversions, card-bill receipts, a government grant credit and a work-from-home "salary payment" scam. Conclusion: a fallback must be tested on held-out issuers, held-out transaction kinds and held-out noise, and must not count unconfirmed items silently.

### Public datasets (checked 9 Nov, nothing downloaded)

No public set is both real, multi-bank, multi-kind and labelled with promotions as negatives. Candidates: `Ranjit0034/finee-dataset` on Hugging Face (152,519 rows, Apache-2.0, about 98% synthetic; 2,419 real ICICI messages); `4-alokk/flashflow-bank-sms` (small, templated, negatives included, licence not stated, label errors seen); `gandharvbakshi/SMS-dataset-OTP-OTP_INTENT_Phishing` (73,470 Indian SMS, real plus LLM plus synthetic, gated, about OTP and phishing rather than transactions); `Shade63/scam-classification-multiclass` (14,000 scam and legit, licence unknown); a Mendeley SMS phishing set (5,971, CC BY 4.0, not Indian). Open-source apps (PennyWise AI is AGPL-3.0; Cashiro GPL-3.0; MFTracker MIT with 5 sample messages) are code, and their licences forbid copying into this app. Use: held-out checks only (kinds, and scam or one-time-password false alarms), never as rule or model training, and never copied into the repo. Real multi-user data has to come from consenting testers through the redacted template upload.

### Result on the public sets (9 Nov, downloaded to a scratch folder only)

Two public sets were replayed (flashflow: 15,200 templated synthetic messages with negatives; finee: 7,627 test messages, mostly synthetic, 28% in regional languages), 3,000 of each, with the sender each message's bank would use. Production rule engine against labels: flashflow 21% of transactions found, finee English 70%, finee regional languages 0%; where it finds one, direction is right 99% and amount 100%. Of the English transactions it missed, 60% were "unknown" (no rule), 12% were dropped by an ignore rule and 20% were recognised but typed "unknown" so not counted. By kind it found 0% of refunds and cashbacks and of NEFT, IMPS and RTGS credits, 2% of wallet payments, 13% of other bank-account debits, but 81% of ATM and 53% of EMI. The generic fallback found 66% and 92%, with no false alarms on the 606 non-transactions (promotions, loan offers, statement reminders, one-time codes); it was worse than the engine on EMI (15% against 53%) and, like the engine, found 0% of foreign-currency-only and regional-language messages. Layered (engine first, fallback second): 68% and 93%. These sets are synthetic and their labels contain errors (invented balances and decimals), so treat the numbers as a ranking of weaknesses, not as expected accuracy. New work items from this: D6 must also cover refunds, cashback, NEFT and IMPS credits, wallet payments and foreign currency; and a regional-language layer (the common verbs in Hindi, Tamil, Telugu, Kannada, Bengali and Marathi) is a separate item, D7.

### Would a trained model be better than D? (tested 9 Nov)

A small text classifier (word and word-pair counts, trained on the same six months) was tested the right way, with whole senders held out so the test banks were never seen in training. On unseen banks it reached precision 0.65, recall 0.88, F1 0.75, against the hand-written fallback's precision 0.89, recall 0.77, F1 0.82. With a random split (same banks in training and test) the same model scored F1 0.93, which is the leak that makes single-user results look better than they are. Combining the two gave no gain (F1 0.81). Decision: ship D1 and D2 now; revisit a model only when there are labelled templates from many users and banks. A model may rank or gate candidates; amounts and dates keep coming from deterministic extraction. A model ships only if it beats D by a clear margin on an unseen-bank test.

## Order

1. A1 (very small, no risk).
2. D1 to D2 (the answer to "only works for my messages"; also catches missed formats).
3. C1 to C2 (removes false spending).
4. B1 to B4 (the safety net; largest).
5. D3 to D4, then A2 to A4 (investigation, may end in "cannot fix").
6. C3 (setup question) with whichever app build ships next.

## Checks before release

- Run the six-month replay again: own-name debits must drop out of spending; statement gaps must match the figures above; the first day of the window must be complete.
- Full app, domain and deploy test suites; the CI shard layout stays the same.
- One app build; no server or rule-bundle change.

## Open questions for the owner

1. One month of PhonePe history (PDF or CSV export) to reconcile every row against the messages.
2. For the "cluster" that is missing: the month, the bank and one payee.
3. Which cards and accounts besides the ones already seen send no messages at all (these can never be found by messages).
