# WP-S6: server release owner (privileges, rollout, verification, review)

Branch `offline/s6`, built on `feature/offline-first`. Server only. Nothing deployed, nothing pushed.
Plan: `OFFLINE_FIRST_MASTER_PLAN.md` sections 4 (D1), 5.1, 7.1. Environment: no `psql` or `initdb` on PATH (Docker CLI present but not used), so nothing below was run against a real PostgreSQL.

## 1. Changes made

| Commit | What |
|---|---|
| privilege manifest | `db/security/product-runtime-privileges.json`: `requiredRoutineAccess` += `app_user` on `pandapay.sync_apply_user_commitment(...)` and `pandapay.sync_apply_change_v2(...)`; `forbiddenRoutineAccess` += `anon` and `authenticated` on `sync_apply_user_commitment`. Both functions already revoke PUBLIC and grant `app_user` in their migrations (`20261115010000`, `20261025150000`); the manifest just did not say so (v2 was only in the forbidden list). 16 added lines, no other edits. |
| clock clamp | `api/src/http_db_errors.js` `parseClientClock`, used by `budgets_write.js` and `recurring_write.js` instead of two copies of `parseClock`. A `clientEditedAt` / `X-Client-Edited-At` more than 5 minutes ahead of the server is clamped to server time (same D9 rule as `/sync/push`). Before, a phone with its clock a year ahead stamped `client_edited_at` in the future and every later edit from any other device came back `superseded:true` for ever. Test added in `http_db_errors.test.js`. |

`pandapay.sync_fields_for` (decision): left alone. It is `LANGUAGE sql IMMUTABLE`, not SECURITY DEFINER, returns a constant list, and has never had a revoke, so `app_user` runs it through default PUBLIC execute (the API calls it in strict mode). Revoking it from PUBLIC would break strict push unless `app_user` is granted explicitly, for a function that exposes nothing secret. Not registered in the manifest for the same reason (nothing to require or forbid). Revisit only if the repo adopts a blanket "revoke PUBLIC on every pandapay function" policy.

No new SECURITY DEFINER function was added by the offline migrations (`20261123010000` only re-declares existing ones; its `CREATE OR REPLACE` keeps the grants). `sync_insert_card_override` (named in the plan) does not exist: WP-S2 deliberately did not add it.

## 2. Verification results

| Check | Result |
|---|---|
| Privilege tests (`db/tests/runtime_privileges`, `shared_expenses_policy`, `release_security_check`, `runtime_privilege_repair`) | 17 / 2 / 42 / 11 pass, 0 fail, after the manifest edit |
| `restored_privilege_review.test.js` | 1 failure (`438 !== 384`), **identical on base `0cb453a7`**: pre-existing, unrelated |
| `portable_backup_coverage.test.js` | 4/4 pass. Offline migrations only add columns, so `coverage.json` needs no change |
| `migration_prefix_policy` (script exit 0, test 5/5), `migration_diagnostics` 4/4, `schema_fingerprint` 10/10, `product_migrate` 15/15 | pass |
| Full API suite, branch (`cd api && npm ci && node --test`) | **2874 tests, 2747 pass, 14 fail, 109 skipped, 4 todo** (the 4 "not ok ... # TODO" lines are known-defect todo cases, not failures) |
| Full API suite, base `0cb453a7` (temporary worktree, removed afterwards) | 2794 tests, 2667 pass, **14 fail**, 109 skipped, 4 todo |

The 14 failures are the same 14 files on both commits: `account_lifecycle_journal_age`, `account_lifecycle_postgres`, `backup_status_postgres`, `catalogue_route_postgres`, `imap_worker_postgres`, `lounge_usage_postgres`, `maintenance_postgres`, `partner_conversion_postgres`, `security_delivery_postgres`, `support_tickets_postgres`, `sync_financial_postgres`, `sync_isolation_postgres`, `sync_transport_postgres`, `sync_typed_changes_postgres`. Run directly, the fixture prints `FAIL ... stage=startup code=check_failed` (no `initdb`). They are environment failures, not regressions. They also mean `sync_*_postgres` and `support_tickets_postgres` have never exercised the offline server changes: run them on a machine with PostgreSQL binaries.

### Migrations added by the offline work (all additive, nothing existing is dropped or rewritten)

| File | Purpose | Reversible? | Risk |
|---|---|---|---|
| `20261123010000_sync_allowlist_and_clock_guard.sql` | Full re-declaration of `sync_fields_for`, `sync_apply_change_v2`, `sync_apply_change` (strict supersets): adds `user_cards.last4`, `annual_fee_override_inr`, `transactions.instrument`, `entry_kind`; typed writer validates annual fee; change_log payload now holds applied fields only | Yes, by re-applying the previous function bodies (`20261023180000`, `20261025150000`, `20261025151350`); no data change | Medium: three hot-path functions replaced. Needs the SQL test on real Postgres. The change_log payload narrowing is the only behavioural change visible to other code |
| `20261123030000_budgets_client_edit_clock.sql` | `budgets.client_edited_at timestamptz NULL` | Yes (`DROP COLUMN`) | Low: metadata-only add |
| `20261123040000_recurring_client_edit_clock.sql` | `recurring_series.client_edited_at timestamptz NULL` | Yes | Low |
| `20261123050000_client_mutation_ids_append_only.sql` | `client_mutation_id uuid NULL` on `notifications`, `user_consents`, `sms_import_batches` + three partial unique indexes `(profile_id, client_mutation_id) WHERE client_mutation_id IS NOT NULL` | Yes (drop indexes, columns) | Low: non-concurrent `CREATE INDEX` takes a short write lock on each table; the index is empty of values so it builds quickly |

## 3. Typed-writes rollout note (`SYNC_TYPED_WRITES_ENABLED`)

### (a) What each value does after `20261123010000`
Runtime accepts only the exact string `true`; the repo default (API, `.env.*.example`, both compose files) is `false`. **The real production value has not been confirmed with the operator.**

| | `false` (legacy `sync_apply_change`) | `true` (typed `sync_apply_change_v2` + transaction domain applier) |
|---|---|---|
| Field list | `sync_fields_for` (now including last4, annual fee, instrument, entry_kind) | typed list, subset of the legacy list (asserted by the SQL test) |
| How a field is written | `($1 ->> field)::text` assigned to the column | typed cast per column |
| Non-text columns (numeric, int, bool, date, enum, uuid) | **rejected** per item (`column ... is of type ... but expression is of type text`, verified on PostgreSQL 18 in WP-S01). So the migration only really helps `last4` in legacy mode; `instrument`, `entry_kind`, `annual_fee_override_inr`, amounts, dates are accepted only with typed writes | accepted, validated (annual fee 0..99999999.99, sub-paise rejected with 22003) |
| Rewards, caps, points, milestones on a transaction edit | **no reconciliation**, no `transaction-ingest` lock (SRV-08 / K13) | applier takes the lock and reconciles |
| Split guard | route re-checks split total for `amount_inr` | applier |
| New permanent rejects | none | card/instrument mismatch and similar domain rejects |

### (b) Recommended order
1. Back up and apply the four migrations on a scratch clone of production first; run section (c).
2. Deploy the API (all changes are additive; old clients see old answers except the three documented exceptions in WP-S345: unknown tag budget 422, invalid notification category 422, invalid Authorization on support tickets 401).
3. Ship the client that sends `strict:true` on `/sync/push` and handles `ignoredFields`, `no_syncable_fields`, `transient`, 409 `device_not_registered`. From then on silent field drops become visible.
4. Confirm the production flag value. If it is `false`, offline edits to amount/instrument/category are rejected, not applied; decide whether to enable typed writes. Do not change `.env.prod.example` or compose defaults for this: set it in the real environment only after `deploy/DEPLOY.md` "Typed sync writes" gates pass (exact-candidate `sync_typed_writes_acceptance` proof registered with `db/scripts/release_security_check.js`, `inputs.features.syncTypedWrites === true`, matching runtime value; rehearse on a full PostgreSQL clone with current and old clients, replay, concurrent edits, reward/split reconciliation).
5. Rollback: setting the flag back to `false` does not undo committed typed writes; fix forward (DEPLOY.md).

### (c) Must be verified on a real PostgreSQL before production
All of these were only checked on PGlite with stubbed schemas, or not at all.
```
psql -v ON_ERROR_STOP=1 -f db/tests/20261123010000_sync_allowlist_and_clock_guard_test.sql
psql -v ON_ERROR_STOP=1 -f db/tests/20261123030000_budgets_client_edit_clock_test.sql
psql -v ON_ERROR_STOP=1 -f db/tests/20261123040000_recurring_client_edit_clock_test.sql
psql -v ON_ERROR_STOP=1 -f db/tests/20261123050000_client_mutation_ids_append_only_test.sql
```
(on a fully migrated scratch DB, each in its own transaction/rollback as the files do). Also: the 14 `*_postgres.js` API fixtures (need `initdb`), `db/tests/runtime_privileges_postgres.js` (confirms the two new required grants and the new forbidden rows against real ACLs; run `node db/scripts/audit_runtime_privileges.js` on the clone), `schema_fingerprint_postgres.js`, and by hand: (1) `POST /user-cards` and `POST /card-overrides` with a client `id` colliding with another profile's row (RLS hides it on SELECT: expect 409 `id_conflict`, not a leak), (2) concurrent replays of one budget/recurring/notification id, (3) `ON CONFLICT DO NOTHING` without a target on `notifications` across both partial unique indexes.

### (d) Request / response contract for client authors
Everything is optional/additive. "Success" below includes `replayed:true` and `superseded:true`.

| Route | New request fields | Responses |
|---|---|---|
| `POST /sync/push` | `strict:true` | per item: `applied, conflicts, reason` (+ `ignoredFields[]`, `clampedClocks[]`); reasons `no_syncable_fields` (permanent), `transient` (retry, do not burn attempt), `rejected` (permanent, `detail`); 409 `device_not_registered` (re-register, retry; push only in strict, always for pull/ack); 503 `transient_db_error` + `Retry-After`; body limit 1 MiB for signed requests |
| `POST /user-cards` | `id` (uuid) | 201 `{userCard}`; 200 `{userCard, replayed:true}`; 200 `{userCard, linkedExisting:true, clientId}` and 409 `{error:'card_already_added', userCard?, clientId}`: remap local id `clientId` to `userCard.id`; 409 `id_conflict`; 400 `invalid_id`; 404 unknown product |
| `PATCH /user-cards/:id` | - | last4 collision now 409 `card_already_added` (was 500) |
| `POST /card-overrides` | `id` (uuid) | 201 `{override}`; 200 `{override, replayed:true}` (stored row, never overwritten); 409 `id_conflict` / `reference_conflict` / `duplicate`; 422 `data_rule_violation`; 400 `invalid_id`; 404 card not owned |
| `PATCH/DELETE /card-overrides/:id`, `DELETE /budgets/:id`, `PATCH /recurring/:id`, `POST /recurring/:id/dismiss`, `POST /notifications/read` (with `id`) | - | non-uuid id: 400 `invalid_id` (was 500) |
| `POST /budgets` | `id`, `clientEditedAt` (ISO, clamped to now+5 min) | 201 `{budget}`; 200 `{budget, replayed:true}`; 200 `{budget, superseded:true}` (stored inactive, newer budget untouched); 422 `tag_unknown`; 400 `invalid_id` / `invalid_client_edited_at` |
| `DELETE /budgets/:id` | header `X-Client-Edited-At` | 200 `{ok:true}`; 200 `{superseded:true}`; 404 on repeat delete (treat as success); 400 bad header |
| `POST /recurring` | `id`, `clientEditedAt` | without either: 201 `{id}` as before. With: 201 `{id, series}` (**adopt `series.id`**: an existing series for the same merchant keeps its id); 200 `{series, replayed:true}`; 200 `{series, superseded:true}` |
| `PATCH /recurring/:id` | `clientEditedAt` | `{ok:true}`; `{superseded:true}`; 404 `not_found` |
| `POST /notifications` | `clientMutationId` (uuid), `createdAt` (ISO, clamped to [now-8d, now]) | 201 `{notification}`; 200 `{notification, replayed:true}` (read_at/created_at untouched, no second push); 204 category muted; 422 `invalid_category`; 400 `invalid_id` / `invalid_created_at` |
| `POST /consents` | `clientMutationId` | 201 `{consent}`; 200 `{consent, replayed:true}`; `granted_at` stays server arrival time |
| `POST /sms-import-batches` | `clientMutationId` | 201 `{smsImportBatch}`; 200 `{smsImportBatch, replayed:true}` |
| `POST /support-tickets` | `id` (uuid) | 201 `{ticket}` always (replay is a 201 too, no limiter charge); 429/503 refusals roll the insert back; bad `Authorization` header: 401 |
| any DB error mapped by `http_db_errors` | - | 400 `invalid_id`, 409 `reference_conflict`/`duplicate`, 422 `data_rule_violation`, 503 `transient_db_error` (retry); bodies are fixed strings |

Idempotency rule on every `id` route: a replay returns the stored row and never applies the new payload. A client that re-sends a *changed* payload under an old id must use the edit route (PATCH / new clock), not a re-POST.

## 4. Whole-diff review (`git diff 0cb453a7..HEAD -- api db`)

Checked: every new route is behind `requireAuth` (support tickets use `optionalAuth`) and runs through `withUserClient` (RLS, `profile_id = req.userId` in every WHERE/INSERT); all SQL is parameterised (the only interpolated identifier is the fixed literal in `documentHandler`, plus the constant `COLS`); catch blocks answer fixed strings, never `err.message`; the notification category list matches `notifications_category_check`; the replay lookup precedes validation of referenced rows only where it is scoped to the caller's profile.

Defects fixed: future client clock poisoning budgets/recurring (section 1).

Not fixed, listed for the owner:
1. **Support tickets, anonymous replay is unmetered.** With an `id`, an existing id returns 201 without charging the limiter; an anonymous caller can create one ticket and then replay it without limit (one cheap transaction each). Only the global request limiter applies. Fix when convenient: charge the limiter for anonymous replays.
2. **Replay hides a payload mismatch.** Same `id` with different content returns the stored row (200 / `replayed:true`) with no warning. Intentional (WP-S2..S5) but the client cannot tell its edit was not applied; the contract above says to use the edit routes.
3. **Notification dedupe replay**: a replay found through `dedupe_key` under a different `clientMutationId` returns the old row and does not refresh title/body (documented in WP-S345).
4. **`POST /user-cards` `linkedExisting` followed by a replay** answers 409 `card_already_added` with `userCard` (the id now holds a last4): the client must treat that as success and remap, as in the table.
5. **Old-client behaviour changes** (all deliberate): the three 422/401 cases in step 2 above; `transient` is not gated by `strict`; `POST /notifications` with an unknown category was a 500.
6. `sms_import_batches` counts are not type-checked (`messageCount: "x"` is a 22P02 -> 500, pre-existing).
7. `/sync/push` clamp only applies in strict mode; non-strict clients can still stamp future field clocks (D9 accepted this).
8. SRV-19 (partial unique index on `is_default`) and sync `is_archived` not stamping `archived_at` remain open (WP-S01).
