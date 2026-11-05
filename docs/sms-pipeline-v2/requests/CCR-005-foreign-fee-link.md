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

### Part 2. The fee event links the transaction (linker, engine 2.3.0)

A link rule, `LINK-FEE-ON-TXN` in `rules/sms/v2/link_rules.json`:

```json
{"id": "LINK-FEE-ON-TXN", "eventType": "fee",
 "legs": [{"role": "charge", "match": {"factType": "movement", "direction": "debit", "purpose": ["fee"], "evidenceOnly": false}},
          {"role": "original", "match": {"factType": "movement", "direction": "debit", "purpose": ["purchase", "atm"], "evidenceOnly": false}}],
 "join": {"amountRole": "posted", "amountTolerancePct": 100, "windowHours": 1080, "reference": "prefer"},
 "singleLeg": "complete", "priority": 95}
```

The linker reads an event type `fee` with a `charge` and an `original` leg as a new kind, `LinkRuleKind.feeCharge` (chosen from the event type and leg roles, never the id). Matching is code:

- The fee joins one transaction only on exact evidence: the same resolved card or account; the transaction not after the fee (two days' slack for a printed date) and at most 45 days before it; no conflicting reference of the same kind; and either a shared reference, or the fee's `original` equal (minor and currency) to the transaction's foreign price (`posted.foreign`: the foreign-only amount, or the original beside an INR posting).
- Notices of one transaction count as one candidate. Two transactions that fit give no link, and the fee is an ordinary fee. A fee is never an `ambiguous` event and never a review item, because an ambiguous event would drop the fee from totals.
- The result is `fee [charge, original]`. As with a refund, the transaction is a shared reference: it keeps its own event and its own ledger row (none for a foreign-only amount), and is never money in the fee's event. The fee's ledger row is the fee's INR amount, spend, exactly as before. The event id is the fee's, in any arrival order: a transaction that arrives after its fee is attached to the fee's event (`_lateFeeOriginal`), the same as a purchase arriving after its refund.
- A fee with no evidence keeps the shape it always had (`fee [debit_leg]`, no link rule), so existing fee events do not change.

Why a version bump: a linker before 2.3.0 reads this rule as a generic rule, joins on its parameters alone and could make an ambiguous fee event, which counts nothing. `smsEngineVersion` is 2.3.0 and `rules/sms/v2/meta.json` requires it, so an older build refuses the bundle and keeps its last good one.

Tests: `packages/pandapay_domain/test/sms_v2/linker/foreign_fee_link_test.dart`; golden scenarios `foreign_fee_*`.

## Compatibility

- Facts: unchanged shape; old builds read a fee with an original as an INR fee, which is what it is.
- Events: `fee` with `charge` and `original` legs is valid under the frozen event schema. Server projection reads the fee as spend (`ENTRY_KIND_BY_TYPE.fee`); `original` legs are not money there either.
- Bundles: `minEngineVersion` 2.3.0 (above). `contractVersion` stays `2.0`.
- Known order effect: if two transactions that both fit a fee arrive only after it, the first to arrive is linked (legs only grow). A transaction normally precedes its fee.

## Rollback

Remove `LINK-FEE-ON-TXN` and revert the rules. Stored fee events keep their `original` leg, which every consumer reads as a non-money reference; facts stay valid. `minEngineVersion` can then go back to 2.2.0.
