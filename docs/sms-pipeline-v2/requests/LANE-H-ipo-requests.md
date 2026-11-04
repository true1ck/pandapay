# Lane H requests: IPO and ASBA lifecycle

Raised by lane H (`sms-v2/lane-h-ipo`). Nothing below was worked around inside the lane.

## 1. Scorer reading table (tools/sms_rules_cli/tool/score_private.dart)

The scorer derives a reading from the first fact and, for `info`, only by rule id (`INV-IPO-NSE-COLLECT-NOTICE` is the one hard-coded id). It reads the amount only from `amounts`. Correct IPO facts therefore still disagree with draft labels. Needed, all additive:

| Fact | Reading |
| --- | --- |
| `info` with `attrs.amountMinor` (any rule) | `ipo_application_notice`, amount taken from `amountMinor` |
| `info` from `IPO-DEMAT-IPO-CREDIT` or `IPO-NSE-SHARES-ALLOTTED` | `ipo_allotment_shares` |
| `info` from `IPO-REG-BID-FUND-NOT-BLOCKED` or `INV-IPO-NOALLOT-01` | `ipo_notice` |
| `movement` from `IPO-REG-PARTIAL-ALLOTMENT` | `ipo_partial_allotment` (the debit; money effect stays investment) |
| `mandate` phase `created` from `IPO-ICICI-MANDATE-APPROVED` | `ipo_mandate_approved` |

A private scratch copy of the scorer with exactly this table scored every row of the IPO family as agreeing (all of them), and moved the subscription family up by three rows. Without it only the hold-release rows agree.

Related: `ICICI-UPI-ONE-TIME-PLACED/RELEASED` and `MND-CREATED-UPI-01` emit holds with purpose `upi_mandate_block`, which the scorer reads as `hold` / `hold_release`, while the draft labels call the same messages `ipo_hold` / `ipo_release`. Either the scorer treats `upi_mandate_block` like `ipo_asba`, or those rules switch purpose. The linker treats both purposes identically, so only the reading differs.

## 2. Bundle `minEngineVersion` for `amountMinor`

`minEngineVersion` exists only at bundle level (`rules/sms/v2/meta.json`, which does not exist today, so builds default to `2.0.0`), and `smsEngineVersion` is still `2.0.0`, which is the engine without `amountMinor`. Three rules emit it: `IPO-NSE-APP-RECEIVED-UPI`, `IPO-NSE-APP-RECEIVED-EMAIL`, `IPO-ICICI-MANDATE-RAISED-FOR-APPROVAL`. An old engine would drop those facts as invalid (CCR-002). Before release: bump `smsEngineVersion` (for example `2.1.0`) and add `meta.json` with the matching `minEngineVersion`. A per-rule field would be better but the contract has none.

## 3. IGN-UPI-COLLECT-REQUEST swallows the exchange "application submitted" notice

`ignore_rules.json` runs before rules, so a BSE notice ("application no. X of Y has been submitted on BSE. You will receive a UPI-Mandate collect request for blocking of funds") is ignored and an IPO rule for it fails lint as shadowed. Please exclude IPO application notices from that ignore rule (for example a leading negative lookahead on `has been submitted on bse`). Then add this rule in `rules/sms/v2/ipo/exchange_notices.json` (family `ipo_notice`, priority 440, sender `*`, emit `info` category `service` with `references.asbaRef` from `ref_asbaRef`):

`application\s+no\.?\s*(?<ref_asbaRef>[a-z0-9]+)\s+of\s+[^.\r\n]{1,60}\.\s*has\s+been\s+submitted\s+on\s+bse\.\s*you\s+will\s+receive\s+a\s+upi[- ]mandate\s+collect\s+request\s+for\s+blocking\s+of\s+funds`

The notice prints no amount, so it is a plain info fact.

## 4. Old NSE collect notice (nse_ipo_notices.json)

`INV-IPO-NSE-COLLECT-NOTICE` emits `info` without `amountMinor`. `IPO-NSE-APP-RECEIVED-UPI` is the same shape with the amount, at priority 440. To keep lint clean (a higher priority rule may not shadow another rule's positive example) it requires whitespace after `Rs`/`Rs.`, which every real notice has; the old rule's synthetic example prints `Rs.14250` and stays on the old rule. Suggest folding `amountMinor` into the old rule, or retiring it with its example changed, then relaxing the new pattern to `\s*`.

## 5. Contract and linker notes

- Registrar notice "bank is instructed to debit X towards partial allotment and unblock Y" is emitted as an investment debit plus a release, as asked. If the bank's own debit alert also arrives for the allotted amount, `LINK-DUP-NOTIFY` pairs the two only within about ten minutes, so a later alert could count twice. A longer window for IPO debits, or marking the registrar debit as evidence when a bank debit exists, would be a WP-05 decision.
- ICICI "mandate redeemed" prints the mandate amount, not the amount debited. It is emitted as a `hold` in phase `converted` (no money) rather than a debit.
- Mandate registration failure (ICICI "AutoPay mandate registration has failed") has no amount and no frozen-contract home; already raised by lane A.
- An unlabelled one-time or block mandate cannot be told apart from a non-IPO one-time mandate by text alone. The ICICI "approved", "raised for approval" and "ONETIME created" rules therefore only fire when the amount has five or more integer digits.
