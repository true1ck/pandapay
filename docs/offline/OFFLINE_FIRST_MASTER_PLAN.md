# PandaPay — Offline + Online: master findings register and multi-agent execution plan

Date: 2026-11-13 · Branch audited: `dev` · Status: **investigation complete, no code changed.**
Supersedes the planning parts of `docs/OFFLINE_FIRST_AUDIT_AND_PLAN_2026-11-13.md` (kept as the per-screen inventory, Appendix A).
Read section 0 first. Sections 1-4 explain the state of the app, 5 lists every finding, 6-9 are the executable plan for several agents.

Evidence tags used everywhere: **[V]** verified by reading the code (a second reader re-checked it), **[R]** verified by running a test, **[I]** inferred from code/SQL, not executed. Anything tagged [I] must be proven with a test *before* its fix is merged (each work package says so).

---------------------------------------------------------------------------------------------------

## 0. How to use this document

| Role | Read |
|---|---|
| Owner / product | 1 (summary), 4 (decisions), 11 (rollout), 12 (risks) |
| Orchestrator (the Claude session that spawns agents) | 6-9 in full, then 5 as needed |
| Implementing agent | 8 (protocol), your work package in 7, the findings it lists in 5, the files it owns in 6 |
| Reviewer / QA agent | 9 (test strategy), the acceptance criteria of the WP under review |

**Non-negotiable rules for every agent** (details in section 8):
1. **Additive only.** New tables, columns, routes, RPCs, files. No renames, no behaviour change for an online, healthy user.
2. **Public repo.** The remote is public. No real SMS, names, phone numbers, account numbers, tokens or keys in code, tests, fixtures, logs or commit messages. Synthetic data only.
3. **Fix on `dev`, merge `dev` into `prod`, never touch `master`.** Agents never push and never merge; the orchestrator integrates.
4. **Performance rulebook** (`docs/PERFORMANCE_RULEBOOK.md`): no O(history) or whole-table work on the UI isolate, `cachedRegExp` not `RegExp(`, `INDEXED BY` for id lookups. Run `flutter test test/performance_guards_test.dart` when touching read paths.
5. **Do not symlink `node_modules` into worktrees** (a past `--force` removal emptied the real folder). Run `npm ci` inside the worktree's `api/`.
6. **Prove [I] items before fixing them** with a failing test, then make it pass.
7. **Stay inside your owned files** (section 6). Hotspot files (`providers.dart`, `router.dart`, `index.js`, `app_database.dart`, `financial_store.dart`, `sync_engine.dart`) are edited only at the anchors your WP names, and everything else goes into new files.

---------------------------------------------------------------------------------------------------

## 1. Executive summary

1. **The app is already mostly offline-first.** SQLCipher database, response cache, field-edit `SyncQueue`, `CommandOutbox`, transaction outbox, SMS v2 outbox, Split command queue. Cold start offline for a signed-in user works: the router has no network gate, and a network error never signs the user out [V].
2. **The remaining problems are specific, and most share seven root causes** (section 3): network-first writes with a late queue fallback; a server that silently drops fields while reporting success; pull that is not a rebuild source; retry/backoff hygiene; connectivity that means "radio up" not "server reachable"; local-only data destroyed on session loss; no visible state.
3. **The five worst issues (data loss or core flow blocked):**
   1. **Silent edit loss.** Edits to `instrument`, `entry_kind` (transactions) and `last4`, `annual_fee_override_inr` (cards) are queued, the server returns `applied=true` but stores nothing, and the next materialize overwrites the local edit. This happens **online as well**, because plain edits always go through `SyncQueue` [V].
   2. **A rejected refresh token wipes local-only data.** On a refresh 401 the app's own comment says local data stays, but the namespace flips to `signed-out` and `cacheLifecycleProvider` calls `financialStore.clear`, deleting bill-to-card assignments, manual bank balances, SMS observations and provisional rows [V]. Reachable after ~90 days offline or any server-side revoke.
   3. **Local notifications never fire offline** (preferences fetched live, no cache) [V].
   4. **Duplicates and blocked creation.** Voice save and "payment sent → log" create a new id per attempt (duplicate on retry); Add card, create/delete override, new budget, subscription add and statement import are online-only [V].
   5. **Sign-out silently discards queued work** (`CommandOutbox`, shared commands, statement imports, foreign payments are neither counted nor flushed) [V].
4. **Corrections to the first audit** are in section 2.
5. **The plan is 25 work packages in four waves** (section 7), designed so up to ~8 agents run in parallel on disjoint files, with an explicit merge order, test gates and rollout flags. Server changes ship first and are backward compatible with installed app versions.

---------------------------------------------------------------------------------------------------

## 2. Corrections to the first audit (what changed on re-investigation)

| # | First audit said | Verified reality |
|---|---|---|
| K1 | "Silent drop → reverts at the next pull, offline edits only" | Reverts **right after the push** (`_materialize` fetches all server rows and `saveTransactions(completeQuery: TransactionQuery())` overwrites). Happens **online too**, for every plain edit (`edit_transaction_screen.dart:495-517`). `payment_method` and `exclude_from_spend` are **not** queued by the edit screen (own routes), so they are not part of this bug. [V] |
| K2 | `last4` dropped in `20261021000000` | Dropped by accident in **`20261019144500_sync_user_category_field.sql`** (re-declared `sync_fields_for` from an old template); later migrations copied the omission. `0039` and `20261013120000` added them on purpose, with a comment describing exactly this failure. Restoring is safe. Neither the legacy nor the typed writer accepts them, so **enabling the typed flag does not fix cards**. [V] |
| K3 | `card_overrides`: no insert, no delete | **Delete is supported** over `/sync/push` (legacy and typed). Replay returns `not_found`, which the client must treat as success. Insert is not. There is a sixth sync entity the first audit missed: **`user_merchant_category_rules`** (update-only, version-based `stale_revision`). [V] |
| K4 | `/sync/pull` can rebuild offline state | **It cannot.** `change_log` is written only by sync pushes and a few RPCs (`user_categories`, `user_commitments`, merchant rules). REST/SMS-created and REST-edited rows, card creation, budgets, recurring, tags etc. never appear; the client rebuilds them from GET routes. `user_commitments` has **no GET route** (pull is the only read path). [V] |
| K5 | `SyncBackupScreen` shows pending counts and last-synced | The screen has **no caller** in `lib` (tests only). No reachable UI shows sync state. `SmsSyncStatusLayout` is iOS-only. [V] |
| K6 | "Add an offline banner/indicator" | The owner **removed offline banners on purpose** (commit `37f7d9c7`, 2026-10-18; `test/features/home/offline_banner_test.dart` asserts Home never shows "You're offline"; no written reason). The plan must not reintroduce a Home banner without an explicit decision (D2). |
| K7 | Data export is local, OK | `GET /export` is the only source for CSV/JSON; only the PDF render is local; unsynced rows are excluded. **BUG, M.** |
| K8 | Notification gate: OS banner and dedupe mark before inbox POST | Order is: preferences → mute lookup → dedupe mark → **awaited inbox POST** → OS banner. Offline the preferences await throws first (silent). On captive Wi-Fi the banner waits up to 30 s. |
| K9 | Gmail/IMAP/portable backup: "NET" | The Gmail-connect, IMAP, SyncBackup, CardSkinPreview, CSV-import screens and `PortableBackupHttpRepository` have no caller. Treat as **dead**, not "legitimately online". |
| K10 | Sign-out report omits tags/splits flush; `sms_intake` not counted | `flushOutboxes` **does** flush tags and `split_documents` through `syncEngine.sync()`; `sms_captured_messages` **is** counted. Still not counted/flushed: `command_outbox`, `shared_commands`, `statement_import_*`, `foreign_payments_outbox`. |
| K11 | Split group create + invite is randomly ordered offline | Ordering is random for same-kind independent commands only. Friend setup already uses `dependsOn`. A group invite can't normally be built offline because the roster needs the server. The real failure is **server 403 `context_not_authorized` treated as permanent** whenever an invite beats its own create. |
| K12 | Corrections parked after "attempts ≥ 6" | The real mechanism: a correction waits only while its source row is in the outbox with `attempts < 6`; after an offline spell the source is in a 30-minute backoff and the correction posts first, gets `correction_facts_not_found`, is re-enqueued once with `_resent`, and parked on the second refusal. `requeue` may not reset `attempts` when the payload is byte-identical [I]. |
| K13 | Typed writes flag: enable (a) or migrate (b) | The **legacy path does a raw column UPDATE with no reward/cap/points reconciliation and no `transaction-ingest` lock**; offline edits to amount/card/category desync `cap_states`, `milestone_states`, `points_ledger`. The typed path reconciles, but adds new permanent rejects (card/instrument mismatch). The decision (D1) is a correctness decision, not just a field-list decision. |
| K14 | Connectivity: "no seed, certain bug" | Android and iOS **do** emit the current state on first listen (`connectivity_plus 7.3.1`). It is a startup-timing hardening **plus** the real problem that interface state ≠ reachability (captive Wi-Fi reads as online, so every fallback waits 15-30 s). |

---------------------------------------------------------------------------------------------------

## 3. Root causes

| # | Root cause | Findings |
|---|---|---|
| RC1 | **Network-first writes** with a queue only in `catch`, gated on `isOnline == false`; or no queue at all | W-* |
| RC2 | **Server drops fields and reports success**; legacy writer has no reward reconciliation; allowlist regressed by accident | SRV-01, 02, 08 |
| RC3 | **Pull is not a rebuild source**; REST edits have no clocks, so stale offline edits overwrite newer ones | SRV-03, 09, 10 |
| RC4 | **Queue hygiene**: attempts burned offline, backoff never reset on reconnect, no park/poison handling, one bad row blocks others, no timers | Q-* |
| RC5 | **"Online" = radio up**, not "server reachable"; 15-30 s waits on captive Wi-Fi; `_isKnownOffline()` unseeded | C-* |
| RC6 | **Session loss / sign-out destroys or ignores local-only and queued data** | L-* |
| RC7 | **No visible state, no offline-aware errors**, copy-pasted "saved offline" messages | U-* |

---------------------------------------------------------------------------------------------------

## 4. Decisions needed from the owner (each has a recommended default)

| ID | Decision | Options | Recommended default | Blocks |
|---|---|---|---|---|
| D1 | Fix route for silent field drop and offline reward correctness | (a) enable `SYNC_TYPED_WRITES_ENABLED`; (b) new migration restoring fields in legacy+typed lists; (c) client guard only | **(b) now** (restore `last4`, `annual_fee_override_inr`, add `instrument`, `entry_kind`; strict mode reports ignored fields) **and plan (a) separately** under the existing release gate, because only (a) reconciles rewards. Confirm the real production flag value first (repo default is `false`). | WP-S1, C5, C6 |
| D2 | Offline visibility UI | (a) none; (b) quiet cues (freshness caption, "N waiting" chip in Settings/You, needs-attention list); (c) restore a global banner | **(b)**. Respect the banner removal; show offline wording only on failure states and write confirmations. Wire or delete `SyncBackupScreen`. | WP-C13 |
| D3 | Split offline depth | (a) fix ordering + failure visibility only; (b) full local read fallback + pending overlay | **(a) in Wave 1, (b) in Wave 2** | WP-C8 |
| D4 | Scheduled local reminders | inexact allow-while-idle (no exact-alarm permission) vs exact alarms | **Inexact.** `USE_EXACT_ALARM` is restricted by Play policy; `SCHEDULE_EXACT_ALARM` is denied by default on Android 14+. | WP-C14 |
| D5 | Baseline SMS rules bundle | ship a signed non-empty baseline vs keep empty | **Ship a signed baseline** via `api/scripts/release_sms_v2_bundle.js`; signing keys are env-only, so this is an owner task. | WP-C9 |
| D6 | Background sync (WorkManager/BGTask) | now / later / never | **Later** (spike only, WP-C15): cross-isolate refresh-token rotation and keystore access are real risks. | none |
| D7 | `PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED` (off by default) | on / off | **On** with auto-resume, after WP-C10 tests | WP-C10 |
| D8 | Consent-policy bump while offline | block SMS reading until re-prompt vs treat previous-version consent as granted | **Treat previous-version mirror as granted** until a re-prompt is possible online; revoke must always work offline. | WP-C11 |
| D9 | Clock skew policy | none / server clamp of future client clocks (+5 min) / baseClocks | **Server clamp + client uses server-time offset from `Date` header.** | WP-S1, C1 |
| D10 | Session-rejected (401) data | keep everything / keep local-only entities / clear | **Keep everything** except tokens; clear only on explicit sign-out (which wipes the file anyway). | WP-C3 |
| D11 | Bundling bank logos | bundle top ~15 issuers / download-and-cache once / leave | **Download-and-cache** via existing http client (no new dependency, no trademark files in a public repo). | WP-C12 |
| D12 | Dead code | delete / keep | Delete after the visibility decision (D2); list in appendix D. | optional |

---------------------------------------------------------------------------------------------------

## 5. Findings register

Severity: **H** data loss, wrong result or core flow blocked · **M** feature blocked/slow/misleading · **L** cosmetic or rare. "WP" is the work package that fixes it (section 7). Rows from the first audit keep their meaning; see Appendix A for screen-by-screen tables.

### 5.1 Server (SRV)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| SRV-01 | H | Non-allowlisted fields in `/sync/push` are skipped; if all are skipped the item returns `applied=true, conflicts=0, reason=null` (legacy `20261025151350_legacy_sync_context_isolation.sql:188-195`; typed `20261025150000_sync_apply_change_v2.sql:185-195`). No error reaches the client. | V | S1 |
| SRV-02 | H | `sync_fields_for` regressed by accident in `20261019144500` (lost `last4`, `annual_fee_override_inr`); later migrations copied the omission. The function is a full replace, so every re-declaration must be a strict superset. Neither writer accepts these two fields. | V | S1 |
| SRV-03 | H | `/sync/pull` only returns `change_log` rows (sync pushes, categories, merchant rules, commitments). REST/SMS rows, REST edits, card create/archive, budgets, recurring, tags, settings are never in it. **Commitments have no GET route**: a device never receives its own writes back, so a wipe/reinstall that reuses the device id loses them. | V / I (reuse) | S1, C3 |
| SRV-04 | M | `change_log.payload` stores the whole submitted payload (including dropped fields and losing values) while `field_clocks` stores only winners; other devices pull payload values the server never stored. Every replay appends another row. | V | S1 |
| SRV-05 | H | Unknown/unregistered `deviceId`: push items all raise 42501 → reported as `rejected` (permanent in the client); pull/ack raise 42501 → HTTP 500. `register-device` always returns 201 and creates a new row for stale/missing ids. Client never re-registers on `not_found`, so one pass can park up to 200 pending changes. | V / I (revoke path) | S1, C3 |
| SRV-06 | H | `/sync/push` is one DB transaction; JSON body limit is **100 KiB** globally (`request_limits.js:7`); count limit 200. A `user_commitments` document can be 16 KiB. The client sends `pending(limit:200)` as a single request; any non-200 throws and the head of the queue blocks forever. | V | S1, C2 |
| SRV-07 | H | Transient DB errors inside an item (57014 statement timeout, 40001/40P01 deadlock) are reported as `reason:'rejected'` with a generic detail; the client treats `rejected` as permanent. Most route catch blocks return 500 for permanent errors (22P02 uuid format, 23503, 23514), which the client treats as retryable-forever. | V | S0, S1, C2 |
| SRV-08 | H | With `SYNC_TYPED_WRITES_ENABLED=false` (default in compose/env examples; real prod value unseen), sync edits are a raw UPDATE: no reward/cap/points reconciliation, no `transaction-ingest` advisory lock (race with ignore/restore), legacy numerics via text casts round sub-paise values silently. `PATCH /transactions/:id` does reconcile. | V | D1 |
| SRV-09 | H | No clock validation: a phone clock ahead poisons per-field clocks (other devices lose until real time catches up); behind loses to everything. REST/SMS/email writes carry no clock (treated as 0), so any queued sync edit, however stale, overwrites a newer REST edit **without a conflict row**. | V merge / I effect | S1, C1 |
| SRV-10 | M | Whole-document entities resolve by arrival order, not edit time: `user_commitments`, `user_categories` insert (upsert), `PUT /user-settings`, `POST /budgets`, `POST /recurring`, `PATCH /profile`. A replay can revert a newer edit. | V | S3, S4, S5 |
| SRV-11 | H | `POST /card-overrides` is not idempotent (no unique key): a duplicate row per replay. | V | S2 |
| SRV-12 | H | `POST /user-cards` has no client id (natural-key dedupe only, 409 `card_already_added` / `linkedExisting`). `PATCH /user-cards` last4 collision (23505) falls to a generic 500. No client-chosen id exists for transactions or cards, which is the root of the remap problem. | V | S2 |
| SRV-13 | M | `POST /budgets` replace semantics with a new id each call; a stale replay deactivates a newer budget. | V | S3 |
| SRV-14 | H | `POST /recurring` upsert resurrects a dismissed series and clobbers newer edits on replay. `PATCH /recurring/:id` and `/dismiss` with a non-uuid id (e.g. the app's `v2:<key>`) → **HTTP 500** (22P02). The server also emits `projection:<key>` ids. Same 500 for `DELETE /budgets/:id`, `PATCH/DELETE /card-overrides/:id`, `POST /notifications/read {id}`. | V | S0, S4 |
| SRV-15 | M | `POST /notifications` with `dedupeKey` re-surfaces on replay (`created_at=now()`, `read_at=NULL`); without a key duplicates; `GET /notifications` returns only the last 8 days; an invalid category hits a CHECK → 500 (poison). | V | S5 |
| SRV-16 | M | `POST /consents`: a new row per replay (`granted_at=now()`; this arrival time is the ordering key, keep it). `POST /support-tickets`: duplicate on replay; the limiter is charged before insert (5/h authed); `optionalAuth` turns a stale token into an **anonymous** ticket. `POST /sms-import-batches`: duplicate summary row. | V | S5 |
| SRV-17 | L | `POST /transactions/:id/ignore` second call → 409; `/restore` second call → 404. Client must treat matching state as success. | V | C2 |
| SRV-18 | H | `member.invite` before its `context.create` → 403 `context_not_authorized` (indistinguishable from "not owner" by design). No server ordering. Client treats 403 as permanent. Also 409 retryable and 429 must be retryable. | V | C8 |
| SRV-19 | M | Two default cards possible via sync (no partial unique index seen); sync `is_archived` doesn't stamp `archived_at`. | I | S1 |
| SRV-20 | M | `db/security/product-runtime-privileges.json` appears to lack `sync_apply_user_commitment` in the required/forbidden lists. | I | S6 |
| SRV-21 | M | `occurredAt` is sent as an offset-less ISO string from a local `DateTime` (`user_cards_repository.dart:1756`); `new Date(...)` on the server (`index.js:4763, 5714`) may shift IST times by 5 h 30 m if the server zone is UTC. | I | C5 + S0 probe |
| SRV-22 | L | Account data-reset deletes `user_devices`, `change_log`, `sync_cursors` (generic loop `20261028150000:155-165`). | I | doc |
| SRV-23 | L | Auth: access token 15 min, refresh 90 d rolling (`REFRESH_MAX_IDLE_MINUTES` default 129600). >90 d offline → 401, re-login. No clock-skew tolerance. | V | doc/C3 |

### 5.2 Sync engine and queues (Q)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| Q-01 | H | `TransactionOutboxRepository._flush` takes the oldest 20 rows every time, records `last_error` only (no attempts, park or backoff), never shown. 20 permanently rejected rows starve all newer ones; the provisional row stays visible forever. | V | C2 |
| Q-02 | M | `duplicate_resolution_outbox` counts every error (even offline) as an attempt → parked after 5 failed flushes on flaky Wi-Fi. `command_outbox` backoff (30 s → 30 min) counts offline attempts and is only re-evaluated at the next trigger (no timer). A 500 for a non-uuid target loops every 30 min forever and keeps the pending badge > 0. | V | C2 |
| Q-03 | M | Only `shared_commands` (45 s) and `v2_outbox` (15 min) have timers. `SyncQueue`, command, transaction, tag and foreign outboxes drain only on reconnect/resume/write. | V | C2 |
| Q-04 | M | Tag outbox: attempts incremented, no backoff/park, one 15 s HTTP timeout per row, never parked. `foreign_payments_outbox`: no attempts/next_attempt columns; drains only on `fetchAll`/mutation (no reconnect trigger). | V | C2 |
| Q-05 | H | Statement import: reviewed rows live only in widget memory; the encrypted continuation outbox is behind `PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED` (default false) and never auto-resumes. | V | C10 |
| Q-06 | M | `_push` calls `_materialize` (full `GET /transactions` + two `GET /user-cards`) **before** removing acked rows; a network drop there leaves server-applied rows queued and re-pushed; O(history) per push. | I | C2 |
| Q-07 | M | `SyncEngine._sync` awaits `splitRepository.sync` (up to 50 sequential PUTs × 30 s) before the edit push; a throw aborts the whole push. | I | C2 |
| Q-08 | M | SMS `FactsUpload._send` increments attempts on any exception; offline 15-min ticks double the delay (30 s → 30 min); reconnect calls `sync()` but `due()` skips rows in backoff → upload delayed up to 30 min. | V | C9 |
| Q-09 | M | Corrections after an offline spell are parked (see K12). | V logic / I byte-identical | C9 |
| Q-10 | M | Pull poison: `fetchSyncTransactionDelta` rethrows a 404 unless the pull named the id as `delete`; a `latestServerSeq <= since` guard throws forever after a DB restore. Cursor never advances. | I | C2 |
| Q-11 | H | Five hand-maintained lists drift (sign-out report, flushOutboxes, `pendingRecoveryStatusProvider`, backup `_queues`, restore wipe list). Backup `_queues` still names old tables (`sms_facts_outbox`). | V | C2, C3 |
| Q-12 | L | Pull/push batch constants: 4 pages × 25 rows per pass, 100 ms continuation; transaction deltas ≤100 ids, concurrency 4. A big backlog drains slowly (several passes). | V | doc |
| Q-13 | M | `SyncQueue` constructor resets `in_flight=0` for the namespace on every construction (sign-out listener constructs one more): an in-flight push can be re-sent (server idempotent per field; cosmetic). | V | C2 |

### 5.3 Session, storage, lifecycle (L)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| L-01 | **H** | Refresh 401 → tokens cleared → namespace `signed-out` → `cacheLifecycleProvider` → `ResponseCache.clearPrefix` → `financialStore.clear(ns)` deletes `financial_entities` incl. `bill_card_assignments`, `manual_bank_balances`, `sms_observations`, `pending=1` provisionals, plus coverage/receipts. Queue tables survive. Same transition resets the sync cursor and device id. (The comment at `providers.dart:1008-1010` says data stays.) `store.clear()` also revokes the native iOS SMS spool [I]. | V | C3 |
| L-02 | **H** | Sign-out `report()` counts only `sync_pending_changes`, `transaction_outbox_entries`, `duplicate_resolution_outbox`, `v2_outbox` (+receipts, review items, captured messages). **Not counted or flushed:** `command_outbox`, `shared_commands`, `foreign_payments_outbox`, `statement_import_*`. **Flushed but not counted:** tags, `split_documents`. Offline the dialog can't say so. | V | C3 |
| L-03 | **H** | `FinancialStore.replaceCards` deletes every non-archived card with `observed_at <= fetchTime` with **no `pending`/queue guard** (transactions have one). Provisional (offline-added) cards would vanish on the next wallet refresh. | V | C6 |
| L-04 | M | Complete-query prune (`financial_store.dart:603-624`) deletes any `pending=0` row absent from the server list: it prunes the card-bill manual payment row (V5, below) and may prune SMS-projected `v2:<eventId>` rows whose facts haven't uploaded. Triggers: full-range `loadTransactionsWithOfflineCache` reads while online and the post-push `_materialize`. Not triggers: paged Activity refresh and pull delta. | V (payment row), I (`v2:`) | C7 |
| L-05 | H | DB key lost/damaged → `loadHexOrReset` wipes the file and key: all unsynced queues lost. Android auto-backup is off; reinstall loses unsynced data. Local-only tables are not in the portable backup (`bill_card_assignments`, `manual_bank_balances`, `local_past_bill_receipts`, `user_merchant_category_rules`, `command_outbox`, `v2_*`). | V | C3 (backup lists) |
| L-06 | L | After a 401 followed by a *different* user signing in, the old user's queues/entities stay in the file forever (decryptable with the same key). `LocalAccountWipe` is unused by real sign-out. | I | C3 |
| L-07 | M | No background execution of sync: no `workmanager`/`background_fetch`. Android SMS handler and iOS BGProcessing capture locally only (never upload). If the app is killed offline and never reopened, nothing uploads. | V | C15 |
| L-08 | M | Client field clocks are `DateTime.now()` at enqueue; coalescing rewrites to now; no skew detection, no server-time offset. | V | C1 |
| L-09 | L | Unbounded growth: `sms_captured_messages`, `v2_*`, `cached_responses`, attachments (no cap), rejected/parked rows, no `VACUUM`, no size readout. | V | C3 (hygiene) |
| L-10 | M | `SQLITE_BUSY_SNAPSHOT` possible when the read worker writes (`migrateLegacy`, card-date repair) while main isolate writes; main-isolate sync sqlite calls can block ≤3 s. Every isolate runs the migration constructor on open. | I | doc/C2 |
| L-11 | L | Edge: refresh token present but access token missing (process death between the two writes in `token_store.dart:97-102`) → routed to `/welcome` offline. | V | C3 |
| L-12 | M | `merchant category rules`: `SmsLearningFeedback.pendingSync/markSynced` have no callers in `lib/` → locally learned rules appear never to reach the server. | V grep | C9 |
| L-13 | M | A "last synced" staleness check does not exist; resume after weeks just runs the normal triggers. | V | C13 |

### 5.4 Connectivity and startup (C)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| C-01 | M | `isOnlineProvider` is a bare `StreamProvider`; `_lastKnownOffline` defaults false; nothing subscribes before the signed-in shell's 500 ms timer. 28 read/listen sites in 12 files and 9 `_isKnownOffline()` sites treat null as online. Seeding changes behaviour at all of them (and a seeded-offline → online transition fires an immediate sync). | V | C1 |
| C-02 | H | Interface state ≠ reachability: on captive/dead Wi-Fi every network-first read waits 15-30 s (`AuthenticatedHttpClient` 15 s header / 30 s total) before its cache fallback; `_isKnownOffline()` never trips. ~15 background requests fire in the first ~5 s of every launch. | V | C1, C12 |
| C-03 | M | Home refresh is unconditional: `homeDataRefreshProvider` runs 6 requests × 15 s and invalidates user cards, catalogue, categories, overrides, home summary even if all failed; a second burst runs at ~3 s (`display-refresh`, `force:true` bypasses the 15 s dedupe); overrides arriving late can flip the "best card". | V/I | C12 |
| C-04 | M | Two calls have no timeout: FCM `getToken` and App Check `getToken` (`attestation.dart:66-80`). `await headers()` is outside the 30 s `.timeout`, and `SmsV2Runtime._sync` awaits `_refreshRules()` **before** the capture loop, so on a black-hole network new SMS parse tens of seconds late. | V | C9, C12 |
| C-05 | M | `appStatusProvider` caches a null result for the process lifetime (a later maintenance/forced-upgrade flag is not re-checked on reconnect). | V | C1 |
| C-06 | L | Transaction loader (`providers.dart:6081`) returns local data only if `local.complete || local.rows.isNotEmpty`; otherwise awaits the network and rethrows. Filtered Activity views, portfolio audit, per-card spend show an error offline for a filter that matches nothing locally. | V | C16 |

### 5.5 Writes that should work offline (W)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| W-01 | H | Edit transaction: queues `instrument`/`entry_kind` that the server drops (K1); refuses payment-method change and self-transfer confirm/undo offline; the category bulk-review and future-rule offers are awaited **before** `context.pop` (up to 2 × 15-30 s on captive Wi-Fi after the local save). | V | S1, C5 |
| W-02 | H | Activity bulk categorize / assign card / delete call `repo.*` directly (`activity_screen.dart:447, 631, 702`). Bulk delete has no `v2:` skip (server answers 400) and sends `local-outbox:` ids. Detail screen has the local-first template. | V | C5 |
| W-03 | H | Voice save (`voice_input_sheet.dart:766-779`): direct `logTransaction`, new `Uuid().v4()` per attempt; loop aborts midway, retry duplicates; raw error text offline; points redemption online only. | V | C5 |
| W-04 | H | Payment-sent log (`payment_sent_screen.dart:145`): direct `logTransaction`, no client id; server fuzzy dedupe does not cover manual rows → duplicate (and card state moved twice). Acceptance report catches only `ApiException`. | V | C5 |
| W-05 | M | Quick add with a receipt refuses offline (`quick_add_screen.dart:1296, 1414-1425`); with an unseeded stream a cold offline start falls to the generic error. Undo after delivery is a direct `ignoreTransaction` (offline: "Could not undo"). | V | C5 |
| W-06 | H | Add card (find cards, picker, scan result, onboarding, SMS instrument confirm): direct `POST /user-cards`, no queue, no client id. | V | S2, C6 |
| W-07 | H | Edit card: network-first; queues `last4`/`annual_fee_override_inr` that the server drops (UI says "Saved offline"); points balance refused offline; set-default (edit screen) refuses offline although card-actions version is local-first; archive/pause are network-first with a ~15 s spin; un-pause offline rethrows. | V | S1, C6 |
| W-08 | M | Card overrides: create/delete direct; toggle/edit queued with no overlay or invalidate (toggle looks unchanged); read is network-first 15 s with no overlay for queued edits. | V | S2, C6 |
| W-09 | H | Budgets: new budget online-only; `spent` is server-computed and frozen offline; no local budget table or sync entity. | V | S3, C7 |
| W-10 | H | Subscriptions in SMS-v2 mode: edit/ignore queue `PATCH/POST /recurring/v2:<key>…` → 500 → retried every 30 min forever; the edit exists only as an overlay derived from the stuck outbox row (lost on sign-out, never reaches other devices); "Add" is online-only and invisible in v2 mode. | V | S4, C7 |
| W-11 | M | Commitments mark-paid/dismiss on SMS-derived v2 bills save `source:sms, isUserConfirmed:false`, which the v2 provider filters out → no visible effect and a junk row synced. | V | C7 |
| W-12 | H | Card-bill manual payment writes a synthetic `payment-<card>-YYYY-MM` transaction (pending=0, not queued) that is pruned by the next full-range refresh or post-push materialize → bill reverts to unpaid. | V | C7 |
| W-13 | M | Statement import submit: see Q-05; duplicate check uses live `fetchTransactions()`. | V | C10 |
| W-14 | M | Profile name edit, contributions opt-in toggle (3 call sites), consent grant (5 paths), SMS-reading consent **revoke** (clears mirror only after the server accepts), support ticket and "Report a problem" (draft lost; awaited merchant-rule preview follows), card requests/data-error reports: direct, no queue. | V | C11 |
| W-15 | M | Duplicate review decisions are queued but have no overlay (a pending-resolved pair reappears); confirm credit-card instrument needing a wallet card is a direct `addCard`. | V | C6, C9 |
| W-16 | L | Onboarding add-first-card / card-details / all-set completion are live (legitimately online for first run; disable buttons with "Needs internet"). | V | C11 |
| W-17 | M | Foreign payments outbox drains only on `fetchAll`/mutation; Split approve/reject/confirm buttons hidden when `runtime.offline`. | V | C2, C8 |

### 5.6 Reads that fail or stall offline (R)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| R-01 | H | **Notification preferences**: live, no cache; `NotificationGate.fire` awaits them → every local alert silent offline; a failed `AsyncError` stays cached for the whole session even after reconnect (plain `FutureProvider`, invalidated only by the settings screen). Muted-merchants is also a live fetch. | V | C4 |
| R-02 | H | **Split reads** server-first; local projection (`shared_projections`) and provisional overlay (`shared_provisional`) are written but never read by any UI; unopened pages/search/later cursors have no copy; capability flags never cached → create/add hidden and `submit` throws. | V | C8 |
| R-03 | M | Budgets cold start offline → ErrorState; legacy subscriptions list; central bills projections (no cache, section vanishes). | V | C7 |
| R-04 | M | `paymentsDueProvider` awaits transactions unconditionally even in v2 mode → Bills tab ErrorState when the window has no usable snapshot (new/quiet account). | V (conditional) | C7 |
| R-05 | M | Deleted transactions list (no cache), duplicate candidates (no cache), notification inbox (network-first), points ledger (one request per card), lounge usage, archived cards, card overrides: network-first or cache only after failure; known-offline short-circuit unseeded. | V | C16 |
| R-06 | M | Transaction detail reads server first (≈15 s on dead Wi-Fi); `local-outbox:` rows are read-only. | V | C16 |
| R-07 | M | Notifications inbox, profile avatar, What's New (no timeout/no cache), consents list, merchant future rules (no cache), linked devices, member avatars/names: live or in-memory only. | V | C11 |
| R-08 | L | Data & Storage "Record counts" downloads the whole history just to count; Data export is server-backed; Import hub / Data transfer recent-imports lists have no cache; Find Cards shows the local SMS result only after the server returns/times out (20 s). | V | C10 |
| R-09 | L | First-ever offline launch: built-in categories fall back to custom-only (no bundled asset); bundled catalogue has 9 cards (stale: 2026-08-05). | V | C12 |
| R-10 | M | Caps, fee waivers, milestones, points and monthly savings: rewards/caps are server-computed; offline-created rows don't move them; v2 monthly report hard-codes `valueMissed`/`baselineSingleCard` = 0 even online. | V | C13 (label), doc |

### 5.7 Notifications and reminders (N)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| N-01 | H | See R-01. Also gate order: dedupe mark and an awaited inbox POST precede the OS banner (banner delayed ≤30 s on captive Wi-Fi); the inbox row is lost permanently if the POST fails (not queued) although the dedupe key is set. | V | C4 |
| N-02 | H | No OS-scheduled notifications exist (`zonedSchedule`, workmanager absent). Triggers run only while the process is alive. The "reminder" toggle schedules nothing. Scheduled reminders also bypass the gate (quiet hours, daily cap, toggles) unless prefs are available locally. | V | C14 |
| N-03 | M | Android scheduling prerequisites missing: no `ScheduledNotificationReceiver`/`ScheduledNotificationBootReceiver` in the manifest, `timezone` only transitive, `RECEIVE_BOOT_COMPLETED` only transitive; iOS keeps 64 pending notifications; AppDelegate doesn't set the `UNUserNotificationCenter` delegate [I]. Geofence stream isn't restored after reboot until the app opens. | V/I | C14 |
| N-04 | L | Push registration retries by timer, not on reconnect. | V | C4 |

### 5.8 SMS v2 and Split (S, X)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| S-01 | M | Baseline rules bundle is empty (`bundleVersion:0`, `rules:[]`, no `solverPack`); a never-online install/restore sends every message to Needs review until a signed bundle downloads. No signed bundle exists in the repo (build via `api/scripts/release_sms_v2_bundle.js`; keys env-only; unsigned non-empty baseline throws `StateError`). | V | C9 (D5) |
| S-02 | M | Offline correction loses the "share with community" part (consent lookup errors → false; no local mirror of shared-learning consent). | V | C9 |
| S-03 | M | SMS-reading consent mirror valid only for `consentPolicyVersion`; stale/new-device/version-bump offline → "not granted" → SMS reading pauses. | V | C11 |
| S-04 | L | Gemini status bar says "could not reach server" and polls every 10 s while offline. | V | C9 |
| S-05 | M | Android background handler drops a message if the DB is busy (recovered by the inbox scan only while the message is still in the provider). | V | doc |
| X-01 | H | Failed Split commands (`rejected`/`conflict`) have no UI (excluded from `waitingCount`); e.g. duplicate friend name created offline is later rejected silently. | V | C8 |
| X-02 | M | After a failure offline, a Split command can wait up to ~5 min after reconnect (`resumeAuthentication` resets only `awaitingAuth`); backoff 5 s·2^n up to 320 s, no attempt cap. | V | C8 |
| X-03 | M | Split enqueue stamps `createdAt = 0`; claim order is `created_at, operation_id` (random UUID) for independent commands; `renameMember` and group invites lack `dependsOn`. | V | C8 |
| X-04 | L | Private per-transaction split: first view offline errors if never loaded; `blocked` splits visible only on that transaction. | V | C8 |

### 5.9 Platform, assets, UX (P, U)

| ID | Sev | Finding | Tag | WP |
|---|---|---|---|---|
| P-01 | **H** | **Fonts**: `google_fonts 6.3.3` fetches Outfit/IBM Plex Sans from fonts.gstatic.com; nothing bundled; `allowRuntimeFetching` never disabled. First-ever offline launch renders Roboto/SF; every failed load rethrows as an unhandled async error and the family is removed from the loaded set, so **every later build retries the HTTP fetch (no timeout)**; arrival triggers a global relayout. After one online launch the fonts are cached on disk (support dir). ~0.6 MB to bundle (5 Outfit + 3 IBM Plex weights; w800 IBM Plex resolves to Bold). OFL 1.1: ship the licence text. | V code / I runtime | C12 |
| P-02 | M | INTERNET permission is not declared in `src/main` (only debug/profile, and transitively via `google_sign_in_android` in release). Fragile. | V | C12 |
| P-03 | L | One remote image in the whole app (bank logo `home_screen.dart:3169`): `errorBuilder` fallback exists; bytes never cached (memory only); bundled catalogue has no remote URLs; avatars come from the API with no disk cache (own and member). | V | C12/C11 |
| P-04 | L | Offline-capable already: ML Kit (bundled models), mobile_scanner (bundled), on-device speech (needs the offline English pack; typed fallback), TTS, PDF parsing, share/export, deep-link capture of invite codes. `rive` is declared but unused. | V | doc |
| U-01 | M | No shared offline-aware error: `ErrorState` (73 uses) always says "Something went wrong"; `userFacingErrorMessage` (≈190 uses) conflates offline with every failure; 23 ad hoc `isOnline == false` checks; ≈353 inline SnackBars with 6+ different "saved offline" strings. | V | C12 |
| U-02 | M | No reachable sync-status UI (K5); `lastSyncedAtProvider`, `financialSyncStatusProvider`, pending counts and `'waiting_for_connection'` status have no consumer; staleness labels only on Emergency Card Info, Subscription Credits, Referrals. | V | C13 |
| U-03 | L | `home_widget` updates only while the app runs, no "as of" label. `card_detail_screen.dart:2938` `launchUrl` unguarded; manifest `<queries>` lacks an https VIEW intent (Android 11+). iOS `UIBackgroundModes` lacks `remote-notification` and entitlements lack `aps-environment` for FCM [I]. | V/I | C12 |

---------------------------------------------------------------------------------------------------

## 6. File ownership and conflict map

**Hotspots** (large, touched by many WPs). Rule: new code goes into **new files**; edits in a hotspot are limited to the anchor named in the WP; the orchestrator merges hotspot-touching branches **one at a time in the order of section 7.3**.

| File | Size | Owner (exclusive) | Others may touch |
|---|---|---|---|
| `app/lib/app/providers.dart` | ~7400 lines | none (serial merge) | only the anchors listed per WP: `isOnlineProvider` 2766 (C1); `_isKnownOffline` 4831 (C1); `notificationPreferencesProvider` 4322 + `recordAppNotification` 4271 (C4); `cacheLifecycleProvider` 2745 + refresh-401 996-1019 (C3); `commandHandlersFor` ~2872-2925 (C2, C7); loader 5933-6120 (C16); `homeDataRefreshProvider` 2554-2680 (C12); `commitmentsProvider` 1348 (C7) |
| `app/lib/app/router.dart` | ~1620 | none | `_AppShell` 1325-1420 (C13 only) |
| `app/lib/data/local/app_database.dart` | ~800 | **C2 creates the v3 step**; afterwards only via the new `LocalFirstSchema` module (below) | none |
| `app/lib/data/local/financial_store.dart` | ~1380 | C6 (`replaceCards` guard), C7 (prune exemption) at separate anchors | C3 (`clear` preservation) |
| `app/lib/features/sync/sync_engine.dart` | ~460 | C2 | C3 (device re-register `_sync` 112-123), C1 (server-time offset) |
| `api/src/index.js` | ~9700 | none | per-WP line ranges in 7.1 (extract to new modules; leave call sites only) |
| `docs/` | | each WP its own doc | none |

**Schema contention solution (client).** `AppDatabase._schemaVersion` is 2, `_schema` only runs for `version < 1` (a new table in `_schema` does **not** reach existing installs [V]). WP-C2 adds step v3 (outbox columns) and a new module `app/lib/data/local/local_first_schema.dart` (own version row, SAVEPOINT-wrapped, append-only numbered migrations, like `SmsV2Schema`). Later WPs append migrations to that list. Every new table is namespaced (`namespace TEXT NOT NULL`, PK `(namespace, id)`), idempotent (`IF NOT EXISTS`, `PRAGMA table_info` before `ALTER`), additive only (older apps ignore unknown tables). Copy `test/data/local/outbox_payment_method_test.dart` for the migration test and update hard-coded version assertions in `app_database_test.dart:12-15`.

**Registries to extend (not rewrite):** `QueueRegistry` (new, C2) is the single list read by sign-out report/flush, `pendingRecoveryStatusProvider`, backup `_queues`/restore wipe list. Until it lands, each WP that adds a queue table must add it to those five lists manually (listed in C2).

**Server migrations (timestamps allocated per owner; latest existing `20261122000300`):**

| Block | Owner | Migration |
|---|---|---|
| `20261123010000` | S1 | `sync_allowlist_and_clock_guard.sql` (re-declare `sync_fields_for` + `sync_apply_change_v2` as strict supersets; clock clamp; device pre-check support) |
| `20261123020000` | S2 | `sync_insert_card_override.sql` |
| `20261123030000` | S3 | `budgets_client_edit_clock.sql` |
| `20261123040000` | S4 | `recurring_client_edit_clock.sql` (optional) |
| `20261123050000` | S5 | `client_mutation_ids_append_only.sql` (notifications, user_consents, sms_import_batches) |

`db/scripts/migration_prefix_policy.js` rejects duplicate prefixes. Each SQL migration gets `db/tests/<timestamp>_<name>_test.sql`. New tables (none planned) must be added to `api/src/portable_backup/coverage.json`.

---------------------------------------------------------------------------------------------------

## 7. Work packages

Sizing: S ≤1 day, M 1-3 days, L >3 days (one agent). "Tests" lists the minimum; every WP also keeps all existing tests green.

### 7.1 Server track

**WP-S0 — DB error mapper (merge first, S).**
Scope: `api/src/http_db_errors.js` mapping 22P02→400 `invalid_id`, 23503→409/422, 23514→422, 23505→409, 57014/40001/40P01→503/409 `{retryable:true}`; adopt in routes touched by S1-S5 only. Add a uuid guard helper. Fixes SRV-07, SRV-14 (500s). Files: new `api/src/http_db_errors.js` + `api/test/http_db_errors.test.js`. Acceptance: `PATCH /recurring/v2:abc` → 400 not 500 (route test).

**WP-S1 — Sync core hardening (M).** Findings SRV-01..09, 19. Decision D1, D9.
- Strict mode: push body `strict:true` (opt-in so old clients are unaffected) returns `ignoredFields` and `reason:'no_syncable_fields'` when nothing applied; `change_log.payload` stores only applied fields.
- `409 {error:'device_not_registered'}` pre-check on push/pull/ack; client re-registers.
- Clock clamp: reject or clamp incoming field clocks > now+5 min (`clock_in_future` only under strict).
- Transient vs permanent: 57014/40001/40P01 inside an item → `reason:'transient'`.
- Separate body parser for `/sync/push` ahead of `index.js:156` (or byte-aware chunking contract documented for the client).
- Migration `20261123010000`: re-declare `sync_fields_for` and `sync_apply_change_v2` as strict superset: `user_cards += last4, annual_fee_override_inr`; `transactions += instrument, entry_kind` in the legacy list (typed already has them; add guard that `exclude_from_spend` requires `entry_kind='spend'` only if D1 adds it; `payment_method` stays on its own route). Handle 23505 on `last4` as a permanent reject with detail, not a 500. Add a SQL test asserting the full field list per entity so a future re-declaration can't drop fields silently.
- Add a unique partial index or guard for one default card per profile [I → prove first].
- Files owned: `api/src/sync_request_validation.js`, `api/src/sync_transaction_state.js`, new `api/src/sync_push_handlers.js` (entity→handler registry so S2 adds handlers without touching the loop), `index.js` lines 1114-1565 only, migration + test.
- Tests: `api/test/sync_request_validation.test.js`, `sync_transport_routes.test.js`, `sync_typed_changes_postgres.js` extended; SQL test for field lists.
- Acceptance: payload `{instrument:'cash'}` under strict returns `ignoredFields` (or applies after migration); `last4` edit applies; unknown deviceId → 409; 200-change push with 16 KiB commitments does not 413 (or client chunks).

**WP-S2 — Cards and overrides idempotent create (M).** SRV-11, 12. Depends S1's handler registry.
- `api/src/user_cards_add.js` (extract body of `POST /user-cards`, `index.js:2060-2181`): accept optional `id` (v4); same-id owned → 200 `{userCard, replayed:true}`; natural-key conflict keeps 409/`linkedExisting` and echoes `clientId` so the client remaps; foreign id collision → 409 `id_conflict`; map PK 23505 to 409. Register `user_cards`+`insert` push handler.
- `api/src/card_overrides_write.js` (`index.js:2474-2595` call sites): `POST` accepts `id`, `ON CONFLICT (id) DO NOTHING`; RPC `pandapay.sync_insert_card_override(...)` per the SECURITY DEFINER recipe (copy `sync_insert_user_category`): `set search_path=''`, `pandapay.uid()` check, device ownership check, validate scope/field pairing (`override_scope_populated`), card owned and not archived, no overwrite on replay, no change_log on replay. Delete: dispatcher maps `op=delete + not_found` → `applied:true, reason:'already_deleted'`. uuid guard on PATCH/DELETE.
- Migration `20261123020000`; privilege manifest entry is **S6's** (see below).
- Tests: `api/test/card_add_idempotency.test.js`, SQL test, `sync_isolation_postgres.js` extension.

**WP-S3 — Budgets (S).** SRV-10, 13. `api/src/budgets_write.js` (`index.js:7155-7339` call sites): accept `id`, `clientEditedAt` (`budgets.client_edited_at`); same id → replay 200; per-target advisory lock; if an active budget has a newer `client_edited_at` insert incoming as inactive history and return `{superseded:true}`; delete wins only if not older. Keep `idx_budgets_one_active_per_target`. Tag-scope budgets referencing local tag ids need alias resolution [I] — specify behaviour (reject 422 `tag_unknown`, client resolves alias first).

**WP-S4 — Recurring (S).** SRV-14. `api/src/recurring_write.js` (`index.js:7683-7788`): uuid guard (400 for `v2:`/`projection:`), accept `id`/`clientEditedAt`, don't resurrect a series dismissed after `clientEditedAt`.

**WP-S5 — Append-only items (M).** SRV-15, 16. Add `client_mutation_id uuid` + partial unique indexes: `notifications (profile_id, client_mutation_id)`, `user_consents`, `sms_import_batches`; accept clamped `createdAt` for notifications; `ON CONFLICT DO NOTHING` returning the stored row; keep `granted_at` as arrival time. Support tickets: accept body `id`, `ON CONFLICT (id) DO NOTHING`, charge the limiter only for new rows, **reject an invalid Authorization header with 401** instead of creating an anonymous ticket. Files: `api/src/support_tickets.js`, `api/src/notification_routes.js`, new `api/src/consents_route.js` (move block `index.js:8275-8312`), `index.js:9315-9331`.

**WP-S6 — Release owner (S, last).** SRV-20, 24. Sole editor of `db/security/product-runtime-privileges.json` (add `sync_insert_card_override`, check `sync_apply_user_commitment`), `api/src/portable_backup/coverage.json`, `deploy/DEPLOY.md`, and the `SYNC_TYPED_WRITES_ENABLED` rollout/acceptance proof. Confirms the real production env value with the operator.

### 7.2 Client track

**WP-C1 — Connectivity and reachability core (M).** C-01, C-02, C-05, L-08, SRV-09 client half.
- `isOnlineProvider` as `async*`: `yield await Connectivity().checkConnectivity()`, then `yield*` the stream; set `_lastKnownOffline` from the same value; subscribe at app root.
- New `app/lib/data/connectivity/reachability.dart`: one cached probe of `/app-status` (1.5-2 s), exposes `serverReachableProvider`; used to skip background reads when radio is up but server isn't.
- `isOfflineLike(Object)` helper in `api_exception.dart` (transient network failure or known offline); adopt at the 28 `isOnlineProvider` sites **only where a WP already edits that file** (no drive-by edits).
- Capture server-time offset from the `Date` header in `ApiRequestHeadersClient`; use for `SyncQueue` field clocks (D9).
- `ref.invalidate(appStatusProvider)` on offline→online.
- Anchors: `providers.dart` 2766-2772, 4831-4833; `api_request_headers_client.dart`; `sync_queue.dart` clock source.
- Tests: provider test with overridden `Connectivity`; a transition test (seed offline → first online event fires exactly one sync); existing `quick_add_offline_test`, `edit_card_screen_test` stay green.

**WP-C2 — Queue hygiene and schema foundation (L).** Q-01..04, Q-06, Q-07, Q-10, Q-11, Q-13, SRV-06 client half, SRV-17.
- App DB v3 step + `LocalFirstSchema` module (section 6).
- `transaction_outbox_entries`: add `attempts`, `next_attempt_at`, `parked`, `last_error`; order by `(parked, next_attempt_at, created_at)`; park on permanent 4xx; expose parked items; `_flush` batch skips parked.
- `command_outbox`: don't count `SocketException`/`TimeoutException`/`ClientException` as attempts; reset backoff on offline→online; treat HTTP 500 for a non-uuid target as permanent; 404/409-matching-state on ignore/restore/delete as success; foreground timer (~5 min) for command and transaction outboxes.
- `duplicate_resolution_outbox`: same attempt rule.
- Tag outbox and foreign-payments outbox: attempts/park/backoff, reconnect trigger (foreign `sync()` from `SyncEngine._sync`).
- `SyncEngine`: push in **byte-bounded chunks** (~60 KiB) in a bounded loop; remove acked rows **before** materialize; materialize via the delta path; run `splitRepository.sync` **after** the edit push (or `unawaited`); on `device_not_registered`/`not_found` re-register then retry once (hand-off with C3); pull poison: 404 for a non-delete change → skip; `latestServerSeq <= since` → cursor reset (full resync), not a throw.
- New `QueueRegistry` (table, namespace column, status columns, counts, flush, wipe) read by: `account_sign_out_provider.dart` (`readPhoneOnlyCounts` 39-58, `report()` 128-166, `flushOutboxes` 107-126), `pendingRecoveryStatusProvider` (`providers.dart` 684-715), `LocalPortableSnapshotSource._queues` (`local_snapshot_source.dart` 75-116), `LocalPortableRestoreWriter` wipe/insert lists (86-124, 78-84). Until C3 lands, C2 registers all existing queues.
- Tests: `sync_queue_test`, `sync_engine_local_test`, `transaction_outbox_repository_test` extended (poison row doesn't block newer ones; park; backoff reset on reconnect; chunking at 200 × 16 KiB; ack-before-materialize with a thrown materialize); migration test v2→v3; `command_outbox_test` with a 500-for-non-uuid.

**WP-C3 — Session loss, sign-out, backup coverage (M).** L-01, 02, 05, 06, 11, SRV-03 client half, SRV-05 client half. Depends C2's `QueueRegistry`.
- Make the 401 path non-destructive (D10): distinguish "signed out by user" from "session rejected" (flag on the provider); `cacheLifecycleProvider` clears `financialStore` only on explicit sign-out. Preserve local-only entities regardless.
- Sign-out dialog and report: count and flush every registered queue; offline + pending>0 → strong copy ("you are offline, N changes will be lost") and explicit confirmation; count only the current account's attachments.
- Device re-registration on `device_not_registered`; persist and reuse the device id across session loss (the server `register_sync_device` tolerates a stale id); on session loss **don't** reset cursor/device (or full-resync deliberately).
- Token store: write access token first (or persist last `sub`) to fix the `/welcome` edge.
- Backup: add `bill_card_assignments`, `manual_bank_balances`, `local_past_bill_receipts`, `user_merchant_category_rules`, `command_outbox` to capture/restore or to `declaredExclusions` with a reason; fix stale table names.
- Optional hygiene: retention for `sms_captured_messages`/parked rows, DB-size readout.
- Tests (all missing today): 401 session loss keeps local-only entities; sign-out report includes every queue; `not_found` device re-registers; attachments counted per account.

**WP-C4 — Notifications offline (M).** R-01, N-01, N-04.
- Cache notification preferences + muted merchants in `ResponseCache` (namespaced), cache-first with `NotificationPreferences.fromJson` defaults; invalidate on reconnect; never leave a cached `AsyncError`.
- `NotificationGate.fire`: show the OS banner first; inbox write non-blocking via a local queue (`CommandOutbox` kind or `local_notifications` table in `LocalFirstSchema`); dedupe mark only after the banner is shown or queued; swallow nothing silently — log a coarse reason.
- Trigger runner keeps running offline; push registration retried on reconnect.
- Anchors: `providers.dart` 4271-4332; `notification_gate.dart`; `notification_preferences_repository.dart`.
- Tests: gate with preferences repo throwing → fires with defaults; inbox queued and replayed; no duplicate OS banner on reconnect.

**WP-C5 — Local-first transaction writes (L).** W-01..05. Depends C2 (park), S1 (D1), C1.
- Activity bulk categorize/assign/delete via a shared helper `bulk_transaction_actions.dart` that groups the selection by kind (v2, local-outbox, server) and uses `SyncQueue.enqueueUpdate` / `CommandOutbox ignore + markInactive` (copy `transaction_detail_screen.dart` 743-786); batch local writes with `financialStore.batch`; fix bulk delete's missing `v2:` handling.
- Voice save and payment-sent log through `TransactionOutboxRepository` with one `clientMutationId` per draft/screen session; points redemption via `OverlayCommand.pointsAdjust`; catch all errors on the acceptance report.
- Quick add: receipt saved to the outbox with the receipt stored locally keyed `local-outbox:<id>` and remapped after flush (same as tags); Undo after delivery via `queueCommand`.
- Edit transaction: after the local save, `pop` first and run the bulk-review/future-rule offers in the background with a ~4 s timeout; route `instrument`/`entry_kind`, if D1 = (c), through the domain PATCH or a command; allow payment-method change by queueing a `CommandOutbox` patch.
- `occurredAt` serialised with `.toUtc()` after the S0 probe proves the shift [I].
- Tests: widget tests for each screen offline; duplicate-on-retry test (same mutation id twice → one row via fake server); `quick_add_offline_test` extended for receipts.

**WP-C6 — Cards offline (L).** W-06..08, 15, L-03. Depends S2, C2, C1.
- Provisional cards in their own `LocalFirstSchema` table (or `pending` guard added to `replaceCards`: `pending=0 AND NOT EXISTS(sync_pending_changes …)`), **test first** (L-03).
- Add card: insert provisional card, `SyncQueue.enqueueInsert('user_cards')`; on server 409/200 remap local id to `userCard.id` across overlays, outboxes and caches; treat `card_already_added` as success-with-merge.
- Edit card: local-first; restore `last4`/`annual_fee_override_inr` after S1; points balance via `pointsAdjust`; set-default and archive/unarchive local-first through `LocalFirstCards` (single code path replacing the copies in `card_actions_screen.dart:96-121` and `edit_card_screen.dart:268-392`).
- Overrides: create via S2 handler (provisional row + overlay), delete via queued delete (already-deleted = success), toggle/edit overlay + invalidate; `cardOverridesProvider` cache-first (no 15 s wait) with `sync_pending_changes` overlay.
- Duplicate review: hide candidate ids present in the duplicate outbox; cache candidates.
- Anchors: `financial_store.dart` `replaceCards` 1086-1108.
- Tests: `financial_store_test` (card survives refresh), `edit_card_screen_test`, `manual_overrides_screen_test`, `deleted_cards_screen_test` extended.

**WP-C7 — Insights, bills, subscriptions, budgets (L).** W-09..12, R-03, R-04, L-04. Depends S3, S4, C2.
- Subscriptions (SMS-v2 mode): local `subscription_overrides` table (hidden, name, amount, cadence, next date, autopay) in `LocalFirstSchema`, applied in the v2 branch of `recurringReportServerProvider`; stop sending `v2:`/`projection:` ids to the server (UI guard plus handler guard); manual "Add" stored locally (as a `Commitment(category: subscription)` or table) and merged as `RecurringSeries(detectionSource:'manual')`; legacy ids keep the server command path.
- Commitments mark-paid/dismiss on derived v2 bills: set `isUserConfirmed:true` or make `billsFromFacts` honour a manual tombstone by `smsBillIdentityForCommitment`.
- Card-bill manual payment: route via `TransactionOutboxRepository` (like Quick Add) or mark pending/local-only so the prune skips it; add the v2-row exemption in the prune if the [I] case is proven.
- Budgets: local `user_budgets` table + sync entity mirroring `user_commitments`; compute `spent` locally in the read worker (rules at `api/src/spend_reports.js:658-721`: spend-only, active-only, excludes `exclude_from_spend`, category/child-category, card, tag and overall scopes, weekly anchoring); new-budget offline; reconcile with S3's `client_edited_at`.
- `paymentsDueProvider`: wrap/skip the transaction load in v2 mode.
- Cache `/bills/projections`.
- Tests: v2 subscription edit survives restart and never produces a server request with `v2:`; budget `spent` equals server result on shared fixtures (golden pairs); prune regression test; `payments_due_screen_test`.

**WP-C8 — Shared expenses (Split) offline (L).** R-02, X-01..04, SRV-18, W-17. Wave 1: fixes only (D3 a); Wave 2: local reads.
- `createdAt = now/monotonic counter`; `dependsOn` for invites/renames on a context created in the same session; treat 403 `context_not_authorized` as retryable while its own `context.create` is unconfirmed, and 409 `retryable`/429 as retryable.
- "Needs attention" list (rejected/conflict) with Retry/Discard; global "N need attention" count for blocked private splits.
- Reset `next_attempt` for `retry` rows on reconnect (`SharedExpensesStore.resetBackoff`); attempt cap with surfaced error.
- Capability flags: treat unknown as allowed to queue; don't clear on `clearPrefix`.
- Wave 2: hub/group/balances/activity built from `store.readContexts/readPage`; render pending ops (`readPendingOperations`) as "Pending"; approve/reject/confirm buttons tappable offline with "queued".
- Files: `features/shared_expenses/**`, `features/sync/split_sync.dart`, `data/local/split_repository.dart` (all exclusive).
- Tests: `shared_sync_test.dart` (ordering, 403 retry), `split_repository_test.dart`.

**WP-C9 — SMS v2 robustness (M).** Q-08, Q-09, C-04, S-01..04, L-12. Files: `features/sms_v2/**`, `data/local/sms_*` (exclusive).
- `SmsV2Runtime._sync`: capture loop first; network steps skipped when `!isOnline`/not reachable; `.timeout(8 s)` around `attestation.headers()` and `_fetchToken`.
- Don't count pure network errors as attempts in `FactsUpload._send`; `OutboxStore.resetBackoff()` on reconnect.
- Corrections: `_waitsForUpload` compares `next_attempt_at` not attempts; `requeueForUpload` resets `attempts=0,next_attempt_at=0` even for identical payload; cap `correction_facts_not_found` retries instead of immediate park (prove the byte-identical [I] with a test first).
- Local mirror of shared-learning consent (copy `SmsReadingConsentMirror`).
- Gemini bar says "You're offline" and stops polling when offline.
- Wire `SmsLearningFeedback.pendingSync/markSynced` (or document why not).
- Baseline bundle (S-01) is an **owner task** (D5): the WP prepares the load path/tests for a signed non-empty baseline.
- Tests: `outbox_store_test`, `corrections_sync_test`, sync harness `test/features/sms_v2/support/sync_harness.dart` with an offline spell.

**WP-C10 — Import and export (M).** Q-05, W-13, R-08, K7.
- Enable continuation (D7) + auto-resume on reconnect/resume (`pending_statement_imports_card`, `statement_import_continuation_provider`); "Saved — will upload when online".
- Data export from `FinancialStore` (JSON/CSV) offline and by default (server export as fallback); includes unsynced rows.
- Data & Storage counts from local store; Import hub/Data transfer "recent imports" cached or hidden offline; review-panel duplicate check from the local store; Find Cards shows the local SMS result immediately.
- Tests: `statement_import_outbox_test`, export golden tests.

**WP-C11 — Account and settings (M).** W-14, 16, R-07, S-03. Depends S5.
- `CommandOutbox` kinds with client ids for: profile name (also patch `profileSnapshotWriterProvider`), contributions opt-in, support ticket and report-a-problem (queued; preview non-blocking), consent grants/audit, card requests/data-error reports.
- **SMS-reading consent revoke works offline**: clear the local mirror first, queue the audit POST; previous-version mirror counts as granted (D8); cache the consents list; privacy screen cache-first.
- Persist avatar info/photo (own and members) in `ResponseCache`; What's New cache + timeout; merchant future rules cache + queued update/disable with version-conflict resolution; settings sync `pullAndApply` on reconnect/resume; disable NET-only buttons with "Needs internet" (delete account, erase data, phone/email change, revoke device, onboarding steps).
- Tests: account/settings widget tests with offline override.

**WP-C12 — Platform, assets, startup, shared UX (L).** P-01..04, U-01, C-02..04, R-09, K8 UX parts.
- Bundle fonts under `app/assets/google_fonts/` (exact Google API filenames: `Outfit-{Regular,Medium,SemiBold,Bold,ExtraBold}.ttf`, `IBMPlexSans-{Regular?,Medium,SemiBold,Bold}.ttf`), add `- assets/google_fonts/` and `OFL.txt`; after a test proving every used weight resolves to an asset, set `GoogleFonts.config.allowRuntimeFetching = false` in `main()`.
- Declare `INTERNET` in `src/main/AndroidManifest.xml`; add an https `VIEW` intent to `<queries>`; guard `launchUrl` at `card_detail_screen.dart:2938`.
- Offline-aware `ErrorState` internals (neutral cloud-off icon, "Can't reach PandaPay", "Showing what's saved on this phone." vs "Connect to the internet and try again.") using `isOfflineLike`; `userFacingErrorMessage` offline string; one `showSavedOfflineSnack` helper + single copy constant, migrate sites **only when a WP already touches the file**.
- Cold-start: 6-8 s cap on every background read (Home burst, lifecycle providers); skip background reads when `serverReachableProvider` is false; no `force:true` second Home burst within 15 s; Home refresh doesn't invalidate on total failure; FCM `getToken` timeout; categories snapshot bundled as `assets/data/bundled_categories.json` (last-resort fallback); refresh the 9-card bundled catalogue in CI (script, owner approval).
- Logos (D11): download-and-cache bytes via the existing http client into a cache file, `Image.file`/`Image.memory`, keep the `errorBuilder`.
- Remove unused `rive` dependency (optional, separate commit).
- Tests: font-weight asset coverage test, `ErrorState` goldens (Alchemist), widget tests, `performance_guards_test`.

**WP-C13 — Visibility (S-M, D2).** U-02, L-13, R-10. Depends C1, C2.
- Default (b): a quiet pending/needs-attention entry (Settings/You tile with count; reachable `SyncBackupScreen` or its replacement), reusable "Saved data · updated 6:40 PM" row from `ResponseCache.read().fetchedAt`/`lastSyncedAtProvider` on Budgets, Subscriptions, Spend Trends (legacy), Caps, Monthly Savings, Bills; "as of last sync" on cap/reward figures. **No Home "You're offline" banner** (keep `offline_banner_test` green).
- Anchor: `router.dart` `_AppShell` only if D2 chooses a persistent indicator.

**WP-C14 — Scheduled local notifications (M, Wave 3).** N-02, N-03. Depends C4.
- Add `timezone` as a direct dependency; init `Asia/Kolkata` (the app hard-codes it); `flutter_local_notifications 18.0.1` requires `uiLocalNotificationDateInterpretation` **and** `androidScheduleMode` (`inexactAllowWhileIdle`, D4).
- Manifest: `ScheduledNotificationReceiver`, `ScheduledNotificationBootReceiver` (BOOT_COMPLETED, MY_PACKAGE_REPLACED, QUICKBOOT_POWERON, HTC variant), explicit `RECEIVE_BOOT_COMPLETED`. iOS: rolling window ≤64, rescheduled on open/resume; set the `UNUserNotificationCenter` delegate [verify on device].
- Schedule for bill due dates, subscription renewals, card due days when commitments/subscriptions/cards change; cancel on paid/ignored; apply the gate rules (quiet hours, cap, toggles) at schedule time from the cached preferences.
- Geofence stream restore after reboot is a separate S item.

**WP-C15 — Background sync spike (L, optional, D6).** L-07. Deliverable: a design + prototype branch only. Android WorkManager periodic (6-12 h, CONNECTED) and iOS BGAppRefresh/BGProcessing with `requiresNetworkConnectivity=true`; requires an app-state-free flush extracted from `outboxFlushProvider`, `commandHandlersFor`, `SyncEngine._push`, plus a **cross-isolate refresh-token lock** (coordinator is in-process only) and keystore/first-unlock handling. No SMS upload in v1. Do not merge without D6.

**WP-C16 — Read-path polish (M).** C-06, R-05, R-06.
- Loader: on network failure return `local.rows` even if empty when a `local` snapshot exists (anchor `providers.dart` 6081-6114).
- Transaction detail reads the local row first, refresh in background; allow editing `local-outbox:` rows by editing the outbox entry (optional).
- Deleted transactions list from local `ignored` rows; archived cards, overrides, points ledger (batched), lounge usage, notifications inbox, bank-account summaries cache-first with `_warmDisplay`; `categorySpendProvider` falls back to local spend.
- Tests: Activity filter offline with zero local matches shows empty, not error; `performance_guards_test`.

**WP-Q — QA and release (M, last).** Executes the section 9 matrix on a real phone and the emulator, runs perf gates, security checks (`owasp-mobile-security-checker` on consent mirror, sign-out, cached preferences), produces the evidence file `docs/OFFLINE_FIRST_VERIFICATION_<date>.md`.

### 7.3 Waves, dependencies and merge order

```
Wave 0 (serial, ≤1 day)   WP-00 baseline + characterization tests  →  owner decisions D1,D2,D3,D5,D7 recorded
Wave 1 (parallel)         Server: S0 → S1 ; S2,S3,S4,S5 (after S1 registry)      Client: C1, C2, C4, C8(fixes), C9, C12a(fonts/manifest/assets)
Wave 2 (parallel)         C3 (needs C2 registry) · C5 (S1,C2) · C6 (S2,C2) · C7 (S3,S4,C2) · C10 · C11 (S5) · C16 · C8(local reads) · C12b(error UI, cold-start)
Wave 3                    C13 · C14 · S6 · WP-Q
Wave 4 (optional)         C15 spike
```

**Merge order (orchestrator, one at a time, run the test gate after each):**
S0 → S1 → S2 → S3 → S4 → S5 → C1 → C2 → C3 → C4 → C9 → C8 → C12 → C5 → C6 → C7 → C10 → C11 → C16 → C13 → C14 → S6 → Q.
Server migrations deploy to dev **before** the client WPs that need them are merged; client WPs must work against an old server (feature-detect or tolerate 404/400) because installed apps and a lagging server both exist.

**Parallelism cap:** 6-8 agents at once. Never run two WPs that edit the same hotspot anchor simultaneously (see section 6).

### 7.4 Overall effort (rough, single agent each)
Server S0-S6: ~8 agent-days. Client C1-C16: ~35-45 agent-days. QA: ~4. With 6-8 parallel agents, ~3-4 calendar weeks including review and device testing.

---------------------------------------------------------------------------------------------------

## 8. Agent protocol (copy into every spawn)

**Setup**
1. Orchestrator first resolves the working tree: `git status` currently shows ~215 uncommitted files on `dev` (`api/`, `app/`, tests). Commit or stash them (owner decision) **before** creating worktrees, otherwise agents start from a base that lacks them and hotspot merges will conflict.
2. One worktree per WP: `git worktree add ../pp-<wp> -b offline/<wp-id> dev`. Do not symlink `node_modules`; run `npm ci` in the worktree's `api/`. Flutter: `cd app && flutter pub get` (first test run ≈ 3 min cold).
3. Agent edits **only** the files its WP owns; hotspot edits only at named anchors; new providers and helpers go in new files.

**While working**
4. Write the failing test first for every [I] item and every bug; then fix. Keep each commit small and green. Commit message: imperative, scoped (`fix(sync): …`), no real data. End with the attribution lines the session requires.
5. Commands: `cd app && flutter test <file>`; `flutter analyze <touched files>`; API: `cd api && node --test test/<file>.test.js`; SQL tests via `psql -v ON_ERROR_STOP=1` on a fully migrated scratch DB (orchestrator provides).
6. Synthetic data only (public repo). Never commit `.env`, keys, tokens, signed bundles' private material, or screenshots/dumps from a real phone (the repo root already contains many; add none).
7. Follow the existing patterns: local write → enqueue → overlay → `unawaited(sync())`; client-generated stable ids; set-state semantics for replayable commands; SECURITY DEFINER recipe for new RPCs.
8. If a finding turns out wrong, **stop and report** with evidence rather than working around it.

**Definition of done (per WP)**
- All acceptance criteria met; new tests green; full existing suite for touched areas green; `flutter analyze` clean for touched files.
- `performance_guards_test` green if read paths or startup were touched; `scripts/perf_smoke_android.sh` result attached for WP-C1, C12, C16.
- No behaviour change for an online, healthy user (state how this was checked).
- A short `docs/offline/<WP-ID>.md` note: what changed, files, flags, migrations, how to test, known gaps.
- Branch left unmerged; the final message lists files changed, tests run with results, and any [I] item that turned out false.

**Reviewer checklist (a fresh agent reviews each branch)**
Replay safety (idempotent? stable id?), ordering (dependsOn/timestamps), poison handling (attempts/park), namespace and sign-out coverage (registered in `QueueRegistry`), backup coverage, old-server/old-app compatibility, overlay shown immediately, cache invalidation, no UI-isolate heavy work, public-data hygiene.

**Spawn template (orchestrator → agent)**
> Work package `<WP-ID>` of `docs/OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md`. Read sections 0, 3, 5 (rows listed below), 6 and 8, then only your WP in 7. Findings: `<IDs>`. You own: `<files>`. Hotspot anchors you may edit: `<anchors>`. Dependencies already merged: `<WPs>`. Decisions recorded: `<D#=choice>`. Work in worktree `../pp-<wp>` on branch `offline/<wp>`. Prove [I] items with a failing test first. Do not push or merge. Return: files changed, tests added/run with results, acceptance checklist, risks, and any finding you believe is wrong.

---------------------------------------------------------------------------------------------------

## 9. Test strategy

**Harness (proven):** `flutter` is on PATH (3.44.8); `flutter test test/data/local/sync_queue_test.dart` passed 14/14 [R] (cold ≈175 s). Style to copy: in-memory `AppDatabase.forTesting(sqlite3.openInMemory())`; Riverpod overrides `cacheNamespaceProvider`, `appDatabaseProvider`, `responseCacheProvider`, `syncApiProvider`, `isOnlineProvider.overrideWith((_) => Stream.value(false))` (widgets must `ref.watch` it to force the stream to emit); fakes `class _Api implements SyncApi` / `UserCardsRepository` throwing `ApiException('no connectivity')`; `MockClient` for real repositories; inject `now:` into queues; `test/flutter_test_config.dart` provides secure-storage and PackageInfo mocks; multi-device SMS harness `test/features/sms_v2/support/sync_harness.dart`.

**Tests missing today (WP-00 writes them as characterization tests that capture current behaviour, then flip in the WP that fixes it):**
1. Refresh-401 session loss clears (or keeps) local-only entities (L-01).
2. Sign-out `report()`/`flushOutboxes` completeness per queue (L-02).
3. `replaceCards` vs a pending/provisional card (L-03).
4. `v2:` rows vs the complete-query prune (L-04).
5. `not_found`/unregistered device parks the whole batch (SRV-05).
6. Wrong-clock merge (future clock wins; clamp) (SRV-09).
7. Edit-transaction `instrument`/`entry_kind` round trip against a fake server that drops fields (SRV-01).
8. Voice/payment-sent retry creates a duplicate (W-03/04).
9. Split `member.invite` before `context.create` → permanent reject (SRV-18).
10. Poison row blocks newer outbox rows (Q-01).
11. Correction parked after an offline spell with an identical payload (Q-09).

**Server:** route tests (`node --test`), SQL tests per migration, `*_postgres.js` fixtures run by the coordinator on a loopback DB. Add a SQL test asserting complete field lists per sync entity.

**Airplane-mode device matrix (WP-Q).** Run each with: (a) cold start offline, (b) offline mid-session, (c) reconnect, (d) kill app offline then reconnect, (e) captive Wi-Fi (radio up, no internet), (f) phone clock +1 year / −1 day, (g) 100+ queued changes, (h) >15 min offline (expired access token), (i) forced refresh-401.

| Scenario | Expected |
|---|---|
| Cold start offline | Home local content ≤ 500 ms, no logout, no spinner > 300 ms after first paint when a snapshot exists, bundled fonts render |
| Captive Wi-Fi | local data within ~1 s everywhere; no 15-30 s spin |
| Add expense (quick add, voice, payment-sent, with receipt) ×2 with a lost response | exactly one row after sync |
| Edit category/instrument/entry kind/note/last4/fee offline and online | persists after sync and survives full refresh |
| Bulk categorize/assign/delete 5 rows offline (incl. `v2:` rows) | applied locally, one push, no error |
| Add card; create/delete override offline | visible immediately, survives wallet refresh, correct after sync, no duplicate on replay |
| New budget, subscription edit/ignore/add, mark bill paid, card-bill paid offline | visible, no 30-min loop, survives full refresh and restart |
| Statement import offline, kill app, reconnect | uploaded once |
| Split: create group + friend + expense offline; reconnect | order preserved, nothing silently rejected; failures listed |
| SMS arrives offline (fresh install with signed baseline / existing install) | parsed or Needs review; upload ≤ ~1 min after reconnect; correction not parked |
| Local notifications offline | bills/caps/renewals fire; inbox row after sync; scheduled reminders fire with the app closed (Wave 3) |
| Sign-out with queued changes offline | warning names counts; online sign-out flushes first |
| Refresh 401 (revoked token) | local-only data kept; queues survive; same-user sign-in resumes them |
| Push of 200 × large commitments | chunked, no 413 head-of-line block |

**Gates before each merge:** the WP's tests, `flutter analyze` (touched), `performance_guards_test` where relevant, no new `RegExp(` in per-message code, no whole-table read in loops.

---------------------------------------------------------------------------------------------------

## 10. Compatibility and rollout

1. **Order:** server migrations/routes first (backward compatible: new fields optional, strict mode opt-in), then client builds. Old clients keep working; new clients must tolerate an old server (feature-detect strict mode/`device_not_registered`/new routes; fall back to online-only behaviour with a clear message).
2. **Flags:** reuse the existing pattern (`env.dart`/compose). Candidates: `SYNC_STRICT_PUSH` (server), `PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED` (client, D7), a client `offline_local_first_v2` kill-switch per WP group (cards, budgets, subscriptions) so a bad release can fall back to the previous network-first path remotely.
3. **`SYNC_TYPED_WRITES_ENABLED`:** separate rollout under `db/scripts/release_security_check.js` (requires the `sync_typed_writes_acceptance` proof; `deploy/DEPLOY.md:500` says "source prepared, disabled"). Needed for offline reward/cap correctness (SRV-08); not a prerequisite for the rest.
4. **Deploy flow:** fix on `dev`, merge `dev` into `prod`, push `prod`; never touch `master`; no guessing about production values (ask the operator).
5. **Rollback:** every migration additive; client schema steps additive (older app ignores unknown tables); `user_version` downgrade is silent, so never repurpose columns.
6. **Data safety in rollout:** do not delete queue rows in any migration; a parked row is kept with its error and visible in the needs-attention list.

---------------------------------------------------------------------------------------------------

## 11. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| 1 | Seeding connectivity flips behaviour at 28+9 sites and fires an immediate sync at startup | M | M | C1 transition tests; roll out with the reachability probe; keep `== false` semantics |
| 2 | Typed-writes flag adds new permanent rejects (card/instrument mismatch) | M | M | D1 (b) first; client sends `user_card_id` consistently; S1 transient/permanent split |
| 3 | Provisional card ids leak into overlays/outboxes after server remap | M | H | C6 remap step covers overlays, outboxes, caches; test with 409 `linkedExisting` |
| 4 | Local `spent`/subscription logic diverges from server | M | M | golden fixture pairs shared by API and client tests; label as "estimate" until synced |
| 5 | Hotspot merge conflicts (`providers.dart`, `index.js`) | H | M | extraction rule, anchors, serial merges, orchestrator owns merge order |
| 6 | Working tree has ~215 uncommitted files | H | H | commit/stash first (section 8) |
| 7 | Clock fixes (server clamp) reject legitimate edits from skewed phones | L | M | clamp only under strict mode; surface `clock_in_future` as retry-after-resync |
| 8 | Non-destructive 401 path keeps a revoked account's data on disk | L | M | clear on explicit sign-out only; orphan-namespace sweep after next different-user sign-in |
| 9 | Bundled fonts: wrong filenames silently fall back to runtime fetch | M | L | asset-coverage test before disabling runtime fetch |
| 10 | Android 14+ scheduled reminders drift | M | L | inexact scheduling accepted (D4) |
| 11 | Background sync refresh-token races | M | H | defer (D6) |
| 12 | [I] items false | M | L | each is proven with a test before fixing |

---------------------------------------------------------------------------------------------------

## 12. Open questions

1. D1-D12 (section 4).
2. What is the real production value of `SYNC_TYPED_WRITES_ENABLED`, and the server timezone (for SRV-21)? (Not visible in the repo.)
3. Does Linked-devices revoke delete the `user_devices` row (SRV-05 revoke path)?
4. Does the app reuse the sync device id after sign-out (SRV-03 reinstall case)?
5. Why was the offline banner removed (K6) — product reason or only duplication?
6. Is the unreachable `SyncBackupScreen` intentional?
7. Who signs and publishes the SMS baseline bundle, and which banks go in?
8. Should locally learned merchant-category rules sync (L-12), or is device-local intended?

---------------------------------------------------------------------------------------------------

## Appendix A — Per-screen inventory

The screen-by-screen READ/WRITE classification tables remain in `docs/OFFLINE_FIRST_AUDIT_AND_PLAN_2026-11-13.md` sections 4.1-4.4. Apply the corrections in section 2 above. Route and HTTP coverage matrices from the completeness sweep are in Appendix C.

## Appendix B — Queue inventory (storage audit)

| Queue (table) | Idempotent replay | Retry / backoff | Poison handling | Drained on | In sign-out report/flush today | In backup |
|---|---|---|---|---|---|---|
| `sync_pending_changes` | per-field LWW; inserts by client uuid | attempts only on per-item failure; none on throw; no time backoff | `attempts>=5` or permanent reason stays forever, counted; no UI | sign-in, offline→online, resume (no timer); ≤200 per push | counted + flushed | counted; not exported |
| `transaction_outbox_entries` | yes (`clientMutationId`) | none | **none** (head-of-line) | namespace change, flush request, offline→online, resume; 20/trigger | counted + flushed | counted |
| `duplicate_resolution_outbox` | yes | attempts on any error | blocked at 5, `resetBlocked()` | same flush provider | counted + flushed | counted |
| `command_outbox` | set-state / client id | 30 s×2^n ≤30 min on any non-permanent error; no timer | permanent 4xx parked; 5xx loops | same flush provider | **neither** | **not counted/exported/wiped** |
| `transaction_tag_outbox` | yes (`mutationId`) | attempts, no backoff | never parked | `SyncEngine._sync`, after each change | flushed, not counted | counted |
| `foreign_payments_outbox` | keyed by `source_key` | none | none | `fetchAll`/mutation only | **neither** | counted |
| `statement_import_*` | yes (`import_key`) | 5-min leases | **well bounded** (caps; 14-day TTL → `needs_review`) | manual resume; flag-gated | **neither** | counted when ciphertext present |
| `shared_commands` | `operation_id` + `request_hash` | 5 s·2^n ≤320 s, no cap | state + error_code, UI-less `rejected/conflict` | resume, connectivity, 45 s timer | **neither** | counted (`state!='committed'`) |
| `split_documents` | version-stamped | 5 s·2^n ≤300 s | `blocked=1` | SyncEngine start, resume, reconnect | flushed, not counted | excluded (server canonical) |
| `v2_outbox` | payload-compare ack | 30 s×2^n ≤30 min or `Retry-After` | **best**: bisect, set aside after 2 | start, resume, offline→online, 15-min timer | counted + flushed | not exported (stale names in `_queues`) |
| `sms_intake` / `sms_captured_messages` | `source_key` hash | attempts, next_attempt | none | foreground pipeline | captured counted | raw intake excluded |
| `local_commitments` | `SyncQueue` entity | as `sync_pending_changes` | as above | as SyncEngine | via `sync_pending_changes` | exported |
| `bill_card_assignments`, `manual_bank_balances` | local-only | n/a | n/a | n/a | not counted | **not exported; wiped by 401 path** |
| `local_past_bill_receipts`, `user_merchant_category_rules` | local-only / `synced` flag never set | n/a | n/a | n/a | not counted | **not exported** |
| `transaction_attachments` | local | n/a | n/a | n/a | counted (all accounts) | exported; no size cap |

## Appendix C — Coverage sweep summary

- Routes audited: every `GoRoute` in `router.dart` plus screens reached only by `Navigator.push` (settings hub, account settings, appearance, data & storage, legal/help, privacy, notification settings, voice/widget settings, tags, email/phone/recovery, linked devices, merchant future rules, feedback, what's new, edit profile, report transaction, deleted transactions, data export/transfer, document/screenshot import, auto-SMS sync, SMS import, email forwarding, referrals, subscription credits, notifications, merchant search, scan card/result, payment sent, calculator, comparison, tools, voice sheet, rules refresh sheet, Split sheets). All appear in Appendix A or section 5.
- HTTP call sites audited: user cards/transactions/notifications/home (`user_cards_repository.dart`), spend reports/budgets/recurring, overrides, catalogue/categories, emergency contacts, app-status, changelog, consents, notification prefs/devices, user settings, support/card requests/data-error reports, partner clicks, acceptance reports, profile/avatars, account lifecycle, auth-service clients, merchants, merchant rules, foreign payments, import (`import_repository.dart`), tags, referrals, subscription credits, bills projections, sync API, shared-expenses (~30 routes), SMS v2, analytics, Gmail, crash reporter. Not audited in depth server-side: `/acceptance-reports`, `/data-error-reports`, `/engagement/check-in`, `PUT /transactions/:id/splits`, `/transactions/category-bulk-apply`, `/duplicate-candidates/:id/resolve`, foreign-payments, muted-merchants (follow-up read in WP-S5/C6).
- Screens/code with no caller in `lib` (dead): `SyncBackupScreen`, `GmailConnectScreen` (controller still used), `ImapConnectionScreen`, `CardSkinPreviewScreen`, `CsvStatementImportScreen`, `PortableBackupHttpRepository`, `portable_backup_export/inspector`, `services/recurrence_engine.dart` (tests only), `SpendReportsRepository.fetchTransactionsCsv`, `Env.legalBaseUrl`, `rive` dependency.
- Duplicate write paths to unify: set-default (card actions local-first vs edit screen online-only); archive/pause (copy-pasted in two screens); create transaction (outbox vs direct in voice/payment-sent/quick-add receipt); delete (command outbox vs direct in bulk/undo); add card (4 direct sites); contributions opt-in (3 sites); consent grant (5 paths); duplicate HTTP clients for `/card-requests`, `/merchant-category-rules/preview`, `/profile` (3 clients), `/consents`, referrals legacy vs v2.

## Appendix D — Verification record (second pass)

| Claim | Verdict |
|---|---|
| V1 edit transaction drops `instrument`/`entry_kind` | PARTLY: worse (online too; reverts right after push; `payment_method`/`exclude_from_spend` not queued) |
| V2 `last4`/fee override dropped | CONFIRMED (accidental regression in `20261019144500`; typed writer drops too) |
| V3 `v2:` subscription ids → 500, retried forever | CONFIRMED |
| V4 v2 mark-paid/dismiss no effect | CONFIRMED |
| V5 card-bill payment pruned | CONFIRMED (+ [R] generic prune test passed; `v2:` row case unproven) |
| V6 Split ordering | PARTLY (see K11) |
| V7 corrections parked | PARTLY (see K12) |
| V8 notification gate | CONFIRMED (+ cached `AsyncError` outlives outage) |
| V9 Bills tab error | PARTLY (only with no usable snapshot) |
| V10 bulk actions | CONFIRMED (delete has no `v2:` skip) |
| V11 receipt refusal / poison rows | CONFIRMED |
| V12 voice/payment-sent duplicates | CONFIRMED |
| V13 `_sync` order | CONFIRMED order; `headers()` outside the 30 s timeout |
| V14 empty baseline | CONFIRMED; no signed bundle in repo |
| V15 sign-out | PARTLY (see K10) |
| V16 connectivity unseeded | CONFIRMED (28 sites/12 files; 9 `_isKnownOffline`) |
| Session-loss wipe (L-01) | CONFIRMED by direct read of `providers.dart:996-1019, 2745-2755`, `response_cache.dart:215-221`, `financial_store.dart:1364-1381` |
| Typed flag default | CONFIRMED false in compose/env examples; prod unseen |
