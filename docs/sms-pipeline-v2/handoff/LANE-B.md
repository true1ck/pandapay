# Lane B handoff: wallets, card and UPI spends, miscellaneous rules

Branch `sms-v2/lane-b-wallets-spends`, from `sms-v2/main`. Local only, nothing pushed or deployed. No flag, Gmail or other-lane file was touched.

## What was added

Two new rule files, 26 new rules, 52 new examples (each rule has a positive and a negative synthetic example). Counts are bundle totals: 752 rules and 1,562 examples before, 778 rules and 1,614 examples after.

- `rules/sms/v2/wallets/lane_b_wallets.json`
  - Meal-card wallet spend with printed mask, merchant and available balance (a more specific format than the baseline rule, which lost the mask and merchant).
  - Meal-card convenience-fee debit, including a masked variant the baseline fee rules missed because of the word "online".
  - Meal-card credit (employer load) and credit reversal with mask.
  - Store-account payment receipt as a counted wallet spend.
  - Wallet credits that carry an expiry date, read as promotional credit (purpose `cashback`) instead of a top-up, so they no longer look like a transfer.
  - Payments and credits for two store wallets (spend, refund to wallet, load).
  - Amazon Pay "Apay balance" payment through a gateway, as an evidence-only receipt with a balance snapshot (the baseline already treats Amazon Pay balance spends as evidence because the top-up is what counts).
- `rules/sms/v2/banks_lane_b/lane_b_cards_upi.json`
  - Card payment received: ICICI "credit card account" wording, HDFC "online payment vide Ref" wording, Federal co-brand wording, SBI Card via BBPS, YES BANK masked-digit wording.
  - Card spend and decline for the Federal co-brand card (INR and USD) with merchant and card kind.
  - ICICI card decline with card kind and mask (credit and debit), and ICICI USD card spend with mask and merchant.
  - UPI collect requests: an SBI-specific rule and a generic "requested money from you on your X app" rule. Both are pending attempts, not debits.
  - SBI account credit via UPI with account mask and UPI reference.

## Private draft-sample scores (sure rows, strict agreement)

Phone ledger effect measured with the offline phone replay, before versus after.

| Family | Before | After | Rows |
| --- | --- | --- | --- |
| wallet | 17 | 31 | 32 |
| movement (card/UPI) | 17 | 21 | 30 |
| other | 17 | 17 | 31 |
| attempt | 4 | 6 | 10 |
| refund | 15 | 16 | 32 |
| all sure rows | 144 | 165 | 316 |

No row that was correct before became incorrect (0 regressions, 21 additional correct rows on the phone measure; 29 on the engine-only measure). Replay on the sample: counted transactions 50 to 52, open review rows 66 to 60, no reused money fact, no card bill or IPO event counted as spending.

Corpus effect (private corpus, engine only): more messages matched and fewer stayed unknown. Every changed message moved from unknown or from the intended baseline rule, and nothing that matched before was lost.

`other` did not move: its remaining misses are non-financial notices whose draft reading cannot be produced from an ignored message, plus two card debits whose label and contract disagree (see requests).

## Remaining misses in the lane families

- Wallet (1): a UPI-app registration notice, a non-money notice (request filed for an ignore or info rule).
- Movement (9): bill-due notices (bills lane), promotional card EMI offers and settings confirmations (ignore rules), a depository demat debit (ignore), a standing-instruction failure (subscriptions lane).
- Attempt (4): an amount-less payment failure (frozen-contract decision), non-money failures, and one USD decline that the scorer mis-scores (dollar sign not recognised).

## Design notes

- Sender-scoped rules use `*` where the handle is not in the registry; patterns are anchored to the full opening wording so they do not read other senders. See the request file for the registry entries to add.
- USD amounts are emitted as `unit: "USD"`. The ledger projector requires INR, so these cannot enter totals by mistake.
- Evidence-only is kept for Amazon Pay balance receipts, consistent with the baseline. The store-account wallet payment now counts as spending, per the draft label; its top-up has no rule in this lane, so if a top-up is ever read as spending this would double count and should be revisited.
- Wallet credits with an expiry are purpose `cashback` (money effect none). This reading is inferred from the expiry wording and matches the draft label; if some of these are order refunds the refund link will not fire.

## Checks run

- `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2`: clean.
- Bundle build: 778 rules, 29 ignore rules, 148 senders, 1,614 examples, all OK.
- `dart run tool/check_pipeline.dart`: 115 cases and 15 scenarios, ok.
- `node test/regex_parity.mjs`: 48,420 comparisons, 0 mismatches.
- `packages/pandapay_domain` `dart test`: 1,004 passed. `tools/sms_rules_cli` `dart test`: 41 passed.
- Phone replay of the draft sample (throwaway test, removed) for the before and after bundles.

## Requests

`docs/sms-pipeline-v2/requests/LANE-B-shared-files.md`: sender registry entries, scorer changes, ignore rules, and two frozen-contract notes (bill-pay receipts, foreign currency).
