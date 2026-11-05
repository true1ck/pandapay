# CCR-002. Informational amount on the info fact

Status. Implemented on `sms-v2/lane-e-info-amount` (lane E, contract change D1), pending orchestrator merge. Additive and backward compatible.

## What

One optional attribute on the `info` fact: `attrs.amountMinor`, a positive integer count of paise (INR).

- Schema: `contracts/sms/v2/fact.schema.json`, `$defs.info.properties.attrs.properties.amountMinor` is `{type: integer, minimum: 1}`. Error code `fact.info.amountMinor_invalid` (type and minimum), added to `error_codes.json`.
- The key follows the existing `limit_change.attrs.previousMinor` precedent: a flat `…Minor` attr that is data, not an `amounts` entry.
- `amounts` on an info fact is unchanged: `maxItems: 0`, still `fact.info.amount_count`. An informational amount in `amounts` (for example `role: informational`) stays invalid.
- Dart: `InfoFact.amountMinor` (`int?`), read in `Fact.fromJson`, written by `attrsJson` only when set. Rule engine: `RuleEngine._attrFromGroup` parses `amountMinor` with `parseAmountIndian`, exactly as it already does for `previousMinor`, so a rule can write `"amountMinor": {"from": "amt"}`. No rule JSON changed here.
- Regenerated: `schema_data.g.dart` (`node contracts/sms/v2/embed_dart.js`) and `api/sms_v2_assets` (`node api/scripts/sync_sms_v2_assets.js`). The Node validator reads the same schema and needed no code change.
- Fixtures: valid `info.ipo_application_amount.json`; invalid `fact.info.amountMinor_invalid.json` (string), `fact.info.amountMinor_invalid~zero.json` (zero), `fact.info.amount_count~informational_role.json` (amount smuggled into `amounts`).

## Why

IPO application notices and similar messages print an amount ("application of Rs.15,000 received") but are not money movement. The frozen `info` fact could not carry that amount, so the scorer saw those messages disagree with labels that record it. Putting it on a `movement` or `hold` would make it money, which is wrong for a notice that moves nothing.

## Never money

The amount lives in `attrs`, never in `amounts`. Every consumer of money reads typed `MovementFact` amounts (ledger projector, totals) or events built from them (linker); info facts are never legs of a money event. Tests in `packages/pandapay_domain/test/sms_v2/info_amount_test.dart` prove:

- the linker makes no event from an info fact with an amount, and linking one beside a debit leaves events and the leg list unchanged;
- the ledger projects the same entry and the same totals with and without the info fact present;
- an info fact forced in as a leg of a spend event projects no entry and zero spend, income and investment totals.

Info facts remain on-phone only (never stored or uploaded), so no server or sync shape changes.

## Compatibility

- Old payloads without `amountMinor` validate and round-trip unchanged (`toJson` omits the key when null).
- New payloads are accepted by old readers of the schema only if they ignore unknown attrs; the previous schema had `additionalProperties: false` on info attrs. Info facts never leave the phone, and the phone, console, CLI and server all ship the same schema, so mixed versions only matter for a phone running an older build against a newer bundle. Mitigation: a rule that emits `amountMinor` should be published with a `minEngineVersion` that includes this change (the old engine would drop the fact as invalid).
- `contractVersion` stays `2.0`.

## Rollback

Revert the commit. Facts already produced with `amountMinor` live only on the phone and are not persisted as info (info is counted, not stored), so no data migration is needed. Rules that emit the attr must be reverted or unpublished first.

## Affected work packages

WP-01 (conformance), WP-02 (engine attr parsing), WP-03 rule lanes that use the field, evaluation scorer. WP-05 and WP-06 only through the tests above.
