# Lane A requests: subscriptions, mandates, bills and attempts

Lane A owns `rules/sms/v2/bills_mandates/*.json` and `rules/sms/v2/subscriptions/*.json`. Everything below is outside that lane or cannot be expressed in the frozen contract. No rule was forced. All examples are generic; no message text from the private sample appears here.

## 1. Scorer (`tools/sms_rules_cli/tool/score_private.dart`, Codex lane)

The scorer maps facts to a reading with a fixed table, so some correct engine outputs cannot agree with a draft label.

| Gap | Effect | Proposal |
| --- | --- | --- |
| An `evidenceOnly` movement with purpose `bill_payment` reads as `movement` | A biller receipt (rule family `bill_receipt`) can never equal the label `bill_receipt` | Read `evidenceOnly` and `bill_payment` as `bill_receipt` |
| A `bill_due` from a card statement reads as `bill_due` | Statement notices carrying total, minimum and due date can never equal the label `statement` | Read a rule in family `card_statement` as `statement`, or treat `statement` and `bill_due` as equal |
| `payment_request` is recognised by two hard-coded rule ids | A pending collect request from another rule reads as `failed_attempt` | Also match rule id `SUB-MND-UPI-COLLECT-PENDING-01`, or match on rule family `payment_request` |
| The currency is inferred only from the letters `USD` in the body | A `$` amount is expected in INR, so a correct USD attempt disagrees on amount | Also infer USD from a `$` sign |
| `not_financial` never equals the engine reading `service_notice` | A correct ignore or info outcome counts as disagreement | Treat `not_financial` as equal to `service_notice` and unknown |
| `recharge` has no reading | A mobile recharge receipt cannot agree | Read a bill-payment receipt in a rule id starting `SUB-RCH-` as `recharge` |

## 2. Shared ignore rules (`ignore_rules.json`)

- `IGN-UPI-COLLECT-REQUEST` matches the phrase "collect request" and shadows a UPI-Mandate collect request sent by a biller (for example a subscription provider asking to authorise a mandate payment). Proposed change: skip the ignore when the body contains "mandate collect request" and emit a pending attempt with this shape:
  - Pattern: `upi-?\s*mandate\s+collect\s+request\s+from\s+(?<m>[a-z0-9&.' _*-]+?)\s+for\s+(?:rs\.?|inr|₹)\s*(?<amt>[\d,]+(?:\.\d{1,2})?)`
  - Emit: `attempt`, status `pending`, direction `debit`, purpose `unknown`, `scheduled` amount, counterparty from `m`.
  - Positive example: "You have received a UPI-Mandate collect request from EXAMPLE MEDIA for Rs.250.00. Login into the Example Pay application to authorize."
  - Negative example: "UPI-Mandate collect request from EXAMPLE MEDIA for Rs.250.00 was declined."
- Candidates for ignore (no money, no instrument change): a failed app-login PIN set-up notice; a failed appointment booking notice; a notice that a minimum-amount-due calculation was updated.

## 3. Frozen contract cannot express

- **Mandate registration failure without an amount.** The contract has no `failed` phase for `mandate`, and `attempt` needs an amount. Same root cause as `WP-03c-attempt-without-amount.md`. Left as review.
- **Merchant payment failure without an amount** (order payment failed, retry). Same root cause. Left as review.
- **A bill reminder with no due date.** `bill_due` requires `dueDate`. Common templates print an amount and say "due today" or "is due, pay to avoid disconnection". Proposal for WP-02: let a `bill_due` rule set `dueDate` from the observation date when a flag such as `dueDate: {"fromObservedAt": true}` is given. Until then these notices stay unknown, which is the safe outcome.
- **A card statement notice with no total or due amount** (statement ready, view in app). `bill_due` needs at least one amount. Left unknown.
- **A non-payment warning for a card statement** (transactions may be declined). No amount and no contract type. A candidate for ignore (section 2).

## 4. Linker (WP-05 owner): charge without a mandate leg loses its ledger row

When two mandate-created notices for the same merchant and account arrive (one with an account mask and one without), the linker keeps one and leaves a later `subscription_charge` event with only its `charge` leg. In a private full-corpus replay, that event then carried no ledger entry, so one real debit stopped counting even though it had counted before. Expected: a `charge` leg alone must still project its debit. This is not caused by a rule, but the new UPI-Mandate created rule exposed it. Removing the account mask from the rule made totals worse, so the rule keeps the mask.

## 5. Label and design notes

- The draft label for a mobile recharge success says it counts as spending. The rules emit an `evidenceOnly` bill-payment movement, because the notice alone does not prove the funding account was debited. If the owner prefers it to count, WP-05 needs a rule for app receipts without a bank leg.
- A card debited through UPI AutoPay (a card network on the UPI rail) is emitted with rail `card` and the credit-card instrument, so it links to card activity. The rail `upi` would be more literal but could bind to a bank account.
- The SI "successfully processed" notice is emitted as `evidenceOnly`, because the issuer sends a separate card spend alert for the same charge.
