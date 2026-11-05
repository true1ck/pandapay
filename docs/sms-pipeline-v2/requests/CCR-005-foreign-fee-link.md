# CCR-005. A forex markup fee and the transaction it was charged on

Status. Implemented on `fresh/foreign-more`. Additive and backward compatible. No schema change.

## What

A forex markup or cross-currency fee is posted by many issuers as its own alert, in INR, often naming the foreign transaction it was charged on ("Forex markup fee of Rs 52.50 charged on your Credit Card XX1234 for transaction of USD 20.00"). The fee is real INR spend. It must count once, as a fee, and never change the purchase.

### Part 1. The fee's `original` (rules, no contract change)

On a movement with `purpose: fee`, the posted amount is the fee in INR and `original` is the foreign amount of the transaction the fee was charged on, when the alert prints it:

```json
{"role": "posted", "minor": 5250, "unit": "INR", "original": {"minor": 2000, "currency": "USD"}}
```

- The shape is the CCR-004 shape (an INR posting with the foreign amount printed beside it), so the fact schema, the Dart and Node validators and the fixtures need no change. A fee is always INR: a foreign-only fee is not written.
- Meaning, per purpose: for `purchase`, `atm`, `refund` and `reversal` the original is the foreign price of the posting itself; for `fee` it is the transaction the fee was levied on. It is evidence for linking only, never the fee's price: no rate is derived from it, and the app's foreign-payment bridge writes no record for a fee (it reads only purchases, ATM withdrawals, refunds and reversals).
- A fee alert that prints no foreign transaction carries no original, and stays an ordinary INR fee.
- Rules: `FX-FEE-*` in `rules/sms/v2/foreign/foreign_more.json` (see that folder's NOTES). They also keep a printed transaction reference as `references.txnId`.

Why not a new attribute: movement `attrs` and `amounts` have `additionalProperties: false`. A new field would make a build without this change reject such a fact when it pulls it from another device (`sync_pull` validates every fact), and would need a sync capability header like CCR-003. Reusing `original` keeps every fact valid for every build.

## Compatibility

- Facts: unchanged shape; old builds read a fee with an original as an INR fee, which is what it is.
- `contractVersion` stays `2.0`.

## Rollback

Revert the rules. Facts already produced stay valid.
