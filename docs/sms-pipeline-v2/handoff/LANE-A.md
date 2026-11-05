# Lane A handoff: subscriptions, mandates, bills and attempts

Branch `sms-v2/lane-a-subscriptions`, from `sms-v2/main` at dc76789. Local only: nothing pushed, deployed or flagged. No Gmail code touched.

## What was added

Thirty-one generic rules in new files under `rules/sms/v2/subscriptions/`. No file in `bills_mandates/`, `ignore_rules.json` or any other shared file changed. Every rule has one positive and one negative synthetic example; no rule contains a real name, number or amount.

| File | Rules | Readings |
| --- | --- | --- |
| `standing_instructions.json` | card standing-instruction due (INR and USD), approval due, failed, charged (evidence only), activated (INR and USD), deleted | scheduled attempt, failed attempt, evidence-only movement, mandate created or revoked |
| `upi_mandates.json` | UPI-Mandate created with account, cancelled with account, revoked by biller, pending collect request from a payment app | mandate created or revoked, pending attempt |
| `attempts.json` | declined card transaction with mask (INR and USD), declined without mask (USD, international disabled), declined contactless | declined attempt |
| `bills.json` | broadband bill overdue, due on a date, e-bill summary, payment-received receipt, mobile recharge success (two shapes), rent invoice generated or pending | `bill_due`, evidence-only `bill_payment` movement |
| `card_statements.json` | statement with total, minimum and due date (three issuer layouts), payment due with minimum and total, amount due pay-by, reminder from a bill app with a fully masked card, card debited through UPI AutoPay | `bill_due`, movement |

Design points:

- Receipts from billers and apps (`bill_receipt`, recharge success, standing-instruction "processed") are `evidenceOnly` movements. They link to the bank or card debit as duplicate notices and never count on their own.
- An overdue notice uses the printed "overdue since" date as `dueDate` and the bill date as `statementDate`.
- Amounts keep their printed currency. USD rules emit unit `USD`.
- Attempts and mandates that print no amount are not forced; see the requests file.

## Verification

- `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2`: clean.
- Build: 783 rules, 29 ignore rules, 148 senders, 1,624 examples, all pass (752 rules and 1,562 examples before).
- `dart run tool/check_pipeline.dart`: golden gate passes (115 cases, 15 scenarios).
- `node test/regex_parity.mjs`: 48,720 comparisons, 0 mismatches.
- `packages/pandapay_domain`: `dart test` passes. `tools/sms_rules_cli`: `dart test` passes (41 tests).
- Private draft-label scoring and full-corpus phone replays were run locally and are not recorded here. Across them no row that agreed before disagrees now, no money fact was reused across counted events, and no card bill or IPO event counted as spending.

## Remaining gaps

See `../requests/LANE-A-subscriptions-requests.md`. In short:

- Several correct engine readings cannot agree with a draft label because the scorer's reading table has no entry for receipts, statements, collect requests, recharge, `$` amounts or `not_financial`.
- `IGN-UPI-COLLECT-REQUEST` shadows a biller's UPI-Mandate collect request.
- The frozen contract cannot hold a mandate registration failure or a payment failure without an amount, or a bill reminder without a due date.
- One linker behaviour (a charge left without its mandate leg loses its ledger row) was exposed by the new UPI-Mandate rule and needs a WP-05 fix.
