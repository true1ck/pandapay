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
