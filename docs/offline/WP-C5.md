# WP-C5: local-first transaction writes

Findings: W-01..W-05 and SRV-21 of `docs/offline/OFFLINE_FIRST_MASTER_PLAN.md`. Branch `offline/c5`.

## What changed

* **Bulk actions (W-02).** `features/activity/bulk_transaction_actions.dart` splits the
  Activity selection by id kind: SMS (`pipelineVersion == 2`) rows use the existing local SMS
  actions (category, hide) and are skipped for "assign card"; `local-outbox:` rows are edited
  (`TransactionOutboxRepository.editQueued`) or cancelled; server rows get a `SyncQueue` field
  edit (category/card are allowlisted) or an `ignore_transaction` command with the row hidden
  locally (`financialStore.batch`). Each id is independent; failures are counted and shown
  ("N could not be changed"). Bulk delete no longer sends `v2:` / `local-outbox:` ids to the server.
* **Voice (W-03).** Each draft editor holds one `clientMutationId` for the sheet's life. Entries
  are written to the outbox (`INSERT OR IGNORE`, so the same id is one row) and tags use the
  `local-outbox:` alias. `saveVoiceEntries` never re-saves an entry and keeps going past a
  failing one. Points redemption is a queued `points_adjust` command (own id, reason now
  carried by the handler) plus a local card overlay. Messages are plain.
* **Payment-sent (W-04).** "Log it" enqueues with a per-screen id. The outbox now keeps
  `merchant_vpa`, `mcc`, `rail` (LocalFirstSchema migration 2, additive nullable columns), which reward
  matching needs. The acceptance report catches every error.
* **Quick add (W-05).** With a receipt and a phone known offline (or server unreachable) the save goes through the
  local-first path and the receipt is stored under `local-outbox:<id>`;
  `userCardsRepositoryProvider.onTransactionSaved` now also calls
  `TransactionAttachmentsRepository.remapTransaction` (alias to server id, same hook tags use).
  Online saves with a receipt are unchanged. Undo after delivery is an `ignore_transaction` command
  with the row hidden at once (works offline).
* **Edit transaction (W-01).** (a) After the local save the screen closes first; the bulk-review and future-rule offers
  run from the root navigator with a 4 s limit and are skipped offline/unreachable. (b) While online,
  `instrument`/`entry_kind` go through the domain PATCH (fall back to the sync queue only on a network
  failure); offline they are queued. A server `rejected` is already `queue.reject(...)` (parked), so
  the sync strip counts it as needs-attention. (c) Offline payment-method change is a
  `transaction_payment_method` command (`features/payments/payment_method_command.dart`, one-line hook in
  `commandHandlersFor`) with a local overlay (`FinancialStore.patchTransaction`). (d) Self-transfer
  confirm/undo stays online-only: the PATCH also writes rules and can re-label history, so it is not
  idempotent by state; refusal copy is now plain.
* **occurredAt (SRV-21).** `logTransaction` and `editTransaction` send `toUtc().toIso8601String()`.

## Online healthy user

Same results and screens. Differences are mechanism only: voice and payment-sent entries appear at
once and are delivered by the outbox flush (as quick add already did); bulk actions and quick-add Undo
apply locally then sync; online instrument/entry_kind edits still use the PATCH route.

## Tests

`test/data/occurred_at_utc_test.dart`, `test/features/activity/bulk_transaction_actions_test.dart`,
`test/features/activity/edit_transaction_offers_test.dart`, `test/features/voice/voice_save_test.dart`,
`test/features/scan/payment_sent_offline_test.dart`, attachment remap in
`test/data/local/transaction_attachments_repository_test.dart`, offline method/instrument/self-transfer
cases in `test/features/payments/edit_payment_method_test.dart` (two existing expectations updated: online
instrument change is now a direct PATCH).

## Known gaps

* A quick-add receipt save offline is not covered by a widget test (needs the file picker).
* A queued payment-method overlay can flash back if a server refresh lands before the command is delivered.
* The queued-row "edit" in bulk assumes the entry is still undelivered; if delivered meanwhile it is reported failed.
