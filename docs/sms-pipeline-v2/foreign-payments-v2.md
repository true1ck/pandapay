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

## App bridge

`app/lib/features/sms_v2/ledger/foreign_payment_bridge.dart`, called from `SmsV2Pipeline._project` in the pipeline's savepoint. It uses `captureLocalForeignPayment`, so it is idempotent by source key (a replay never duplicates, an edited row is never overwritten), account scoped, and queues the existing outbox, which `ForeignPaymentsRepository.sync` sends to `/foreign-payments`. No SMS text is stored or sent.

Settlement (`settleAwaitingForeignPayments`): the v2 linker is not used, because a rupee posting and a foreign price are different units and the linker only joins like with like. A later alert that states the billed INR settles an earlier foreign-only alert on exact evidence: same direction, currency and original amount, same card (saved card, else last four, else same merchant), within 7 days, and exactly one candidate each way. The earlier record is dismissed (`ignored`, synced as a PATCH after its create) and the billed one stays confirmed, so the purchase counts once. Weak or ambiguous matches stay pending.

## Not handled

- A foreign alert whose wording no rule knows still goes to review, as any unknown message does.
- Foreign debit-card ATM and cash withdrawals, EMI conversions and bank-account (non-card) foreign debits.
- Fees posted separately (forex markup alerts) are not linked to the purchase; they stay ordinary INR fee movements.
- A billed alert that carries no foreign amount cannot settle the foreign-only one by itself; the server link by reference or a statement import, or the user, still can.
- The settled record shows as dismissed, not as "settled by a later alert".
