# Rejected instruments retire server financial projections

Orchestrator approved this narrow WP-14/WP-08 integration fix after the cross-device Not mine review. The phone owner handles rejection adoption and local ledger/transaction removal in SyncPull, preserving pending user corrections.

Approved files: `api/src/sms_v2/storage.js`, `projection.js`, and their logic/Postgres tests. No request/response or error schema changes.

An accepted instrument-only rejection now locates the profile's affected events through stored ledger endpoints. Projection reads instrument status, deletes all ledger entries belonging to an event that involves a rejected instrument, marks the derived transaction ignored, and reverses previously applied card state once. Its unchanged event is emitted again by sync so another device can clear its local ledger. The frozen sync response has no ledger tombstones; the rejected instrument and re-emitted event drive local reprojection.

A financial transaction requires at least one INR ledger entry. Event-only stale uploads cannot recreate a row after rejection. Resent ledger entries referencing the rejected instrument are purged again. Automatic `detected` instrument uploads preserve stored `confirmed` or `rejected` decisions. Explicit confirmed/rejected choices remain available; their conflict ordering is bounded by the frozen contract's lack of an explicit user-decision clock.

Validation: 25 pure logic tests and 20 real disposable-Postgres tests pass. The latter includes instrument-only rejection, sync event emission, one-time card-state reversal, event-only replay, full stale replay including ledger and detected instrument, and ownership isolation. The disposable database needed the already-integrated WP-10 migration before the pre-existing whole-route sync test could run.
