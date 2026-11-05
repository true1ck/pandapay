# Foreign-currency rules: notes

The rule schema has no description field, so the purpose of each rule lives here. All wording is a best-effort generalisation of how Indian banks and card issuers phrase foreign-currency card alerts; every example is synthetic. See `docs/sms-pipeline-v2/requests/CCR-004-foreign-amounts.md` and `docs/sms-pipeline-v2/foreign-payments-v2.md`.

Two shapes, never mixed:

- **Foreign only** (`FX-SPEND-*`, `FX-REFUND-FOREIGN-*`, `FX-REVERSAL-FOREIGN-*`): the message prints only the foreign price. The posted amount is `{minor, unit: <currency>}`. It is never INR spend and never reaches the ledger.
- **INR with original** (`FX-INR-*`, `FX-REFUND-INR-*`, `FX-REVERSAL-INR-*`, and the card-spend-foreign rules that print an INR figure): the posted INR amount carries `original: {minor, currency}`.

A rule fires only when a currency token (a code, `US$`, `$`, `€`, `£`) sits directly beside a number. A bare `$` or `¥` is written as unit `XXX` (currency not stated). Declined, failed, pre-authorisation and verification wording is rejected. Each family has a credit card, debit card and plain card variant, and a `-LIM` variant that also reads an "Avl Lmt" INR balance.

| Rule | Family | Priority | What it matches |
| --- | --- | --- | --- |
| FX-SPEND-SPENT-FIRST-CR | card_spend_foreign | 332 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-SPENT-FIRST-CR-LIM | card_spend_foreign | 342 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-SPENT-FIRST-DB | card_spend_foreign | 331 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-SPENT-FIRST-DB-LIM | card_spend_foreign | 341 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-SPENT-FIRST-NONE | card_spend_foreign | 330 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-SPENT-FIRST-NONE-LIM | card_spend_foreign | 340 | Foreign-currency card spend worded "Spent USD 20.00 on <bank> Card xNNNN at MERCHANT". No INR is printed, so the amount is kept in its own currency and nothing is converted or counted. |
| FX-SPEND-AMT-FIRST-CR | card_spend_foreign | 332 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-AMT-FIRST-CR-LIM | card_spend_foreign | 342 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-AMT-FIRST-DB | card_spend_foreign | 331 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-AMT-FIRST-DB-LIM | card_spend_foreign | 341 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-AMT-FIRST-NONE | card_spend_foreign | 330 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-AMT-FIRST-NONE-LIM | card_spend_foreign | 340 | Foreign-currency card spend worded "USD 20.00 spent using <bank> Card xNNNN at MERCHANT" (amount first). No INR printed. |
| FX-SPEND-TXN-OF-CR | card_spend_foreign | 332 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-TXN-OF-CR-LIM | card_spend_foreign | 342 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-TXN-OF-DB | card_spend_foreign | 331 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-TXN-OF-DB-LIM | card_spend_foreign | 341 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-TXN-OF-NONE | card_spend_foreign | 330 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-TXN-OF-NONE-LIM | card_spend_foreign | 340 | Foreign-currency card transaction worded "Transaction of EUR 15.50 done on <bank> Card xNNNN at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-CR | card_spend_foreign | 332 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-CR-LIM | card_spend_foreign | 342 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-DB | card_spend_foreign | 331 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-DB-LIM | card_spend_foreign | 341 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-NONE | card_spend_foreign | 330 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-SPEND-USED-FOR-NONE-LIM | card_spend_foreign | 340 | Foreign-currency card use worded "<card> has been used for GBP 9.99 at MERCHANT". No INR printed. |
| FX-INR-PAREN-SF-CR | card_spend_foreign | 907 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-PAREN-SF-CR-LIM | card_spend_foreign | 917 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-PAREN-SF-DB | card_spend_foreign | 906 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-PAREN-SF-DB-LIM | card_spend_foreign | 916 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-PAREN-SF-NONE | card_spend_foreign | 905 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-PAREN-SF-NONE-LIM | card_spend_foreign | 915 | Card spend worded "Spent Rs.x on <bank> Card xNNNN at MERCHANT (USD 20.00)": INR posted first, the foreign amount in brackets as the original. |
| FX-INR-LABEL-SF-CR | card_spend_foreign | 907 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-LABEL-SF-CR-LIM | card_spend_foreign | 917 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-LABEL-SF-DB | card_spend_foreign | 906 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-LABEL-SF-DB-LIM | card_spend_foreign | 916 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-LABEL-SF-NONE | card_spend_foreign | 905 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-LABEL-SF-NONE-LIM | card_spend_foreign | 915 | Card spend worded "Spent Rs.x on <bank> Card ..." followed by a labelled foreign amount. A markup printed as a separate INR figure is never added. |
| FX-INR-PAREN-CR | card_spend_foreign | 907 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-PAREN-CR-LIM | card_spend_foreign | 917 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-PAREN-DB | card_spend_foreign | 906 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-PAREN-DB-LIM | card_spend_foreign | 916 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-PAREN-NONE | card_spend_foreign | 905 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-PAREN-NONE-LIM | card_spend_foreign | 915 | Card spend that prints the INR posted and the foreign amount in brackets. The INR is the amount; the foreign amount rides along as the original. |
| FX-INR-LABEL-CR | card_spend_foreign | 907 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-INR-LABEL-CR-LIM | card_spend_foreign | 917 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-INR-LABEL-DB | card_spend_foreign | 906 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-INR-LABEL-DB-LIM | card_spend_foreign | 916 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-INR-LABEL-NONE | card_spend_foreign | 905 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-INR-LABEL-NONE-LIM | card_spend_foreign | 915 | Card spend that states the INR posted and a labelled foreign amount (foreign currency amount, original amount, converted from, DCC). A markup printed as a separate INR figure is never added to the amount. |
| FX-REFUND-FOREIGN-CR | card_refund_foreign | 912 | Foreign-currency refund credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REFUND-FOREIGN-DB | card_refund_foreign | 911 | Foreign-currency refund credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REFUND-FOREIGN-NONE | card_refund_foreign | 910 | Foreign-currency refund credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REFUND-INR-CR | card_refund_foreign | 912 | Foreign-currency refund with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |
| FX-REFUND-INR-DB | card_refund_foreign | 911 | Foreign-currency refund with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |
| FX-REFUND-INR-NONE | card_refund_foreign | 910 | Foreign-currency refund with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |
| FX-REVERSAL-FOREIGN-CR | card_refund_foreign | 912 | Foreign-currency reversal credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REVERSAL-FOREIGN-DB | card_refund_foreign | 911 | Foreign-currency reversal credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REVERSAL-FOREIGN-NONE | card_refund_foreign | 910 | Foreign-currency reversal credited to a card, no INR printed. Kept as a foreign amount, never counted as money in. |
| FX-REVERSAL-INR-CR | card_refund_foreign | 912 | Foreign-currency reversal with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |
| FX-REVERSAL-INR-DB | card_refund_foreign | 911 | Foreign-currency reversal with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |
| FX-REVERSAL-INR-NONE | card_refund_foreign | 910 | Foreign-currency reversal with the INR credited printed beside the foreign amount. INR is the amount; the foreign amount is the original. |

## ATM withdrawals, non-card debits and markup fees (`foreign_more.json`)

Same two shapes as above. Card variants are `-CR` (credit card), `-DB` (debit card), `-PP` (forex, prepaid, travel or multi-currency card, read as `prepaid_card`), `-ACCT` (bank account) and `-NONE` (a card the message does not classify). An optional transaction reference ("Ref", "Ref No", "txn ref", "RRN") is kept as `references.txnId`.

- **ATM** (`FX-ATM-*`): purpose `atm`, rail `cash`. A foreign-only withdrawal never reaches the ledger; one that states the INR counts once as cash withdrawn, with the foreign amount as its original. These outrank the INR ATM rules only when a foreign amount is printed.
- **Non-card and prepaid** (`FX-ACCT-*`, `FX-DEBIT-WITH-*`, `FX-SPEND-*-PP`): purpose `purchase`, foreign price only. A balance printed in a foreign currency is not read: a balance snapshot is INR.
- **Fees** (`FX-FEE-*`): purpose `fee`, an ordinary INR fee that counts as spend. When the alert prints the foreign transaction the fee was charged on, that amount is the fee's `original` (CCR-005): evidence for linking, never the fee's price.
- **EMI conversion** of a foreign transaction is the ignore rule `IGN-CARD-EMI-CONVERTED-FX` (service notice): the purchase was already read from its own alert, so the conversion is not a second spend. A notice that also says money was charged is left to the money rules. `FX-SPEND-TXN-OF-*` reject "EMI conversion" wording.

| Rule | Family | Priority | What it matches |
| --- | --- | --- | --- |
| FX-ATM-WD-CR | atm_foreign | 354 | Foreign ATM withdrawal worded "Cash/ATM withdrawal of USD 200.00 at ATM using <card> XX1234". Foreign price only: purpose `atm`, rail `cash`, never INR. |
| FX-ATM-USED-CR | atm_foreign | 354 | Card used for a foreign ATM withdrawal: "<card> XX1234 has been used for an ATM withdrawal of THB 5,000.00 at PLACE". Foreign price only. |
| FX-ATM-WD-DB | atm_foreign | 353 | Foreign ATM withdrawal worded "Cash/ATM withdrawal of USD 200.00 at ATM using <card> XX1234". Foreign price only: purpose `atm`, rail `cash`, never INR. |
| FX-ATM-USED-DB | atm_foreign | 353 | Card used for a foreign ATM withdrawal: "<card> XX1234 has been used for an ATM withdrawal of THB 5,000.00 at PLACE". Foreign price only. |
| FX-ATM-WD-PP | atm_foreign | 352 | Foreign ATM withdrawal worded "Cash/ATM withdrawal of USD 200.00 at ATM using <card> XX1234". Foreign price only: purpose `atm`, rail `cash`, never INR. |
| FX-ATM-USED-PP | atm_foreign | 352 | Card used for a foreign ATM withdrawal: "<card> XX1234 has been used for an ATM withdrawal of THB 5,000.00 at PLACE". Foreign price only. |
| FX-ATM-WD-NONE | atm_foreign | 350 | Foreign ATM withdrawal worded "Cash/ATM withdrawal of USD 200.00 at ATM using <card> XX1234". Foreign price only: purpose `atm`, rail `cash`, never INR. |
| FX-ATM-USED-NONE | atm_foreign | 350 | Card used for a foreign ATM withdrawal: "<card> XX1234 has been used for an ATM withdrawal of THB 5,000.00 at PLACE". Foreign price only. |
| FX-ATM-WDN-CR | atm_foreign | 354 | Amount-first foreign withdrawal: "USD 200.00 withdrawn from <card or A/c> XX1234 at ATM". Foreign price only. |
| FX-ATM-WDN-DB | atm_foreign | 353 | Amount-first foreign withdrawal: "USD 200.00 withdrawn from <card or A/c> XX1234 at ATM". Foreign price only. |
| FX-ATM-WDN-PP | atm_foreign | 352 | Amount-first foreign withdrawal: "USD 200.00 withdrawn from <card or A/c> XX1234 at ATM". Foreign price only. |
| FX-ATM-WDN-ACCT | atm_foreign | 351 | Amount-first foreign withdrawal: "USD 200.00 withdrawn from <card or A/c> XX1234 at ATM". Foreign price only. |
| FX-ATM-WDN-NONE | atm_foreign | 350 | Amount-first foreign withdrawal: "USD 200.00 withdrawn from <card or A/c> XX1234 at ATM". Foreign price only. |
| FX-ATM-INR-WD-CR | atm_foreign | 924 | "Cash withdrawal of Rs 17,450.00 (USD 200.00) at ATM using <card>": INR posted, the bracketed foreign amount is the original. |
| FX-ATM-APPROX-CR | atm_foreign | 924 | "USD 200.00 (approx INR 17,450.00) withdrawn at ATM using <card>": the approximate INR is posted, the foreign amount is the original. |
| FX-ATM-INR-WD-DB | atm_foreign | 923 | "Cash withdrawal of Rs 17,450.00 (USD 200.00) at ATM using <card>": INR posted, the bracketed foreign amount is the original. |
| FX-ATM-APPROX-DB | atm_foreign | 923 | "USD 200.00 (approx INR 17,450.00) withdrawn at ATM using <card>": the approximate INR is posted, the foreign amount is the original. |
| FX-ATM-INR-WD-PP | atm_foreign | 922 | "Cash withdrawal of Rs 17,450.00 (USD 200.00) at ATM using <card>": INR posted, the bracketed foreign amount is the original. |
| FX-ATM-APPROX-PP | atm_foreign | 922 | "USD 200.00 (approx INR 17,450.00) withdrawn at ATM using <card>": the approximate INR is posted, the foreign amount is the original. |
| FX-ATM-INR-WD-NONE | atm_foreign | 920 | "Cash withdrawal of Rs 17,450.00 (USD 200.00) at ATM using <card>": INR posted, the bracketed foreign amount is the original. |
| FX-ATM-APPROX-NONE | atm_foreign | 920 | "USD 200.00 (approx INR 17,450.00) withdrawn at ATM using <card>": the approximate INR is posted, the foreign amount is the original. |
| FX-ATM-INR-WDN-CR | atm_foreign | 924 | "Rs.17,450.00 withdrawn/debited from <card or A/c> ... ATM ... (USD 200.00)": INR posted with the original. Needs ATM or cash-withdrawal wording. |
| FX-ATM-INR-WDN-DB | atm_foreign | 923 | "Rs.17,450.00 withdrawn/debited from <card or A/c> ... ATM ... (USD 200.00)": INR posted with the original. Needs ATM or cash-withdrawal wording. |
| FX-ATM-INR-WDN-PP | atm_foreign | 922 | "Rs.17,450.00 withdrawn/debited from <card or A/c> ... ATM ... (USD 200.00)": INR posted with the original. Needs ATM or cash-withdrawal wording. |
| FX-ATM-INR-WDN-ACCT | atm_foreign | 921 | "Rs.17,450.00 withdrawn/debited from <card or A/c> ... ATM ... (USD 200.00)": INR posted with the original. Needs ATM or cash-withdrawal wording. |
| FX-ATM-INR-WDN-NONE | atm_foreign | 920 | "Rs.17,450.00 withdrawn/debited from <card or A/c> ... ATM ... (USD 200.00)": INR posted with the original. Needs ATM or cash-withdrawal wording. |
| FX-SPEND-SPENT-FIRST-PP | card_spend_foreign | 345 | "Spent USD 20.00 on/from <forex, prepaid, travel or multi-currency card>": the spend shape of FX-SPEND-SPENT-FIRST with the card read as `prepaid_card`. |
| FX-SPEND-AMT-FIRST-PP | card_spend_foreign | 345 | "USD 20.00 spent on <forex card>": FX-SPEND-AMT-FIRST with the card read as `prepaid_card`. |
| FX-SPEND-TXN-OF-PP | card_spend_foreign | 345 | "Transaction of EUR 15.50 done on <forex card>": FX-SPEND-TXN-OF with the card read as `prepaid_card`. |
| FX-SPEND-USED-FOR-PP | card_spend_foreign | 345 | "<forex card> has been used for GBP 9.99": FX-SPEND-USED-FOR with the card read as `prepaid_card`. |
| FX-DEBIT-WITH-CR | card_spend_foreign | 340 | "<card> XX1234 has been debited with EUR 50.00 at MERCHANT": foreign price only. A foreign balance printed after it is not read (it is not INR). |
| FX-DEBIT-WITH-DB | card_spend_foreign | 339 | "<card> XX1234 has been debited with EUR 50.00 at MERCHANT": foreign price only. A foreign balance printed after it is not read (it is not INR). |
| FX-DEBIT-WITH-PP | card_spend_foreign | 338 | "<card> XX1234 has been debited with EUR 50.00 at MERCHANT": foreign price only. A foreign balance printed after it is not read (it is not INR). |
| FX-DEBIT-WITH-NONE | card_spend_foreign | 336 | "<card> XX1234 has been debited with EUR 50.00 at MERCHANT": foreign price only. A foreign balance printed after it is not read (it is not INR). |
| FX-ACCT-DEBIT-AMT-FIRST | account_debit_foreign | 344 | "USD 100.00 debited from your A/c XX1234 ... towards PARTY": a foreign debit from a bank account, foreign price only, rail `unknown`. |
| FX-ACCT-DEBITED-WITH | account_debit_foreign | 344 | "Your A/c XX1234 is debited with EUR 50.00 ... for PARTY": a foreign debit from a bank account, foreign price only. |
| FX-FEE-LABEL-CR | fx_fee | 939 | "Forex/cross-currency markup (fee) of Rs 52.50 charged/levied on <card or A/c>": an INR fee. The foreign transaction it was charged on, when printed ("for transaction of USD 20.00"), is the fee's original (CCR-005). |
| FX-FEE-AMT-CR | fx_fee | 939 | "Rs 52.50 debited from <card or A/c> towards foreign currency/cross currency markup": an INR fee, with the transaction as original when printed. |
| FX-FEE-AS-CR | fx_fee | 939 | "Rs.52.50 has been charged as Forex Markup Fee on <card or A/c>": an INR fee, with the transaction as original when printed. |
| FX-FEE-LABEL-DB | fx_fee | 938 | "Forex/cross-currency markup (fee) of Rs 52.50 charged/levied on <card or A/c>": an INR fee. The foreign transaction it was charged on, when printed ("for transaction of USD 20.00"), is the fee's original (CCR-005). |
| FX-FEE-AMT-DB | fx_fee | 938 | "Rs 52.50 debited from <card or A/c> towards foreign currency/cross currency markup": an INR fee, with the transaction as original when printed. |
| FX-FEE-AS-DB | fx_fee | 938 | "Rs.52.50 has been charged as Forex Markup Fee on <card or A/c>": an INR fee, with the transaction as original when printed. |
| FX-FEE-LABEL-PP | fx_fee | 937 | "Forex/cross-currency markup (fee) of Rs 52.50 charged/levied on <card or A/c>": an INR fee. The foreign transaction it was charged on, when printed ("for transaction of USD 20.00"), is the fee's original (CCR-005). |
| FX-FEE-AMT-PP | fx_fee | 937 | "Rs 52.50 debited from <card or A/c> towards foreign currency/cross currency markup": an INR fee, with the transaction as original when printed. |
| FX-FEE-AS-PP | fx_fee | 937 | "Rs.52.50 has been charged as Forex Markup Fee on <card or A/c>": an INR fee, with the transaction as original when printed. |
| FX-FEE-LABEL-ACCT | fx_fee | 936 | "Forex/cross-currency markup (fee) of Rs 52.50 charged/levied on <card or A/c>": an INR fee. The foreign transaction it was charged on, when printed ("for transaction of USD 20.00"), is the fee's original (CCR-005). |
| FX-FEE-AMT-ACCT | fx_fee | 936 | "Rs 52.50 debited from <card or A/c> towards foreign currency/cross currency markup": an INR fee, with the transaction as original when printed. |
| FX-FEE-AS-ACCT | fx_fee | 936 | "Rs.52.50 has been charged as Forex Markup Fee on <card or A/c>": an INR fee, with the transaction as original when printed. |
| FX-FEE-LABEL-NONE | fx_fee | 935 | "Forex/cross-currency markup (fee) of Rs 52.50 charged/levied on <card or A/c>": an INR fee. The foreign transaction it was charged on, when printed ("for transaction of USD 20.00"), is the fee's original (CCR-005). |
| FX-FEE-AMT-NONE | fx_fee | 935 | "Rs 52.50 debited from <card or A/c> towards foreign currency/cross currency markup": an INR fee, with the transaction as original when printed. |
| FX-FEE-AS-NONE | fx_fee | 935 | "Rs.52.50 has been charged as Forex Markup Fee on <card or A/c>": an INR fee, with the transaction as original when printed. |
