# WP-16 approved server integration touchpoints

Orchestrator assigned the server half of WP-16 and approved narrow integration changes in `api/src/sms_v2/storage.js`: refuse adoption of superseded legacy rows and mark projections with legacy source history as backfill even on live-mode uploads. This prevents source-key collision/data loss and duplicate card-state application. The new migration guards stale legacy sync reactivation and allows only authenticated private learning.publish rollback.

The work package authorizes the `api/src/sms_v2/index.js` hook registration plus status-only filters in server transaction list/totals queries. The inventory expands that check recursively, preserves raw archive/identity/mutation reads and reports no frozen Gmail query gap. Filters touch `api/src/index.js`, `transaction_splits.js` and `self_transfer.js`. Deleted/ignored detail and duplicate review semantics are preserved by excluding only superseded where active-only would change existing recovery behavior.

Rollback is SQL-only through the existing private authenticated database authority. No additive HTTP route, contract, dependency, flag or applied migration change is required. New migration timestamp is 20261112170000; category-rule work uses 180000 and consent-lock follow-up reserves 190000.
