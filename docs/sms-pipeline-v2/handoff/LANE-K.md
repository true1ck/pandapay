# Lane K handoff: fair scorer and full-pipeline replay harness

Branch `sms-v2/lane-k-measurement`, from `sms-v2/claude-lanes`. Local only: nothing pushed, deployed or flagged; no rules, contracts, server or phone code changed. No private data or result is recorded here; the numbers stay in the private evaluation folder.

## What changed

| Item | Where |
| --- | --- |
| Scoring rules moved to a tested library | `tools/sms_rules_cli/lib/scoring.dart` (new); `tool/score_private.dart` is now the file-reading wrapper and re-exports it |
| Synthetic scorer tests | `tools/sms_rules_cli/test/scoring_test.dart` (new, 19 tests); `score_private_test.dart` unchanged and passing |
| Replay harness | `app/test/tool/sms_private_replay_test.dart` (new); skips unless `SMS_PRIVATE_DIR` is set |
| Private-folder layout and commands | `tools/sms_rules_cli/README.md` (new) |

## Reading-table fixes (all derived from facts or the rule family, not rule ids)

- A pending debit attempt with no stated purpose reads as `payment_request`, whatever rule produced it.
- A `$`, `USD` or `US$` in the body infers USD for the amount check.
- An expected `not_financial` agrees with `otp`, `promo` and `service_notice` readings (an ignored notice). It does not agree with `unknown`.
- An evidence-only bill-payment movement (or any evidence-only movement from a `bill_receipt` rule) reads as `bill_receipt`; when the rule id has an `RCH` segment it reads as `recharge`.
- A bill-due from a rule in family `card_statement` reads as `statement`; other bill-dues stay `bill_due`.
- An IPO notice (rule family `ipo_notice`) reads as `ipo_application_notice`, replacing a hard-coded rule id; `ipo_notice` and `ipo_application_notice` agree.
- An info fact's `amountMinor` is read for the amount check, flagged informational, and never reaches totals.
- A phone replay's effect now also carries the money: the sum of the distinct ledger rows of contributing legs, so a linked duplicate leg is not counted twice.

## Metric definitions

Weight of a row is `family_population` divided by the rows of that family in the scored subset. The weights of a family therefore sum to its population, the sure subset is reweighted to the whole family, and a row without a population weighs 1. Everything is reported unweighted and weighted for `sure` rows and for all rows; `headline` collects the main ones.

| Metric | Definition |
| --- | --- |
| Weighted accuracy | Weighted share of rows whose reading, effect, amount and stated instrument all agree. Unweighted accuracy is reported beside it. |
| Totals-correct | Over rows whose expected effect changes totals (spending, money in, refund, investment invested or withdrawn): share with the same effect and the same amount. The amount is the ledger money in a replay, the movement amount otherwise. Also split by effect and into missed (counted as none or transfer), wrong effect and wrong amount. |
| False counts | Over rows whose expected effect is `none` or `transfer`: share that change totals anyway. Reported with the count, the effect counted and the money (unweighted and weighted). |
| Event fidelity per feature | For IPO, investments, subscriptions and refunds (rows chosen by expected reading): share of rows with the right reading, effect, amount and instrument and, in a replay, a counting event of the expected type (IPO application, investment or withdrawal, subscription charge, refund; neutral rows must stay neutral). The components are listed too. |
| Financial unknown rate | Unknown or unprocessed share of financial rows, weighted as well. |

The scorer writes a review export beside the report: `<report>.disagreements.jsonl` (machine) and `<report>.disagreements.txt` (reading), ordered by consequence (false count, wrong effect or amount, missed count, other) and then by weight. Both carry message bodies and belong in the private folder.

## Replay harness

`SMS_PRIVATE_DIR=<private> SMS_BUNDLE=<bundle>.json SMS_REPLAY_PREFIX=<prefix> flutter test --no-pub --concurrency=1 test/tool` from `app`. It runs the real phone runtime (interpret, instruments, linker, ledger) over the sample and the corpus and writes `<prefix>-sample-phone.json` and `<prefix>-corpus-phone.json` under the private folder only, mode 600. The sample output is the scorer's optional fourth argument. Reports also hold invariants (transaction count, totals, open review rows, reused money facts, card bills and IPO events counted as spending, event-type counts). It prints counts only.

## Verification

- `cd tools/sms_rules_cli && dart test`: all pass, including the new synthetic tests.
- `dart run tool/score_private.dart` runs on the private sample with and without replay outcomes; results kept privately.
- `cd app && flutter test --no-pub --concurrency=1 test/tool`: skipped without the variable; with it, passed on a built bundle over the full corpus and the sample in about ten seconds.

## Decisions for the owner

- Whether `recharge` and card-bill receipts from a bill-pay app should count in totals. The scorer follows the contract (evidence-only means no effect), so drafts that count them score as missed totals; the lane A and B requests describe the same conflict.
- Whether a card debit to a wallet top-up merchant should read as `card_spend` (the draft) or `wallet_credit` (the contract purpose). The scorer is unchanged here.
- Whether `statement` and `bill_due`, or `bill_reminder` and `bill_due`, should be one reading. They stay distinct, except as stated above.
- Labels remain Claude drafts, not independent ground truth; weighted figures inherit that.
