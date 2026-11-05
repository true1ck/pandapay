# Lane F handoff: a real debit under a mandate stops counting

Branch `sms-v2/lane-f-linker-mandate` (from `sms-v2/main`). Local only. No rule file, scorer, phone rig, history or Gmail file was touched.

## Bug

When two mandate-created notices for one merchant exist and the debit cannot be tied to just one of them, the linker made the charge event `ambiguous` (one `charge` leg, no `original`). The projector and the totals ignore ambiguous events, so a real debit lost its ledger row and stopped counting. Request: `requests/LANE-A-subscriptions-requests.md` item 4.

## Root cause

`RuleDrivenLinker._mandateCandidates` groups mandate facts into one candidate per mandate. The group key is `ref:<reference>` when the notice prints a reference and `name:<merchant>` when it does not, so a notice with a reference and one without (or two notices with different references) are two "mandates". When the debit named no reference, and instrument, amount and party could not tell them apart in `_narrow`, there were two candidates and the generic pair-rule path called `_ambiguous`. That is right for pairs of money legs (two possible bank debits for one card receipt) but wrong here: the debit is spending whichever mandate it belongs to, and the mandate notices carry no money. Which mandate is only a label.

The ledger projection itself was correct: a `subscription_charge` event with only a `charge` leg projects its debit. It was the `ambiguous` status that removed it.

## Fix

`packages/pandapay_domain/lib/src/sms_v2/linker/rule_driven_linker.dart`:

- `_mandateCandidates` now returns candidates most recently active mandate first (latest notice time, ties by fact id).
- In the pair-rule step, a mandate-charge rule with several candidates joins the first (the most recent active mandate) instead of making an ambiguous event and review item. Active-state, ceiling, one-time/IPO/SIP/loan and reference-mismatch filters are unchanged, so a revoked, paused, expired or over-ceiling case still does not join. A debit with no active mandate is unchanged (own event typed by purpose).

Mandate notices still never become money legs. The debit is the single money leg, so it counts exactly once.

## Tests

`packages/pandapay_domain/test/sms_v2/linker/mandate_charge_ledger_test.dart` (fact level, synthetic facts, links one message at a time then projects):

- two mandate notices then a debit, by merchant name and with a mandate reference: one ledger row, one money leg
- a notice with a reference plus one without, no account on either: not ambiguous, counted (failed before the fix)
- two mandates with different references: counted once, joins the most recent, no double count (failed before the fix)
- other arrival order of the notices
- two real charges under one mandate both count
- mandate notices alone give no ledger rows and no money legs

Gates: `dart test` in `packages/pandapay_domain` (1011), `tools/sms_rules_cli` `dart test` (41) and `dart run tool/check_pipeline.dart` (115 cases, 15 scenarios, unchanged), and `flutter test --no-pub --concurrency=1 test/features/sms_v2` with the flag off and with `--dart-define=SMS_PIPELINE_V2=true` (256 passed, 2 skipped each).

## Follow-ups

- A replay over a real corpus is still worth running to confirm the earlier lost debit counts again; no private data was used here.
- The pair rules for other kinds (card bill, wallet top-up, duplicate notice) keep the ambiguous behaviour on purpose.
