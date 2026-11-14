# WP-C8 - Split (shared expenses) offline fixes, Wave 1

Branch `offline/c8`. Plan: `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md` (X-01..X-03, SRV-18, decision D3 option a).
Scope here is fixes only. The local-read fallback and the pending overlay (D3 b, X-04 first-view) are Wave 2.

## What changed

| Finding | Change | Where |
|---|---|---|
| X-03 ordering | Every enqueue gets a real monotonic `created_at` (wall clock, never repeats or goes back in this process). A caller-supplied positive `createdAt` is kept exactly. | `SharedExpensesStore._stamp` |
| X-03 / SRV-18 dependsOn | A non-create command that names a context whose `context.create` is still queued, sending, retrying or waiting for sign-in now waits for that create's receipt (reuses the existing `shared_command_dependencies` claim clause). Covers invites, renames, expenses, responses. If the create is refused for good, the commands waiting on it are refused too (`dependency_rejected`) and shown under it, not as separate problems. | `_enqueue`, `_rejectDependents` |
| SRV-18 403 | 403 `context_not_authorized` is retryable only while that context's own create can still commit; once the create is committed (or there is none) it is a real refusal as before. 409 with `retryable` and 429 were already retried; 429/503 now honour a `Retry-After` (whole seconds, max 1 h, the longer of that and the 5s doubling backoff). | `SharedExpensesStore.fail`, `SharedTransportException.retryAfter`, transport `_retryAfter` |
| X-02 reconnect | `SharedExpensesStore.resetBackoff()` and `SharedExpensesRuntime.reconnect()` (never throws). The lifecycle provider calls it from the resume observer and the connectivity listener; the 45 s timer still honours the backoff. | `shared_providers.dart` |
| X-02 cap | A temporary server error (5xx, 408, 429, retryable 409, pending-create 403) is tried `sharedMaxAttempts` (10) times, then the command is rejected with `retry_limit:<code>` and appears in needs-attention. A command that never got an answer (network unreachable) never counts toward the cap. Backoff stays 5s*2^n (max 320 s). | `fail` |
| X-01 needs attention | `attentionCount`, `readAttention`, `requeue` (Retry, fresh budget, same bytes) and `discard` on the store; "N need attention" row on the Split hub; "Not synced" sheet with plain-language reason, Retry and Discard. A refusal the screen already explained (taken name) is discarded on the spot so it does not also show here. | `shared_attention_sheet.dart`, `shared_routes.dart`, `acknowledgeRefusal` |
| Providers | `sharedAttentionCountProvider` (Split commands), `blockedSplitCountProvider` (private per-transaction splits, `SplitRepository.blockedCount`) and the combined `needsAttentionCountProvider` in `runtime/shared_attention.dart` (for a later global indicator). | |
| Capability flags | `canQueueProposals` / `canQueueSettlements`: unknown flags (never loaded) allow queueing; a known-off flag still blocks. Used by `submit`, add friend, rename, approve/reject, settlement report/respond, hub buttons, members sheet. `shared:capabilities` is re-saved after the `shared:` cache prefix is cleared by a revocation. | `shared_runtime.dart` |
| Approve/confirm offline | The buttons are no longer hidden when `runtime.offline`; the notice reads "Saved on this phone - will send when you're online". Operation ids stay deterministic, so a replay is the same command. | `shared_expense_review.dart`, `shared_settlements_sheet.dart` |

Offline group creation no longer opens the members sheet (it needs the server's roster); it shows a snackbar that the group will be created when online.

## No behaviour change for an online healthy user

- Same claim order for already-stamped commands (the editor already passed `DateTime.now()`); only the formerly `0`-stamped ones now sort by save time instead of random id.
- The new dependency only applies to a command whose create has not committed; in the online flow the create is awaited before anything is added to the new context.
- Retry classification is unchanged for every code except the one 403 above; the attempt cap only triggers after 10 temporary server errors.
- The new hub row and sheet render nothing at zero.

## Files

Store: `features/shared_expenses/storage/shared_store.dart`. Transport: `data/shared_transport.dart`, `data/shared_http_transport.dart`. Sync: `sync/shared_sync.dart`. Runtime/providers: `runtime/shared_runtime.dart`, `runtime/shared_providers.dart`, `runtime/shared_attention.dart` (new), `runtime/shared_routes.dart`, `runtime/shared_expense_review.dart`. UI: `ui/shared_attention_sheet.dart` (new), `ui/shared_members_sheet.dart`, `ui/shared_settlements_sheet.dart`, `ui/shared_presentation.dart`. Private splits: `data/local/split_repository.dart` (`blockedCount`), `features/sync/split_sync.dart` (`blockedSplitCountProvider`).

No migration, no new tables (existing columns `created_at`, `state`, `attempts`, `next_attempt`, `error_code`), no flags.

## Tests

`flutter test` on: `test/features/shared_expenses/storage/shared_store_offline_test.dart` (new), `sync/shared_sync_test.dart`, `data/shared_http_transport_test.dart`, `data/shared_runtime_offline_test.dart` (new), `data/shared_expense_review_test.dart`, `ui/shared_settle_members_test.dart`, plus the existing `test/features/shared_expenses/**` and `test/data/split_repository_test.dart`.

[I] items proven with a failing test on the old store before the fix: independent commands claimed by random operation id instead of enqueue order; invite before create classified `rejected` on 403.

## Known gaps / follow-ups

- Wave 2: hub/group/balances from `readContexts/readPage`, pending overlay, private-split first view offline (X-04), a way to resolve a blocked private split from the needs-attention sheet (today it says to open the transaction).
- `quick_add_screen.dart` (not owned here) still gates "add to a split" on `proposalsEnabled`; it needs the roster from the server anyway.
- The global "N need attention" indicator is another package; it should watch `needsAttentionCountProvider`.
- Old servers: unchanged wire format; `Retry-After` is only read when sent.
