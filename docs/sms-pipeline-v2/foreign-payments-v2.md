# Foreign payments on SMS v2

The legacy client parser was the only thing that created `ForeignPayment` rows. It was deleted in the fresh-start release, so nothing created them. This note records what v2 did, what was missing, and how the feature works now. Design inputs: `docs/foreign-payments-complete-release-plan-2026-11-02.md` and `docs/sms-foreign-currency-amount-guard-2026-11-02.md`.

## Gap analysis (before this work)

| Area | What v2 did | Gap |
| --- | --- | --- |
| Contract | `amounts[]` could carry `original {minor, currency}` and a non-INR `unit`. | Nothing could write either: the rule format had a fixed `unit` and no `original`. Only two bank rules (a Federal and an ICICI USD alert) hard-coded `unit: USD`. |
| Rules | INR-posted foreign rules (`GEN-CARD-FOREIGN-*`, `GENZ-CARD-FOREIGN-PAREN-*`) and ordinary bank spend rules read the INR and dropped the foreign amount. | Foreign-only alerts ("Spent USD 20.00 ...", "Transaction of EUR 15.50 ...", `$`, refunds) matched no rule and became unknown/review. A bank rule such as `SBI-CARD-SPEND` read "(USD 20.00)" messages and lost the foreign price. |
| Linker | `_principal` returned the posted minor with no unit. | USD 20.00 (2000) equalled Rs 20.00 (2000 paise): a foreign notice could join a bank debit as a duplicate and gave its event an INR amount. Foreign credits fed `MoneyInItem` through `event.amountMinor`. |
| Projector | Ignores any posted amount whose unit is not INR. | None. |
| Server projection | Needs an INR ledger row and `amountMinor > 0`. | None. Foreign-only facts make no transaction. |
| App | Nothing wrote foreign rows. | New bridge below. |

## Representation

| Message states | Fact amount | `ForeignPayment` |
| --- | --- | --- |
| INR posted and the foreign price | `{posted, minor: paise, unit: INR, original: {minor, currency}}` | `billed_inr`, `confirmation_source: sms`. Status `confirmed` as soon as the ledger holds the same SMS and amount, else `awaiting_rate` until the server links it by source key. |
| Foreign price only | `{posted, minor: foreign minor, unit: USD}` (any ISO code) | `awaiting_rate` (the server then estimates: `estimated`). No billed INR. |
| Foreign price behind a bare `$` or `¥` | same with `unit: XXX` | `awaiting_amount`, currency null: "Currency needed". |

A foreign-only fact is never INR spend: no ledger entry, no transaction, event `amountMinor` 0, no card, reward or cap effect. Estimates stay server-side reference values, as before.

## Rules (CCR-004, engine 2.2.0)

`rules/sms/v2/foreign/foreign_currency.json` (generated variants per credit, debit and plain card, and `-LIM` forms that also read "Avl Lmt" as a balance). Details per rule: `rules/sms/v2/foreign/NOTES.md`.

Handled shapes, all with codes (USD, EUR, GBP, AED, SGD, JPY, KWD and about 45 more), `US$`, `$`, `€`, `£`:

- Foreign only: "Spent USD 20.00 on <bank> Card xNNNN at M", "USD 20.00 spent using ... Card", "Transaction/Txn of EUR 15.50 done on ... Card", "<card> has been used for an international transaction of GBP 9.99".
- INR plus original: "Rs.1,750.00 spent ... at M (USD 20.00)", "Spent Rs.1,750.00 on ... (USD 20.00)", "Rs 1750.00 spent ... Foreign currency amount USD 20.00 with forex markup of Rs 52.50" (markup is never added), "USD 25.00 (approx INR 2,100.00) spent", "USD 20 spent ... Billed INR 1742" (existing rules, now carrying the original).
- Refunds and reversals: foreign only, and INR credited with the foreign amount in brackets.
- Not purchases: declined, failed, pre-authorisation and verification wording is rejected (review); `USD 0.00` is ignored; `USD .00` matches nothing and goes to review.

## More shapes (CCR-005, engine 2.3.0)

`rules/sms/v2/foreign/foreign_more.json`, the ignore rule `IGN-CARD-EMI-CONVERTED-FX` and the link rule `LINK-FEE-ON-TXN`. Details per rule: `rules/sms/v2/foreign/NOTES.md`; the fee semantics and the link: `requests/CCR-005-foreign-fee-link.md`.

| Message | Fact | Ledger | `ForeignPayment` |
| --- | --- | --- | --- |
| Foreign ATM withdrawal, foreign only: "Cash withdrawal of USD 200.00 at ATM using your Debit Card XX1234", "USD 200.00 withdrawn from Credit Card x1234 at ATM", "<card> has been used for an ATM withdrawal of THB 5,000.00" (credit, debit, forex card or account) | movement `atm`, rail `cash`, `{posted, minor, unit: USD}` | none | `awaiting_rate`, category "Cash withdrawal", merchant "ATM withdrawal" unless a place is printed |
| Foreign ATM withdrawal with the INR: "Rs.17,450.00 withdrawn from ... at ATM (USD 200.00)", "Cash withdrawal of Rs 17,450.00 (USD 200.00) ...", "USD 200.00 (approx INR 17,450.00) withdrawn ...", "INR ... debited from A/c ... for ATM withdrawal (EUR 100.00)" | movement `atm`, INR posted with `original` | ATM withdrawal, spend, once | `confirmed` (billed INR) |
| Foreign debit from a bank account: "USD 100.00 debited from your A/c XX1234 ... towards PARTY", "Your A/c XX1234 is debited with EUR 50.00 ... for PARTY" | movement `purchase`, rail `unknown`, foreign only, `references.txnId` when printed | none | account record (`account_last4`) |
| Forex, prepaid, travel or multi-currency card: "Your Forex Card XX1234 has been debited with EUR 50.00 at M", "EUR 50.00 spent on your Forex Card ... at M", and the existing spend wordings on such a card | movement `purchase`, instrument `prepaid_card`, foreign only; a foreign "available balance" is not read | none | card record |
| EMI conversion of a foreign transaction: "Your transaction of USD 500.00 ... has been converted to EMI ...", "... (USD 500.00) ... is converted into 6 EMIs ...", "EMI conversion successful for transaction of USD 500.00 ..." | ignored (`service`) | none: the purchase was already counted from its own alert | none |
| Forex markup / cross-currency fee: "Forex markup fee of Rs 52.50 charged on your Credit Card XX1234 for transaction of USD 20.00", "Rs 52.50 debited from ... towards foreign currency markup fee", "Rs.52.50 has been charged as Forex Markup Fee on ... for txn ref NNN", account forms | movement `fee`, INR posted; the transaction it was charged on as `original` and a reference as `txnId` when printed | fee, spend, once | none (a fee is not a foreign price) |

A fee joins its transaction (`fee [charge, original]`) only on exact evidence: the same resolved card or account, the transaction not after the fee and at most 45 days before it, and a shared reference or the same foreign amount. Two transactions that fit, or no evidence, leave an ordinary INR fee, never an ambiguous event or a review item. The transaction keeps its own event and row either way, as a refund's original does.

A foreign spend whose alert ends with an EMI offer ("To convert this txn to EMI call us") is the spend: the EMI offer ignore rule now treats a currency code or symbol beside a spend verb as money, as it did rupees.

## App bridge

`app/lib/features/sms_v2/ledger/foreign_payment_bridge.dart`, called from `SmsV2Pipeline._project` in the pipeline's savepoint. It uses `captureLocalForeignPayment`, so it is idempotent by source key (a replay never duplicates, an edited row is never overwritten), account scoped, and queues the existing outbox, which `ForeignPaymentsRepository.sync` sends to `/foreign-payments`. No SMS text is stored or sent.

The bridge records purchases (card, prepaid card, bank account), ATM withdrawals and refunds or reversals. ATM withdrawals get the category "Cash withdrawal" (`ForeignPayment.cashWithdrawalCategory`). Fees and EMI conversions never make a record.

Settlement (`settleAwaitingForeignPayments`): the v2 linker is not used, because a rupee posting and a foreign price are different units and the linker only joins like with like. A later alert that states the billed INR settles an earlier foreign-only alert on exact evidence: same direction, currency and original amount, same card (saved card, else last four, else same merchant), both cash withdrawals or both not (a USD 200 withdrawal never settles a USD 200 purchase), within 7 days, and exactly one candidate each way. The earlier record is dismissed (`ignored`, synced as a PATCH after its create) and the billed one stays confirmed, so the purchase counts once. Weak or ambiguous matches stay pending.

## Not handled

- A foreign alert whose wording no rule knows still goes to review, as any unknown message does.
- A markup fee that prints only an INR transaction amount ("on txn of Rs 1,750.00") links only by reference: a fee's `original` must be a foreign amount, and a new fact field for an INR amount would need a sync capability header (CCR-005). The existing foreign purchase rules (`FX-SPEND-*`, `FX-INR-*`) do not read a reference, so a fee links to those purchases by amount only.
- An EMI conversion notice that also says a fee was charged ("processing fee of Rs 199 has been charged") is left to the money rules; when it states a foreign amount with "EMI conversion" wording and no rule reads the fee, it goes to review. The monthly instalments a card EMI bills are read by the existing INR EMI rules and count as spend, as they did before; the converted purchase was already counted. INR-only EMI conversions keep their previous reading.
- Foreign card loads and reloads ("Your Forex Card has been loaded with USD 1,000") match no rule and go to review: the money moved when the INR was paid, and that debit is read on its own.
- A balance printed in a foreign currency (forex card) is not stored: a balance snapshot is INR.
- Promotion ignore rules guard money with spend verbs beside rupee amounts. The EMI offer rule now also accepts a currency code or symbol beside "spent", "debited", "charged" or "withdrawn", but a foreign alert worded otherwise ("Transaction of USD 20.00 done on Card ...") that ends in an offer ("apply now") can still be dropped as a promotion, by that rule or another.
- If two transactions that both fit a fee arrive only after it, the first to arrive is linked (legs only grow).
- A billed alert that carries no foreign amount cannot settle the foreign-only one by itself; the server link by reference or a statement import, or the user, still can.
- The settled record shows as dismissed, not as "settled by a later alert". The bridge dismisses it with a PATCH to `valuation_status: ignored`, which the server stores as a user dismissal. A distinct status needs a server change: `confirmation_source` is limited to `user`, `sms` and `statement` by a database CHECK constraint (`db/supabase/migrations/20261102100000_foreign_payments.sql`), and a local-only marker would be lost the next time the row is refreshed from the server. Options: a migration adding a `settled_by_source_key` column (or a `later_alert` confirmation source) that the PATCH sends and the model reads for its label.
