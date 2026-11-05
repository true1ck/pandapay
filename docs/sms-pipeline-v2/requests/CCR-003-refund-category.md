# CCR-003. Category on refund ledger entries

Status. Implemented on `sms-v2/lane-m-refund-category` (lane M, contract change D2), pending orchestrator merge. Additive and backward compatible for stored and uploaded data. Contract change request: written together with the implementation, as CCR-002 was.

## What

A ledger entry may carry `category` and `categorySource` when it is a refund entry, not only when `to` is external.

- Field: the existing `category` (slug or null) and `categorySource` (enum or null) of `ledger_entry.schema.json`. No new property, no new required field, no new error code. Both stay required and nullable; the pair rule (`ledger.category_source_mismatch`) is unchanged.
- A refund entry is identified by shape: `from` is `{external}`, `to` is not external (`{instrumentId}` or `{ownUnresolved}`), `countsAsTransaction` is true, and `isSpend`, `isIncome` and `isInvestment` are all false. The projector produces this shape only for `refund` events (income and cashback set `isIncome`, withdrawals set `isInvestment`, own transfers are own to own).
- Validator rule (`ledger.category_requires_external_to`, message widened in `error_codes.json`): a non-null category is still an error unless `to` is external or the entry is refund-shaped. Dart `_ledgerSemantics` (`validate.dart`) and Node `ledgerSemantics` (`api/src/sms_v2/contracts.js`) implement the same rule.
- Value: the refund takes the category and source of the purchase it reverses (linked refund). A standalone refund (no linked purchase) takes the decision the category resolver makes for its own counterparty, which is `other` with source `default` when nothing matches. It is never invented on the wire as anything else.
- Schema file: only a `description` was added to `category`. `schema_data.g.dart` (`node contracts/sms/v2/embed_dart.js`) and `api/sms_v2_assets` (`node api/scripts/sync_sms_v2_assets.js`) were regenerated.
- Fixtures: valid `refund_with_category.json`, `refund_without_category.json`; invalid `ledger.category_requires_external_to~income_shape.json`, `~investment_shape.json`, and `ledger.category_source_mismatch~refund_category_without_source.json`. The existing own-to-own invalid fixture still fails.
- Dart API: `LedgerEntry.isRefundShaped` and `LedgerEntry.withCategory`. `DefaultLedgerProjector.project` fills category and source on refund rows.

## Why

The frozen validator forbade a category when `to` is not external, so a refund could not say which purchase category it reduces. WP-06 worked around this with a local `_categoryDecision` payload note, stripped from wire JSON. A second device had to rebuild the category from facts and links, and a standalone refund whose context never synced fell to `other` there while showing its real category on the first device. Carrying the category on the row makes category totals a pure function of synced rows and events.

## Totals

`DefaultLedgerProjector.totals` picks a refund's category in this order: the category of the linked purchase's entry (so a corrected purchase category is followed live), the refund row's own category, the explicit `categoryByEvent` context (rows written before this change), then `other`. Counts, spend, refund, income and investment amounts are unchanged. Tests: `packages/pandapay_domain/test/sms_v2/ledger/projector_test.dart`, `app/test/features/sms_v2/ledger/refund_category_test.dart`.

## Persistence, sync and server

- `LedgerStore.replaceForEvent` writes the decision into a refund row's `category` and `categorySource` and no longer writes `_categoryDecision` for refund rows. `categoryDecisions()` still reads old `_categoryDecision` metadata first, then falls back to a refund row's wire category. A refund row written by an older build keeps working and is upgraded the next time its event is projected. Spend rows still use `_categoryDecision`, which also holds the rule id and confidence.
- Phone pull (`sync_pull.dart`): an incoming refund entry keeps its own category; a locally retained decision does not overwrite it. A refund linked to a purchase is not locked by its stored category, so a purchase category refresh from another device still reaches it. The pull sends `X-Sms-Contract-Features: refund-category`.
- Server: storage already keeps `category_slug` and `category_source` for any ledger entry and no database constraint ties them to `to_external`, so no migration is needed. `projectEvent` already takes the first entry category, so the refund `transactions` row now gets a category. `GET /sms/v2/sync` removes the category from refund entries unless the request carries `X-Sms-Contract-Features: refund-category` (see below). Stored rows are not changed.

## Compatibility and minEngineVersion

- Old payloads (refund with `category: null`, `categorySource: null`) validate and round-trip unchanged. `contractVersion` stays `2.0`.
- Rules are unaffected. The category on a refund row is computed by the projector and the category resolver, not by a rule, so no rule JSON changes and no bundle needs a higher `minEngineVersion`. `smsEngineVersion` stays `2.0.0`.
- A phone built before this change would throw a `ContractException` on a refund entry with a category (its validator rejects it) and its pull would roll back. The sync handler therefore returns refund entries with category null unless the client declares `refund-category`; an old build sends no such header, so it keeps receiving the previous shape and keeps its old local-derivation behaviour. New builds always send the header. If a future change is to be treated like this one, the same capability header is the mechanism, and the engine version is not the gate because the engine does not construct ledger entries.
- A phone on the new build pushing refund rows with a category to a server without this change is rejected by that server's old validator (`ledger.category_requires_external_to`). Deploy the server before any build that writes the field. The pipeline is behind `SMS_PIPELINE_V2` and the server routes behind `sms_pipeline_v2_enabled`, so no released client is affected today.
- Two devices on different builds still agree on totals: the new device uses linked purchase category first, then the row, then local context; the old device uses linked purchase, then local context. They differ only for a standalone refund whose category the old device cannot see, in which case the old device shows `other` for it, which is the same fallback as before.

## Rollback

Revert the commit and redeploy the server. Refund entries already stored or held on phones with a category would fail an old validator, so first clear them on the server with a one-off update: `UPDATE sms_v2_ledger_entries SET category_slug = NULL, category_source = NULL WHERE from_external IS NOT NULL AND to_external IS NULL AND NOT is_spend AND NOT is_income AND NOT is_investment;`. Phone rows are re-projected by the reverted code on the next projection, which omits the category; until then the reverted build would reject such a local row, so ship the revert as a build, not as a server-only change. Totals do not change: the reverted code derives the category from the linked purchase or local context.

## Affected work packages

WP-01 (contract and conformance), WP-06 (ledger projector, LedgerStore, totals), WP-08 (validator and sync), WP-14 (sync pull and projection writer). WP-07 and WP-16 only through the category refresh tests, which pass unchanged.
