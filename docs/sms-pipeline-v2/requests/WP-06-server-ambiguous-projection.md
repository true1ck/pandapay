# WP-06 / WP-08 integration: ambiguous events must not become transactions

During the ledger integration review, `api/src/sms_v2/projection.js` was found to project an ambiguous purchase as an active spend even with no ledger entries. The phone projector correctly excludes it, but the existing server reports would still count the server row.

A new failing regression demonstrates this for purchase, income, investment, refund and card-bill events. The local integration fix adds one status guard to `entryKindFor`. Existing WP-08 retirement/reversal logic then handles a previously projected row if it becomes ambiguous. No legacy route, migration or contract changes.

This session is performing the integration review requested by the owner; this narrowly scoped cross-package fix is explicitly recorded here. The nested server suite is also added to CI, because `npm test` alone only globs top-level tests.
