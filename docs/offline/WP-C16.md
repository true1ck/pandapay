# WP-C16: read paths work offline and never stall

Branch `offline/c16`. Every change is additive: an online, healthy user gets the same data, screens and ordering.
(Reachability "unknown" is never a reason to skip a request, so an unprobed healthy user behaves as before.)

## What changed
| Area | Change | Online healthy user |
|---|---|---|
| `loadTransactionsWithOfflineCache` | Network failure (offline-like) with a local snapshot returns `local.rows`, even empty. Never-synced store still errors. | Unchanged (only the failure path differs). |
| `_skipBackgroundRead(ref)` (new, providers.dart) | Radio down **or** `ServerReachability.shouldSkipBackgroundReads`. Used by `_warmDisplay`, lounge usage, points ledger, bank-account summaries, contribution stats, profile cold miss. | Unknown reachability = no skip. |
| Home refresh (`homeDataRefreshProvider`) | Skipped when unreachable; 8 s cap (`_backgroundReadTimeout`) on its reads; no provider invalidation when every request failed; `displayDataSyncLifecycleProvider` will not start a second burst within 15 s of Home's own refresh. | Same reads, 8 s instead of 15 s timeout on this background burst. |
| Transaction detail | Saved row paints first, server copy refreshes in the background and replaces it (consumed once, so an edit's invalidate never replays a stale row). `local-outbox:` rows were already viewable/cancellable (provisional row in the store). | Row appears instantly, then updates. |
| Deleted transactions | Built from local `ignored` rows (`FinancialStore.deletedTransactions`) merged with the server list; server list cached under `<ns>:deleted_transactions`; shows "Saved data" caption when served from that cache. Restore stays queued. | Same list (server rows, plus anything deleted on the phone not yet synced). |
| Categories | `assets/data/bundled_categories.json` (15 built-ins from `0014_seed_reference.sql` + emi) is the last fallback of `categoriesProvider`; used immediately when there is no cache and the API is known unreachable. | Untouched when the network works. |
| `categorySpendProvider` | No cache + offline-like failure: trailing-12-month totals from local transactions. | Unchanged. |
| `SavedDataCaption` | `features/sync_status/saved_data_caption.dart`; used only on Deleted transactions. | n/a |

## Known gaps / decisions
- Bundled category ids are placeholders (`bundled:<slug>`): the real ids are random UUIDs assigned by the database and are not in the repo. `categoryIdForServer` maps them to `null`, so a transaction queued with a bundled category reaches the server uncategorised (server auto-classifies). They are never cached, so the next online refresh swaps in real ids.
- Home ranking flip on a late `cardOverridesProvider`: not changed here. WP-C6 makes that provider cache-first, which removes the flip; editing its body is out of scope.
- Points ledger is still one request per card when online and uncached; offline/unreachable with a cache is served from cache. No batch endpoint was added.
- `notificationsProvider` is owned by WP-C11. Editing a `local-outbox:` row (optional) was not done.
- Only the Home burst got the 8 s cap; per-provider reads (`userCardsProvider` etc.) keep `_homeRequestTimeout` (15 s).
- `deletedTransactions` filters with `json_extract` in SQLite over the transactions entity (not a Dart decode of every row), but is still O(history) on the caller isolate; the screen is opened rarely.

## Tests
`app/test/offline/c16_*_test.dart`.
