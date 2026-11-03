# WP-06 to WP-14: transaction fetch identity must preserve event id

The projection writer persists `TransactionEntry(id: v2:<eventId>, eventId: ..., pipelineVersion: 2)`. WP-08's server projection uses a database UUID for its transactions row. The current legacy `GET /transactions` queries in `api/src/index.js` do not select `event_id` or `pipeline_version`; an ordinary fetch could therefore introduce a second display row with the same source key but no v2 identity.

Before completing phone sync, choose an explicit integration path: use synced events/ledger as the sole v2 SMS display source while continuing to fetch non-SMS rows, or add event metadata to transaction responses and canonicalise by event id during fetch-merge. Do not rely on a UUID matching the local `v2:` id or let the legacy parser own new v2 rows.

The new TransactionEntry model can round-trip both fields. LedgerReadModel prefers an existing ledger event over a compatibility row with the same eventId, but cannot infer a missing eventId safely from an arbitrary server UUID. A two-device/reload test must cover this before WP-14 is Done.
