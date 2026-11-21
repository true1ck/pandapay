# Timestamp audit (21 Nov 2026)

Why: a restored "Not mine" account was undone by the server because instruments had no
"when did the user decide" time (fixed with `decidedAt`, see below). This audit checks every table
for created / modified / user-action times, so the same rule can be applied app-wide.
Facts only; file:line as of this date. Each fix below is its own reviewed change.

## The convention

| Column | Set by | Used for |
|---|---|---|
| `created_at` | server, once | history |
| `updated_at` | server (trigger or `clock_timestamp()`) | sync cursor, change noise. Never a conflict arbiter. |
| user-action clock (`decidedAt`, `client_edited_at`, `edited_at`) | the phone, only when the user acts, from `ServerClock.now` (`app/lib/data/server_clock.dart`); server clamps to now + 5 min | latest user action wins; absent = fall back to the old rule |
| tombstone | `deleted_at` | deletes |

Already following it: `budgets.client_edited_at`, `user_local_state.client_edited_at` (+ `server_seq`),
`transactions.edited_at` (PATCH only), and now `sms_v2_instruments.decided_at`.

## Done: events (`decidedAt`)
Same pattern as instruments, for events a person decided on (a correction, a confirmed receipt): optional `decidedAt` on the event contract, `sms_v2_events.decided_at` (migration `20261126000100`), `mergeEvent` (the later dated confirmation wins; a stale device loses; an undated one still replaces and keeps the stored time), the phone stamps corrections and receipt answers, and a pulled confirmation replaces an unsent local one only when it is later. One header token, `X-Sms-Contract-Features: decided-at`, now covers instruments and events.

Still open: a user-chosen category on a ledger entry (`categorySource: user`) is resolved by source, not time; two user-sourced writes are last-writer-wins.

## Done: instruments (`decidedAt`)
Contract `instrument.schema.json` (optional `decidedAt`), migration
`20261126000000_sms_v2_instrument_decided_at.sql`, `mergeInstrument` in `api/src/sms_v2/storage.js`
(later dated decision wins; undated writes keep the old "detection never undoes a decision" rule),
sync response strips `decidedAt` unless the phone sends `X-Sms-Contract-Features: decided-at`
(`api/src/sms_v2/sync_route.js`), phone stamps confirm / reject / archive / restore / attachCard
(`instrument_actions.dart`) and `sync_pull.dart` no longer lets an incoming "rejected" overwrite a
newer unsent local decision. Open: the seeder's wallet-card `confirmed` is not stamped.

## Server (Postgres, 227 live tables, no `timestamp without time zone`)
`updated_at` is the only modified name; `pandapay.touch_updated_at()` (`0002_reference_data.sql:4-8`) always
forces `now()`, so a client value can never win on tables with it.

Mutable user data, with the gap:

| table | modified | gap |
|---|---|---|
| transactions | `updated_at` (trigger) + `edited_at` (PATCH only) | seven user edits skip `edited_at` (P1) |
| card_overrides, transaction_splits | none | no modified column (`index.js:2317, 3410`) |
| cap/milestone/fee_waiver_states | `updated_at` (app code) | no trigger; `waived_at` flips skip it |
| transaction_tags, _links | client-supplied `updated_at` | no trigger, no `created_at`, mixed clocks |
| user_cards, user_categories, user_commitments, profiles | trigger | no user-action clock |
| user_settings, self_transfer_rules, foreign_payments | app code + `revision`/`version` | no trigger |
| sms_v2_instruments/events/ledger | `clock_timestamp()` | no `created_at`; cursor ordering (below) |
| shared_expenses.contexts/members/expenses/invitations | none | mutable via 51 UPDATEs, no `updated_at` |
| notifications, user_consents, imap_connections | partial | no `updated_at` |

Problems (file:line):
1. Edits that set only the noisy `updated_at`, not `edited_at`: `api/src/index.js:6287` (note), `6335` (spend exclusion), `6411` (ignore), `6470` (restore), `6205` (bulk category), `4654` (payment method), `4723` (merchant rename). The stale-edit guard (`5554`) compares only `edited_at`.
2. `transactions.updated_at` also moves on system writes (`index.js:3002, 3114, 5769`, `card_state_v2.js:641, 1234, 1278, 1447`), so it is not a "user changed this" clock.
3. `UPDATE fee_waiver_states SET waived_at` skips `updated_at` (`card_state_v2.js:457, 464`, `index.js:4452, 4459`).
4. `sms_sources.projection_version` updated without `updated_at` (`central_financial_projection.js:551`; `sms_facts.js:474` does bump it).
5. Tag tables: client `updated_at` with a 5-minute future allowance (`transaction_tags.js:11, 57-79`), no trigger, also written with server defaults (`:122, 126`) and `GREATEST` merges; a fast clock can lock out later edits.
6. Sync cursor `(profile_id, updated_at, id)` uses `clock_timestamp()`; concurrent transactions can commit out of order and be skipped. `user_local_state.server_seq` and `sms_v2_correction_cases.change_seq` are the sequence-based precedents.
7. Five tombstone styles: `deleted_at` (tag links, commitments), `archived_at` (cards, tags), boolean `deleted` (`user_local_state`), status value (transactions, instruments), hard DELETE (`card_overrides`, budgets).
8. `now()` (transaction start) mixed with `clock_timestamp()` (wall clock).
9. No `created_at`: `transaction_splits`, `points_ledger`, `cap/milestone/fee_waiver_states`, tag tables, `user_settings`, `user_local_state`, `sms_v2_instruments/events/ledger`, `shared_expenses.*`.

## Phone (SQLite)
Three clocks in use: server (`v2_sync_state` `clock:<kind>:<id>`, recorded on pull), `ServerClock`
(`sync_pending_changes`, transaction `edited_at`), and raw `DateTime.now()` (everything else).

| table | modified | user-action time | merge on pull |
|---|---|---|---|
| v2_instruments / v2_events / v2_ledger | none locally (server clock in `v2_sync_state`) | instruments: `decidedAt` (new) | apply if `newer()` and not dirty (see defect 1) |
| financial_entities (transactions, cards, ...) | `observed_at` (raw phone clock) | `edited_at` only via `patchTransaction` | server wins unless pending/newer |
| user_categories, local_commitments, self_transfer_rules, transaction_tags/_links | phone clock or none | none | overwritten from server |
| user_budgets, subscription_overrides | `edited_at`/`updated_at` (phone clock) | same column | last-writer-wins on `clientEditedAt` |
| cached_responses | `fetched_at` (arrival time) | none | `INSERT OR REPLACE` |

Defects (file:line):
1. `sync_pull.dart:176-201`: an incoming `userConfirmed` event that is `newer` overwrites a dirty local event and deletes its outbox rows (an unsent local edit is dropped). (Instruments fixed; events remain.)
2. `sync_pull.dart:109-118`: `newer()` is true when no clock was recorded, even if the incoming clock is null; a null clock is never recorded, so the row re-applies on every pull.
3. `financial_store.dart:1364-1568, 502`: local writes stamp `observed_at` with raw `DateTime.now()`; the gate is `>=`, so a backwards phone clock lets a server snapshot win and a tie goes to the server. Only `patchCard` (`:1668`) guards.
4. `financial_store.dart:805-813, 909`: `markInactive`, `markActive`, `setExcludeFromSpend` and `stamp*` set no `edited_at`; a server copy without `edited_at` always passes the guard.
5. `response_cache.dart:101-131`, `sync_engine.dart:653-656`: only `user_cards` keys pass `requestedAt`; other keys (e.g. `card_overrides`) are overwritten whatever happened in flight; `fetched_at` is arrival time.
6. `user_categories_repository.dart:187-198`: `upsertRemote` overwrites unconditionally, ignores `sync_pending_changes`, never deletes rows the server dropped.
7. `financial_store.dart:913-921`: a pending local row with the same `sourceKey` is deleted before the gated upsert, with no `observed_at` check.
8. `commitments_repository.dart:797-826`: `applyRemote` is `INSERT OR REPLACE` / delete with no clock or dirty flag; table has no time columns.
9. `transaction_tags_repository.dart:511-575`: pull wipes and rewrites tags/links (server rows stamped with the phone's `now`), then replays every outbox row including parked ones; `_link` compares ISO strings (`:386`) of differing fractional length; writes use `DateTime.now()` not `ServerClock`.
10. `user_state_sync.dart:314-391`: `clientEditedAt` compared across devices without skew correction; local value is the raw phone clock (`financial_store.dart:1121`, `user_budgets_store.dart:21`, `subscription_overrides_store.dart:80`); overrides/budgets are layered over server data at read time.
11. `self_transfer_rules.dart:63-103` with `sync_engine.dart:180, 586-594`: every sync deletes all local rules and rewrites from the server, erasing a rule learned on the phone (`remember`, no pending marker) that has not synced yet.
12. `sync_pull.dart:132`, `sync_queue.dart:379`, `financial_store.dart:963`: `markUploaded` / `last_synced_at` use raw `DateTime.now()`.

Clean: `shared_store.dart:894-902` (revision merge), `split_documents` pending/409 flow, `sync_pull` clock strings (UTC with `Z`).

## Priority
- P1 (can lose or mis-order user data): phone defects 1, 4, 6, 8, 9, 11; server problems 1 and 5.
- P2 (reliability): phone 3, 5, 10, 2; server 3, 6 and tables with no modified column.
- P3 (consistency): server 7, 8, 9 (tombstone style, `now()` vs `clock_timestamp()`, missing `created_at`).

Not traced: merge rules for `local_user_cards`, `local_past_bill_receipts`, `local_needs_review`,
`local_auto_resolved_history`; the 51 shared_expenses UPDATE statements were counted, not read.

## Re-verified against origin/dev (21 Nov 2026)
The findings above were first read on an older branch. Checked again on `origin/dev` (HEAD 6bf93fc1):

| Item | Status on dev |
|---|---|
| Server: `PATCH /transactions/:id` | Fixed (`edited_at`, clamp, stale guard; commit fb47fbec, migration 20261125040000) |
| Server: note, spend-exclusion, ignore, restore, payment-method follow-up, bulk category apply | Still present (`index.js` ~6271, 6319, 6395, 6454, 4638, 6189; single-row category UPDATE ~3810) |
| Server: tag tables client `updated_at` (S2), card_overrides / transaction_splits / waived_at (S3), clock_timestamp cursor (S4) | Still present |
| Phone: pull overwrites a dirty `userConfirmed` event (`sync_pull.dart` ~380-405) | Still present (instruments fixed by `decidedAt`) |
| Phone: `patchTransaction` stamps `edited_at` with `ServerClock` | Fixed |
| Phone: `markInactive`, `markActive`, `setExcludeFromSpend` set no `edited_at`; `observed_at` uses raw `DateTime.now()` | Still present |
| Phone: self-transfer rules wipe (`readAfterWrites` covers only in-flight writes, not rules learned locally) | Still present |
| Phone: commitments `applyRemote`, tags wipe and replay, `user_categories.upsertRemote`, `response_cache` `requestedAt` | Still present |

Related fix already on dev: `af5750f8` (a list answered before a write can no longer delete or overwrite it, `write_fence.dart`).
