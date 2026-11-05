# Lane T handoff: accuracy cleanup after wave 1

Branch `sms-v2/lane-t-gaps`, from `sms-v2/claude-lanes` (a8a9560). Local only: nothing pushed, deployed or flagged. No Gmail, code, scorer, `meta.json` or `link_rules.json` change.

## Finding that changes the refund plan

The initiated-refund notices were not ignored or unknown. Every one of them already matches a Lane J rule and is read as a pending refund attempt, which is the right reading. The scorer (`tools/sms_rules_cli/lib/scoring.dart`) has no branch that turns a pending refund attempt into `refund_initiated`, so all of them score as `failed_attempt` and disagree. Refunds therefore cannot move with rules alone. With the branch below applied to a throwaway copy (reverted, not committed), the refund stratum is 30 of 32 with the phone replay and 31 of 32 engine only. Without it, it stays 18 of 32. The scorer owner needs to add:

```dart
AttemptFact f
    when f.purpose == MovementPurpose.refund &&
        f.status == AttemptStatus.pending =>
  'refund_initiated',
```

## Rules changed (all under `rules/sms/v2/`)

| Item | Change |
| --- | --- |
| `GEN-REFUND-NOMASK` | Rejects "initiated", "will be credited", "to be credited". An initiated-and-will-be-credited notice is no longer money back. |
| `GEN-REFUND-PENDING` | Gap between amount and "initiated" raised from 40 to 120 characters, but the gap may not contain "has been credited/refunded/processed". Rejects policy text ("initiated within", "as per", "policy", "terms"). |
| `GEN-ACCT-SALARY-*` (8 rules, with and without balance) | Capture the payer (NEFT narration form `NEFT-<payer>-SALARY`, and "salary from <payer>" for the unknown rail). No payer still matches as before. |
| `BOB-UPI-CREDIT`, `BOB-UPI-CREDIT-B` | Reject IMPS, NEFT and RTGS wording. A Bank of Baroda IMPS credit with a 12-digit reference now falls to the generic IMPS credit rule (rail imps, with balance). |
| `INV-BROKER-WITHDRAW-CREDIT-02` | Rejects "trading account" / "demat account" credits. |
| `GEN-ACCT-LAST-D1` | Rejects a debit with "failed" or "unsuccessful" within 120 characters after the account. |
| `LIM-*` (nine limit rules) | Card mask accepts digits directly before the X ("4315X6153"). |
| `REW-*` (four rules) | Points amount cannot follow `/`, `.` or `-` or end in a comma. A date such as "25/11/26," was read as 26 points. |
| `IGN-DELIVERY-STATUS`, `IGN-ORDER-STATUS-UPDATE`, `IGN-NOTICE-DO-NOT-SHARE-ADVICE` | Do not claim a message that carries an OTP code. Ignore rules run in id order, so these swallowed OTP messages before `IGN-OTP-CODE`. They are now ignored with reason `otp`. |
| `senders/investments.json` | `BSELTD` added as an alias of `BSEIND`. |

New rules:

- `AXIS-ACCT-DEBIT-EMI` (movement, debit, purpose emi, bank account mask) for Axis EMI/LOAN debit narrations.
- `rules/sms/v2/lane_t/lane_t_gaps.json`: `LANE-T-ACCT-DEBIT-FAILED` (failed debit attempt, posted amount, account mask); `LANE-T-BROKER-TRADING-ACCOUNT-CREDITED` (info, so a broker-side top-up confirmation moves no money); `LANE-T-BSE-IPO-APPLICATION-SUBMITTED` (info, family `ipo_notice`); `LANE-T-UPI-MANDATE-COLLECT-REQUEST` (pending debit attempt, scheduled amount, merchant); `LANE-T-REWARD-LOYALTY-POINTS-LABEL` (retail loyalty points, no instrument).
- `IGN-REWARD-CLAIM-REMINDER` (promotion): "claim your coins earned" reminders.

Every new rule has a positive and a negative synthetic example; no real name, number or amount appears anywhere.

Golden: 8 new cases (`lanet:*`, 225 cases in all, 18 scenarios) and `tools/sms_golden/ignore_examples/lane_t.json` (4 rules). The info and ignore outcomes are covered by rule examples and ignore examples, because the golden gate treats an ignored message as a financial miss.

## Private draft-sample scores (sure rows, with the proposed scorer branch applied temporarily)

| Family | Before (phone) | After (phone) | Rows |
| --- | --- | --- | --- |
| refund | 18 (30 with the scorer branch) | 30 | 32 |
| rewards_limits | 20 | 23 | 23 |
| security | 29 | 32 | 32 |
| other | 28 | 29 | 31 |
| subscription | 20 | 22 | 30 |
| attempt, card_bill, investment, ipo, movement, salary, wallet | unchanged | unchanged | 10, 30, 32, 32, 30, 2, 32 |

No family regressed. The false-count rate over the sure rows stays 0. The over-all rate (including the unsure rows) stays at one row, an unsure UPI transfer whose label guesses a card bill; it did not change.

Phone replay of the whole corpus, before versus after: the spend, income and investment totals are identical; the transaction count is unchanged; no money fact is reused, no card bill and no IPO event counts as spend. 34 messages moved from unknown to a reading (exchange submitted notices and mandate collect requests, none with ledger effect). About 55 messages changed only their ignore reason to `otp`. One false reward (a date read as points) became an ignore.

## Checks run

- Lint clean. Build: 966 rules, 71 ignore rules, 2,002 examples, all pass.
- `dart run tool/check_pipeline.dart`: 225 cases, 18 scenarios, ok.
- `node test/regex_parity.mjs`: 144,144 comparisons, 0 mismatches.
- `packages/pandapay_domain` `dart test`: 1,047 passed. `tools/sms_rules_cli` `dart test`: 239 passed.
- `app` golden pipeline and runtime scenario tests: 54 passed.

## Left open

See `../requests/LANE-T-requests.md`: the scorer branch, rows that no rule can fix (amount-less notices, a statement with no amount, a bill with no due date), rows owned by the IPO lane, and the draft label doubts.
