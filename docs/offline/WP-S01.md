# WP-S0 + WP-S1: server sync hardening

Branch `offline/s01`. Server only (`api/`, `db/`). Not merged, not pushed.
Plan: `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md` sections 5.1 (SRV-01..07, 09, 14), 7.1.

## What changed

### WP-S0: database error mapper
- `api/src/http_db_errors.js`: `classifyDbError`, `respondDbError(res, err)`, `isTransientDbError`, `isUuid`, `rejectInvalidUuid(res, value)`.
  - 22P02 -> 400 `{error:'invalid_id'}`; 23503 -> 409 `reference_conflict`; 23514 -> 422 `data_rule_violation`; 23505 -> 409 `duplicate`; 57014 / 40001 / 40P01 -> 503 `{error:'transient_db_error', retryable:true}` plus `Retry-After: 1`.
  - Bodies are fixed strings; the database message, detail and constraint never reach the client.
- Adopted only in the sync routes (register-device, push, pull, ack, conflict-ack catch blocks).
- uuid guard (one line each, `api/src/index.js`): `PATCH /recurring/:id`, `POST /recurring/:id/dismiss`, `DELETE /budgets/:id`, `PATCH /card-overrides/:id`, `DELETE /card-overrides/:id`, `POST /notifications/read` (only when an `id` is given). A non-uuid id such as `v2:abc` or `projection:x` now answers 400 `invalid_id` instead of 500 (22P02).

### WP-S1: sync push/pull hardening
- `api/src/sync_push_handlers.js` (new): entity -> handler registry plus the per-item pipeline (savepoint, dispatch, result shaping). The previous inline branches are now handlers: `user_categories:insert`, `user_commitments:*`, `user_merchant_category_rules:*`, and the generic fallback (transactions / user_cards / card_overrides, legacy or typed). A later package adds handlers with `registerSyncPushHandler(entity, ops, handler, {usesFieldAllowlist})` without touching the loop.
- `api/src/sync_request_validation.js`: `strict` flag parsed (key present only when exactly `true`, so the validated value for old clients is unchanged); fixed rejection detail for a last4 identity collision; re-exports the helpers the route needs (the route fragments are evaluated in sandboxes that only see this module's exports, see `sync_transport_routes.test.js` and `sync_transport_postgres.js`).
- `api/src/sync_push_body.js` (new): dedicated 1 MiB JSON parser for `/sync/push`, mounted in `index.js` before the global 100 KiB parser. Only requests that already carry a validly signed access token get the larger limit; anonymous requests keep 100 KiB and then get 401 from `requireAuth`. The 200-change limit is unchanged.
- Migration `db/supabase/migrations/20261123010000_sync_allowlist_and_clock_guard.sql` (see below) and its SQL test.
- `api/test/card_state_v2.test.js`: the C8 D23d source-scan guard looked for the transaction-ingest lock inside the `/sync/push` route in `index.js`; the lock now lives in `applyGenericChange` in `sync_push_handlers.js`, so that one entry points at the new file (same invariant: lock before `applyTransactionSync`).

## Request / response contract

All of this is additive. Unless noted, a client that does not send `strict:true` sees exactly the old responses.

| Behaviour | Old client (no `strict`) | New client (`strict:true`) |
|---|---|---|
| Result keys for a normal item | `clientSeq, entityId, applied, conflicts, reason` (unchanged, same order) | same, plus the fields below when relevant |
| Payload keys not on the allowlist | silently skipped, item may report `applied:true` | `ignoredFields: [...]` on every result for transactions / user_cards / card_overrides; `[]` for entities with a dedicated SQL function (their allowlist lives inside that function, not reported) |
| Update with nothing syncable | `applied:true, reason:null`, a no-op change_log row | `applied:false, reason:'no_syncable_fields'`, nothing written (no change_log row) |
| Field clock more than 5 minutes ahead of the server | stored as given | clamped to the server clock; `clampedClocks: [field,...]` returned |
| Unknown / unregistered `deviceId` on push | 200, every item `rejected` (unchanged) | 409 `{error:'device_not_registered'}` before anything is applied |
| DB timeout / serialization failure / deadlock inside one item | `reason:'rejected'` (permanent) | `reason:'transient'` (retryable) |
| Unknown `deviceId` on pull / ack | was 500, now 409 `{error:'device_not_registered'}` | same |
| Request-level transient DB error | was 500, now 503 `retryable:true` | same |

Decisions:
- **Clock guard = clamp, not reject.** Rejecting would retry the same stale clock for ever on a phone whose clock is hours ahead (the client stamps clocks at edit time). Clamping lets the edit land, ordered as "now", and stops the clock from winning every later conflict. Tolerance 5 minutes (`SYNC_CLOCK_TOLERANCE_MS`). The clamp is done in the route (JS) so no SQL signature changed; `reason:'clock_in_future'` is not used.
- **`transient` is not gated by `strict`.** The shipped client treats any unknown reason as retryable (`SyncPushResult.isPermanentFailure` only lists not_found / malformed / unknown_entity / rejected), so this only turns a wrongly-permanent outcome into a retry. The transient item is rolled back to its savepoint; later items still run.
- **Device 409 on push is gated by `strict`.** For the shipped client a non-200 push throws and is swallowed by `SyncEngine._sync`, with nothing re-registered. That would trade "all changes parked as rejected" for "sync stuck, changes kept" for old clients; harmless but a behaviour change, so it is opt-in. Pull/ack were 500 before (also swallowed), so 409 there changes nothing for old clients.
- **Pull/ack 409 is detected after the fact**: the SQL raises 42501; only then does the route check `user_devices`. The happy path costs no extra query. A 42501 for any other reason stays 500.

### Client follow-ups (another package)
- Send `strict:true` on `/sync/push`.
- On 409 `device_not_registered` (push, pull, ack): call `register-device`, store the new id, retry.
- Treat `no_syncable_fields` as permanent (surface it; it means the client queued fields the server will never accept), `transient` as retryable without burning an attempt.
- Treat `ignoredFields` non-empty as a visible warning (this is SRV-01).

## Migration `20261123010000_sync_allowlist_and_clock_guard.sql`

Full-function replacement of three functions, each a strict superset of its latest definition:

| Function | Previous latest | Added |
|---|---|---|
| `pandapay.sync_fields_for` | `20261023180000` | `user_cards`: `last4`, `annual_fee_override_inr`; `transactions`: `instrument`, `entry_kind` |
| `pandapay.sync_apply_change_v2` (typed) | `20261025150000` | `user_cards`: `last4`, `annual_fee_override_inr` (typed already had instrument / entry_kind); `annual_fee_override_inr` rejects negative (23514) and sub-paise (22003) like `credit_limit_inr` |
| `pandapay.sync_apply_change` (legacy) | `20261025151350` | uses the new `sync_fields_for` list |

`payment_method` and `exclude_from_spend` are deliberately not added (own routes).

**change_log payload** is now only the applied fields (both writers). All-lost / nothing-allowlisted changes are still logged, with `{}`. Checked consumers: the Flutter pull path re-fetches authoritative rows and never reads card/transaction payloads (`sync_engine._pullAndApply`, `sync_transaction_delta.dart`); `user_commitments` and merchant rules use their own functions (untouched); `sms_amount_audit.js` only tests for row existence; `portable_backup/restore.js` copies rows. Not changed: grants (CREATE OR REPLACE keeps them), argument lists, return shapes.

A last4 collision (23505 on `uq_user_cards_active_identity`) is a per-item permanent reject with the fixed detail "Another active card already uses these last four digits." Inside `/sync/push` every item error was already a per-item `rejected` (never a 500); the 500 the plan mentions is `PATCH /user-cards` (S2).

SQL test: `db/tests/20261123010000_sync_allowlist_and_clock_guard_test.sql` pins the COMPLETE field list of every sync entity for `sync_fields_for` and for the typed writer (read from the function source), checks typed fields are a subset of the legacy list, last4 / annual fee / instrument / entry_kind apply, the guards, the identity collision, applied-only change_log payloads (typed and legacy), and unknown-entity / unregistered-device results.

## Tests

API (run from `api/`, `node --test test/<file>`):
- new: `http_db_errors.test.js` (mapper, uuid guards on the six routes via the real route source), `sync_push_strict.test.js` (strict mode, ignoredFields, no_syncable_fields, device 409 on push/pull/ack, clamp, transient, last4 detail, registry), `sync_push_body_limit.test.js` (limit, anonymous fallback, mount order).
- unchanged and green: `sync_request_validation`, `sync_transport_routes`, `sync_transaction_state`, `sync_typed_configuration`, `request_boundaries`; full `node --test test/*.test.js` is green.
- SQL: `psql -v ON_ERROR_STOP=1 -f db/tests/20261123010000_sync_allowlist_and_clock_guard_test.sql` on a fully migrated scratch DB.
- Not runnable without a loopback Postgres: `api/test/sync_*_postgres.js` (they extract the same route fragments, which still resolve; the re-exports keep their sandboxes working).

## Known gaps / findings
- **Legacy writer cannot write non-text columns.** `sync_apply_change` assigns every column as `($1 ->> field)::text`; PostgreSQL only allows that for text-like targets (reproduced on PostgreSQL 18: `sort_order` and `annual_fee_override_inr` fail with "column ... is of type ... but expression is of type text"). So with `SYNC_TYPED_WRITES_ENABLED=false` most edits (amount, dates, ints, booleans, enums, uuids) are rejected, not silently rounded as plan K13 / SRV-08 assume. Adding fields to the legacy list therefore only helps text columns (`last4`) there. Not fixed here (changing it would make raw, unreconciled money writes succeed); belongs to decision D1 / S6.
- **SRV-19 not done.** No partial unique index on `is_default` exists (confirmed by grep), but adding one can fail on existing data and `UPDATE ... SET is_default = (id = $2)` flips two rows in one statement, so it needs a data check and a design pass first. Sync `is_archived` also does not stamp `archived_at` (REST does); left alone.
- `ignoredFields` is `[]` (not computed) for entities with dedicated SQL functions.
- `sync_fields_for` is called by the API as `app_user`; it relies on its default PUBLIC execute (no migration revokes it). Not added to `db/security/product-runtime-privileges.json` (S6 owns that file).
- No new SECURITY DEFINER functions, so no privilege-manifest change was needed.
