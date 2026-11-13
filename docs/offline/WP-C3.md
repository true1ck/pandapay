# WP-C3: session loss, sign-out safety, backup coverage

Branch `offline/c3` (based on `feature/offline-first`, which has C1, C2, C4, C8, C9, C12a).
Work package C3 of `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`. Findings: L-01, L-02,
L-05, L-06 (documented), L-11, Q-11 (the three lists C2 left), SRV-03 and SRV-05 (client
halves, documented). Decision D10 (a rejected session keeps everything except tokens).

## What changed

### 1. A rejected session no longer deletes local data (L-01, D10)

The chain was: `SessionRefreshCoordinator._refresh` 401 branch clears the tokens and
`writeAccessToken(null)` -> `cacheNamespaceProvider` flips to `signed-out` ->
`cacheLifecycleProvider` -> `ResponseCache.clearPrefix('<ns>:')` ->
`financialStore.clear(ns)` (bill assignments, manual balances, SMS observations,
provisional rows, coverage, receipts, plus the cached responses) and, in
`syncLifecycleProvider`, `SyncQueue.resetCursor()` (cursor **and** device id). The comment
in the 401 branch said account data stays; the code contradicted it.

* New `lib/data/session_end_reason.dart`: `SessionEndReasonHolder` /
  `sessionEndReasonProvider`. Plain state, not a `StateProvider`, so writing it rebuilds
  nothing. `markSessionRejected()` never overrides an explicit sign-out already under way
  (the sign-out's own server call can itself be answered 401); `markUserSignedOut()` always
  wins; `mayWipeAccountData` is true only for an explicit sign-out. Unknown reason = keep.
* `SessionRefreshCoordinator` got an optional `onSessionRejected`, called in the 401 branch
  before the token is dropped (wired in `sessionRefreshCoordinatorProvider`). Tokens are
  still cleared exactly as before.
* `AccountSignOut` got an optional `onSignOutStarted`, called first in `run()` (before any
  server call or wipe step; an exception from it never stops the wipe). It marks
  `userSignedOut`. `run()` is used by Sign out and by the account-deletion wipe, so both
  keep the old behaviour.
* `cacheLifecycleProvider` clears the account cache and `financialStore` only when
  `mayWipeAccountData`. It also forgets the reason when a session starts again
  (`signed-out` -> user). `syncLifecycleProvider` (`sync_engine.dart`) resets the cursor
  and device id only for the same condition, so after a rejected session the device id,
  the cursor and the queues survive (they are keyed by namespace).

Explicit sign-out is unchanged. Verified in code: `AccountSignOut.run` closes the databases,
`destroyKeysAndTokens` (`TokenStore.clear` + `PhoneWipeHooks.destroyKeys`, which deletes the
database key and every receipt key), `deleteFiles` (`StoragePaths.wipe()` deletes the whole
`PandaPay` root that contains `pandapay.sqlite`; `wipeAccountFiles` also removes
`documents/pandapay.sqlite*`, the attachment folder and the cache directory). The row-level
clear in `cacheLifecycleProvider` ran before that and still runs for an explicit sign-out; it
is belt and braces, nothing is left behind either way.

**Namespaces and leaks.** The same person signing in after a 401 gets the same namespace
(`user:<sub>`) and finds entities, queues, cached responses, device id and cursor. A different
person gets `user:<other sub>` and sees nothing of it (tested). Every table that holds account
data has a `namespace` column except: `cached_responses` (key prefix is the namespace; public
catalogue keys are shared on purpose), `cache_refresh_requests` (keys), `local_user_cards`
(the guest wallet, not account data), the legacy single-row `sync_state` (superseded by
`account_sync_state`), and `transaction_attachments` (no column; the account is the first
folder of the stored path, and the files are encrypted under a per-account key, so another
account can neither list nor open them by transaction id in practice). Leftover rows of a
rejected account stay in the file, decryptable with the same device key, until an explicit
sign-out wipes the whole file (L-06, risk R3 below).

### 2. Sign-out safety (L-02, Q-11)

* New `lib/features/auth/sign_out_queues.dart`. `scanSignOutQueues` counts every `outbox`
  queue of `QueueRegistry` (edits, new expenses, duplicate decisions, `command_outbox`, tags,
  foreign payments, statement import, Split commands and documents, SMS uploads, SMS intake)
  with parked and blocked rows included (they are lost on sign-out too) and the pushed but
  unverified rows excluded (`in_flight = 2` is not in the registry's pending set). It returns
  the total plus the kinds in plain words (`3 new expenses, 2 queued changes`).
  `flushSignOutQueues` attaches one flusher per queue and runs it. Always flushed, as before:
  SMS runtime, sync engine, transaction outbox, duplicate outbox. Every other queue only when
  it has something waiting (so signing out of a healthy account never starts the Split
  runtime or the statement continuation to find them empty). The command outbox uses
  `commandHandlersFor` with the same spend/notification handlers as `outboxFlushProvider`.
  Split documents are awaited directly (`SyncEngine` starts them unawaited since C2, so
  "flushed through `syncEngine.sync()`" no longer waited for them). Outboxes are drained in
  rounds (batch size 20) until a round sends nothing. A failing queue never stops the others;
  a sync cycle that does not finish counts as a failure. The caller's 20 s timeout
  (`AccountSignOut.prepare`) and the 8 s server-step timeout in `run()` are unchanged.
* `account_sign_out_provider.dart`: `report()` and `flushOutboxes()` use the above.
  `readPhoneOnlyCounts` counts receipts for the current account only. The table has no
  namespace column, so `TransactionAttachmentsRepository.storedPathMayBelongTo` reads the
  account folder from the stored path (relative form or the old absolute `.../receipts/...`
  form). A row whose path shows no account folder (an old flat path) is still counted, because
  its owner cannot be proven and a wrong under-count loses data silently.
* `SignOutReport` gained `pendingKinds` and `connection` (`ok`, `offline`, `unreachable`);
  `signOutWarningMessage` has a plain variant for "changes waiting and could not be sent":
  "Your phone is offline, so 5 changes (3 new expenses, 2 queued changes) have not been sent
  and will all be lost if you sign out now ... Connect to the internet and wait for the
  changes to send first if you want to keep them." `unreachable` says "PandaPay could not be
  reached" instead. `connection` is `offline` when the radio is known offline, `unreachable`
  when the flush did not complete or changes are still *waiting* (not parked) after it, else
  `ok`.
* `confirmAndSignOut`: in that case the title is "You're offline" / "Can't reach PandaPay",
  the prominent choice is **Stay signed in**, and the destructive button names the loss:
  **Sign out and lose N changes**. Not a one-tap "Sign out anyway". A `TextButton`, not a
  `FilledButton` (the app theme makes filled buttons full width).

### 3. `pendingRecoveryStatusProvider` (Q-11)

Reads `QueueRegistry`; applied rows are no longer counted. `sms`, `blocked`, `legacy` keep
their meaning (`blocked` = parked rows of edits, duplicate decisions and commands, the three
queues the recovery screen can retry). New keys `parked` (other queues) and `awaiting`
(blocked until something else happens, e.g. a sign-in). `legacy` still reads the raw tables.

### 4. Backup coverage (L-05)

* `LocalPortableSnapshotSource._queues` is built from `QueueRegistry.defaultQueues`. It now
  verifies `v2_outbox` and `command_outbox` and no longer names the four `sms_*_outbox`
  tables that do not exist. Skipped on purpose and already declared: `sms_intake`,
  `split_documents`; `statement_import` keeps its explicit ciphertext count; the shared and
  `financial_pending` counts are unchanged. A row in any counted queue, parked or not,
  blocks the export (it is not in the archive).
* `LocalPortableRestoreWriter` wipes the queues named in `restoreWipedQueues` (registry
  names): the four it always wiped (`sync_pending_changes`, `transaction_tag_outbox`,
  `duplicate_resolution_outbox`, `transaction_outbox_entries`), minus the stale `sms_*`
  names. It does **not** wipe any other queue: deleting unsent work is not something a
  restore should do as a side effect.
* `declaredExclusions` gained `bill_card_assignments`, `manual_bank_balances`
  (`financial_entities` rows of those types), `local_past_bill_receipts`,
  `user_merchant_category_rules`, `command_outbox`, each with a one-line reason. The archive
  format, versions and the server coverage manifest are untouched. Note: neither class has a
  caller in `lib` today (K9), so nothing user-visible changes.

### 5. Device registration across session loss (SRV-05 / SRV-03, client half)

Read in code: the sync device id lives in `account_sync_state.device_id`, per namespace, in
the app database. It is **not** stored anywhere outside the database, so:

| Event | Device id |
|---|---|
| Rejected session (401), same user signs in | **kept** (new in C3; before, `resetCursor()` deleted the row) |
| Explicit sign-out, then sign-in | new (the file and its key are wiped, a new device registers) |
| Reinstall | new (new database) |
| Server no longer knows the id (409 `device_not_registered`, or an old server answering `not_found`) | `SyncEngine` re-registers **with the stale id** and retries once (C2); tested in `sync_engine_queue_hygiene_test.dart` |

So the plan's SRV-03 "a wipe/reinstall that reuses the device id loses commitments" does not
arise from this client: it never reuses the id after a wipe, and a new device starts its pull
at cursor 0. (What a new device's pull at 0 returns is server behaviour, not read here.)

### 6. Token store (L-11)

`TokenStore.save` for a **first** sign-in (no access token held yet) first writes the new
access token under `pandapay_app.access_token_pending` (same Keychain/Keystore, never
plaintext), then the refresh token, then the access token, then deletes the pending entry.
`TokenStore.load` finishes an interrupted write: a pending entry next to a refresh token and
no access token is promoted; a pending entry anywhere else is deleted and never used.
A **rotation** (access token already held) keeps its old order, because the old access token
stays in place until the new one is written, so a death in between leaves a stale but present
access token: offline start works, the first request refreshes. No extra write per rotation.
Why not simply "access first": that would leave (new access, spent refresh) on a rotation,
which depends on the server replaying the rotation, and (access only) on a first sign-in,
which is worse online than (refresh only). `clear()` deletes the pending entry first.

### 7. Retention note (no code)

Nothing in C3 deletes user data. Growth to be aware of for a later hygiene pass:
`sms_captured_messages` (original SMS text, kept only on the phone, only deleted per message
or with the account), `sms_intake` once parsed rows are acknowledged, parked rows in every
outbox (kept on purpose with their error), `v2_*` history, `cached_responses`, receipts (no
size cap), no `VACUUM`. A DB-size readout and a parked-row review list belong with WP-C13.

## Files

New: `lib/data/session_end_reason.dart`, `lib/features/auth/sign_out_queues.dart`.
Edited: `lib/app/providers.dart` (only `sessionRefreshCoordinatorProvider`,
`SessionRefreshCoordinator`, `cacheLifecycleProvider`, `pendingRecoveryStatusProvider`, one
import), `lib/features/sync/sync_engine.dart` (the namespace listener in
`syncLifecycleProvider`, one import), `lib/features/auth/account_sign_out.dart`,
`account_sign_out_dialog.dart`, `account_sign_out_provider.dart`, `lib/data/token_store.dart`,
`lib/data/local/transaction_attachments_repository.dart` (two static helpers, two call
sites), `lib/data/portable_backup/local_snapshot_source.dart`, `local_restore_writer.dart`.

Tests added: `test/data/token_store_interrupted_save_test.dart`,
`test/app/session_rejected_keeps_data_test.dart`,
`test/features/sync/sync_cursor_session_loss_test.dart`,
`test/features/auth/account_sign_out_reason_test.dart`, `account_sign_out_queues_test.dart`,
`account_sign_out_dialog_offline_test.dart`, `test/app/pending_recovery_status_test.dart`,
`test/data/portable_backup/backup_queue_coverage_test.dart`. One existing test edited:
`local_snapshot_source_test.dart` used the stale `sms_facts_outbox` as its "schema drift
fails closed" probe; it now uses `v2_outbox` (same intent, live table).

## Flags and migrations

None. No schema change, no archive-format change.

## Behaviour an online, healthy user can observe

None for a signed-in, online session: no change to token rotation (the extra pending write
happens only on the very first sign-in), sync, the cache or the outboxes. Sign-out of a
healthy account (nothing waiting) shows no warning and wipes as before; its flush also starts
no new runtime (extra queues only flush when they hold something). Differences that exist:

1. After a server-rejected refresh token the phone keeps the account's data (the point of
   the WP) and the sync device id and cursor. Tokens are cleared as before, so the app still
   shows the signed-out screens.
2. Sign-out with changes still waiting that could not be sent shows the stronger dialog;
   sign-out with changes still waiting while online and a clean flush (parked rows only)
   shows the old dialog, now with the kinds in brackets.
3. The report counts more queues (commands, Split, statement import, tags, foreign payments,
   intake) and fewer receipts (current account only).

Explicit sign-out: same order of steps, same wipe, `cacheLifecycleProvider` and the cursor
reset still run (the reason is marked first); tests assert the data is gone.

## Security notes (owasp-mobile-security-checker mindset)

* Tokens: still only in Keychain/Keystore. The new pending entry has the same storage and
  options as the other two, is removed on success, on `load`, and first in `clear()`, and is
  ignored without a refresh token, so it cannot revive a signed-out session. Nothing is logged.
* A rejected session still clears every credential and the refresh request id and revokes the
  iOS SMS capture account (`TokenStore.clear` -> `IosSmsIntakeService.revoke`). Side effect to
  know about: `revoke` resets the native iOS SMS spool (`configure(reset: true)`), so SMS not
  yet imported from the iOS spool at the moment of a 401 are dropped. Not changed (cannot be
  verified without the native side); the original SMS text is also in `sms_captured_messages`
  once imported.
* Data kept after a 401 sits in the same SQLCipher file; the database key is not touched by a
  401 (as before). It is gone on explicit sign-out (key destroyed, file deleted). A different
  account signing in on the phone cannot read it (namespaces), but it is also not removed
  until the next explicit sign-out; that sign-out wipes the whole file, including the other
  account's unsent work, and the report counts only the current account's items.
* Sign-out copy and counts never include amounts, merchants or SMS text, only counts and
  generic kind names.
* Backup/restore: no format change; restore still does not delete unsent queues beyond the
  four it always cleared.

## Risks

1. **Kept data after a 401.** The wiped-on-401 behaviour was effectively a (leaky) privacy
   feature; now an account's cached responses and entities stay on the phone until sign-out.
   Mitigation: namespaced reads, encrypted file, explicit sign-out wipes everything.
   Open (plan risk 8): an orphan sweep after a *different* user signs in was not implemented,
   because deleting unsent work of the first account silently is worse than keeping it.
2. A stale `userSignedOut` reason can only exist between `run()` and the next sign-in, where
   it is cleared in two places; a `sessionRejected` reason is also cleared at sign-in.
3. Unknown reason = keep, so any future path that sets the token to null without going
   through `run()` or the 401 branch keeps data (the safe direction).
4. `sign_out_queues.dart` reads the registry through SQL on the main isolate (a dozen COUNTs
   once per sign-out; not on a hot path).
5. A flusher for a queue can hang (e.g. a Split runtime waiting on the network): the 20 s
   `prepare` timeout still bounds the dialog, and the report then says `unreachable`.

## Plan claims that turned out wrong or weaker than stated

* K10 / L-02: "tags and `split_documents` are flushed through `syncEngine.sync()`". After C2
  the split sync is started unawaited, so sign-out did not wait for it. Now awaited directly.
* L-05 / appendix B: `LocalPortableSnapshotSource` and `LocalPortableRestoreWriter` have no
  caller in `lib` (K9), so the backup lists were drifting without any runtime effect.
* "Count only the current account's attachments (readPhoneOnlyCounts counts all rows)": true,
  but `transaction_attachments` has no namespace column at all; the account is only in the
  path, hence the path-based count.
* SRV-03 reinstall case: this client never reuses a sync device id after a wipe or reinstall.
* L-11 is only reachable on a first sign-in (rotation leaves the old access token in place),
  which is also the only case where it can matter offline.
* Plan 7.2 C3 "Device re-registration on `device_not_registered`": already done in C2
  (`SyncEngine._reregisterDevice`); only the "keep the id on session loss" part was C3's.
* Test 5 of section 9 (`not_found`/unregistered device) is already covered by C2's
  `sync_engine_queue_hygiene_test.dart`; C3 adds the session-loss half
  (`sync_cursor_session_loss_test.dart`).

## How to test

```
cd app
flutter test test/data/token_store_interrupted_save_test.dart test/data/token_store_test.dart \
  test/app/session_rejected_keeps_data_test.dart test/app/session_keepalive_test.dart \
  test/app/pending_recovery_status_test.dart test/features/sync \
  test/features/auth test/data/portable_backup test/data/local test/data/local_first \
  test/data/sync_engine_local_test.dart test/data/sync_engine_queue_hygiene_test.dart \
  test/app/profile_provider_test.dart test/performance_guards_test.dart
```
