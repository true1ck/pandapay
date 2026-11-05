# Lane X: a bill-payment receipt with no funding debit

Branch `sms-v2/lane-x-receipt-review`, from `sms-v2/publish` (9ebe7fe). Local only: nothing pushed, deployed, flagged. No Gmail code, no `link_rules.json` change, no new dependency. Synthetic data only.

## Product rule (owner decision, implemented as written)

Some bill-pay apps send a "your credit-card bill was paid" receipt. The debit from the bank or UPI is a separate message and is the payment that counts. A receipt (`evidenceOnly`) never counts by itself. When no funding debit matches it:

| Receipt date (IST) | Result |
| --- | --- |
| Earlier calendar month than the current one | Skipped silently: never counted, never asked. Another app or account may have paid it. |
| Current calendar month, less than 3 days old | Waits. |
| Current calendar month, more than 3 days old | One review item: "Did you pay this bill? We found a receipt for a credit card bill payment of ₹X on <date> through <app>, but no matching debit in your messages. Was this paid from one of your accounts?" |

Answers:

- **Yes, I paid it**: the user picks the funding account, or "Another account". The payment counts once as a card payment (an own transfer, never spending). A non-card receipt counts as its own type (bill payment, purchase, ...).
- **No, someone else paid it**: dismissed, counts nothing, never asked again.
- **Not sure**: stays in review, nothing changes.

Money is never counted twice:

- Debit arrives before or after the receipt: they join (existing `LINK-RECEIPT`), one event, no question.
- Debit arrives after the question was raised: the item closes itself (`answer: matched`) and the debit counts once.
- Debit arrives after the user said Yes: it becomes a one-leg `unknown` event (no money). The confirmed event is never changed (`user_confirmed`).

## Where it lives

| Piece | File |
| --- | --- |
| Named constants `kReceiptWaitPeriod` (3 days), `kIstUtcOffset` (UTC+5:30), month test `isEarlierCalendarMonthIst`, decision `receiptDisposition`, dedupe key, event type for a confirmed receipt | `packages/pandapay_domain/lib/src/sms_v2/linker/receipt_policy.dart` |
| One localisable wording set `kReceiptReviewTexts` (`en`; unknown locale falls back to English): title, both questions with `{amount}` `{date}` `{app}`, three answers, account picker, snackbars | same file |
| `RuleDrivenLinker.reviewReceipts(now, context, rules, alreadyRaised)` (new); `expire()` uses the same code | `.../linker/rule_driven_linker.dart` |
| Sweep, auto-resolve, Yes and No | `app/lib/features/sms_v2/pipeline/receipt_review.dart` (`ReceiptReviews`) |
| Inbox section, wording, three buttons, account picker | `app/lib/features/sms_v2/ui/review_inbox_screen.dart`, `review_controller.dart` (`smsReceiptReviews`) |

"Now" is always an injected clock: the linker's `clock`, `reviewReceipts(now:)`, `ReceiptReviews(clock:)` (the runtime passes its own clock). Tests pin it.

## Behaviour changes to know about

1. `link()` no longer raises the receipt question. Only `reviewReceipts` (called by `ReceiptReviews.sweep`, and by `expire`) does. Before, a history import raised one item per receipt older than 3 days inside the chunk, so a long history could flood the inbox. Now the question is asked once, after the import.
2. The sweep runs in `SmsV2Runtime._sync`, after all pending messages are captured. It is cheap (one SQL probe for evidence-only facts, then a window of about five weeks).
3. A receipt is also not asked about when a non-receipt debit of the same amount is inside the join window, whatever event holds it, or when it already sits under an `ambiguous_link` review.
4. De-duplication: review id `link:receipt:<factId>` (written with `DO NOTHING`, so an answered or dismissed item is never reopened) plus `dedupeKey` (amount, biller or card, IST month) so a receipt that arrives twice asks once.
5. The review payload keeps `reason: receipt_without_payment`, `biller`, `amountMinor`, `message`, and adds `receiptAt`, `cardBill`, `purpose`, `dedupeKey`, `app` (the sending app, from the message's sender entry), and `answer` once closed. The inbox builds the displayed text from these fields and the wording set, not from the stored `message`, so a wording or locale change shows on existing items.
6. The old test "a receipt with no payment in 3 days becomes a review item" now uses `reviewReceipts` in the receipt's month and new wording; a second test covers the earlier month.

## Tests

- `packages/pandapay_domain/test/sms_v2/linker/receipt_review_test.dart` (21): constants, IST month edges (31 Oct 23:30 against 1 Nov 00:30), disposition, wording, old-month receipt alone, current-month alone (one item, no money), wait boundary, month turnover, receipt then debit, debit then receipt, debit in a non-extendable event, different amount, re-processing, a receipt arriving again, ambiguity review present, debit after confirmation, 20,000-fact history with many old receipts (no receipt money, only current-month questions, bounded count).
- `app/test/features/sms_v2/pipeline/receipt_review_test.dart` (12), real stores and pipeline: the same cases end to end, plus Yes (card payment from the chosen account, not spending, confirmed event, answering twice is refused), Yes from another account (unresolved bank source), Yes then late debit (still one entry), No (nothing, not asked again), debit after the question (item closes itself), history replay of 1,200 messages in 500-message chunks (nothing asked mid-import, only current-month receipts asked).
- `app/test/features/sms_v2/ui/receipt_question_test.dart` (2): question text, three buttons, generic message buttons hidden, actions sent.
- Four new golden scenarios (new files only): `lanex_receipt_then_debit`, `lanex_debit_then_receipt`, `lanex_receipt_alone_old_month`, `lanex_receipt_alone_current_month`. Existing cases and scenarios unchanged.

## Verification

- `packages/pandapay_domain`: `dart test` 1,099 passed (was 1,077); `dart test -t benchmark`: 20,000 facts link in about 0.3 s.
- `tools/sms_rules_cli`: `dart test` 244 passed; lint clean; `check_pipeline` 239 cases, 30 scenarios, ok.
- `node test/regex_parity.mjs` (run from `tools/sms_rules_cli`): 0 mismatches.
- `app`: `flutter test --no-pub --concurrency=1 test/features/sms_v2` 374 passed, 3 skipped, flag off and with `--dart-define=SMS_PIPELINE_V2=true`.

## Limits and open questions

- **Scope.** The question covers every `evidenceOnly` debit receipt (card bills and other bills or purchases through a payment app), as the earlier mechanism did; the wording differs for card bills. Say if only card-bill receipts should ask.
- **Month turnover.** On the 1st (IST) a receipt from the last days of the previous month becomes "earlier month" and is skipped even if it was never asked about. Intended by the rule.
- **Late debit after Yes** is absorbed into a one-leg `unknown` event, so the payment counts once, but it is attributed to the account the user chose, not to the debit's own account. A different real payment of the same amount within 3 days of a confirmed receipt would be absorbed too.
- **Not sure** keeps the item open with no snooze; it is shown again at every visit to the inbox.
- **App name** is the sender entry's `issuerSlug` with a capital letter (for example `kiwi` becomes `Kiwi`); a sender without a captured raw message falls back to the biller name. A display-name field on sender entries would give nicer names.
- Only an English wording set exists; adding a locale is one map entry.
- The confirmed fact is uploaded like other user corrections (`correction:receipt:<factId>` source); the server side was not exercised.
