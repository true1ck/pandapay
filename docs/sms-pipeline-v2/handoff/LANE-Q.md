# Lane Q handoff: generalise the rules beyond one user's banks

Branch `sms-v2/lane-q-generalise`, from `sms-v2/claude-lanes` at 1baab86. Local only: nothing pushed, deployed or flagged. No Gmail code, existing rules file, `ignore_rules.json`, sender file, scorer, contract or code was touched.

## What was added

87 rules in five new files under `rules/sms/v2/generalization/`, plus `NOTES.md` (the rule schema has no description field, so each rule's purpose and its wording confidence are listed there), and 68 new synthetic golden cases under `tools/sms_golden/cases/` (hash-named, following the existing format, origin `lane-q`, ids `laneq:*`). The 115 existing cases are unchanged and all still pass.

| File | Rules | Covers |
| --- | ---: | --- |
| `cards.json` | 38 | card spend in four extra word orders (three kinds each: credit, debit, kind not printed, plus a balance variant where "Avl limit" is printed), foreign spend with the INR figure in brackets, ATM cash withdrawal with a card (two word orders), card payment received for one-word card brands, credit limit up, down and revised, card statements in any field order, card due reminders (three shapes) |
| `accounts_emi.json` | 31 | Dr./Cr. abbreviation account alerts by rail (NEFT, IMPS, RTGS, UPI, plain, each with a balance variant), loan or card EMI debited, upcoming, bounced and received, bank debits that name a SIP or a utility, insurance or BBPS bill, Canara ATM debits |
| `bills_insurance_utilities.json` | 8 | insurance premium due and renewal and receipt, utility, telecom and gas bill due, biller payment received, recharge success, FASTag toll, travel booking receipt |
| `sip_funds.json` | 2 | SIP executed and mutual fund purchase processed (evidence only) |
| `wallets_apps_gateways.json` | 8 | PhonePe, Google Pay, Paytm and Amazon Pay UPI receipts, smaller UPI apps, gateway receipts, wallet spend for Paytm, PhonePe, MobiKwik and Freecharge, CRED card bill receipts |

Every rule has one positive and one near-miss negative example (declined, failed, "will be", "could not", "pending", an offer). Rules whose message can carry a balance come as a pair, a plain rule and a `-B` rule at priority +5 that also emits the balance or available-credit snapshot, so a generalised rule never drops a snapshot the baseline rules would have kept.

Design points:

- Priorities: cross-issuer card, account and wildcard-sender shapes sit between 120 and 306 (below the issuer-exact bands, above the last-resort rules at 40 to 65 and the balance-only rules at 200 that were swallowing some spends). Bill, statement and insurance shapes sit in 240 to 640. Rules scoped to registered app senders (PhonePe, Google Pay, Paytm, Amazon Pay, CRED) sit at 559 to 700. The only rules above 700 are the two Canara ATM rules, scoped to the Canara handles. No rule outranks an existing rule on the same wording: a comparison run over the 1,791 existing rule examples, ignore examples and golden messages shows no changed result except 13 existing near-miss examples that used to be UNKNOWN and are now read correctly (for example "Txn of Rs x successful on your card" as a card spend, "Payment of Rs x is due on your card" as a bill due).
- Receipts from billers, insurers, telcos, payment apps, gateways, travel sites and fund houses are `evidenceOnly` movements. The bank, card or mandate debit is the counted movement; the linker pairs them as duplicate notices. FASTag toll alerts are also evidence only, so a FASTag recharge and the toll are never both counted.
- A card message that does not say credit or debit gets no `kind`, so it can only attach to a card the user already has; this is why five golden cases (kind-less or unregistered sender) assert the movement but no instrument.
- Wording is a guess everywhere. No rule is copied from a private message. Each rule's confidence is 0.75 to 0.95; the least certain (wildcard-sender receipts, travel) are at 0.75 to 0.82.

## Coverage matrix

Method: about 400 synthetic probes, written in each issuer's typical style, run against the bundle built before this lane and after it (`dart run bin/sms_rules.dart build ...`). A cell is "covered" when the message gives the right fact kind, direction and purpose. Probe rows are what exists in the bundle, not an exhaustive issuer list; a blank cell was not probed. Legend: `Y` covered before and after, `N>Y` gap closed by this lane, `N` still a gap, `Y>N` regression (none).

Summary by message kind (cells are issuer or service probes):

| Kind | Cells | Covered before | Covered after |
| --- | ---: | ---: | ---: |
| Card spend | 23 | 22 | 23 |
| ATM | 10 | 8 | 10 |
| Acct debit | 26 | 26 | 26 |
| Acct credit | 22 | 22 | 22 |
| UPI debit | 16 | 16 | 16 |
| UPI credit | 3 | 3 | 3 |
| NEFT/IMPS/RTGS | 11 | 10 | 11 |
| Card pmt rcvd | 18 | 17 | 18 |
| Statement/due | 16 | 5 | 16 |
| Limit change | 16 | 14 | 16 |
| Reward pts | 17 | 17 | 17 |
| EMI | 17 | 13 | 16 |
| SIP/MF | 6 | 2 | 6 |
| Insurance | 11 | 0 | 11 |
| Utility/telecom | 14 | 1 | 13 |
| Fuel | 4 | 2 | 2 |
| Travel | 5 | 1 | 4 |
| Wallet/UPI app/gateway | 18 | 2 | 17 |
| Cashback | 6 | 5 | 5 |
| Refund | 6 | 3 | 3 |
| Broker | 7 | 7 | 7 |

Before this lane the generic cross-issuer rules already covered account debit and credit, UPI, rewards and most card spends for the registered banks. The gaps were statements and dues (11 of 16 cells missing), insurance (all 11), utilities and telecom (13 of 14), wallets, UPI apps and gateways (16 of 18), and a handful of card, ATM, EMI, SIP and limit wordings.

Per issuer or service:

**Private banks**

| Issuer | Spend | ATM | AcDr | AcCr | UPIDr | UPICr | Rails | CardPmt | Stmt | Limit | Reward | EMI | Refd | Cash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| HDFC | Y | Y | Y |  | Y | Y |  | Y | Y | Y | Y | N>Y | N | Y |
| ICICI | Y |  | Y |  |  |  |  | Y | N>Y | Y | Y | Y | Y |  |
| Axis | Y |  | Y |  |  |  |  | Y | N>Y | Y | Y | N | Y |  |
| Kotak | Y | Y |  | Y |  |  | Y | Y | Y | Y | Y | N>Y | Y |  |
| IDFC FIRST | Y | Y |  | Y | Y | Y | Y | Y | N>Y | N>Y | Y | Y | N |  |
| YES | Y | Y |  | Y | Y |  | Y | Y |  | Y | Y | Y |  |  |
| IndusInd | Y |  |  | Y | Y |  | Y | Y | N>Y | N>Y | Y | Y |  |  |
| RBL | Y |  |  | Y | Y |  |  | Y | Y | Y | Y | Y |  |  |
| Federal | Y | Y |  | Y | Y |  | Y | Y | N>Y | Y | Y | Y |  |  |
| Bandhan | Y |  |  | Y |  |  |  |  |  |  |  |  |  |  |
| DCB | Y |  |  | Y |  |  |  |  |  |  |  |  |  |  |
| South Indian |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Karur Vysya |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Tamilnad Mercantile |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |

**Public sector banks**

| Issuer | Spend | ATM | AcDr | AcCr | UPIDr | UPICr | Rails | CardPmt | Stmt | Limit | Reward | EMI | Refd | Cash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| SBI | Y | N>Y | Y |  | Y |  | Y | Y | Y | Y | Y | Y | N |  |
| PNB | Y | Y |  |  | Y |  | Y | Y | N>Y | Y | Y | Y |  |  |
| Bank of Baroda | Y |  |  |  | Y |  | N>Y | Y | N>Y | Y | Y | Y |  |  |
| Canara |  | N>Y |  |  | Y | Y | Y |  |  |  |  |  |  |  |
| Union |  | Y | Y | Y | Y |  | Y |  |  |  |  |  |  |  |
| Bank of India |  | Y | Y | Y | Y |  |  |  |  |  |  |  |  |  |
| Indian Overseas |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| Indian Bank |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| Central Bank |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| Bank of Maharashtra |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| J&K |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| UCO |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Punjab and Sind |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |

**Small finance, payments banks, co-operative, fintech cards**

| Issuer | Spend | ATM | AcDr | AcCr | UPIDr | UPICr | Rails | CardPmt | Stmt | Limit | Reward | EMI | Refd | Cash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AU | Y |  |  | Y | Y |  |  | Y | N>Y | Y | Y | Y |  |  |
| Equitas | Y |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| Ujjivan | Y |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| Jana |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| ESAF |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Utkarsh |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Paytm Payments Bank |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Airtel Payments Bank |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| NSDL Payments Bank |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Fi (Federal) |  |  | Y |  |  |  |  |  |  |  |  |  |  |  |
| Co-operative style |  |  | Y | Y |  |  |  |  |  |  |  |  |  |  |
| slice | Y |  |  |  |  |  |  |  |  |  |  |  |  |  |
| OneCard | N>Y |  |  |  |  |  |  | N>Y |  |  |  |  |  |  |

**Foreign banks and card networks**

| Issuer | Spend | ATM | AcDr | AcCr | UPIDr | UPICr | Rails | CardPmt | Stmt | Limit | Reward | EMI | Refd | Cash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard Chartered | Y |  |  | Y | Y |  | Y | Y | N>Y | Y | Y | Y |  |  |
| HSBC | Y |  |  | Y | Y |  |  | Y | Y | Y | Y | Y |  |  |
| Citi | Y |  |  | Y |  |  |  | Y | N>Y | Y | Y | Y |  |  |
| American Express | Y |  |  |  |  |  |  | Y | N>Y |  | Y |  |  |  |

**Billers, insurers, telcos, fuel, travel, wallets, UPI apps, gateways, SIP and brokers**

| Service | Message kind | Before | After |
| --- | --- | --- | --- |
| BESCOM electricity | Utility/telecom | gap | covered |
| Tata Power | Utility/telecom | gap | covered |
| Adani Electricity | Utility/telecom | gap | covered |
| MSEDCL | Utility/telecom | gap | covered |
| MGL piped gas | Utility/telecom | gap | covered |
| IGL piped gas | Utility/telecom | gap | covered |
| Water board | Utility/telecom | gap | covered |
| Jio postpaid and recharge | Utility/telecom | gap | covered |
| Airtel postpaid, fibre and recharge | Utility/telecom | gap | covered |
| Vi postpaid | Utility/telecom | gap | covered |
| BSNL landline | Utility/telecom | gap | covered |
| ACT Fibernet | Utility/telecom | covered | covered |
| Tata Play DTH | Utility/telecom | gap | gap |
| FASTag toll | Utility/telecom | gap | covered |
| LIC | Insurance | gap | covered |
| HDFC ERGO | Insurance | gap | covered |
| Star Health | Insurance | gap | covered |
| ICICI Lombard | Insurance | gap | covered |
| Bajaj Allianz and Bajaj Finance | EMI | gap | covered |
| Bajaj Allianz and Bajaj Finance | Insurance | gap | covered |
| SBI Life | Insurance | gap | covered |
| HDFC Life | Insurance | gap | covered |
| ICICI Prudential Life | Insurance | gap | covered |
| Max Life | Insurance | gap | covered |
| Niva Bupa | Insurance | gap | covered |
| Acko | Insurance | gap | covered |
| HP Pay | Fuel | gap | gap |
| Bharat Pay fuel wallet | Fuel | gap | gap |
| BPCL pump over UPI | Fuel | covered | covered |
| IRCTC | Travel | gap | covered |
| MakeMyTrip | Travel | gap | covered |
| redBus | Travel | gap | covered |
| Uber | Travel | gap | gap |
| Airline bought by card | Travel | covered | covered |
| Paytm | Cashback | covered | covered |
| Paytm | Wallet/UPI app/gateway | covered | covered |
| PhonePe | Cashback | covered | covered |
| PhonePe | Wallet/UPI app/gateway | gap | covered |
| Google Pay | Cashback | gap | gap |
| Google Pay | UPI debit | covered | covered |
| Google Pay | Wallet/UPI app/gateway | gap | covered |
| Amazon Pay | Cashback | covered | covered |
| Amazon Pay | Wallet/UPI app/gateway | gap | covered |
| CRED | Cashback | covered | covered |
| CRED | Wallet/UPI app/gateway | gap | covered |
| BHIM | Wallet/UPI app/gateway | gap | covered |
| MobiKwik | Wallet/UPI app/gateway | covered | covered |
| Freecharge | Wallet/UPI app/gateway | gap | covered |
| Razorpay | Wallet/UPI app/gateway | gap | covered |
| PayU | Wallet/UPI app/gateway | gap | covered |
| Cashfree | Wallet/UPI app/gateway | gap | covered |
| CCAvenue | Wallet/UPI app/gateway | gap | covered |
| BillDesk | Wallet/UPI app/gateway | gap | covered |
| PayPal | Wallet/UPI app/gateway | gap | gap |
| JioFinance | Wallet/UPI app/gateway | gap | covered |
| super.money | Wallet/UPI app/gateway | gap | covered |
| Navi | Wallet/UPI app/gateway | gap | covered |
| Ola Money | Wallet/UPI app/gateway | gap | covered |
| Groww SIP | Broker | covered | covered |
| Groww SIP | SIP/MF | gap | covered |
| Upstox SIP | Broker | covered | covered |
| Upstox SIP | SIP/MF | gap | covered |
| SBI Mutual Fund | SIP/MF | covered | covered |
| CAMS | SIP/MF | gap | covered |
| Zerodha Coin | SIP/MF | covered | covered |
| Bank debit for a SIP | SIP/MF | gap | covered |
| ICICI Direct | Broker | covered | covered |
| HDFC Securities | Broker | covered | covered |
| 5paisa | Broker | covered | covered |
| Angel One | Broker | covered | covered |

The refund and cashback columns and the broker rows belong to the refunds, brokers and money-in lanes; they are shown to record the audit, and Lane Q wrote no rule for them (the requests file lists what was found).

## Still not covered (and why)

- Refunds for SBI card, SBI account and IDFC card wording, broker payouts and withdrawals, and the broker top-up credit that reads as a withdrawal: owned by the refunds and brokers lanes. Details in `docs/sms-pipeline-v2/requests/LANE-Q-generalisation.md`.
- Axis "EMI/LOAN" debit wording, card EMI conversion notices, Fuel wallets (HP Pay, Bharat Pay), Uber receipts, Google Pay rewards, PayPal, DTH low-balance nudges. Rare or not money movement; they stay in review.
- Issuer on unregistered senders: Equitas, Ujjivan, Jana, ESAF, Utkarsh, Indian Bank, Punjab and Sind, payments banks, co-operative banks, OneCard and the billers, travel, gateway and app handles. Their messages are captured by the generic rules, but with no `issuerSlug`. The request file lists the candidate handles (unverified).

## Verification (all run from the worktree)

| Check | Result |
| --- | --- |
| `dart run bin/sms_rules.dart lint --rules ../../rules/sms/v2` (in `tools/sms_rules_cli`) | clean |
| `dart run bin/sms_rules.dart build --rules ../../rules/sms/v2 --bundle-version 0 --out ...` | 896 rules, 1,850 examples OK |
| `dart run tool/check_pipeline.dart` | golden ok: 183 of 183 cases and 15 of 15 scenarios, every metric at 1.0 except ask rate 0.0066 (was 0.0114) |
| `node test/regex_parity.mjs` | 55,500 comparisons, 0 mismatches |
| `packages/pandapay_domain` `dart test` | 1,029 pass |
| `tools/sms_rules_cli` `dart test` | 40 pass, 1 fails: `shared_golden_parity_test.dart` hard-codes 115 cases (see the request file; the CLI and browser results agree) |
| No existing golden case or rule example changed result | confirmed by the comparison run above |

## Requests filed

`docs/sms-pipeline-v2/requests/LANE-Q-generalisation.md`: sender registration (with the wildcard rules that depend on it), the hard-coded 115 in the parity test and the derived asset copies to refresh at merge, and findings for the banks, brokers, refunds and noise lanes.
