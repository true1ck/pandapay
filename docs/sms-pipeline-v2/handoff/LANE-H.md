# Lane H handoff: IPO and ASBA lifecycle rules

Branch `sms-v2/lane-h-ipo`, from `sms-v2/claude-lanes` at 1baab86. Local only: nothing pushed, deployed or flagged. No Gmail code touched. Only `rules/sms/v2/ipo/` (new) and docs changed; `ipo_asba.json` needed no edit.

## What was added

Fifteen generic rules in three new files under `rules/sms/v2/ipo/`, ids prefixed `IPO-`. Every rule has one positive and one negative synthetic example; none contains a real company, number or amount.

| File | Rule | Reading |
| --- | --- | --- |
| `exchange_notices.json` | `IPO-NSE-APP-RECEIVED-UPI` | application received, UPI collect to follow: `info` with `amountMinor`, never money |
| | `IPO-NSE-APP-RECEIVED-EMAIL` | application received, details by email: `info` with `amountMinor` |
| | `IPO-NSE-SHARES-ALLOTTED` | shares allotted at a price: `info`, no amount |
| | `IPO-REG-BID-FUND-NOT-BLOCKED` | registrar: bid received but bank did not block funds: `info` |
| | `IPO-DEMAT-IPO-CREDIT` | depository credit through an IPO: `info` (shares credited, no money) |
| `registrar_releases.json` | `IPO-REG-UNBLOCK-INFORMED` | registrar "informed your bank to unblock" on non-allotment: `hold` released |
| | `IPO-REG-UNBLOCK-INSTRUCTED` | registrar "bank is instructed to unblock" (precedes the bank release): `hold` released |
| | `IPO-REG-PARTIAL-ALLOTMENT` | "instructed to debit X towards partial allotment and unblock Y": investment debit plus `hold` released |
| `bank_mandates.json` | `IPO-ICICI-MANDATE-RAISED-FOR-APPROVAL` | mandate raised, awaiting approval: `info` with `amountMinor` |
| | `IPO-ICICI-MANDATE-APPROVED` | mandate approved: `mandate` created (one-time, IPO) |
| | `IPO-ICICI-ONETIME-AUTOPAY-CREATED` | one-time AutoPay created: `hold` placed plus `mandate` created |
| | `IPO-ICICI-MANDATE-REDEEMED` | mandate redeemed: `hold` converted (no money) |
| | `IPO-ICICI-UNBLOCK-AGAINST-ISSUER` | bank unblock naming the issuer and date: `hold` released with account mask |
| | `IPO-SBI-MANDATE-BLOCKED` | UPI-Mandate created, funds blocked: `hold` placed plus `mandate` created |
| | `IPO-SBI-MANDATE-REVOKED-UNBLOCKED` | UPI-Mandate revoked, funds unblocked: `mandate` revoked plus `hold` released |

Existing rules were left as they are: the bank allotment debits (`INV-IPO-ALLOT-*`), ASBA blocks and releases, `INV-IPO-NOALLOT-01`, and the ICICI one-time block and release rules in `bills_mandates/`.

## Design points

- Money. Only an actual debit is investment. Notices and demat credits are `info`. Holds link into `ipo_application` events through `LINK-IPO` and are never ledger money. The registrar partial-allotment debit is the one money fact; it is an investment debit on an unnamed bank account.
- Application number. Registrar and exchange rules put the printed application number in `references.asbaRef` (for `info` through an explicit `references` mapping, since the engine only auto-maps `ref_` groups on money-bearing facts), so a later release can find its application.
- The three ICICI rules with no IPO signal in the text require an amount with five or more integer digits. The SBI and registrar rules need no such gate: their text says funds are blocked or names an IPO.
- Hold purpose is `ipo_asba` wherever an issuer is named. The existing UPI one-time rules use `upi_mandate_block`; the linker treats the two the same.
- The new NSE collect-notice rule needs whitespace after `Rs` so it does not shadow the older rule's example; see request 4.

## Verification

- `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2`: clean.
- Build: 824 rules, 29 ignore rules, 148 senders, 1,707 examples, all pass (809 rules and 1,676 examples before).
- `dart run tool/check_pipeline.dart`: golden gate passes (115 cases, 15 scenarios).
- `node test/regex_parity.mjs`: 51,210 comparisons, 0 mismatches.
- `packages/pandapay_domain`: `dart test` passes (1,029). `tools/sms_rules_cli`: `dart test` passes (41).
- Private draft-label scoring (engine only, as the scorer is today): the IPO family went from 0 of 32 to 16 of 32 strict, the subscription family from 12 of 30 to 16 of 30, and no family went down. The remaining IPO disagreements are all reading-table gaps in the scorer, not engine facts; with the table in request 1 applied in a private copy, all 32 agree. A full-corpus probe left no IPO or ASBA template unknown except the BSE submitted notice (request 3), a registration failure and a credit-card AutoPay template owned by other lanes.
- Not run: phone replay of the corpus and any physical check.

## Remaining gaps

See `../requests/LANE-H-ipo-requests.md`: scorer reading table, bundle `minEngineVersion` for the three `amountMinor` rules, the ignore rule that swallows the BSE notice, the older NSE rule, and the linker window for a registrar debit followed by a bank alert.
