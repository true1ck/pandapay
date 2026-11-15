# CCR-006. `insurance` purpose

Status. Implemented. Additive and backward compatible.

## What

One new value for the `purpose` attribute of a `movement` and an `attempt` fact: `insurance`.

- Schema: `contracts/sms/v2/fact.schema.json`, `$defs.movement` and `$defs.attempt` `attrs.purpose` enums; `contracts/sms/v2/rule_bundle.schema.json`, the `counterpartyPurpose` purpose enum and the link-rule leg `match.purpose` enum. No new error code: an unknown purpose still fails with the existing `fact.*.purpose_invalid`.
- Dart: `MovementPurpose.insurance`. The event linker treats it exactly like `bill_payment` (a debit is a `bill_payment` event, a credit a refund). Receipt policy falls through to `bill_payment`.
- Regenerated: `schema_data.g.dart` (`node contracts/sms/v2/embed_dart.js`) and `api/sms_v2_assets` (`node api/scripts/sync_sms_v2_assets.js`).

## Why

A scheduled debit ("keep funds ready, your insurance premium of Rs x will be debited on DATE") is an insurance premium, not a utility bill. With only `bill_payment` the Bills page could not tell the two apart without reading the insurer's name against a hard-coded list in app code. Owner direction (15 Nov 2026): knowledge about what a message is belongs in the rule set. A rule now types it (`purpose: insurance`) and the app reads the typed value.

## Rules that use it

- `BIL-INS-PREMIUM-DEBIT-01` (version 2): emits `purpose: insurance` and the insurer as the counterparty.
- `GENZ-INS-PREMIUM-UPCOMING-DEBIT`: the generalized wording for any insurer.

The scheduled-debit kinds the Bills page shows come only from typed purposes: `emi`, `investment`, `insurance`; any other `bill_payment` is classified from the biller's name by the same classifier every other bill uses.

## Compatibility

- Old payloads validate unchanged. A phone on an older build reading a bundle with these rules drops the attempt (unknown purpose) and shows nothing for it; publish the rules with a `minEngineVersion` that includes this change.
- Facts with this purpose are a scheduled attempt, which has no money effect, so no ledger, totals or server projection changes.

## Rollback

Revert the commit after unpublishing the two rules. Nothing is persisted that needs migrating: an attempt fact with this purpose is re-read from the message.
