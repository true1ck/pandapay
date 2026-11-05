# Lane S: linker correctness

Branch `sms-v2/lane-s-linker`, from `sms-v2/claude-lanes` (a8a9560). Local only. No Gmail code touched. Files changed: the linker, `rules/sms/v2/link_rules.json`, their tests, two new golden scenarios, and one line of the lane P idempotency test.

## 1. Batch against one-at-a-time

**The reported difference was a test-harness artifact, not the linker.** `Device.capture` in `app/test/features/sms_v2/support/sync_harness.dart` numbers messages from zero on every call, so one message per call gives every message the source key `0|<body>`. Several golden scenarios carry the same text (the same IPO block, release, refund). One batch kept both copies as two messages; one at a time treated the second as the same message and dropped it. The batch therefore saw two identical applications (legitimately ambiguous) where the sequential store saw one. The same cause explains the refund difference the coordinator found on the merged branch (`refund/complete 13` against `10 + 3 ambiguous`, `purchase 32` against `33`). Proof: with the original linker and a unique `sourcePrefix` per message, the test passes.

Fix to the test (`idempotency_test.dart`): sequential capture uses a unique prefix, and the comparison now covers every event type including `ipo_application` (the IPO exclusion and the "known difference" comment are gone).

**Real order sensitivity in the linker, found while checking** (new `order_independence_test.dart`; deterministic synthetic corpus of 8 IPO applications, card bills, top-up, purchases with duplicate notice and receipt, refund, mandate with two charges, own transfer, payout; 3 seeds):

| Case | Before | Now |
| --- | --- | --- |
| Same facts re-chunked in time order, one at a time, one shuffled batch | identical | identical (event ids included for sequential) |
| A fact arriving in a later call than facts that depend on it | different | identical (see below) |

Causes and fixes in `rule_driven_linker.dart`:

1. **Processing order.** A batch was sorted by `occurredAt ?? observedAt`; live capture sees messages in receipt order. A printed date can sit before an earlier message, so a batch linked two competing debits for one hold in the opposite order to live capture (found with the real corpus once the harness was fixed). The order is now `observedAt`, then `factId` (`_arrival`).
2. **Late earlier legs.** An earlier-in-time leg that arrives later never joined facts already standing as events. New `_lateHold` (an IPO hold placed after its release or allotment debit), `_lateOriginal` (a purchase after its refund), `_lateMandate` (a mandate after its charges). A fact is still a money leg of one event only.
3. **Duplicate notice roles.** Which of two notices is the money leg depended on arrival; now the one naming the account, else the earlier one.

**Known limits (documented in the test as the "hard" corpus, tested in batches only):** a match that only the whole picture can settle cannot be revised, because events only grow and nothing is deleted. (a) A fact arriving before the hold that would settle it (a second application of the same issue with a larger amount, or a release printing no issue) links to what it has. (b) A partial allotment whose debit and release both arrive before the hold: the hold joins the debit's event and the release keeps its own. Money is unaffected in every case.

## 2. Partial allotment double count

New rule `LINK-DUP-INVEST-DEBIT` (investment debit joined to an investment debit as `duplicate_notice`, 24 h, same amount, reference preferred, priority 55). Linker changes it needs:

- Duplicate rules now use their own legs (`_legMatches`) instead of hard-coded "debit, not evidence".
- Conflicting references now block a join only when both carry the **same kind** of reference with different values. Before, any two references blocked it, so the registrar's application number and a bank reference would have kept them apart.
- Unchanged guards: same account when both are known, never two facts of one template on one account without a shared reference.

Result: whichever notice arrives first, the bank debit (it names the account) is the `debit_leg` and the registrar debit the `duplicate_notice`; the IPO event keeps its type and `amountMinor`. Tested in 20 arrival orders, batch and one at a time (`investment_duplicates_test.dart`), plus no-hold, different amount, over a day, two real payments, different transaction ids. Golden scenario `lanes_partial_allotment_late_bank_alert` (10 hours apart; investment total exactly the debit).

## 3. Broker payout double count

New rule `LINK-DUP-INVEST-CREDIT` (investment credit to investment credit, 24 h, UTR or other reference when both print one). The duplicate step is no longer debit-only (a credit goes through it; ambiguity picks the credit role). Result `investment_withdrawal [credit_leg, duplicate_notice]`, the bank credit being the money. Golden scenario `lanes_broker_payout_and_bank_credit` (investment total -1,550,000, once).

## Verification

- `packages/pandapay_domain`: `dart test` 1,075 passed (was 1,064; 18 order tests, 11 duplicate tests).
- `tools/sms_rules_cli`: `dart test` 227 passed; `lint` clean; `check_pipeline` golden ok (217 cases, 20 scenarios; no existing case or scenario changed).
- `node test/regex_parity.mjs`: 0 mismatches.
- `app`: `flutter test --no-pub --concurrency=1 test/features/sms_v2` 303 passed, 3 skipped, flag off and with `SMS_PIPELINE_V2=true`.

## Notes for others

- `LANE-H-ipo-requests.md` item 5 and `LANE-I-shared-files.md` item 4 are resolved by these two rules.
- Stale receipt reviews: a "receipt without payment" review raised before the debit arrives (late arrival) is not withdrawn by the linker. The pipeline owner may want to resolve it when the receipt joins.
- The pipeline context window is 120 days of facts; the late-join code uses the same indexes and was within the existing 20,000-fact benchmark gate.
