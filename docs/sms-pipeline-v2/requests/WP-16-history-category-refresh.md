# Explicit history category refresh

The owner requested a deliberate testing flow for previously imported history and stable behaviour on subsequent syncs. The implementation adds a Debug preview/apply control in History update and extends local migration to pick up retained sources arriving after its initial completion.

`POST /sms/v2/categories:batch` uses the existing facts-batch request and response schemas. Its source, instrument and event arrays must be empty. The route has the existing SMS feature, membership, attestation, rate and row-ownership gates. The category path updates existing ledger category fields and active display categories only. It preserves user category authority, checks that money fields match the stored reading, and avoids reward/card-state projection. When a stale phone conflicts with stored money or a user category, the canonical ledger is touched for the next pull. The normal facts path also preserves stored user categories against incoming automatic categories.

The phone keeps category-only queue metadata locally and uses this dedicated endpoint. An older server returns 404, retaining the pending job. New schemas, applied-migration changes, production flags and key changes are outside this addition.

Replacing already-matched immutable facts remains a separate contract review. The versioned-generation proposal is recorded in history-recheck-plan.md.
