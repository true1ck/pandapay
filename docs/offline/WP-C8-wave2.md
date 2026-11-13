# WP-C8 wave 2 - Split readable and creatable offline

Branch `offline/c8r`. Plan: master plan R-02 / X-04 (decision D3 option b). Wave 1 (ordering, dependsOn,
retry rules, needs-attention) is in `WP-C8.md`.

## What changed

Order on every Split screen: saved copy paints first -> live refresh -> **stored records on this phone** ->
error only if nothing is stored anywhere. No screen file changed; the runtime answers in the server's own JSON
shape so the existing mapping code is reused.

| Piece | Where |
|---|---|
| Local fallback (`SharedLocalReads`): contexts (hub friends / groups), context detail, members, expenses, balances, totals, built from `shared_projections` via `store.readContexts` / `readPage` (one page, max 100 rows per section, no history walk) | `runtime/shared_local_reads.dart` |
| Hook: `_admittedQuery` consults it when a live fetch fails (non-refusal error) and no saved copy exists; the "live failed -> older saved sections" paths run `runCacheOnly(allowLocal: true)`. Refusals (401/403/404, account_changed, feature off) still surface. | `runtime/shared_runtime.dart` |
| Pending overlay: `loadHub` adds waiting groups / friends (subtitle "Waiting to sync") and a "Waiting to sync - ..." activity line per queued command; `loadGroup` leads the first expense page with queued expenses (review label "Waiting to sync"). Matched by context id / expense id, and a command that commits leaves the pending list, so the server copy never shows twice. Works online too (a create still queued behind a slow server). | `loadHub`, `loadGroup`, `_waitingExpense` |
| Group created offline: opens with just the owner and accepts an expense. The server picks the owner's member id at create time, so queued commands use the stand-in `sharedPendingOwnerMemberId(contextId)`; when the create's receipt arrives the store rewrites every waiting command of that context to the real id (same operation id, new bytes/hash, in the commit transaction). Immutability trigger is bypassed by replacing the row (delete + insert) inside `complete`. | `data/shared_commands.dart`, `storage/shared_store.dart` (`_adoptOwnerMemberId`) |
| Private per-transaction split (X-04): never loaded + offline (or the first GET fails with a network/5xx error) opens an EMPTY editable split, version 0, `fetched_at` = epoch so the first online read refreshes it unless it was edited. First save is `pending=1`; on reconnect the existing `expectedFingerprint` / 409 / blocked / `resolve` flow reconciles. A 4xx on first fetch is still an error. | `data/local/split_repository.dart` |

## Integrator hand-offs

1. **Quick add** (`features/quickadd/quick_add_screen.dart` ~436-440, not owned here): the "add to a split" gate can use
   `runtime.offlineEditorContext(contextId)` - synchronous, local only, returns `({name, ownMemberId, members})` or null
   (null = this phone knows nothing of that split; then use `editorContext` online). It includes pending groups (owner
   only) and friends added offline (as `invited`). `runtime.contexts()` (the picker list) now also falls back to local
   records and includes waiting groups/friends (`membershipState: active`, `waiting: true`). `editorContext(id)` itself now
   also works offline for the same cases.
2. **Transaction detail** (`transaction_detail_screen.dart` ~340): no change needed; `SplitRepository.read` no longer
   throws offline, so the "Connect once to load..." message is no longer reachable from there.
3. Add the Split pending overlay count to any global banner via the existing `needsAttentionCountProvider` (unchanged).

## No behaviour change for an online healthy user

Local records are only consulted when a live fetch failed with a non-refusal error and no saved copy exists (plus the
overlay of commands that are still queued, which is empty for a healthy user). `_isDenied` now treats "no saved copy of
an extra section (overview, personal activity)" as a missing extra, not a refusal.

## Known limits (honest)

- Hub totals strip and per-row owed/owing are unknown from local projections (the feed carries no overview): rows read
  "Some balances missing" and the strip is marked incomplete. Group balances and totals ARE computed locally.
- Hub activity tab offline shows only waiting commands (no per-context activity projections are walked).
- Search, later cursors and the expense review sheet (revisions, single expense) stay online-only; the first 100 expense
  records of a group are shown offline (no pagination).
- A friend/group created offline still needs the server before people can be invited (members sheet refuses offline).
- Offline expense shares only include the owner (and friends added offline, who are `invited`).
- Settlement reports queued offline have no row in the group screen (they show in the hub activity as waiting).
- Server contract note: the owner member id is server-generated; the stand-in rewrite lives on the client. A server
  `ownerMemberId` in `context.create` would remove it.

## Tests

`test/features/shared_expenses/runtime/shared_runtime_local_reads_test.dart` (hub / group from local with the network
down; nothing stored still errors; group created offline waits then appears once; expense added offline to a pending
group keeps the real owner id; offline editor context; friend added offline), `storage/shared_store_wave2_test.dart`
(owner stand-in rewrite), `test/data/split_repository_test.dart` (never-loaded split opens empty, saves, 409 reconcile,
baseline replaced by the server copy, refusal still an error).
