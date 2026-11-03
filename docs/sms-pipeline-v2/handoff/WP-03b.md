# WP-03b handoff: Wallets and UPI apps

Branch `sms-v2/wp-03b-wallets` (from `sms-v2/main`). Data only: no engine, contract or Dart change. Owned paths written: `rules/sms/v2/wallets/*.json`, `rules/sms/v2/senders/wallets.json`, `rules/sms/v2/counterparty_purposes.json`.

## What was built

- **98 rules, 199 examples** (each rule has at least 1 positive and 1 near-miss negative) in `rules/sms/v2/wallets/`: `paytm`, `phonepe`, `mobikwik`, `freecharge`, `zomato_money`, `pluxee`, `amazonpay`, `tinymart`, `bill_pay_apps`, `generic` (`.json`). Ids are `WAL-<WALLET>-<KIND>-<nn>`.
- **12 senders** in `senders/wallets.json`: PAYTM (aliases PYTM, IPAYTM), PHONPE, AMAZON (`walletSpendVisibility: partial`), ZOMATO, PLUXEE (alias SODEXO), MOBIKW, FRCHRG, TINYMT (all other wallets `sms`), gateways JUSPAY and PINELB, and TATNEU and PAYZPP (bill-pay apps, `issuerKind: other`).
- **13 counterparty purposes** in `counterparty_purposes.json`: wallet top-ups (Paytm, PhonePe, MobiKwik, Freecharge, Zomato Money, Pluxee, Amazon Pay) and card-bill payees (CRED, CHEQ incl. "CHEQ DIGITAL PRI", BBPS/BillDesk card billers, "<bank> credit card" payees, SBI Card/Amex payees, Tata Neu/PayZapp bill pay).

### Rule shapes per wallet (priority bands)

| Band | Rules |
| --- | --- |
| 750 | `FAILED-01/02`: payment or add-money failed, as `attempt` (failed) |
| 700-800 | `CASHBACK-01` (credit, `cashback`), `REFUND-01` (credit, `refund`), Pluxee `FEE-01/02` (debit, `fee`), Pluxee `SPEND-01/02` |
| 600-640 | spend with a printed balance: `DEBIT-01`, `PAID-01`, `PAID-03`, gateway `GATEWAY-01` (movement debit `purchase` + `balance_snapshot`) |
| 440-580 | the same shapes without a balance, plus `LOAD-01/02` (credit, `wallet_topup`, + balance when printed) |
| 55-200 | `generic`: named-wallet debit/load (`senders: ["*"]`, issuer from the text) and last-resort unnamed wallet debit/load (`purpose` unknown/`wallet_topup`, confidence 0.6-0.75) |

Wording shapes covered: "debited/deducted/spent/charged from X", "paid from/using/via X [to M]", "Paid Rs N to M using X", "added/loaded/credited to X", cashback and refund credited, failed payment/top-up. `ref_txnId`, `ref_orderId` (Zomato) and `ref_upiRef` are captured with lookaheads, so order of the reference and balance in the text does not matter.

### Product decisions as implemented

- **Amazon Pay (partial).** Balance payments (`AMAZON`, `JUSPAY`, `PINELB` senders; issuer `amazonpay` is set explicitly) emit `movement` debit `purchase` with `evidenceOnly: true` plus `balance_snapshot`. A refund to the balance is also `evidenceOnly`. Cashback to the balance is a normal `cashback` credit. The top-up side is `CPP-AMAZONPAY-TOPUP` (VPA `amazonpay@…`, names starting "AMAZON PAY WALL" or "AMAZON PAY IN E") which sets `wallet_topup` and `counterparty.kind = own`; WP-05/06 must turn a `wallet_topup` into an Amazon `purchase` because the sender is `partial` (see Follow-ups). "AMAZON PAY IN" alone (the ICICI golden) is deliberately not matched, so it stays a purchase.
- **Zomato Money, Pluxee, Paytm (sms).** Each purchase is a `purchase` debit; loads are `wallet_topup` credits (transfers). Loads containing cashback, refund, reward, bonus, gift, promo or compensation are refused by the load rules (cashback/refund rules take their own wording; the rest goes to review).
- **Card-bill payments.** CRED, CHEQ, BBPS/BillDesk card billers, "<bank> credit card" payees, SBI Card/Amex payees and Tata Neu/PayZapp bill pay get `card_payment` with `counterparty.kind = own` (CPP only replaces `unknown`, `p2p`, `purchase`, `transfer`). Tata Neu/PayZapp "bill payment of … is successful" app receipts are `evidenceOnly` movements (no instrument): `card_payment` when the biller says "credit card", otherwise `bill_payment`.
- **TinyMart** store-account payments: `evidenceOnly` purchase receipts.
- **Pluxee** fees ("convenience/service/processing fee deducted") are `purpose: fee`.

## Results

- `lint`: clean. `build`: 98 rules, 12 senders, 199 examples OK. Node/Dart regex parity (`node tools/sms_rules_cli/test/regex_parity.mjs rules/sms/v2`): 199 comparisons, 0 mismatches.
- `golden` (82 cases) with 03b's bundle: every wallet case passes: `probe:amazon_pay_balance_spend`, `probe:amazon_pay_cashback`, `probe:paytm_wallet_spend`, `probe:zomato_money_spend` (all 100% kind, amount, instrument).
- Cases that need a bank rule plus 03b's counterparty purposes: `probe:paytm_wallet_load_bank` (HDFC debit to `add-money@paytm`), `probe:cc_bill_via_cred` (ICICI "CRED Club credited"), and `local:16` ("deposited into your wallet", covered by `WAL-GEN-LOAD-LAST`). These pass when a bank rule extracts the VPA/name into `counterparty` (verified with two throwaway stub bank rules kept outside the repo). They depend on 03a extracting `counterparty.vpa` from "to VPA …" and `counterparty.name` from "…; CRED Club credited".
- Remaining wallet-family failure: `corpus:cashback_offer_only` expects an ignore rule (03d). No 03b rule matches it.
- Scenarios (`amazon_pay_topup_counts_as_spend`, `card_bill_via_cheq_no_receipt`, `wallet_topup_then_wallet_spend`) need the linker; not evaluable yet.
- All patterns were also run against 12 extra synthetic messages (loads with expiry, Zomato order id, Pluxee fee and spend, Juspay Amazon Pay, Tata Neu card receipt, MobiKwik remaining balance): all as intended.

## Old parser branches mapped to rule ids (for WP-17)

| Old code | New rules |
| --- | --- |
| `local_sms_parser.dart` `_walletLoad` (866-871), load branches (2824, 3104-3105); `sms_parser.js` `isWalletLoadMessage` (280-289), wallet_load entry (560-635, 768-790, 1178-1193) | `WAL-*-LOAD-01/02`, `WAL-GEN-LOAD-01`, `WAL-GEN-LOAD-LAST`, plus `CPP-*-TOPUP` for the bank side |
| `local_sms_parser.dart` `walletDebit`/`isWalletDebit` (2868-2938, 3020); `sms_parser.js` `parseBuiltInWalletSpend` (793-857, 859-861) | `WAL-*-DEBIT-01/02`, `WAL-*-PAID-01..04`, `WAL-PLUXEE-SPEND-*`, `WAL-GEN-DEBIT-01`, `WAL-GEN-DEBIT-LAST` |
| Wallet cashback/refund credit heuristics (`wallet|cashback`, `sms_parser.js` 670) | `WAL-*-CASHBACK-01`, `WAL-*-REFUND-01` |
| Amazon Pay Later / Axio drawdown (`local_sms_parser.dart` 2039-2084, `sms_parser.js` 910-929) | Not ported: Pay Later is 03c |
| "wallet balance is Rs 0 … add money to wallet" in the not-financial regexes | Not ported: ignore rule, 03d |
| `CHEQ CREDIT CARD REPAYMENT` merchant handling | `CPP-CHEQ`, `CPP-BANK-CREDIT-CARD` |

## Follow-ups and gaps

1. **Standalone balance snapshots are not emitted.** A `balance_snapshot` needs `asOf`, and the engine can only take it from another emit (`sameAs`) or a printed date. Wallet balance-only SMS usually has no date. Request filed: `docs/sms-pipeline-v2/requests/WP-03b-balance-asof.md` (default `asOf` to `occurredAt`, else `observedAt`). Until then wallet balances come only inside spend and load messages.
2. **Linker contract for Amazon Pay top-ups (WP-05/06).** A `wallet_topup` whose `targetInstrument` is an Amazon Pay wallet (sender `partial`) must become a `purchase` at Amazon (category online), not a transfer. If the linker only reads link rules, it needs the issuer's `walletSpendVisibility`. The scenario `amazon_pay_topup_counts_as_spend` exercises this.
3. **Round 2 real templates.** Wallet wording for PhonePe, MobiKwik, Freecharge, Pluxee, TinyMart, Tata Neu and PayZapp is built from the old parser's fixtures and the work-package list, not from the owner's labelled messages. Only Paytm, Zomato Money and Amazon Pay have golden cases. Expect wording and sender-brand corrections (for example the real brands for TinyMart, Tata Neu and PayZapp) when the real set is labelled.
4. **Possible sender overlaps with other sub-packages.** `TATNEU` (Tata Neu "bill is ready" messages are 03c's) may be defined again in `senders/billers.json`; if the orchestrator's build reports a duplicate brand, keep one entry. No CRED or CHEQ sender is defined here (bank debits only; CRED reminders are 03c).
5. **Speculative card-payment payees.** `CPP-BILLPAY-APP-CARD` (Tata Neu/PayZapp "bill pay" names and VPAs) follows the product decision literally and would also treat a non-card bill paid through those apps as a card payment. It is the first pattern to tighten once real bank-side payee names are seen.
6. **Wallet instruments have no mask** (except Pluxee, where the printed card digits are kept). Wallet identity is `(wallet, issuerSlug)`.
