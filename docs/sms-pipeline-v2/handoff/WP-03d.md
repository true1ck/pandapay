# WP-03d handoff: limits, rewards, links, categories

Branch `sms-v2/wp-03d-limits-categories` (merged with `sms-v2/main` after 03b and 03c). No engine, contract or Dart code touched.

## What was built

| File | Count | Notes |
| --- | --- | --- |
| `rules/sms/v2/rewards_limits/rewards_limits.json` | 27 rules | `LIM-*` limit changes (9), `REW-*` reward points (10), `CBK-*` cashback to credit card, debit card, wallet and bank account (8). All `senders: ["*"]`; the issuer comes from the sender entry. |
| `rules/sms/v2/ignore_rules.json` | 27 ignore rules | OTP, security and scam, promotions (cashback, limit/loan/EMI/card offers, recharge, insurance renewal, gambling, generic), service (telecom, delivery, survey, KYC, card controls, PF, ops, demat, biller onboarding, wallet nag, reward expiry), broker "payable to you for all trades", UPI collect requests, loan-consent offers. |
| `rules/sms/v2/link_rules.json` | 8 | The 7 baseline rules plus `LINK-RECEIPT`. |
| `rules/sms/v2/category_rules.json` | 411 | Catalogue rules, whole-token matching, 14 spend slugs (all of WP-07's 15 except `other`). |
| `rules/sms/v2/merchant_aliases.json` | 78 | Whole-key aliases. |
| `tools/sms_golden/cases/**` | +33 cases (`wp03d:*`) | Synthetic. These are the only files outside the owned paths (the work package method asks for missing golden cases). |
| `docs/sms-pipeline-v2/requests/WP-03d-points-unit.md` | request to WP-02 | See Gaps. |

## Ignore rule design

Ignore rules run before every rule, so each one is `^(?!<financial guard>)...<trigger>`. The guard (`G_FULL`) refuses a message that states a posted movement (`debited`, `credited`, `Rs X spent`...), an available limit or balance, a due amount or date, a UPI/UTR reference, a mandate, ASBA or lien, a payment success, or earned/redeemed/credited points or cashback. Lighter guards are used where a trigger cannot hide a movement (OTP, collect requests, broker notices). Results: golden ignore precision 27 of 27; none of the 1,000+ other messages checked (probe cases, all scenario messages, synthetic versions of every real template in WP-03, 926 strings mined from old tests) that are financial was ignored; JS and Dart pick the same winner on all of them.

Deliberate differences from the old parser: "Refund initiated" and "refund pending" are NOT ignored (golden expects an `attempt`); NSE/BSE fund-balance reports are not ignored (03c balance snapshots); CDSL/NSDL debit and credit are not ignored (only pledge/unpledge).

## Old parser branch to new rule

| Old branch (`local_sms_parser.dart` unless noted) | New rule |
| --- | --- |
| `isNonTransactionNoise` offer / promotion regex, `promotion` regex (~2482), spend-and-cashback offers | `IGN-PROMO-CASHBACK-OFFER`, `IGN-PROMO-GENERIC` |
| loanOrCreditPowerMarketing, `claim your ... emi card`, `avail card with limit`, pre-approved loan, EMI conversion offers | `IGN-LIMIT-OFFER`, `IGN-EMI-AND-CARD-OFFER`, `IGN-LIMIT-NOTICE-NO-AMOUNT` |
| bettingOrGamblingSpam | `IGN-PROMO-GAMBLING` |
| insurance renewal marketing (`operationalNotice`) | `IGN-PROMO-INSURANCE-RENEWAL` |
| telecomCarrierNotice, call forwarding, data pack, talktime | `IGN-TELECOM-SERVICE`, `IGN-TELECOM-PREPAID-DEDUCTION`, `IGN-RECHARGE-PROMO` |
| serviceNotice: survey, DND/spam, CKYC, card controls, security tip, ticket id, ATM free-txn count, delivery | `IGN-SERVICE-SURVEY`, `IGN-SERVICE-KYC-CONTROLS`, `IGN-SERVICE-CARD-CONTROLS`, `IGN-SERVICE-ADVICE`, `IGN-SERVICE-OPS-NOTICE`, `IGN-DELIVERY-STATUS` |
| transaction check alert, SIM swap, unsolicited tips, scams | `IGN-SECURITY-ALERT`, `IGN-SECURITY-SCAM` |
| OTP gate (also `api/src/sms_parser.js` OTP rejection) | `IGN-OTP-CODE` |
| `isProvidentFundNotice` | `IGN-SERVICE-PF-NOTICE` |
| billerOnboarding, `controlNotice` SEBI/demat noise | `IGN-SERVICE-BILLER-ONBOARDING`, `IGN-SERVICE-DEMAT-NOTICE` |
| `wallet balance is Rs 0`, `add money to wallet` | `IGN-SERVICE-WALLET-NAG` |
| (new, from real messages) broker payable, collect requests, YES BANK consent, recharge promos | `IGN-BROKER-PAYABLE-TRADES`, `IGN-UPI-COLLECT-REQUEST`, `IGN-LOAN-OFFER-CONSENT`, `IGN-RECHARGE-PROMO` |
| `extractCreditLimit` (`api/src/card_limit_parser.js`), limit-with-amount balance branch | `LIM-INCREASE-01/02`, `LIM-DECREASE-01`, `LIM-*-VERB-01`, `LIM-UPDATED-01`, `LIM-ASSIGNED-01`, `LIM-STATED-01` |
| `rewardCredit`, "Reward or cashback" merchant label, `rewardState` | `REW-EARNED-*`, `REW-REDEEMED-*`, `CBK-*` |
| `api/src/merchant_category.js` `BUILTIN_CATEGORY_RULES`, `flashtext_merchant_extractor.dart` catalogue | `category_rules.json` |

## Categories: collisions fixed

Whole-token matches only (longest match wins, then priority 950 context/wallet descriptors, 900 multi-token brands, 800 single brands, 700 exact-only or low-priority, 400 generic words). KUBER, SUBER, SPARK, SHELLY give no category; UBER EATS is dining; SWIGGY INSTAMART is groceries; AMAZON PAY IN is aliased to AMAZON (online) while AMAZON PAY WALL and AMAZON PAY IN E (top-up descriptors) are wallet; INDIGO needs a context token (AIRLINES, AVIATION, FLIGHT, 6E), INDIGO PAINTS gives nothing; OLA and VI are exact-only. Dropped as ambiguous: bare rental, apollo, apple, coin, paytm, phonepe, metro, essar, gst, cred. `investments` is not a spend slug (WP-07). A Python reference matcher with the WP-07 semantics passed 71 cases (all audit collisions); the real resolver is WP-07's.

Assumptions WP-07 should confirm: aliases are whole-key matches applied after upper-casing and legal-suffix stripping; `context` tokens are looked up in the merchant key's tokens; `token` means a contiguous token span.

## Link rules

Priorities: IPO 120, MANDATE-CHARGE 110, CARD-BILL 100, WALLET-TOPUP 100, REFUND 90, OWN-TRANSFER 80, RECEIPT 70, DUP-NOTIFY 60. Windows: card bill 72 h, wallet top-up 48 h, IPO 504 h, refund 2,880 h (120 days), own transfer 24 h, receipt 72 h, duplicate 10 minutes (0.1667 h), mandate charge 8,784 h. `LINK-REFUND`, `LINK-IPO` and `LINK-MANDATE-CHARGE` use tolerance 100 meaning "up to": the linker must enforce refund and allotment at most the original amount. `LINK-RECEIPT` and `LINK-DUP-NOTIFY` use event type `purchase`; the linker keeps the anchor debit's type.

## Results

- `lint` on merged `rules/sms/v2`: clean. `build`: 289 rules, 27 ignore rules, 62 senders, 607 examples OK.
- Golden (115 cases with mine; only 03b, 03c and 03d rules exist so far): 40 of 46 cases in my area pass (ignore, limit, cashback, and all non-points reward cases). Ignore precision 100%.
- The 6 failures are all `unit: POINTS` amounts, which the engine turns into paise (50 points becomes 5000). See the request file.
- Regex parity: `regex_parity.mjs` 1,708 comparisons, 0 mismatches; a JS re-implementation of winner selection agrees with the engine on 1,019 messages.

## Gaps and follow-ups

1. **WP-02: POINTS unit** (request filed). Until fixed, the reward cases above fail.
2. **iOS `smsfp` tag** cannot be used by an ignore rule: rules see only the body and the brand. The safety gate (code, WP-14) should treat `smsfp` as a supporting promotion signal. The same applies to `-P` sender suffix and 6-digit numeric headers.
3. **Expiring points** have no contract slot (`reward` needs `points_earned` or `points_redeemed`). Pure expiry notices are ignored as service; expiry dates on earn messages go to `expiresAt`.
4. **Balance-only points messages** ("your points balance is N") are not covered; with the new asOf default a `balance_snapshot` rule is now possible and can be added in round 2.
5. **Priority overlap with 03a:** reward and cashback rules sit at 270-298, below 03a issuer rules (300+). 03a spend/credit rules that could match a cashback message should reject `cashback`. 03b's `WAL-AMAZONPAY-CASHBACK-01` (700) wins for Amazon Pay; my examples use a neutral wallet name.
6. **Real templates:** the broker payable, YES BANK consent and collect-request wording was written from the work package description, not from a redacted real sample. Check these three against the real golden set in round 2.
7. `LINK-DUP-NOTIFY` covers debits only, as in the contract.
