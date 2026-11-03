# Request from WP-05: rules for the duplicate-notice scenario

**To:** WP-03a (bank rules) and WP-03b (wallets and UPI apps). **From:** WP-05 (event linker).

The golden scenario `duplicate_notice_bank_and_upi_app` is the only scenario the linker cannot pass, and the cause is in the rules, not the linker. With the facts fixed, the linker already produces `purchase [debit_leg, duplicate_notice]` for this pair (unit test `LINK-DUP-NOTIFY joins a bank debit and a UPI app notice` in `packages/pandapay_domain/test/sms_v2/linker/linker_test.dart`).

## 1. WP-03a: `rejectAny: ["ipo"]` matches inside words

Message: `Rs.250.00 debited from A/c XX1234 on 05-11-26 to VPA chaipoint@okaxis (UPI Ref No 432100000001). Avl bal Rs 40,000.00`

- Expected winner: `HDFC-UPI-DEBIT-VPA` (or `GEN-ACCT-UPI-VPA-D1-B`): purpose `purchase`, `counterparty.vpa`, `references.upiRef`.
- Actual winner: `GEN-ACCT-LAST-D1-B` (purpose `unknown`, confidence 0.6, no reference), because `chaipoint` contains `ipo` and every UPI debit rule has `"ipo"` in `rejectAny` (a substring check, WP-02 decision 3).
- Ask: make the IPO hand-off word whole-word, for example `" ipo "`, `" ipo."`, `"ipo allot"`, `"(ipo"`, or move it into the pattern as a `\bipo\b` negative lookahead. The same applies to `" sip "`-style words already spaced; `"asba"` and `"folio"` are safe.

## 2. WP-03b: no rule or sender for Google Pay notices

Message: `VM-GPAY-S` `You paid Rs.250.00 to Chai Point using Google Pay. UPI Ref 432100000001.`

- Actual: `no_rule_matched` (the brand `GPAY` is not in `senders/`).
- Ask: a `GPAY` sender (and PhonePe/Paytm UPI equivalents if the wording is shared) and a rule emitting `movement` `debit` `purchase` `rail: upi`, `counterparty.name`, `references.upiRef`, no instrument (the notice names no account). Not `evidenceOnly`: the linker treats it as a second notice of the bank debit (`LINK-DUP-NOTIFY`, 10 minutes, shared UPI reference preferred).

## Effect

Golden today (bundle built from `rules/sms/v2`): `pairsLinked` 7/8 (87.5%), `scenarioEvents` 13/14. With both fixes: 8/8 and 14/14.
