# WP-C17: sync bill-card picks, typed bank balances, subscription overrides

Branch `offline/c17`. Kill switch: `kSyncLocalState` in `app/lib/features/sync_state/user_state_sync.dart` (false = as before).
Server: WP-S7 (`/user-state`). An old server answers 404: kept local, never parked, asked again only after an app restart.

## How it works
* Edit time: `financial_entities.observed_at` (set to now by every user edit) for bill assignments and typed balances,
  `subscription_overrides.updated_at` for overrides. No schema change.
* Push: after each local write the screen calls `queueUserStatePush(ref, kind, key)`. It queues `user_state_put` (row exists) or
  `user_state_delete` (row gone, or a bill with no card) in `command_outbox`, target `<kind>/<key>`; a later command for the same
  target replaces either kind (`CommandOutbox.enqueue(replaces:)`). Handlers ride on `accountCommandHandlers`, so the background
  flush and the sign-out flush send them. QueueRegistry already counts `command_outbox`.
* Pull (`user_state_pull.dart`): `userStatePullProvider` (read from `outboxFlushProvider`) on sign-in, offline-to-online and resume
  (1 min debounce), through `startupWorkSchedulerProvider`. LWW on `clientEditedAt` per (kind,key); a queued local push counts as a
  local edit; ties keep the phone; tombstones delete unless a newer local edit exists; `undecryptable` items are skipped. Applying an
  item never queues. A bill naming an unknown card is kept. The opaque cursor is kept in memory per namespace (so a fresh or restored
  phone, which holds no rows, always starts from scratch); pages until `hasMore` is false.
* Privacy: payloads are never logged; errors carry only status and server error code; nothing goes to ResponseCache or analytics.
  Balances sit in `command_outbox` only until delivered.

## JSON the client sends
PUT `/user-state/<kind>/<key>` body `{"payload": {...}, "clientEditedAt": "<UTC ISO>"}`; DELETE with header `X-Client-Edited-At`.
* `bill_card_assignment` (key = bill/observation id): `{userCardId, billKey, amountDuePaise, dueDate, statementDate}`
* `bank_balance` (key = `<canonical bank>:<last4>`): `{id, balance_paise, updated_at, amount (rupees), accountLabel, label}`
* `subscription_override` (key = series id, only `v2:`/`projection:`/`manual:` ids): the stored override object as is.

## Not done / risks
* Pull cursor is not persisted across app starts (full pull each run; small).
* On an old server queued commands stay pending (backoff) so the top strip shows them; nothing is sent until restart.
* Screens that write these stores elsewhere (not found) would not push; hooks are at the 6 call sites found.
* A bill with a null card is sent as a delete.
* Tests: `test/features/sync_state/user_state_sync_test.dart` (26).
