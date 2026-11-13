# WP-C6: cards and card overrides work offline

Findings: L-03, W-06, W-07, W-08, W-15 (and the archived-cards read) of the master plan. Branch `offline/c6`.
Master switch: `kCardsLocalFirst` in `lib/features/cards/add_card_local_first.dart` (`false` restores the old network-first flows).

## How an online healthy user is unaffected

Every write helper asks a reachable server first, exactly as the screens did, and only falls back to the phone-first path
when the server is not there (offline, a recent failed probe, timeout, 5xx). A real refusal (4xx) is still shown as before; a
409 `card_already_added` on a direct tap still reads "already in your wallet". Reads keep their old result; the only change
for an online user is that the override list and the archived-cards list are served from the saved copy and refreshed in the
background (after any write they clear the saved copy first, so the next read is the server's answer).

## What changed

* **L-03 (test first).** `FinancialStore.replaceCards` no longer deletes `pending=1` card rows. A card added on the phone is
  stored with `pending=1`; the server copy replaces it (same id) or the add command remaps it. Test:
  `test/data/local/financial_store_pending_cards_test.dart` (failed before the fix).
* **Add card** (`add_card_local_first.dart`, `addCardLocalFirst(ref, ...)`). Client uuid; one bounded (8 s) attempt with the id
  when the server looks reachable; otherwise a provisional card (catalogue name/type) is stored pending and an `add_card`
  command is queued. Used by find cards (3 sites), my cards, scan result. `found_instruments_screen.dart` and
  `add_first_card_screen.dart` were left alone (other owners); they can call the same helper.
* **Replay and remap.** `UserCardsRepository.addCardWithClientId` sends `id`; 200/201 give the server id, 409 `card_already_added`
  (or `linkedExisting`) is success-with-merge. `remapLocalId(db, ns, from, to)` (pure helper `remapIdInJson` + SQL) rewrites the
  card row (drops the provisional row if the server card is stored), pending transaction rows, queued sync edits, queued commands
  (target and payload), the transaction outbox and the cached override list. An old server that ignores `id` is handled because
  the id in the response always wins.
* **Order.** `CommandOutbox.flush(onlyKinds:)`: `outboxFlushProvider` and the sign-out flush send queued `add_card` first, before
  the transaction outbox, so queued quick-adds name a real card.
* **Failure.** A permanent 4xx parks the add (kept, counted by the top strip through the existing `command_outbox`
  `QueueRegistry` entry). The wallet tile shows "Saving..." / "Not saved" (`cardSaveStatesProvider`). No new table, so nothing
  new to register: all new kinds (`add_card`, `card_fields_patch`, `create_override`, `delete_override`) live in `command_outbox`.
* **Edit card.** `_save` goes straight to the phone when the server is known unreachable or the card is only queued. Offline:
  field edits go to `SyncQueue` as before; `last4` / `annual_fee_override_inr` ALSO go as a `card_fields_patch` command (the card's
  own PATCH route) because an old server drops them from `/sync/push`; points balance is queued as `OverlayCommand.pointsAdjust`
  (client mutation id) instead of being refused; a card that is still queued gets its edits folded into the `add_card` payload
  (`patch`), a separate follow-up command is created after the add succeeds.
* **One path for archive / pause / un-archive / default** (`card_state_local_first.dart`): `setCardArchived`, `setCardDefault`,
  `queuePointsBalance`, `refreshAfterCardChange`. Both `card_actions_screen.dart` and `edit_card_screen.dart` use it (the two
  copy-pasted network-first versions are gone). Un-archive offline is now queued (`is_archived:false`).
* **Overrides** (`override_local_first.dart`, `card_overrides_overlay.dart`). Create (`create_override`, client id, provisional
  row), delete (`delete_override`, 404 = done, a still-queued create is just cancelled), toggle/edit (sync queue, or folded into a
  queued create) all show at once through `overlayCardOverrides`. `cardOverridesProvider` is cache first with a quiet background
  refresh, skips the network when the server is known unreachable, and applies the overlay to whatever it returns.
  "Always use this card here" in scan result uses the same helper.
* **Duplicate review.** `duplicateCandidatesProvider` caches the list (`<ns>:duplicate_candidates`), serves it when the server is
  unreachable, and hides candidate ids already in `duplicate_resolution_outbox`.
* **Archived cards.** `archivedCardsProvider` shows the saved include-archived snapshot at once (background refresh), and with no
  snapshot and no server uses the phone's own archived rows. Restore stays online-only (plain copy already there).

## Files

New: `lib/features/cards/add_card_local_first.dart`, `lib/features/cards/card_state_local_first.dart`,
`lib/features/overrides/override_local_first.dart`, `lib/data/local_first/card_overrides_overlay.dart`,
tests `test/data/local/financial_store_pending_cards_test.dart`, `test/features/cards/add_card_local_first_test.dart`,
`test/features/cards/card_local_first_flows_test.dart`.

Edited: `financial_store.dart` (`replaceCards` only), `command_outbox.dart` (`onlyKinds`), `user_cards_repository.dart`
(`addCardWithClientId`, `toJson` for the duplicate models), `card_overrides_repository.dart` (`id`, 200 on replay),
`providers.dart` (`cardOverridesProvider`, `duplicateCandidatesProvider`, `archivedCardsProvider`, `commandHandlersFor` + the
`outboxFlushProvider` flush order, `_backgroundDisplayRefresh`, two imports), `sign_out_queues.dart`, `find_cards_screen.dart`,
`my_cards_screen.dart`, `scan_result_screen.dart`, `edit_card_screen.dart`, `card_actions_screen.dart`, `manual_overrides_screen.dart`.

## Known gaps / risks

* A queued sync edit for a still-provisional card id (for example a wallet reorder after an offline add) can reach `/sync/push`
  before the add is delivered and be refused by the server; the remap rewrites it afterwards but a row the server already
  rejected is not revived. Provisional ids are not filtered out of `LocalFirstCards.reorder`.
* A queued transaction naming a provisional card is sent after the add (flush order), but if the add itself is failing with a 5xx,
  the transaction outbox still tries and may be parked. Queued overrides wait (plain error, backoff) instead.
* Guest (signed-out) find-cards adds now store the SMS-discovered last four (the helper passes it through).
* Un-archive offline is applied through the sync queue; if the same product and last four was added meanwhile the server refuses it
  and the change is parked.
* Server side (WP-S2) was not available: the contract is implemented from the brief and tested with fakes only.
