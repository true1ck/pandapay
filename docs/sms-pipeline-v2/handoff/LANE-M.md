# Lane M handoff: refund category on the wire (CCR-003)

Branch `sms-v2/lane-m-refund-category`, from `sms-v2/claude-lanes` (1baab86). Local only; nothing pushed or deployed. Full change description: `requests/CCR-003-refund-category.md`.

## What changed

- Contract: a refund ledger entry (external to own, `isSpend`/`isIncome`/`isInvestment` all false, counts as a transaction) may carry `category` and `categorySource`. Same fields as before, no new property. Dart (`validate.dart`) and Node (`api/src/sms_v2/contracts.js`) validators agree; old payloads with `null` still validate. Schemas regenerated, API copy synced, 2 valid and 3 invalid fixtures added.
- Domain: `LedgerEntry.isRefundShaped`, `LedgerEntry.withCategory`. The projector writes category and source on refund rows. Totals order for a refund: linked purchase entry, the refund row, explicit `categoryByEvent` context, `other`. Totals and counts are otherwise unchanged.
- App: `LedgerStore` persists a refund decision in the wire fields (no `_categoryDecision` for refund rows), still reads old `_categoryDecision` metadata, and upgrades old rows when the event is next projected. `sync_pull.dart` keeps an incoming refund row's category, does not lock an inherited refund category (a purchase refresh still reaches the refund), and sends `X-Sms-Contract-Features: refund-category`.
- Server: `projectEvent` already carried an entry category, so the refund transaction row now gets one. `GET /sms/v2/sync` drops the category from refund entries unless the header above is sent, so an older phone build (whose validator would reject it and roll back its pull) keeps working. No migration; the table has no constraint tying category to `to_external`.

## Tests

- New or changed: `packages/pandapay_domain/test/sms_v2/ledger/projector_test.dart` (earlier-month linked refund reduces that purchase category, standalone refund, no-decision fallback to `other`, pre-CCR-003 row context), `app/test/features/sms_v2/ledger/refund_category_test.dart` (two devices syncing the same events give identical category totals, with and without local context; standalone fallback; old local metadata read and upgraded), `app/test/features/sms_v2/sync/sync_pull_test.dart` (refund row carries the category, header sent), `api/test/sms_v2/refund_category.test.js` (validator, projection, sync downgrade), contract fixtures.
- Results: domain 1040 pass; contracts test 9 pass; `npm run check` OK and `npm test` 1437 pass, 4 skipped, 0 fail; `tools/sms_rules_cli` 41 pass and `check_pipeline` golden ok; `app test/features/sms_v2` 259 pass, 2 skipped with the flag off and with `SMS_PIPELINE_V2=true`.

## Owner decisions and follow-ups

1. Rollout order: deploy the server before any phone build that writes refund categories. A new phone against an old server has its refund rows rejected (`ledger.category_requires_external_to`).
2. Refund shape is the discriminator (the entry has no event type). If a future event type projects external to own with all three flags false, it would be allowed a category; the projector table in contracts.md says only refunds do.
3. A category refresh of a purchase on another device updates a linked refund's own row on the phone that pulls it, but the server's stored refund row keeps the older category until that phone's re-projection is pushed. Totals follow the linked purchase first, so they are correct either way.
4. The `X-Sms-Contract-Features` capability header is new server behaviour; confirm it is acceptable to WP-08/WP-14 owners and that WP-17's version gate does not need to replace it.
5. Rules and `minEngineVersion`: no rule changes, no bundle needs a higher `minEngineVersion`; `smsEngineVersion` stays 2.0.0.
