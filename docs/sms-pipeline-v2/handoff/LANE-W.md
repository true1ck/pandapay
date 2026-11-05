# Lane W: final accuracy and linker follow-ups

Branch `sms-v2/lane-w-followups`, from `sms-v2/claude-lanes` (ea837c1). Local only: nothing pushed, deployed, flagged or signed. No Gmail code, no `meta.json`, no frozen contract change. No message text, name, number or amount from private data appears here. Row numbers are indexes into the private draft sample.

## Result on the private draft sample (sure rows, phone replay)

| Family | Before | After | Rows |
| --- | --- | --- | --- |
| subscription | 22 | 25 | 30 |
| ipo | 29 | 32 | 32 |
| card_bill | 27 | 28 | 30 |
| movement | 28 | 29 | 30 |
| attempt, investment, other, refund, rewards_limits, salary, security, wallet | unchanged | unchanged | 10, 32, 31, 32, 23, 2, 32, 32 |
| all sure rows | 295 of 316 (weighted 92.8%) | 303 of 316 (weighted 94.4%) | 316 |

False counts on the sure rows stay 0. The financial-unknown rate falls from 2.3% to 1.8%. The one over-all false count is the unsure UPI transfer row that the draft label guesses as a card bill (unchanged, cannot be decided from the text).

Phone replay of the whole corpus, before and after: transaction count, spend, income and investment totals identical; no money fact reused; no card bill or IPO event counted as spend. Event types moved only where intended: 19 processed card standing-instruction alerts changed from a plain purchase to a subscription charge (totals unchanged, one event each), and 10 statement-ready notices moved from "needs review" to a recognised no-money notice.

## Tasks

1. **Payer names (rules).** The generic credit rules now capture the payer where one is printed:
   - IMPS, NEFT and RTGS credits (12 rules, `GEN-ACCT-RAIL-*`): the segment after the reference in a slash or dash narration, or the name after "by". Bounded patterns; lint clean.
   - UPI person credits (6 rules, `GEN-ACCT-UPI-PLAIN-*`, `GEN-ACCT-RECEIVED-UPI*`): "from NAME (vpa)", counterparty kind `person`.
   - Dividend credits (`INV-DIVIDEND-CREDIT-01/02`): "from COMPANY".
   - Refund and reversal credits: the `merchant` group was already captured by the eight `GEN-REFUND/REVERSAL-*-OF` rules and `GEN-REFUND-NOMASK` but never emitted; now emitted (a leading "your" is skipped). Federal and HDFC card refund alerts capture the merchant too.
   Seven golden cases (`lanew:payer_*`) plus rule examples. The refund stratum did not move (30 of 32): the linker requires a refund's merchant to be compatible with its purchase's, and the replay shows no new unlinked refunds.
2. **Broker withdrawals.** The broker's own "withdrawal credited to your bank" notice (`INV-BROKER-PAYOUT-DONE-01`) was evidence-only on a broker instrument, so it produced no event. It is now a normal investment credit with the broker name from the message prefix and no instrument (a broker sender cannot own the user's bank account). `BRK-PAYOUT-BANK-CREDITED-01` got the same treatment (it was creating a bank account of the broker's issuer). No linker code change was needed: `LINK-DUP-INVEST-CREDIT` joins the bank credit as `duplicate_notice`. Scenarios: notice plus bank credit (investment taken out once), notice only, and notice with UTR plus NEFT credit.
3. **Standing instructions.** `SUB-SI-CHARGED-01` (the issuer's "successfully processed ... as per Standing Instruction") and `MND-EXEC-SI-01` ("standing instruction (SI) of ... has been processed") now also emit a subscription mandate for the merchant, and `MND-EXEC-SI-01` is evidence-only like the other (the issuer's own spend alert is the money). The spend alert joins the mandate as the charge and the notice is its `duplicate_notice`, in either arrival order, so the charge counts once and a later failed standing instruction (same merchant name) attaches to the service. First attempt left `MND-EXEC-SI-01` as a real debit and double counted when the notice came first; the evidence-only form fixes that. Scenarios in both orders; app test `ledger/lane_w_subscriptions_test.dart` checks the service shows "failed payment" with one occurrence.
4. **ICICI raised mandates.** New file `bills_mandates/icici_raised_mandates.json`. The discriminator is the amount: an IPO UPI mandate is never below five integer digits, so a raised, approved or revoked mandate of at most 9,999.99 with no IPO wording (`ipo`, `onetime`, `asba`, `allot`) is a `subscription` mandate (`oneTime: false`). The contract has no "pending" phase, so "raised for your approval" and "you have approved" both read as `created`. Larger amounts are left to the IPO rules. Found while checking: a revoked IPO mandate ("raised by X on date and is revoked") was read by the generic `MND-REVOKED-03` with no IPO purpose, so it would list as a cancelled subscription; `IPO-ICICI-MANDATE-REVOKED` now keeps it a one-time IPO mandate (about 30 real messages). Same for SBI "UPI-Mandate successfully created towards ISSUER for Rs 15000" and its revoke (`bills_mandates/ipo_looking_mandates.json`, about 28 real messages that the generic rules listed as subscriptions). Limitation: a genuine recurring mandate of 10,000 or more from these two shapes is not shown as a subscription.
5. **Broker messages.** Both shapes already produce facts through the pipeline: the Zerodha "funds added" notice is an evidence-only credit by design (the bank's UPI debit is the put-in, a scenario shows exactly one investment of the amount), and the NSE fund-balance message gives a balance snapshot on the broker instrument. What was missing were sender entries: `NSESMS`, `NSETRA`, `NSEWEL` (alias of NSE), `UPSTX` (Upstox), `KFINCR`, `KFINTH` (KFintech). `GROWWO` is deliberately not registered (see below).
6. **Scorer reading table** (`tools/sms_rules_cli/lib/scoring.dart`, readings only, unit-tested): an IPO mandate created reads `ipo_mandate_approved` (revoked stays `mandate_revoked`); a `upi_mandate_block` hold reads like `ipo_asba`; an info fact from family `ipo_allotment_shares` reads `ipo_allotment_shares`, from `demat` reads `demat_movement`, from `card_statement_notice` reads `statement`; a debit from family `ipo_partial_allotment` reads `ipo_partial_allotment`. Matching rule families were renamed where the facts are the same (`IPO-DEMAT-IPO-CREDIT`, `IPO-REG-PARTIAL-ALLOTMENT`), and `BIL-CC-STMT-READY-NO-AMOUNT` is a new no-money notice for a card statement that prints no amount. Gains: IPO 29 to 32, subscription 22 to 25, card bills 27 to 28, movement 28 to 29.

## Rows that still disagree, and whether the label or the rule is doubtful

| Rows | Cause | Doubt |
| --- | --- | --- |
| 268, 269, 283 (ICICI hold or release "against the UPI one-time mandate") | Facts are holds with purpose `other`; labels say IPO hold or release | Rule is right to be cautious: the text does not say IPO, and UPI one-time blocks also serve other uses. Calling them IPO would make the linker build IPO applications from them. Label is plausible from amount and timing; needs a product decision. |
| 282 (SBI mandate created for an IPO-sized amount) | Now an IPO mandate, label says IPO hold | Granularity: the message creates a mandate; the block is a separate fact. Label doubtful. |
| 14, 26 (bill paid through a card app) | Rule is evidence-only; label counts it as a card bill transfer on the card | Label doubtful (own note says the bank debit counts); keep rule. |
| 144, 166 (card spend on a wallet top-up merchant) | Reads as wallet credit with the spending effect | Label reading `card_spend` is the doubt. |
| 183 (clinic refund successful) | No account named, so the ledger gives no effect | Ledger decision: an unlinked refund with no instrument. Label likely right. |
| 10, 285, 204 (failed payment, failed mandate registration, cancellation without an amount) | Frozen contract: an attempt needs an amount, a mandate has no failed phase | No rule can fix. |
| 132 (bill "due today") | `bill_due` needs a due date and an amount | Needs a `fromObservedAt` option; frozen contract. |
| unsure rows 2, 7, 9, 39, 134, 157, 226, 286 | Unchanged from lane T | See `requests/LANE-T-requests.md` section 4. |

## Notes and open questions for the coordinator

- **Bank account of a broker's issuer.** When a registered broker handle sends a notice that names a bank account mask, the engine turns the mention into a `bank_account` of the broker's own issuer (the sender fallback in `rule_engine.dart` cannot be switched off). `BRK-PAYOUT-TRANSFER-OK-01` still does this for a registered handle, which is why the settlement handle `GROWWO` stays unregistered (registering it would create an account of the broker, and the draft label reads the mask from that mention). A rule-level way to say "no issuer" would remove the problem.
- Standing instructions: if a bank sends the processed notice but never the spend alert, the notice is evidence only, so the charge has no money until the alert arrives (the existing receipt-without-payment review still applies). This matches how `SUB-SI-CHARGED-01` already worked.
- Raised mandates read as `created`, not pending (no such phase in the contract); a mandate the user never approves would still list until it is revoked.

## Checks run

- Lint clean. Build: 973 rules, 71 ignore rules, 2,022 examples, all pass. `check_pipeline`: 239 cases, 26 scenarios, ok. `node test/regex_parity.mjs`: 145,584 comparisons, 0 mismatches.
- `packages/pandapay_domain` `dart test`: 1,077 passed. `tools/sms_rules_cli` `dart test`: 244 passed.
- `app`: `flutter test --no-pub --concurrency=1 test/features/sms_v2`: 348 passed, 3 skipped, flag off and with `--dart-define=SMS_PIPELINE_V2=true`.
