# Lane V handoff: product screens from the real pipeline

Branch `sms-v2/lane-v-screens`, from `sms-v2/claude-lanes` at a8a9560. Local only: nothing pushed or deployed. No rules, linker, contracts, scorer or Gmail code touched. Flag-on only.

## How it is verified

`app/test/features/sms_v2/support/scenario_model.dart` replays golden scenarios (`tools/sms_golden/scenarios/`, plus a few rule-example messages as extras) through the real `SmsV2Runtime` and returns the `LedgerReadModel` the screens consume. `ui/lane_v_screens_test.dart` pumps the real screens from that model; `ledger/lane_v_readmodel_test.dart` covers shapes the scenarios cannot produce (broker rails, month-boundary salary) with contract fixtures. No Alchemist goldens were added: the repo's goldens cover only found accounts, the inbox and Why this.

| Screen | Result | Evidence |
| --- | --- | --- |
| 1 Investments | Verified; two bugs fixed | IPO allotment lands in "IPO allotments" (put in 14,250, net 14,250), a bank dividend in "Dividends paid to bank" (1,200); spend 0, one investment entry. Broker put in 5,000, taken out 3,000, net 2,000, fund balance and dividends on one platform row (fixtures). |
| 2 Your IPO applications | Verified; two bugs fixed | Allotted, released (not allotted, released 14,250, no totals) and applied-amount-blocked each show company, blocked/invested/released amounts, platform, account and applied date; newest first. A hold alone is not an investment or spend. |
| 3 Money in | Verified; four bugs fixed | Grouped Salary, Dividends, Refunds, Cashback, From people, Other with subtotals and a total that excludes refunds. Own transfer (20,000) and card payment (25,000) never appear. Two same-payer salaries 1 Nov and 2 Dec detected as salary. |
| 4 Subscriptions | Verified; one bug fixed | Netflix mandate plus charge is active at 649; revoked is one past "cancelled" row keeping the last charge; failed AutoPay is "failed payment", no spend; IPO UPI mandates (both the "for IPO of" and "raised by" shapes) are never listed. |
| 5 Card payments | Verified; one label bug fixed | Bank debit plus card receipt is one own-to-own entry (counts as transaction: false, spend 0, count 0). CHEQ, CRED and BBPS bill-pay are all `card_bill_payment`, spend 0, rows labelled "Credit card payment". |

## Bugs found and fixed

1. Subscriptions split one service by card or account: a cancellation notice without the card left "NETFLIX active" and "NETFLIX cancelled" as two rows. Series now key on the service name only (`adapters.dart`).
2. Salary missed across the Indian month boundary: months and days were compared in UTC, so 1 Nov and 2 Dec IST (UTC 31 Oct and 1 Dec) were "two months apart" and 31 vs 1 was "30 days apart". Detection now uses Indian wall time and wraps at month end.
3. Unnamed credits were grouped under one payer ("Unknown service") and could be called salary by repetition. Unnamed payers are never salary and show as "Unknown payer".
4. Refunds and other legs showed "Unknown service" as the payer; the payer now falls back to the merchant on the paired original purchase (SWIGGY).
5. Investments showed the IPO company as a "platform" and dividends as "UNKNOWN SERVICE". Now "IPO allotments" and "Dividends paid to bank"; broker names like "UPSTOX SECURITIES" merge with the `upstox` broker instrument so the fund balance lands on the same row.
6. IPO screen showed the issuer as the platform, had no date and bare status codes. Added applied date, released amount and plain statuses (Applied, amount blocked; Allotted; Partly allotted; Not allotted, amount released).
7. Money in was a flat list with the raw kind word. It now has sections, subtotals, a total that excludes refunds (they reduce spending), and a note that own transfers are left out.
8. Card payment rows had no merchant (and category "Other"). `projection_writer.dart` now labels `card_bill_payment` rows "Credit card payment" and unnamed own transfers "Transfer between your accounts".
9. `smsDate` used the phone's time zone; SMS dates are Indian calendar days, so it now formats in IST.

## Needs other lanes

See `requests/LANE-V-rules-and-linker.md`: payer names missing on IMPS, dividend, refund and person credits (rules); ICICI "mandate raised by" for non-IPO companies yields no subscription mandate (rules); Zerodha funds-added and NSE fund balance messages produced no facts in a probe (rules/sender registration); Upstox withdrawal produces no `investment_withdrawal` event (linker); processed card SI is a plain purchase so a failed SI cannot attach to a service (linker).

## Test status

- `flutter test --no-pub --concurrency=1` (flag off, whole suite): 3027 pass, 8 skipped, 1 fail (the same idempotency test below).
- `--dart-define=SMS_PIPELINE_V2=true test/features/sms_v2`: all pass except `pipeline/idempotency_test.dart` "one batch and one-at-a-time agree on every non-IPO event", which fails identically at the lane tip a8a9560 without any Lane V change (batch leaves 3 refund events ambiguous). Logged as a linker request.
- `flutter analyze --no-fatal-infos`: no new warnings in changed files.
