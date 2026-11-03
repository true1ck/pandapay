# WP-03a handoff: bank rules

Branch `sms-v2/wp-03a-banks` (merged with `sms-v2/main` after WP-02, 03b and 03c). Synthetic data only. No engine, contract or Dart file was touched.

## What was built

| Path | Content |
| --- | --- |
| `rules/sms/v2/senders/banks.json` | 90 sender entries, 36 issuer slugs (hdfc, icici, sbi, axis, kotak, idfc, yes, indusind, pnb, bob, canara, union, federal, au, rbl, sc, hsbc, citi, amex, plus indiapost, uco, iob, boi, cbi, bom, idbi, kvb, sib, tmb, csb, dcb, bandhan, jkb, karnataka, dbs, slice). One entry per sender brand, no aliases, so other work packages can list any brand in a rule. |
| `rules/sms/v2/banks/<issuer>.json` | Issuer-exact templates (priority 700-780): hdfc 44, icici 39, sbi 20, axis 21, kotak 8, idfc 5, yes 4, indusind 3, pnb 4, bob 4, canara 5, union 4, federal 2, au 2, rbl 2, sc 2, hsbc 2, citi 2, amex 2. |
| `rules/sms/v2/banks/others.json` | 259 rules. Cross-issuer generic rules (`senders: ["*"]`, priority 40-330) and the India Post rules. |

Most rules come in pairs: a `-B` rule (priority +5) that also emits the balance or available-credit snapshot, and a plain rule. Every rule has at least one positive and one near-miss negative example (declined, failed, "will be", "could not be").

### Families covered

- **Card spends** with kind from the wording (`Credit Card` or an `Avl Limit` part gives `credit_card` plus an `available_credit` snapshot, `Debit Card` gives `debit_card`, plain "Card" leaves the kind empty so the instrument resolver matches by issuer and mask). Seven word orders: `GEN-CARD-SPEND-AT/-DATE/-MERCHFIRST/-SPENTFIRST/-ENDING/-BARE`, `GEN-CARD-DEBITED`, `GEN-CARD-WASDEBITED`.
- **Foreign spends**: only when the INR amount is printed (`GEN-CARD-FOREIGN-APPROX`, `GEN-CARD-FOREIGN-BILLED`).
- **Account debits and credits** (`GEN-ACCT-<tail>-D1/D2/C1/C2[-B]`): amount-first (D1/C1) and account-first (D2/C2) wording, each with tails for card bill, ATM, cheque, own transfer, transfer to an account mask, IMPS/NEFT/RTGS, UPI (VPA, numeric VPA, `UPI/ref/name`, P2M, "by UPI:", "via UPI/PhonePe"), fee, EMI, merchant, payee, and last resort (purpose `unknown`, confidence 0.6).
- **Credits**: salary (NEFT and any), interest, refund, reversal, rail-from-payer, UPI from VPA, from name.
- **Refunds and reversals** to account or card (`GEN-REFUND-*`, `GEN-REVERSAL-*`), **card payment received** (`GEN-CARD-PAYMENT-RECEIVED`, `-CREDITED`, `GEN-CARD-AMOUNT-RECEIVED`), bank side of a card bill (`GEN-ACCT-CARDBILL-*`, `GEN-ACCT-CARDBILL-PRE-D1`, `GEN-CARDBILL-NOACCT`), **card ATM** and **card fees**.
- **Attempts**: declined and failed on card or account, failed and pending credits, pending refunds (`GEN-CARD-DECLINED/FAILED[-WORDFIRST]`, `GEN-ACCT-DECLINED/FAILED`, `GEN-CREDIT-FAILED/PENDING`, `GEN-REFUND-PENDING`).
- **Balance only** (`GEN-BALANCE-ASOF`, `GEN-BALANCE-ASOF-CARD`; undated ones rely on WP-02's `asOf` default).
- **Issuer exact**: HDFC (UPI "Sent ... From ... To", old "debited from a/c ... to VPA", a/c to a/c, NEFT/IMPS/RTGS "Update! ... deposited", BillPay, IMPS self, Money Transfer), ICICI (card "spent using/on", "Acct ... debited ...; X credited", `Info:` forms for BIL*, ATM, UPI, NEFT/IMPS/RTGS, salary, interest, BBPS card payment), SBI (UPI "trf to", UPI credit, hyphen forms, YONO UPI, NEFT/IMPS/RTGS credit, SBI Card spend and payment), Axis (all multi-line account forms, multi-line card spend, card payment, bank side of card bill), Kotak (Sent, Received, "transferred to your account"), and a few templates each for IDFC, Yes (including "amount received on your card"), IndusInd, PNB, BoB, Canara, Union, Federal, AU, RBL, SC, HSBC, Citi, Amex, India Post.

### Counterparty fields (requested by 03b)

- `counterparty.vpa` is set from "to VPA ..." / "to x@y" in every UPI debit rule (`GEN-ACCT-UPI-VPA-*`, `HDFC-UPI-DEBIT-VPA`, `HDFC-UPI-SENT-VPA`, `KOTAK-UPI-SENT`, ...).
- `counterparty.name` is set from "...; CRED Club credited" (`ICICI-ACCT-DEBIT-UPI`) and from every named-payee form (SBI "trf to", HDFC "To", Axis `UPI/P2M/ref/name`). The purpose is `purchase` or `p2p`, so 03b's `counterpartyPurposes` can replace it with `wallet_topup` or `card_payment` (checked on the merged bundle: Paytm add-money, CRED, CHEQ).

## Results

- `lint` on the merged `rules/sms/v2`: clean (no shadowing against 03b/03c; 03c's 800-850 IPO/broker rules sit above mine).
- `build`: 696 rules, 146 senders, 1,442 examples, all agree with the engine.
- `golden` (82 cases, merged rules, no 03d yet): 69 cases fully pass. Per family: debit, credit, card_spend, card_payment, refund_reversal, salary_income, failed_declined, balance, investment, ipo, wallet: 100% event kind, amount, instrument. The 13 remaining failures all belong to others: 03d (ignore rules x7, limit_change, reward x2, cashback) and 03c (`corpus:autopay_failed`, an attempt with no amount).

## Decisions and deviations

1. **Rules that moved to other work packages.** To avoid shadowing 03c, I dropped my own broker-payee and dividend rules (UPI debits and NEFT credits to/from brokers, NACH dividends). 03c's `INV-BROKER-*` and dividend rules cover them (checked: SBI "trf to UPSTOX SECURITIE" gives purpose investment). `GEN-WALLET-DEPOSIT` was dropped for 03b's `WAL-GEN-LOAD-*`.
2. **Hand-off words.** Payee-style generic rules (UPI, merchant, to-name, for-merchant) have `rejectAny` for mandate/AutoPay/UMRN/IPO/ASBA/SIP/mutual fund/e-NACH and broker names, so those messages reach 03c's rules or the last-resort review rule, never a wrong `purchase`.
3. **UPI debit purpose.** `purchase` by default, `p2p` for P2A/P2P markers, phone-number VPAs, SBI "trf to" (per the golden case), Union "Fvg:" and ICICI honorific payees. Credits from a person or VPA are `p2p`. Salary needs the word salary/payroll/wages. Cheque debit is `purchase` (per scenarios).
4. **Foreign spends** record the billed INR only; the foreign amount cannot be stored because emits have no `original` field. USD-only messages are not matched and become review items. A request to WP-02 for `original` support is the follow-up.
5. **Merchant names** use `sanitizeNarration`, which turns "AMAZON PAY IN" into "AMAZON PAY" (it strips a trailing " IN"). 03d's alias for "AMAZON PAY IN" must match the sanitized form.
6. **Amex spend** has no `occurredAt` (the date is written with a full month name, which `parseDate` cannot read).
7. **Debit-card spends** do not emit a balance snapshot (the balance belongs to the linked account, not the card).
8. Plain "ICICI Bank Card" is `credit_card` (golden `local:01`); other issuers' plain "Card" leaves the kind empty.

## Known gaps

- **Templates not seen on real data.** Everything beyond the golden cases and the old parser's fixtures is written from known bank wording. Least certain: IDFC, Yes, IndusInd, PNB, BoB, Union, Federal, AU, RBL, SC, HSBC, Citi, India Post, the Kotak "transferred to your account" form, the ICICI `Info:` forms, SBI "has a credit by TRANSFER" style (not written), SBI NACH dividend credits, and several sender brand ids (for example `HDFCCC`, `KMBANK`, `UBOI`, `SLICEB`). Verify in round 2 with the owner's labeled templates.
- No rule for: SBI "has a credit/debit by" old style, A/c linked to card ATM form ("linked to card XXXX debited ... ATM txn"), Union/Canara ATM, debit card POS with `Info:`, UCO "credited ... towards EMI" (loan repayment received), forex mark-up fee messages, cheque deposits and returns, standing-instruction debits (03c).
- **Old parser mapping.** Old branches map to families, not to one rule each: `local_sms_parser.dart` / `sms_parser.js` card-spend branches -> `GEN-CARD-SPEND-*`, `GEN-CARD-DEBITED`, `GEN-CARD-WASDEBITED`; UPI/NEFT/IMPS/RTGS debit branches -> `GEN-ACCT-UPI-*`, `GEN-ACCT-RAIL-*`; credit/salary/interest/dividend-less branches -> `GEN-ACCT-*-C1/C2`, `GEN-ACCT-SALARY*`, `GEN-ACCT-INTEREST*`; refund and reversal branches -> `GEN-REFUND-*`, `GEN-REVERSAL-*`; card payment branches -> `GEN-CARD-PAYMENT-*`, `GEN-ACCT-CARDBILL-*`; ATM -> `GEN-CARD-ATM-*`, `GEN-ACCT-ATM-*`; declined/failed -> `GEN-*-DECLINED/FAILED`; balance -> `GEN-BALANCE-*`; fees and EMI debits -> `GEN-ACCT-FEE*`, `GEN-ACCT-EMI-*`, `GEN-CARD-FEE-*`. Old wallet, IPO, broker, mandate, bill and reward branches are in 03b/03c/03d.
- Rules were generated with a throwaway script kept outside the repo; the JSON files are the source of truth and can be edited by hand.
- Overlap with 03d not yet checked: its ignore rules run before all rules, so run `lint` once 03d merges (my examples are bank movements, none is a promotion or OTP).
