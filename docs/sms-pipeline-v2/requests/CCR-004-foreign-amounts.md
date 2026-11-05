# CCR-004. Foreign amounts in rules

Status. Implemented on `fresh/foreign-v2`. Additive and backward compatible. Engine 2.2.0.

## What

Two optional fields on a rule's emit amount (`rule_bundle.schema.json`, `$defs.emitAmount`), and nothing else in the contract.

- `unitFrom`: the named regex group that holds the currency of the amount (`USD`, `US$`, `€`). Used instead of the fixed `unit`. Exactly one of `unit` and `unitFrom` is required (`bundle.emit.amount_unit_required`).
- `original`: `{from, currency | currencyFrom}` on an INR amount. `from` is the group with the foreign amount printed beside the INR posting. The currency is a fixed ISO code or a group. A malformed original is `bundle.emit.original_invalid`.

The fact contract is unchanged. It already carried both shapes:

| Message states | Fact amount | Meaning |
| --- | --- | --- |
| INR posted and the foreign price | `{role: posted, minor: <paise>, unit: INR, original: {minor, currency}}` | INR known. Counts once, as today. The original is evidence. |
| Only the foreign price | `{role: posted, minor: <foreign minor>, unit: <ISO code>}` | INR not known. Never counted (see below). |
| Foreign price behind a bare `$` or `¥` | same, `unit: XXX` | Amount kept, currency asked for. |

`XXX` is the ISO 4217 code for "no currency". A symbol that names no single currency (`$` could be USD, AUD, CAD, SGD) is never guessed.

## Engine behaviour

- The unit group is normalised with `smsForeignCurrencyCode` (`contract/currency.dart`): codes, `US$ A$ C$ S$ HK$ NZ$ € £`, bare `$ ¥` to `XXX`. INR stays INR. An unknown code is an invalid emit (`rule_emitted_invalid`).
- A foreign minor uses the ISO 4217 exponent of its own currency (JPY 0, USD 2, KWD 3). Extra non-zero decimals are refused, never rounded. A zero amount fails the existing `minimum: 1` and is an invalid emit, so a verification authorisation never becomes a purchase.
- `original` requires an INR posting. A group that did not match skips only the original and keeps the INR amount.
- Lint reports `lint.group.missing` for a `unitFrom`, `original.from` or `original.currencyFrom` group the pattern does not define.

## Money safety

- The projector already ignores any posted amount whose unit is not INR. The linker now does the same in `_principal`: a foreign minor is never compared with paise and never becomes an event's `amountMinor`. Amounts in different units join only under an "up to" rule that tolerates an unknown amount (a mandate and its charge), never under the refund rule: a foreign-only refund is not shown to be part of an INR purchase.
- A foreign-only event has `amountMinor 0`, no ledger entry, no transaction, no card or reward effect. The server projection needs an INR ledger row and an event amount above 0, so it makes no row either.
- Linking a later INR-billed message to the foreign-only one is done by the app bridge, see `foreign-payments-v2.md`.

## Compatibility

- Old bundles validate unchanged. `toJson` omits both fields when unset.
- A 2.1.x engine refuses a bundle that uses either field (the schema has `additionalProperties: false`), keeping its last good bundle. `rules/sms/v2/meta.json` requires 2.2.0.
- `contractVersion` stays `2.0`.

## Files

Schema and codes: `contracts/sms/v2/rule_bundle.schema.json`, `error_codes.json`; regenerated `schema_data.g.dart` (`node contracts/sms/v2/embed_dart.js`) and `api/sms_v2_assets` (`node api/scripts/sync_sms_v2_assets.js`). Dart: `EmitAmount.unitFrom/original`, `EmitOriginal`, `Amount.isInr/foreign`, engine and lint. The Node validator reads the same schema and needed no code change. Fixtures: valid `bundle/foreign_amounts`, `fact/movement.foreign_only`, `fact/movement.foreign_refund`; invalid `bundle.emit.amount_unit_required`, `bundle.emit.original_invalid`.

## Rollback

Revert the commit and unpublish rules that use the fields first. Facts already produced keep validating, because the fact contract did not change.
