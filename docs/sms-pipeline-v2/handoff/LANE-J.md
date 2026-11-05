# Lane J handoff: refunds and money-in rules

Branch `sms-v2/lane-j-refunds-moneyin`, from `sms-v2/claude-lanes` (1baab86). Local only: nothing pushed, deployed or flagged. No Gmail, scorer, contract, phone or server file was touched.

## What was added

Two new rule folders, 29 new rules, 60 new rule examples (each rule has a positive and a negative synthetic example). Bundle totals went from 809 rules and 1,676 examples to 838 rules and 1,736 examples. All rules use `senders: ["*"]` with patterns anchored to the full wording, and `createdBy: lane-j`.

### `rules/sms/v2/refunds_lane/lane_j_refunds.json` (16 rules)

The reading rule is: **no money yet is an `attempt` (pending, credit, purpose refund); money back is a `movement` (credit, purpose refund or reversal).**

- Refund initiated, no money moved (pending attempt): "refund of Rs X for your order ... is/has been initiated/raised/approved", "your refund request ... approved", "refund reference number for Rs X", "Rs X refund ... processed/initiated" (amount first), "Rs X will be refunded", and a card-refund notice that waits on the cardholder (carries the card mask).
- Processed by the merchant but with no credit confirmation: pending too (`REFUND-PROCESSED-NOT-CREDITED`). The rule rejects any wording that says credited, successful or reflected, so those stay money back.
- Refund credited (movement): operator notices that say the refund is successful or complete (for example a cancelled clinic booking), and a card issuer's "transaction ... has been cancelled and refunded by the merchant" for credit and debit cards, with merchant, mask and date.
- Merchant cancellation or reversal to a card: "your txn for Rs X at <merchant> on your credit card has been reversed".
- Refund or reversal to a wallet balance: "Rs X has been refunded to your <wallet> balance/wallet/cash" and "your <wallet> has been credited with Rs X as refund". Brand-specific wallet rules (priority 690) still win.
- UPI reversals of an earlier debit, linked by the original UPI reference: bank-account wording in three shapes (account first, amount first, "UPI reversal: ... against failed UPI transaction") and a credit-card wording. All emit `ref_upiRef`, the same reference key the UPI debit rules emit, so the event linker joins the reversal to its purchase. Rail is `upi`.

### `rules/sms/v2/money_in/lane_j_money_in.json` (13 rules)

- Salary (purpose `salary`, with the payer as counterparty): NEFT, IMPS and RTGS, each in an amount-first and an account-first shape (6 rules); UPI "received ... from <company handle> ... salary" and UPI "via UPI from <payer> ... salary" (2 rules). The narration word is salary, payroll or sal. The NEFT rules need an IFSC or UTR token before the payer so they do not shadow the generic NEFT rules, which have no payer.
- Refund versus income: a refund or reversal narration on an NEFT, IMPS or RTGS credit is a refund, not money in (priority above salary and p2p).
- Dividend by ACH/NACH/ECS credit, with payer.
- Interest: "Int.Pd" and similar period wording, and "interest of Rs X credited to A/c" (amount after the word).
- Credits from people: "received Rs X from <person> on <UPI app>" (counterparty kind `person`). Bank credits by IMPS, NEFT and UPI from a person were already read as `p2p` by existing rules and are covered by new golden cases.

## Golden coverage

- 34 new synthetic cases under `tools/sms_golden/cases/<brand>/<templateHash>.json`, ids `lanej:*`, covering every reading above, plus two boundary cases (a non-salary IMPS credit stays `p2p`, a credited-wording refund stays money back).
- 3 new scenarios in `tools/sms_golden/scenarios/`: `lanej_salary_two_months_same_payer` (two months, same payer, same account, income counted twice), `lanej_refund_initiated_then_credited` (an initiated notice moves no money and creates no event; only the credit nets the purchase), `lanej_upi_reversal_linked_to_debit` (reversal joins the earlier debit through the UPI reference and nets to zero).
- Golden set: 115 to 149 cases, 15 to 18 scenarios.

## Private draft-sample scores (sure rows, strict engine measure)

| Family | Before | After | Rows |
| --- | --- | --- | --- |
| refund | 16 | 18 | 32 |
| refund, with the proposed scorer reading for pending refunds | 17 | 30 | 32 |
| all other families (attempt, card_bill, investment, ipo, movement, other, rewards_limits, salary, security, subscription, wallet) | unchanged | unchanged | 284 |
| all sure rows | 174 | 176 (188 with the proposed scorer reading) | 316 |

Financial rows left unknown (sure): 72 before, 63 after. 0 rows that were correct before became incorrect.

The target of 26 of 32 needs the scorer change in the request file: the current scorer cannot produce the `refund_initiated` reading for any rule, so none of the 12 initiated-refund rows can pass its `reading` check. Verified with a throwaway patched copy of the scorer (removed before commit).

Remaining refund misses (both outside what a rule can do): a non-money notice that no rule or ignore rule claims (scorer and ignore request), and a cancellation notice that prints no amount (contract request).

The two sample rows labelled salary are job-offer spam labelled `not_financial`; they stay unmatched. The sample still has no real salary message, so salary coverage is synthetic.

Corpus effect (private corpus, engine only): more messages matched and fewer stayed unknown. Every changed message moved from unknown or from the intended baseline rule, and nothing that matched before was lost.

## Design notes

- The refund link rule (`LINK-REFUND`) joins on instrument, counterparty compatibility and a preferred shared reference; UPI reversal rules emit `ref_upiRef` for the last. The earlier debit must be a purchase, bill payment, fee or EMI (a person-to-person debit never links).
- Pending refund attempts carry no instrument and no merchant, because the initiated notices rarely name the account; they create no ledger entry or event (checked in the new scenario).
- Refund credit rules that name a merchant emit it as the counterparty (`kind: merchant`) so the link rule can compare names.
- No contract change was needed except the amount-less refund notice (request).

## Checks run

- `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2`: clean.
- Bundle build: 838 rules, 29 ignore rules, 148 senders, 1,736 examples, all OK.
- `dart run tool/check_pipeline.dart`: 149 cases and 18 scenarios, ok.
- `node test/regex_parity.mjs`: 52,080 comparisons, 0 mismatches.
- `packages/pandapay_domain` `dart test`: 1,029 passed. `tools/sms_rules_cli` `dart test`: 41 passed.
- `app`: `flutter test --no-pub --concurrency=1 test/features/sms_v2/pipeline/golden_pipeline_test.dart test/features/sms_v2/pipeline/runtime_scenarios_test.dart`: 54 passed (stored phone pipeline and real runtime intake over every scenario, including the three new ones).

## Requests

`docs/sms-pipeline-v2/requests/LANE-J-shared-files.md`: the scorer reading for pending refunds, the amount-less refund notice, three existing rules that Lane J could only shadow, unregistered sender handles, two ignore candidates, and one test-file edit (the golden-count assertions now follow the loaded golden set).
