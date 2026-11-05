# Lane Q requests: sender registration, a hard-coded golden count, and findings for other lanes

Lane Q (generalise the rules beyond one user's banks) owns only `rules/sms/v2/generalization/` and new synthetic cases under `tools/sms_golden/cases/`. It filed no change to any existing rules file, sender file, ignore rule, scorer, contract or code. Everything below needs an owner outside the lane.

## 1. Register more senders (`rules/sms/v2/senders/*.json`)

Several rules cover issuers whose sender handle is not in the registry, so they fire on `senders: ["*"]` with the issuer, app or gateway named in the pattern (the rows marked "wildcard rule" below). Registration would let those rules narrow to the real handle and would give instruments an `issuerSlug`. Today an unregistered issuer still gets the movement, but the instrument has no issuer, so it cannot be discovered as a new account or card (the golden instrument test shows `got []` for such cases).

**Every handle below is a guess** from how TRAI headers are usually built (6 letters, the brand). Confirm each against real header data before registering. Nothing here comes from private messages.

| Candidate brand | Suggested slug and kind | Why it matters |
| --- | --- | --- |
| EQTBNK | equitas, bank | small finance bank, account and debit card alerts |
| UJJVNB | ujjivan, bank | small finance bank |
| JANASF | jana, bank | small finance bank |
| ESAFSF | esaf, bank | small finance bank |
| UTKSFB | utkarsh, bank | small finance bank |
| INDIAN | indian_bank, bank | public sector. Note: the registry maps INDBNK to indusind; check that this is not Indian Bank's handle |
| PSBANK | psb, bank | Punjab and Sind Bank |
| PAYTMB, AIRBNK, NSDLPB | paytm_payments_bank, airtel_payments_bank, nsdl_payments_bank | payments banks |
| SARASW, COSMOS | saraswat, cosmos, bank | co-operative bank style alerts ("Dear Member") |
| ONECRD | onecard, bank (card only) | card spend and payment received |
| ADANIE, IGLGAS, BWSSBS | adani_electricity, igl, bwssb | utility bills |
| TATASK | tata_play | DTH |
| HPCLPY | hp_pay | fuel |
| IRCTCI, MMYTRP, REDBUS, UBERIN | irctc, makemytrip, redbus, uber | travel receipts (wildcard rule `GENZ-TRAVEL-BOOKING-CONFIRMED`) |
| IDFCFT and other FASTag issuer handles | fastag | toll alerts (wildcard rule `GENZ-FASTAG-TOLL-DEDUCTED`) |
| BAJAJA, SBILIF, HDFCLF, ICIPRU, MAXLIF, NIVABP, ACKOIN | bajaj_allianz, sbi_life, hdfc_life, icici_prudential_life, max_life, niva_bupa, acko | insurance premium alerts. `ICICIP` is already registered as `icici_prudential_mf`; a life-insurance handle needs a different brand |
| RZRPAY, PAYUMN, CSHFRE, CCAVNU, BILDSK | razorpay, payu, cashfree, ccavenue, billdesk | gateway receipts (wildcard rule `GENZ-GATEWAY-PAYMENT-SUCCESS`) |
| BHIMUP, JIOFIN, SUPRMN, NAVIUP, OLAMNY | bhim, jiofinance, super_money, navi, ola_money | UPI apps (wildcard rules `GENZ-UPIAPP-OTHER-PAID-PAYFIRST` and `-AMTFIRST`) |

Wildcard rules (all anchored, all evidence-only or bill-due, never a counted movement): `GENZ-UPIAPP-OTHER-PAID-PAYFIRST`, `GENZ-UPIAPP-OTHER-PAID-AMTFIRST` (need an app name in the text), `GENZ-GATEWAY-PAYMENT-SUCCESS` (needs a gateway name), `GENZ-TRAVEL-BOOKING-CONFIRMED` (needs a travel word, a booking word and an amount paid), `GENZ-FASTAG-TOLL-DEDUCTED` (needs "FASTag" and "toll"). The bill, insurance, telecom and EMI-receipt rules also use `*` because biller handles vary; they match the baseline bill rules, which do the same.

## 2. Hard-coded golden count (tools/sms_rules_cli test)

`tools/sms_rules_cli/test/shared_golden_parity_test.dart` line 39 has `expect(browser.casesPassed, 115);`. Adding any golden case breaks it, so every lane that adds cases will hit this at merge. Lane Q adds 68 cases (115 to 183). Suggested change: compare with `golden.cases.length`, or update the constant once at merge. It is the only failing test in `tools/sms_rules_cli` (`dart test`: 40 pass, 1 fails on that count; the Dart-versus-browser metrics themselves agree).

After merge the orchestrator also needs to refresh the derived copies of the case set (`console/assets/sms_golden/bundle.json` through `api/scripts/sync_sms_v2_assets.js`) and the baseline bundle.

## 3. Findings for other lanes (no change made)

Seen while probing. Each is existing behaviour that Lane Q could not edit.

- **Bank of Baroda IMPS credit read as UPI.** `BOB-UPI-CREDIT-B` (priority 763) matches "Rs.x Cr. to A/c N by IMPS ... Ref:<12 digits>" and returns `rail: upi, purpose: p2p`. The new `GENZ-ACCT-CR-ABBREV-IMPS` rule never wins for BOBSMS because of it. A BoB IMPS credit with a 12-digit reference is ambiguous in real data; the owner of the BoB rules should decide.
- **Brokers (brokers lane).** `INV-BROKER-WITHDRAW-CREDIT-02` matches "Rs x credited to your ICICI Direct / HDFC Securities / Kotak Securities trading account" and returns a credit with purpose investment, instrument kind `bank_account` for the broker issuer with no mask. A credit to a trading account is more likely a top-up confirmation. Zerodha and Groww "withdrawal initiated / payout" wording is UNKNOWN in the bundle.
- **Refunds (refunds lane).** UNKNOWN today: SBI card "refund received on your SBI Card ending N from MERCHANT", SBI account "refund from MERCHANT credited to A/c N", IDFC "refund from MERCHANT has been credited to your credit card". `GEN-REFUND-NOMASK` turns "Refund of Rs x ... will be credited within 5-7 working days" into a credit movement; a future refund is not money moved.
- **Account debit with "failed".** "Rs x debited from A/c N on DATE towards SIP in FUND failed. Retry." is read by `GEN-ACCT-LAST-D1` as a debit movement because "failed" follows the amount and account.
- **Axis EMI.** "INR x debited A/c no. XX567890 DATE EMI/LOAN1234 Axis Bank" falls to `GEN-NOMASK-DEBIT-LAST` (no mask, purpose unknown); `AXIS-ACCT-DEBIT-*` has no EMI shape.
- **Not covered, deliberately.** Fuel wallets (HP Pay, Bharat Pay), Uber receipts, Google Pay rewards, PayPal, card EMI conversion notices, DTH low-balance nudges. They are rare in SMS or not money movement; left to review.
- **Past-due and offers.** No ignore-rule change is needed: the offer and nudge probes (cashback offers, limit offers, FASTag low balance, reward expiry) already land on ignore rules.
