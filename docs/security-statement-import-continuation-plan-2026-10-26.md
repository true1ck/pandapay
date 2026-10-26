# Statement import continuation: receipt prerequisite

**Progress — 26 October 2026:** the [encrypted mobile continuation source slice](security-mobile-import-continuation-implementation-2026-10-26.md) now implements the bounded exact-batch queue, same-account foreground resume, receipt handshake and backup/restore admission described below. It remains default off. The following prerequisite/follow-up plan is retained for context; signed-device/transport acceptance and distributed/provider budgets remain open.

## Implemented prerequisite

The optional receipt path is enabled by the parent through
`STATEMENT_IMPORT_RECEIPTS_ENABLED`, default off. With the flag off, the
statement route uses its legacy SQL and behavior, and it does not reference
the new nullable columns. With the flag on, keyed requests store a SHA-256
request digest and the original `{ imported, pendingDuplicates, exactRetries
}` response counters on the same `statement_imports` row and in the same
transaction as the ledger writes.

An exact same-key, same-semantics replay returns the persisted response
summary. A same-key request whose digest differs returns HTTP 409 before the
route invokes the financial transaction writer. A pre-migration/legacy row
without a stored digest keeps the prior duplicate response behavior; it is
never sent back through the financial writer. Keyless summary-only imports
remain on the legacy path. Supplying `importKey` to a summary-only request in
receipt mode opts that request into receipts.

The digest is SHA-256 for consistency checking, not secrecy or anonymization.
It includes the route's supported semantic fields, keeps transaction array
order, canonicalizes object key order, normalizes fields as used by the
handler, and hashes the masked account string rather than the raw account
string. Unknown top-level and transaction properties remain ignored by the
route and are excluded from the digest. The receipt stores no PDF, password,
raw transaction payload, or raw account value.

## Follow-up client continuation slice

The next small client change should persist a complete bounded import plan
before the first request, then submit the saved batches sequentially through
the existing authenticated `POST /statement-imports` contract. Keep the
current 250-row / 64-KiB batch limits, existing import keys, and stable row
keys. Mark each batch complete only after a 200 or 201 response. After process
death, replay the same saved body and key; the receipt returns the original
batch result when the server committed but the response was lost. Keep the
existing 200/201 behavior; do not introduce HTTP 202 or a server worker in
this slice.

Likely client files are `app/lib/data/local/app_database.dart`, a dedicated
statement-import outbox repository, `app/lib/data/transaction_import_pipeline.dart`,
`app/lib/data/import_repository.dart`, import-flow/provider resume plumbing,
and targeted tests. Gate the new behavior behind a default-off client flag
until local durability and restore behavior are reviewed.

Before that queue is enabled, settle these rules:

- Namespace each pending session to the signed-in profile and refuse to send
  it under another account. Coordinate its runner with
  `AccountRecoveryOperationGate`.
- Pending payloads contain financial descriptions and amounts. The current
  app database is plain SQLite. Decide whether to use an encrypted store or
  accept device-local SQLite storage with strict size caps, short expiry,
  immediate payload deletion after confirmed batches, and explicit UI for
  expired/cancelled sessions.
- Include the new queue in account-switch/signout cleanup and decide whether
  portable backup must block while it is pending. Do not silently export or
  discard pending financial input.
- Persist the exact batch payload, `importKey`, and ordinal before sending;
  regenerating them from a later preview could rebind a committed key or
  change the import selection.
- Bound pending sessions, batches, total serialized bytes, attempts, and
  expiry. A failed or ambiguous request stays resumable; confirmed batches
  can drop their payload while retaining minimal local progress metadata.

## Scope and remaining checks

The server continues to process one POST atomically using the existing
`insertTransactionAndUpdateState` path, preserving its transaction lock,
source-key idempotency, observation writes, tagging, and reward-state
reconciliation. `sync_apply_change_v2` is not a transaction-creation path.
Do not move this work to an async server worker without a separately reviewed
narrow capability: the existing JS category resolution and financial state
transition logic must remain intact, and the general API database role has
broad table privileges.

Release order: apply the additive migration first, keep the feature flag off
until the receipt SQL fixture passes on the disposable fully migrated clone,
then enable receipts before any client durable-resume rollout. Confirm the
server and mobile rollback order preserves exact replay behavior.
