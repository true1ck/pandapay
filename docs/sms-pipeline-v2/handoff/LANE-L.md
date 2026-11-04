# Lane L handoff: noise sweep and sender registry

Branch `sms-v2/lane-l-noise`, from `sms-v2/claude-lanes` (1baab86). Local only; nothing pushed, no flag changed, no Gmail code touched. Owned paths: `rules/sms/v2/ignore_rules.json` and `rules/sms/v2/senders/`. Two new files outside them, both additive and test-only: `tools/sms_golden/ignore_examples/lane_l.json` and `tools/sms_rules_cli/test/ignore_examples_test.dart` (ignore rules have no example slot in the bundle contract, so their synthetic positive and negative examples live there). No real name, number or amount appears in any rule or example.

## What changed

| Area | Change |
| --- | --- |
| Sender registry | 74 new entries in `senders/lane_l_registry.json` (bundle goes from 148 to 222 senders). Four aliases added to existing brands: the store-account wallet handle (`TINYMT`), the Amazon Pay handle relayed through the payment aggregator (`JUSPAY`), and two YES BANK card handles (`YESBNK`; the second was seen in the corpus beside the one Lane B named). New wallet brands for the quick-commerce cash wallet and the district money wallet (kind `wallet`, spend visibility `sms`). New `BHIM` brand (kind `other`) with the BHIM relay handle as alias. The remaining 70 entries are notice-only or promotional handles (kind `other`, no slug, so no instrument is implied), registered so ignore rules can be sender-scoped, plus one small bank (kind `bank`) that earlier lanes matched through `*`. |
| Ignore rules | 29 to 70: 41 new, 1 changed. All new rules are sender-scoped except five that use wording-only scope with a strict guard (OTP number-first forms, delivery handover codes, do-not-share advice, survey requests, a spam job-offer link). |
| Shadowing fix | `IGN-UPI-COLLECT-REQUEST` now refuses any body that mentions a UPI mandate. A biller's UPI-Mandate collect request (and the exchange's advance notice that one will arrive) is no longer ignored. |
| Tests | `ignore_examples_test.dart` checks every new rule and the collect-request fix: each positive is matched by its own rule and ignored by the engine, each negative is not matched by the rule. 167 checks. |

## Rule families added (41)

OTP and codes: `IGN-OTP-NUMBER-FIRST` (number then "is your ... OTP/verification code", including card OTPs with a foreign amount), `IGN-OTP-DELIVERY-HANDOVER`, `IGN-OTP-NOT-DELIVERED-NOTICE`.
Security and advice: `IGN-NOTICE-DO-NOT-SHARE-ADVICE`, `IGN-GOVT-AWARENESS-NOTICE`, `IGN-ACCOUNT-LOCK-NOTICE`, `IGN-ACCOUNT-RECOVERY-REQUEST-NOTICE`, `IGN-SPAM-WHATSAPP-JOB-OFFER`.
Telecom: `IGN-TELECOM-DATA-USAGE-ALERT` (including regional-language alerts), `IGN-TELECOM-PLAN-EXPIRY-REMINDER`, `IGN-TELECOM-PROMO-FREE-OFFER`, `IGN-TELECOM-PROMO-HANDLE-OFFER`, `IGN-TELECOM-JIO-SERVICE-PROMO`.
Cards and banks (candidates filed by earlier lanes): `IGN-CARD-USAGE-SETTING-CONFIRMATION`, `IGN-CARD-MIN-DUE-RECALCULATED`, `IGN-CARD-NONPAYMENT-DECLINE-WARNING`, `IGN-CARD-LOAN-EMI-PROMO`, `IGN-CARD-LIMIT-CHANGE-OFFER`, `IGN-CARD-FEE-CHARGES-UPDATE-NOTICE`, `IGN-CARD-PIN-ACTIVATION-NOTICE`, `IGN-CARD-APPLICATION-STATUS-NOTICE`, `IGN-CARD-EXPIRY-REPLACEMENT-NOTICE`, `IGN-APP-LOGIN-SETTING-NOTICE` (failed and successful login-PIN set-up, biometric login, registration), `IGN-UPI-REGISTRATION-NOTICE`, `IGN-BANK-SERVICE-DOWNTIME-NOTICE`, `IGN-CONSENT-DATA-SHARING-NOTICE`, `IGN-CREDIT-REPORT-NOTICE`.
Orders, travel, appointments, services: `IGN-ORDER-STATUS-UPDATE`, `IGN-TRAVEL-STATUS-NOTICE`, `IGN-TRAVEL-BOOKING-INCOMPLETE`, `IGN-APPOINTMENT-NOTICE` (includes failed booking), `IGN-FEEDBACK-SURVEY-REQUEST`, `IGN-HOME-SERVICE-PROMO`, `IGN-DEALERSHIP-SERVICE-NOTICE`, `IGN-BROADBAND-ACCOUNT-NOTICE`, `IGN-RENTAL-LATE-FEE-WARNING`.
Demographic, social and marketing: `IGN-SOCIAL-MATRIMONIAL-NOTICE`, `IGN-ASTROLOGY-APP-PROMO`, `IGN-EDUCATION-ADMISSION-PROMO`, `IGN-GOVT-EXAM-NOTICE`, `IGN-DEMAT-EVOTING-NOTICE`.

## How each rule stays off financial rules

- Every rule starts with a negative lookahead (the guard) that refuses a body stating a posted movement, balance, due amount, mandate, refund or statement. Four guard strengths are used. Promotions that print an amount use a guard without the amount test; notices that cannot carry money also refuse any currency amount; telecom and wallet-like senders also refuse "successful". The card-settings rule also refuses "declined" and "failed".
- Lint caught one real shadow while building: the settings rule swallowed two failed-attempt rules ("transaction declined because international usage is disabled"). The rule now refuses declined, failed and any amount.
- **Alias trap.** The engine compares an ignore rule's `senders` with the canonical brand only; lint accepts aliases. A rule scoped to an alias never fires. Two such mistakes were found (a Jio and a Federal Bank alias) and fixed by writing canonical brands. Request filed below.
- Not ignored on purpose: bills and statements with no due date, mandates, IPO holds and unblocks, broker fund-balance reports, refunds, recharge and wallet-recharge receipts, rental payment receipts, card EMI conversion confirmations.

## Results (private corpus 5,196 messages; labeled sample 327, draft labels)

| Measure | Before | After |
| --- | --- | --- |
| Corpus matched | 2,064 | 2,064 |
| Corpus ignored | 1,518 | 2,290 |
| Corpus unknown | 1,614 (31.1%) | 842 (16.2%) |
| Unknown to ignored | | 805 |
| Ignored to unknown (shadow fix) | | 33 |
| Matched rows lost to an ignore rule | | 0 |
| Sample accuracy (rows right of 327) | 176 | 188 |
| Sample rows labeled non-financial but unknown | 26 | 0 |
| Sample sure-financial rows ignored | 2 | 0 |
| Sample sure-financial rows newly ignored | | 0 |
| Sample unsure-financial rows ignored | 1 | 3 |
| Sample financial unknown (of 233) | 76 (32.6%) | 76 (32.6%) |
| Sample sure-financial unknown (of 222) | 72 | 74 |

The financial-unknown rate on the sample is flat, not lower. Two sure-financial rows (a biller's UPI-Mandate collect request and the exchange's advance notice of one) were hidden inside the "ignored" count by the shadowing bug; fixing it moved them to unknown until a rule claims them (request 1), and two unsure bill-reminder rows moved the other way. With request 1 accepted the sample rate is expected to be 74 of 233 (31.8%). Corpus unknown share fell by 14.9 points; the sample has no noise left unknown. The remaining unknowns are mostly financial: bills without a due date, mandates, IPO holds and unblocks, broker balance reports, card statements.

## Checks run

- `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2`: clean.
- `build`: 809 rules, 70 ignore rules, 222 senders, 1,676 examples, all pass.
- `dart run tool/check_pipeline.dart`: 115 cases, 15 scenarios, gates pass (ignore precision unchanged).
- `node test/regex_parity.mjs`: 118,996 comparisons, zero mismatches.
- `tools/sms_rules_cli` `dart test`: all pass. `packages/pandapay_domain` `dart test`: all pass.
- Whole-corpus diff of every outcome before and after: no message that a financial rule matched became ignored.

## Decisions and deviations

- **Demat debit notices were not ignored.** Lane B asked for it, but the draft label for such a row is a sure demat movement, so ignoring it would newly ignore a sure-financial row. Credit-by-IPO and debit-for-pay-in notices stay unknown. The depository handles are registered so the investments lane can add info rules.
- **No NPCI relay entry.** Lane B named a BHIM handle and an NPCI relay handle; only the BHIM handle appears in the corpus. No handle was invented.
- **Failed payment with no amount** (a clinic app) stays unknown: its label is unsure and a future amount-less attempt rule may want it.
- The pre-existing `IGN-EMI-AND-CARD-OFFER` also ignores one card "converted into EMI" confirmation. It has no money effect (the spend alert is separate), so it was left alone.

## Requests filed

`docs/sms-pipeline-v2/requests/LANE-L-requests.md`: (1) rules for a biller's UPI-Mandate collect request and the exchange's advance notice, (2) lint should reject aliases in `senders`, (3) a note for the investments lane on depository notices, (4) a larger gate sample for ignore precision.
