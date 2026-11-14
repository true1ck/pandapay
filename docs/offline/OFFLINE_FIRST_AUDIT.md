# PandaPay — Offline + Online (offline-first) audit and change plan

Date: 2026-11-13 · Branch audited: `dev` · Status: **audit and plan only. No code was changed.**

> **Superseded for planning by [OFFLINE_FIRST_MASTER_PLAN_2026-11-13.md](OFFLINE_FIRST_MASTER_PLAN.md).**
> This file remains the per-screen inventory (sections 4.1-4.4). Several statements below were corrected after a
> second, deeper investigation (see section 2 of the master plan): the silent field drop also happens online;
> `last4` was dropped in `20261019144500`; `card_overrides` delete is supported; `/sync/pull` is not a rebuild
> source; Data export is server-backed; the Sync & Backup screen is unreachable; and offline banners were removed
> on purpose (commit `37f7d9c7`), so section 5.5's "shell banner" suggestion is withdrawn pending decision D2.

Goal: the app must work with no internet (open it, read existing data, enter and edit data) and sync automatically
when the internet returns, **without breaking anything that works today**.

How this was produced: four parallel read-only code audits (startup/auth/account · transactions/cards/import ·
insights/bills/subscriptions · shared-expenses/SMS/backup), plus direct verification of the highest-impact claims.
Everything is from reading code. **Nothing was run on a device**, so items marked *(inferred)* need a quick
airplane-mode test before they are treated as fact. File references are `app/lib/...` unless noted.

---------------------------------------------------------------------------------------------------

## 1. Executive summary

1. **The app is already mostly offline-first. It is not "online only".** It has a local SQLite store, a response
   cache, and three write queues (details in section 2). Cold start offline for a signed-in user works: no network gate
   in the router, and a network error never logs the user out. Reading transactions, cards, Home, Insights, bills, SMS
   capture and parsing all work from local data.
2. **What is broken is specific, and falls into six root causes** (section 3):
   - **A. Some writes are network-first** with a queue only as a fallback in `catch`, or have no queue at all.
   - **B. Several data types cannot be queued** because the server's `/sync/push` accepts only a few entities and
     silently drops some fields while still reporting success. This causes real **silent data loss**.
   - **C. Some reads have no local copy** and show an error offline (Split lists, deleted transactions, duplicate
     candidates, notification preferences, budgets on a cold start, and others).
   - **D. Queues exist but retry badly**: backoff burned while offline and not reset on reconnect, one stuck row blocking
     others, some queues never resuming on reconnect.
   - **E. Notification preferences are fetched live with no cache**, so *every local notification is suppressed offline*.
   - **F. Nothing tells the user** they are offline or that changes are waiting. There is no offline banner and no
     pending-sync indicator anywhere on the shell.
3. **Top five by user impact**
   1. Local notifications never fire offline (preferences fetched live, no cache) — tiny fix, large effect.
   2. Silent data loss: edits to `instrument`, `entry_kind`, `payment_method`, `last4`, annual-fee override are queued but
      dropped by the server (reports success), then overwritten on the next pull.
   3. Activity bulk actions (categorize, assign card, delete), voice save, and "payment sent → log it" are online-only,
      and the last two can create duplicates on retry.
   4. Adding a card, creating or deleting an override, creating a budget, adding a subscription, and importing a
      statement are blocked offline (need new queue paths).
   5. Split (shared expenses): reads are server-first, offline group creation/member-add can be rejected because queued
      commands are sent in random order, and failed commands have no UI.
4. **Safe to do incrementally.** Almost every fix reuses a pattern already in the repo (local write, then
   `SyncQueue` / `CommandOutbox` / transaction outbox, with an overlay and a client-generated id). Section 7 orders the
   work by risk, with Phase 0 and Phase 1 needing no new server routes except one small migration.

---------------------------------------------------------------------------------------------------

## 2. How offline works today (what we build on)

| Piece | Where | What it does |
|---|---|---|
| Local DB | `data/local/app_database.dart`, `financial_store.dart` | SQLite. Transactions, cards, entities, namespaced per user (`user:<sub>` derived from the JWT locally, so it works with an expired token). |
| Response cache | `data/local/response_cache.dart` | Raw JSON of server responses by key. Used as the offline snapshot for many readers. |
| `SyncQueue` + `SyncEngine` | `data/local/sync_queue.dart`, `features/sync/sync_engine.dart` | Field-level edits, coalesced per row. Push, then pull, then ack. Triggers: sign-in, connectivity regained, app resume. |
| `CommandOutbox` | `data/local_first/command_outbox.dart` | "Do this on the server later" for actions with their own routes (ignore/restore, lounge visit, points adjust, budgets, recurring edit). Ordered per target, opposite commands cancel, backoff 30 s → 30 min, permanent 4xx are parked. |
| Transaction outbox | `data/local/transaction_outbox_repository.dart` | Quick-add creates. Stable `clientMutationId`, provisional row shown in Activity at once, server dedupes. |
| Other durable queues | duplicate-resolution outbox, tag outbox, foreign-payments outbox, statement-import outbox (flag-gated), SMS v2 `v2_outbox`, shared-expenses `shared_commands`, private split documents | Each has its own sync. |
| Overlays | `data/local_first/pending_overlays.dart`, `FinancialStore.entities()` | Queued edits show immediately on top of last-loaded data. |
| Connectivity | `isOnlineProvider` (`app/providers.dart:2766`) | `connectivity_plus` stream. Interface state only, **not** real reachability. |

**What the server's `/sync/push` accepts** (`api/src/index.js:1277`, `db/supabase/migrations/20261025150000_sync_apply_change_v2.sql`,
`20261021000000_card_day_sources.sql`):

| Entity | Allowed | Notes |
|---|---|---|
| `transactions` | **update only**, fields `user_card_id, amount_inr, occurred_at, merchant_name, merchant_vpa, mcc, category_id, user_category_id, rail, note` | `status` and `delete` are rejected here (must use the domain route). **`instrument`, `entry_kind`, `payment_method`, `exclude_from_spend` are not in the legacy list.** |
| `user_cards` | **update only** | Not accepted: `last4`, `annual_fee_override_inr`. Delete becomes archive. |
| `card_overrides` | **update only** | No insert, no delete. |
| `user_categories` | insert only | Own RPC. |
| `user_commitments` | insert / update / delete | Own RPC. |
| anything else | rejected as `unknown_entity` | Client treats as a permanent failure. |

The typed `sync_apply_change_v2` (which *does* list `instrument` and `entry_kind`) is behind `SYNC_TYPED_WRITES_ENABLED`,
which **defaults to false** in `docker-compose.prod.yml:152` and `docker-compose.staging.yml:126`. *Check the real production
value before relying on either behaviour.*

---------------------------------------------------------------------------------------------------

## 3. Root causes (fix these and most symptoms go away)

| # | Root cause | Evidence | Effect |
|---|---|---|---|
| RC1 | **Connectivity signal is a bare stream with no seeded value.** `_lastKnownOffline` defaults to `false`; `isOnlineProvider.valueOrNull` is `null` until the first event. Every `== false` check and `_isKnownOffline()` shortcut is inert until then. | `providers.dart:2766-2772, 4831-4833`; no `checkConnectivity()` anywhere in `lib/`. I verified `connectivity_plus 7.3.1` on Android *does* emit the current state on first listen, so this is a **timing hardening**, not a certain bug. It still matters because readers evaluated before the first event go network-first. | Offline fallbacks fire late or not at all. |
| RC2 | **"Online" means "an interface is up", not "the server is reachable".** Captive portal / dead Wi-Fi reads as online, so each live call burns the 15 s header / 30 s total timeout before falling back. | `authenticated_http_client.dart:26-31` | Screens spin 15-30 s on "bad" Wi-Fi. |
| RC3 | **Network-first writes with a queue-on-error fallback**, and the fallback is gated on `isOnline == false`. | edit card, archive card, voice, etc. | Spinner, then error, or no queue. |
| RC4 | **Server accepts only a few entities/fields** and **drops unknown fields while reporting `applied=true`.** The client cannot tell success from a silent drop. | section 2 table | Edits shown as "Saved offline", then lost after sync. |
| RC5 | **Queue retry hygiene**: backoff incremented by offline attempts and not reset on reconnect; no attempts/park state on the transaction outbox; queue ordering by `created_at` when it is always 0 (Split). | see section 5.4 | Delayed sync, head-of-line blocking, silent rejection. |
| RC6 | **No user-visible state.** `lastSyncedAtProvider`, `financialSyncStatusProvider`, pending counts all exist, but only `sync_backup_screen.dart:415-417` shows any. | `providers.dart:4955, 4765, 2815` | User cannot tell what is saved, what is stale, what is waiting. |

---------------------------------------------------------------------------------------------------

## 4. Inventory by area

Legend: **OK** works offline · **PART** partly works · **BUG** online-only but should work offline · **NET** legitimately needs internet.
Severity of a BUG/PART: H = data loss, wrong result, or core flow blocked · M = feature blocked or slow · L = cosmetic.

### 4.1 Startup, auth, account

| Item | Read offline | Write offline | Class | Sev | Change needed |
|---|---|---|---|---|---|
| Cold start, signed-in | Local token + namespace, no network in router or `main.dart`. Refresh runs un-awaited; only a definitive 401 signs out. | n/a | **OK** | | none |
| Edge: refresh token present, access token missing (process death between the two writes in `token_store.dart:97-102`) | Routed to `/welcome` offline | | PART | L | write access token first, or persist last `sub` and seed namespace |
| Forced-upgrade / maintenance gate | Fails open (2 s timeout). Null result cached for the process lifetime. | n/a | **OK** | L | `ref.invalidate(appStatusProvider)` on offline→online |
| First-ever launch, OTP login, activation, onboarding complete | needs server | | **NET** | | clearer "needs internet" message only |
| Profile / You tab | cache-first, background refresh | | **OK** | | |
| Edit profile name | | two-step live PATCH, error offline | **BUG** | M | write to profile cache now (`profileSnapshotWriterProvider` exists), queue a command |
| Avatar | live every launch, no cache (falls back to initial letter) | live | PART | L | cache last `AvatarState`. Photo upload stays NET |
| **Notification preferences** | **live, no cache, error offline** | live PUT per toggle | **BUG** | **H** | cache JSON in `ResponseCache`, read cache-first, optimistic write + queued command; `NotificationPreferences.fromJson` already has defaults (`notification_preferences_repository.dart:60-70`) |
| **`NotificationGate.fire`** and every local trigger (caps, bills, renewals, budgets, milestones, geofence, recovery reminders) | `await ref.read(notificationPreferencesProvider.future)` at `notification_gate.dart:123` — throws offline, swallowed by the trigger runner, **so every local alert is silent offline** (verified) | the OS banner and dedupe mark are written before the inbox POST; the inbox POST fails silently and is not queued, so the inbox row is lost while the dedupe key is set | **BUG** | **H** | gate falls back to cached/default prefs; queue `recordAppNotification` via `CommandOutbox` |
| Notifications inbox | network first, cache after failure | mark-read live, failures swallowed | PART | M | cache-first + background refresh; optimistic mark-read via command |
| Settings/prefs sync (`settings_sync.dart`) | SharedPreferences is source of truth | dirty-key replay runs only on sign-in transition and next push, **not on reconnect** | PART | M | listen to `isOnlineProvider` and app resume, call `pullAndApply()` |
| Biometric lock | local | | **OK** | | |
| Consents | list is live, no cache; SMS-reading consent is mirror-first but the mirror is only valid for `consentPolicyVersion` (`'2026-11-15'`), so a version bump or new device offline reads as "not granted" and **SMS reading pauses** | every grant/revoke POST is live and blocking | PART | M | cache the list; set mirror immediately and queue the audit POST; treat previous-version mirror as granted until a re-prompt is possible |
| Contributions opt-in toggle | | live | **BUG** | L | queue a command, patch profile cache |
| **Sign-out** | works offline (8 s server steps, then wipe) | **`flushOutboxes` and `report()` ignore `CommandOutbox`, pending tags, and shared-expense commands** → user can sign out and silently lose queued work | PART | **H** | count + flush command outbox, tags, shared commands, `split_documents` pending; stronger copy when offline |
| Support / feedback ticket | | live POST, draft lost | **BUG** | M | queue as command, "will send when online" |
| What's New / changelog | live GET, **no timeout, no cache** | | PART | L | cache last response + add timeout |
| Merchant future rules screen | live GET only, no cache | live update/disable with version check | **BUG** | M | cache list, queue update/disable, resolve version conflict on sync |
| Linked devices | live, in-memory cache only | revoke live | NET (read PART) | L | optional persisted list |
| Delete account / erase server data / email-phone-recovery changes | | | **NET** | | disable buttons offline with "needs internet" hint |
| Referrals, subscription credits, emergency contacts | cache fallback with stale text | spin/purchase live | **OK** / **NET** | | none |
| Transaction tags, partner apply, product access, portable backup, analytics, crash reporter | tags **OK** (model implementation); others NET or best-effort | | | | analytics: add `.timeout` |

### 4.2 Transactions, entry, import, cards

| Item | Read offline | Write offline | Class | Sev | Change needed |
|---|---|---|---|---|---|
| Activity list, Home | local-first, filters local | | **OK** | | |
| Transaction detail | `fetchTransaction` first (≈15 s on dead Wi-Fi) then local; `local-outbox:` rows are read-only | note, ignore/delete/restore, spend-exclusion: queued with overlay | PART | M | read local row first, refresh in background |
| **Edit transaction** | local-first block exists | queues `instrument` and `entry_kind`, which the legacy server function **silently drops with `applied=true`**, so the pull overwrites the edit. `payment_method` change and self-transfer confirm/undo are refused offline | PART | **H** | see RC4 fix in 7 (Phase 1). Queue `payment_method` as a command |
| **Activity bulk categorize / assign card / delete** (`activity_screen.dart:447, 631, 702` — verified direct `repo.*` calls) | | online only, error offline | **BUG** | **H** | per-id `SyncQueue.enqueueUpdate` for category/card; delete = `CommandOutbox` ignore + `markInactive` (same as detail screen). Skip `v2:` ids as today |
| Bulk tags, bulk spend-exclusion | | local-first | **OK** | | |
| Deleted transactions screen | live, no cache | restore queued | **BUG** | M | build list from local `ignored` rows; cache server list |
| Duplicate review | live, no cache (error + Retry) | decisions queued in `DuplicateResolutionOutbox`, idempotent; no overlay so a pending-resolved pair reappears | PART | M | cache candidates; hide ids present in the duplicate outbox |
| Foreign payments | local + own outbox | | **OK** | M | outbox drains only on `fetchAll`/mutation. Call `sync()` on reconnect/resume |
| Tags, attachments, user categories | local | local / `SyncQueue` insert with client id | **OK** | | |
| Built-in categories | cache-first; first-ever offline launch has custom categories only | | PART | L | bundle `categories.json` like the catalogue |
| **Quick add** | | outbox + provisional row + stable `clientMutationId` | **OK** | | |
| Quick add **with receipt** | | refuses offline ("Connect to the internet…") | PART | M | save to outbox; store receipt locally keyed `local-outbox:<id>`; remap after flush (same as tags) |
| Quick add: poison handling | | oldest 20 rows each flush, `last_error` only, no attempts/park → 20 permanent rejects starve newer rows | PART | **H** | add attempts + park on 4xx |
| **Voice save** (`voice_input_sheet.dart:766-778` — verified) | on-device speech + local parse | `repo.logTransaction` direct, **new `Uuid().v4()` per attempt** → retry after a lost response duplicates; raw error text offline; points redemption online only | **BUG** | **H** | use outbox with id generated once per draft; points via `OverlayCommand.pointsAdjust` |
| **Payment-sent "log it"** (reported, `payment_sent_screen.dart:~145`) | | direct `logTransaction`, no client id → duplicates; acceptance report only catches `ApiException` | **BUG** | **H** | outbox with stable id; catch all errors on the report |
| UPI QR scan, card scanner (OCR), comparison, home widget, payment rules | local | | **OK** (UPI intent itself NET) | | |
| Scan result: "always use this card here", "add this card" | | direct | **BUG** | M | via override/add-card fixes below |
| Wallet / cards read | local-first + overlay | | **OK** | | |
| Archived cards read | network-first (15-30 s), snapshot fallback | restore refused offline | PART / NET | L | cache-first; restore may stay NET |
| **Add card** (find cards, picker, scan, scan result) | | direct POST `/user-cards`, no client id, no queue; sync INSERT is not supported | **BUG** | **H** | new `sync_insert_user_card` RPC (client uuid) + provisional card in `FinancialStore` + `enqueueInsert`; treat `card_already_added` as success-with-merge |
| **Edit card** | | network-first then queue; queued `last4` / `annual_fee_override_inr` are dropped by the server, UI says "Saved offline". Points balance refused offline | PART | **H** | local-first; add fields to allowlist (migration); points via `pointsAdjust` |
| Set default card (card actions) | | local-first | **OK** | | |
| Set default card (edit card screen) | | refuses offline | PART | L | call `localFirstCardsProvider.setDefault` |
| Reorder cards | | local-first | **OK** | | |
| Archive / pause card | | network-first then queue, ≈15 s spin | PART | M | local-first like set-default; un-pause/unarchive offline currently rethrows |
| Lounge visit, points correction | cache fallback | queued, idempotent, overlay | **OK** | | |
| Card overrides read | network-first 15 s, no overlay for queued edits, ignores `_isKnownOffline()` | | PART | M | cache-first; overlay `card_overrides` pending rows |
| **Card overrides create / delete** | | direct, no queue | **BUG** | M | `sync_insert_card_override` (client uuid) and queued delete |
| Card overrides toggle / edit | | queued but no invalidate/overlay, toggle visually unchanged | PART | M | overlay + invalidate |
| Discover new cards | `categorySpendProvider` rethrows with no cache offline | | PART | L | fall back to spend computed from local rows |
| Merchant search | local history, cache, then server with **no timeout** | | PART | L | add timeout; search local merchant directory |
| Nearby merchants / geofence | device cache; first discovery needs server | | PART / NET | | |
| Catalogue | cache → live → **bundled asset** | | **OK** | | |
| Card requests / report wrong data | | direct POST | NET | L | optional command kind |
| Parsing (CSV/TSV/XLSX/PDF/JSON/OCR) | all on-device | | **OK** | | |
| **Statement import submit** | | posts batch by batch; reviewed rows live in widget memory only; durable outbox exists but is **flag-gated off** (`PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED`) and never auto-resumes | **BUG** | **H** | enable flag; resume on reconnect; "Saved, will upload when online" |
| Import review duplicate check | live `fetchTransactions()` | | PART | L | read local store |
| Gmail / IMAP / forwarding / inbound email | | | **NET** | | |
| SMS import (Android/iOS) | local intake first, durable | | **OK** | | see 4.4 |
| Data export | local | | **OK** | | |

### 4.3 Insights, bills, subscriptions, tools

| Item | Read offline | Write offline | Class | Sev | Change needed |
|---|---|---|---|---|---|
| Spend trends, hub, overview, category spend (SMS-v2 users) | fully local ledger | | **OK** | | |
| Same, legacy users (manual/email/iOS) | cached server JSON or `_buildLocalSpendReport` (no reward/cap maths, annual fee null, fixed 12 buckets) | | PART | M | "Saved data · updated …" chip; accept the local fallback differences |
| Duplicate-candidate badge | reads 0 offline | | **OK** (acceptable) | | |
| **Budgets read** | cached server list; **`spent` is server-computed and frozen offline**; error on cold start | brand-new budget online-only; edit/delete queued with overlay | PART | **H** | local `user_budgets` table + sync entity (mirror `user_commitments`); compute `spent` locally (logic is spend-only, scope rules in `api/src/spend_reports.js:658-721`) |
| Subscriptions list (v2) | fully local | | **OK** | | |
| Subscriptions list (legacy) | cached `/recurring` or a local heuristic that differs from the server's | | PART | M | accept; label |
| **Subscription add** | | direct server call, error offline; in v2 mode a server-created one is never shown | **BUG** | M | store as local commitment/subscription and merge |
| **Subscription edit / ignore in v2 mode** | | queued command calls `PATCH /recurring/:id` with id `v2:<key>` on a uuid column → expected **HTTP 500** *(inferred from SQL, not run)* → retried every 30 min forever; edit lives only in an overlay | **BUG** | **H** | local synced `subscription_overrides` keyed by series id; apply in the v2 branch; keep server command only for legacy ids |
| Bills / commitments list | local | | **OK** | | |
| `paymentsDueProvider` | awaits `loadTransactionsWithOfflineCache` even in v2 branch → Bills tab shows ErrorState for a v2 user with no coverage offline | | PART | M | move load into the legacy branch, or wrap in try/catch |
| **Commitments add/edit/delete/mark paid** | | local SQLite + `SyncQueue` (the reference implementation) | **OK** | | |
| Mark paid / dismiss on SMS-derived v2 bill | | saves a copy with `source: sms, isUserConfirmed: false`, which the v2 provider filters out → **no visible effect**, junk row synced *(inferred)* | **BUG** | M | merge manual copies over derived bills by id, or set `isUserConfirmed: true` |
| Card bill ledger read | local | | **OK** | | |
| **Card bill "mark paid"/edit** | | writes a synthetic payment row with no outbox entry; **pruned at the next complete refresh** (`financial_store.dart:603-624`), so the bill reverts to unpaid | **BUG** | **H** | route via transaction outbox or mark local-only so prune skips it |
| Past bill receipts | local, device-only | local | **OK** (not synced) | L | decide whether to sync |
| Central bills projections | uncached; section silently vanishes | | PART | L | cache response |
| Caps, fee waivers, milestones, points | local-first, **but cap/reward numbers are server-computed**; offline-created rows do not move them until sync | | PART | M | "as of last sync" label (do not duplicate reward maths on device) |
| Monthly savings report | local-first; v2 mode hard-codes `valueMissed`/`baselineSingleCard` = 0 even online | | PART | L | restore locally or hide those tiles |
| Voice answers, EMI advisor, split planner, travel mode, emergency card info, credit utilization | local | | **OK** | | |
| Calculator override fetch | `cardOverridesProvider` network-first 15 s | | PART | L | cache-first (shared with 4.2) |
| **Reminders / due-date notifications** | no OS-scheduled notifications exist anywhere (no `zonedSchedule`, `workmanager`); triggers run only while the app process is alive, **and** are blocked offline by the preferences bug | | **BUG** | **H** | Phase 0 prefs fix, then Phase 4 scheduled local notifications. The "reminder" toggle currently schedules nothing |
| Subscription credits / referrals | cache + stale text | | **OK** / **NET** | | |
| Dead code | `services/recurrence_engine.dart` (tests only), `fetchTransactionsCsv` (no caller) | | | | leave, note for cleanup |

### 4.4 Shared expenses (Split), SMS v2, backup, misc

| Item | Read offline | Write offline | Class | Sev | Change needed |
|---|---|---|---|---|---|
| **Split hub/group/balances/activity** | server-first, falls back to cached JSON of pages opened before; unopened pages error. The local projection (`shared_projections`) and provisional overlay (`shared_provisional`) are filled but **never read by any UI** | | PART | **H** | build views from `store.readContexts/readPage`; render pending ops as "Pending" rows |
| Split capabilities flags | never cached → create/add hidden and `submit` throws | | PART | M | treat unknown flags as allowed to queue; don't clear on `clearPrefix` |
| **Create group + add member offline** | new group not in any list | `context.create` and `member.invite` both stamped `created_at = 0` (verified `shared_store.dart:254,265`), claimed by `ORDER BY created_at, operation_id` → **random order**; invite can hit server first and be `rejected` for good *(inferred)* | **BUG** | **H** | stamp `now`/monotonic counter; `dependsOn: [createOpId]` for invites and renames |
| Add expense (shared) | roster from cache; never-opened group fails | atomic seal + enqueue, idempotent | PART | M | pending overlay |
| Settle / report payment | cached roster | deterministic ids | **OK** | | |
| Approve / reject / confirm settlement | | runtime would queue, UI hides buttons when `runtime.offline` | **BUG** | M | allow tap, show "queued" |
| Failed shared commands (`rejected`/`conflict`) | | no UI lists them | **BUG** | **H** | "Needs attention" list with Retry / Discard |
| Shared retry after reconnect | | command that failed offline can wait ≈5 min | PART | M | reset `next_attempt` on reconnect |
| Invites, join requests, links, transfer owner, leave, remove member | | | **NET** | | disable with hint |
| Private per-transaction split | stored doc read local; first view offline errors | durable, idempotent, 409 → user picks | **OK** | L | global "N need attention" count |
| **SMS capture → parse → ledger** | zero network on Android foreground/background and iOS | | **OK** | | |
| **Baseline rule bundle is empty** (`assets/sms_rules/baseline_bundle.json`, `rules: []`, verified) | a never-online install/restore parses nothing; everything goes to Needs review; recovers on first reconnect | | PART | M | ship a signed non-empty baseline |
| `SmsV2Runtime._sync` order | `_refreshRules()` runs **before** the capture loop and awaits App Check with no timeout → on dead Wi-Fi new SMS parse tens of seconds late | | PART | M | capture first; skip network steps when offline; 5 s timeout on `headers()` |
| **SMS outbox backoff** | | `FactsUpload._send` increments attempts on any exception, so offline ticks double the delay (30 s → 30 min); reconnect calls `sync()` but `due()` skips rows still in backoff → upload delayed up to 30 min | PART | M | don't count pure network errors; reset backoff on reconnect |
| **Corrections after an offline spell** | | `_waitsForUpload` stops waiting once source attempts ≥ 6; correction posted before facts exist → `correction_facts_not_found`, parked as "kept on phone" *(inferred)* | **BUG** | M | hold while source is network-failed; reset attempts on requeue |
| Offline correction loses "share with community" | consent lookup errors → false | | PART | L | local mirror of shared-learning consent |
| Confirm a credit-card instrument needing a wallet card | | direct `addCard`, card stays unconfirmed | **BUG** | M | queue via add-card fix |
| Rules refresh, template/AI upload, stats, telemetry, `sync_pull` | | all degrade gracefully and retry | **OK** / **NET** | L | Gemini bar: say "offline", stop polling |
| Portable backup | `PortableBackupHttpRepository` has no caller in `lib` outside its own folder; no timeout on `client.send` | local wipe is local | **NET** | | add timeout if wired in |
| Crash reporter | queued, retries on next report/start | | **OK** | L | flush on reconnect |

---------------------------------------------------------------------------------------------------

## 5. Cross-cutting fixes in detail

### 5.1 Connectivity seed and reachability (RC1, RC2)
- `isOnlineProvider`: `async*` that yields `await Connectivity().checkConnectivity()` first, then `yield*` the stream. Subscribe at app root so `_lastKnownOffline` is correct from the first frame.
- Wherever a fallback is gated on `isOnline == false`, also treat `isTransientNetworkFailure(e)` (`api_exception.dart:138`) as "offline". The archive paths already do.
- Local-first reads should return the snapshot **before** any fetch and refresh in the background (the `profileProvider` + `_warmDisplay` pattern). Fixes the 15-30 s dead-Wi-Fi spins for transaction detail, notifications, archived cards, overrides.

### 5.2 One write pattern for everything (RC3)
1. Validate and write to the local store, with a client-generated stable id.
2. Enqueue (`SyncQueue` for allowlisted field edits and inserts, `CommandOutbox` for actions with their own route, transaction outbox for creates).
3. Show the result immediately via the overlay.
4. `unawaited(syncEngine.sync())` / `outboxFlushRequest`. No `await` on the network.
Rule already written in `command_outbox.dart`: a replayed command must set a state, not add to one; anything additive needs a client request id.

### 5.3 Server allowlist (RC4) — the data-loss fix
Choose **one** of:
- **(a)** Enable `SYNC_TYPED_WRITES_ENABLED` (the typed function lists `instrument` and `entry_kind`). Needs a release-gate review (`db/scripts/release_security_check.js` tracks it as a gated feature).
- **(b)** A new additive migration extending `sync_fields_for`: `transactions` += `instrument, entry_kind, payment_method, exclude_from_spend`; `user_cards` += `last4, annual_fee_override_inr`. Note `20261021000000` dropped `last4` from the earlier list; confirm why before restoring.
- **(c)** Interim client-side guard: never queue those fields through `SyncQueue`; use the online PATCH only and show "needs internet" for them.

Also make the push response honest: report fields that were dropped so the client can fail loudly instead of "applied".
New insert RPCs (pattern: `sync_insert_user_category`): `sync_insert_user_card`, `sync_insert_card_override`, and a queued delete for `card_overrides`. Add a `user_budgets` entity (mirror `user_commitments`).

### 5.4 Queue hygiene (RC5)
- Transaction outbox: `attempts`, `next_attempt_at`, park on permanent 4xx, so a bad row cannot starve the next 20.
- Reset backoff on offline→online for: `shared_commands`, SMS `v2_outbox`, and do not count pure network errors (`SocketException`, `TimeoutException`, `ClientException`) as attempts.
- Reconnect/resume triggers still missing: statement-import `resume()`, foreign-payments `sync()`, settings `pullAndApply()`, `appStatusProvider` re-check, crash-report flush, push registration retry.
- Split: stamp real `created_at` and use `dependsOn`.

### 5.5 Make the state visible (RC6)
One shell widget in `_AppShell` (`router.dart:~1396`, beside `SmsSyncStatusLayout`) that reads `isOnlineProvider`, `pendingOutboxCountProvider`, `pendingSyncCountProvider`, parked/rejected counts:
"Offline · showing saved data" and "N changes waiting to sync" and "N need attention" (taps through to a list).
A reusable "Saved data · updated 6:40 PM" row using `ResponseCache.read().fetchedAt` / `lastSyncedAtProvider`, placed on Budgets, Subscriptions, Spend Trends (legacy), Caps, Monthly Savings, Bills. A "Needs attention" screen listing `rejected`/`parked`/`blocked` items from every queue with Retry / Discard.

### 5.6 Sign-out safety
`flushOutboxes` and `report()` must also cover: `CommandOutbox`, pending tags, shared commands (`shared_commands` not `committed`), `split_documents` with `pending=1`, statement-import outbox. When offline with pending > 0, say so plainly ("you are offline, N changes will be lost") and require an explicit confirmation.

---------------------------------------------------------------------------------------------------

## 6. Things that legitimately need internet (leave online, improve messaging only)

OTP login, first activation/onboarding, account recovery, email/phone/recovery-email verification, delete account / erase server data, revoke linked device, avatar photo upload, referral spin, partner apply links, UPI payment intent, Gmail/IMAP/email forwarding, inviting another user / join requests / owner transfer in Split, server OCR/AI (Gemini) classification, rules-bundle download, portable-backup download/restore, remote push (FCM) and push-token registration (self-retries), first-time catalogue (bundled fallback already covers offline), first nearby-merchant discovery.
For these: disable the button when offline and show "Needs internet", instead of an error after a spinner.

---------------------------------------------------------------------------------------------------

## 7. Phased plan (ordered by risk, each phase shippable alone)

### Phase 0 — Foundations and visibility (no server change, low risk)
| # | Change | Files |
|---|---|---|
| 0.1 | Seed `isOnlineProvider`; subscribe at root | `providers.dart:2766` |
| 0.2 | Cache notification preferences; gate falls back to cached/default prefs | `providers.dart:4322`, `notification_preferences_repository.dart`, `notification_gate.dart:123` |
| 0.3 | Queue `recordAppNotification` so inbox rows survive offline; write dedupe mark only after the OS banner is shown | `providers.dart:4271`, `notification_gate.dart` |
| 0.4 | Shell offline + pending + needs-attention indicator | `router.dart` `_AppShell`, new small widget |
| 0.5 | Sign-out report/flush covers every queue (5.6) | `features/auth/account_sign_out_provider.dart` |
| 0.6 | Reconnect triggers (5.4): settings pull, app-status re-check, foreign payments, statement-import resume, crash flush | `settings_sync.dart`, `providers.dart`, `sync_engine.dart` |
| 0.7 | Timeouts on bare HTTP: merchant search, changelog, analytics, portable HTTP | respective files |
| 0.8 | `paymentsDueProvider`: don't await transactions in the v2 branch | `payments_due_screen.dart:178-185` |

### Phase 1 — Stop silent data loss and duplicates
| # | Change |
|---|---|
| 1.1 | Server allowlist decision (5.3 a/b/c) plus honest push response |
| 1.2 | Activity bulk categorize / assign card / delete → queue (`activity_screen.dart:447, 631, 702`) |
| 1.3 | Voice save and payment-sent log → transaction outbox with a stable id per draft |
| 1.4 | Transaction outbox: attempts + park |
| 1.5 | Split: real `created_at`, `dependsOn` for invite/rename, "Needs attention" list, reconnect backoff reset |
| 1.6 | SMS: capture before network in `_sync`; don't burn backoff offline; reset on reconnect; corrections hold |
| 1.7 | v2 subscription edit/ignore: stop sending `v2:` ids to the server; local override store |
| 1.8 | Card-bill manual payment made durable (not pruned) |
| 1.9 | v2 commitments mark-paid / dismiss take effect |

### Phase 2 — Create and edit offline where it is currently blocked
| # | Change |
|---|---|
| 2.1 | Add card offline: `sync_insert_user_card` + provisional card + `enqueueInsert` |
| 2.2 | Edit card local-first (incl. points via `pointsAdjust`); set-default and archive local-first |
| 2.3 | Card overrides: create/delete queue, overlay, invalidate |
| 2.4 | Budgets: local table + `user_budgets` sync entity + local `spent` |
| 2.5 | Subscription add offline (local record merged into list) |
| 2.6 | Quick add with receipt via outbox; receipt remapped after flush |
| 2.7 | Statement import: enable continuation flag, auto-resume, "will upload when online" |
| 2.8 | Profile name, support ticket, contributions toggle, consent grants → `CommandOutbox` |
| 2.9 | Split approve/reject/confirm tappable offline |

### Phase 3 — Offline reads and stale labelling
Split local-projection fallback and pending overlay · deleted transactions from local rows · duplicate candidates cache + outbox filter · bundled `categories.json` · local spend fallback for `categorySpendProvider` · central bills projection cache · avatar / What's New / consent list / merchant rules / linked devices caches · "Saved data · updated …" row · transaction detail reads local first · archived cards and overrides cache-first.

### Phase 4 — Larger features
- Scheduled **local** notifications (`flutter_local_notifications` `zonedSchedule` + `timezone`, Android exact-alarm permission, cancel when paid/ignored) so due-date and renewal reminders work with the app closed.
- Signed non-empty baseline SMS rule bundle so a never-online install can parse common banks.
- Optional: sync past-bill receipts; restore v2 monthly "value missed".

---------------------------------------------------------------------------------------------------

## 8. "Don't break existing things" guardrails

1. **Additive only.** New tables/columns/RPCs/keys; no renames; no behaviour change for users who are online and healthy.
2. Every new queued write must be **idempotent** (client id or set-state semantics) and show via overlay.
3. Keep legacy server behaviour for older app versions: new RPCs are new names; the allowlist change adds fields only. Gate risky pieces behind the existing env flags pattern.
4. Respect `docs/PERFORMANCE_RULEBOOK.md` (no O(history) work on the UI isolate, `cachedRegExp`, `INDEXED BY` id lookups). Local budget `spent` and any local-row fallback must run in the read worker / off the UI isolate. Run `flutter test test/performance_guards_test.dart` and `scripts/perf_smoke_android.sh` before claiming done.
5. The working tree currently has many uncommitted edits across `api/` and `app/` (same files this plan touches, e.g. `providers.dart`, `router.dart`, `financial_store.dart`, `activity_screen.dart`, `sms_v2/*`). Land or branch those first, or rebase each phase carefully.
6. Follow the project flow: fix on `dev`, merge into `prod`, never touch `master`.
7. Security: nothing in this plan stores card numbers; cached notification prefs, consent mirror and queued support tickets contain no secrets. Re-run `owasp-mobile-security-checker` on the consent-mirror and sign-out changes.

---------------------------------------------------------------------------------------------------

## 9. Test matrix (airplane-mode, on a real phone and the emulator)

For each, run: (a) cold start offline, (b) go offline mid-session, (c) reconnect, (d) kill app while offline then reconnect, (e) captive Wi-Fi (connected, no internet).

| Scenario | Expect |
|---|---|
| Signed-in cold start offline | Home renders from local data, no logout, banner shows "Offline" |
| Add expense (quick add, voice, payment-sent) offline ×2 with a lost-response retry | exactly one row after sync |
| Edit category/instrument/payment method/note offline | survives the pull after reconnect |
| Bulk categorize/assign/delete 5 rows offline | applied locally, one push, no error |
| Add card, edit card (last4, fee, nickname, points), create/delete override offline | visible immediately, correct after sync |
| New budget, subscription add/edit/ignore, mark bill paid offline | visible immediately, no 30-min retry loop, survives full refresh |
| Import a statement offline, kill app, reconnect | uploaded once, no duplicates |
| Create Split group + add member + expense offline, reconnect | order preserved, nothing rejected; failures listed |
| SMS arrives offline (fresh install with no bundle / existing install) | parsed or in Needs review; uploads within ~1 min of reconnect |
| Local notifications offline | bills/caps/renewal alerts fire, inbox row appears after sync |
| Sign out with 3 queued changes offline | warning names the count; changes flushed first when online |
| Captive Wi-Fi | screens show local data within ~1 s, not 15-30 s |

Automated: unit tests for each new queue (idempotent replay, ordering, park), provider tests with `isOnlineProvider` overridden `false`, and the existing `performance_guards_test.dart`.

---------------------------------------------------------------------------------------------------

## 10. Decisions and questions for the owner

1. **Allowlist fix (5.3)**: prefer enabling typed writes (a), a new migration (b), or the client guard (c) first? What is `SYNC_TYPED_WRITES_ENABLED` in real production?
2. **Scope for Split offline**: full local read + pending overlay (Phase 3), or only fix ordering/visibility of failures (Phase 1) for now?
3. **Scheduled reminders** (Phase 4) need an exact-alarm permission on Android 12+. Acceptable?
4. **Baseline SMS bundle**: who signs and publishes it, and which banks go in?
5. **Budgets and subscriptions offline**: confirm you want these computed on the phone (a second implementation of server logic) rather than only labelled "as of last sync".
6. **Statement-import continuation flag** was left off by default. Was that deliberate (a known issue), or can it be turned on?
7. **Consent policy bump offline**: OK to keep SMS reading running on the previous-version consent until the next online re-prompt?

---------------------------------------------------------------------------------------------------

## 11. Confidence and limits

- **Verified by me directly:** connectivity stream behaviour in `connectivity_plus 7.3.1` (Android emits an initial event); typed-sync flag defaults; server sync allowlists; bulk-action direct calls (`activity_screen.dart:447, 631, 702`); notification gate awaiting preferences (`notification_gate.dart:123`); Split `createdAt = 0` default; empty baseline SMS bundle; voice save with a fresh UUID per attempt.
- **Reported by the audit agents, spot-read but not re-checked line by line:** the remaining rows.
- **Marked *(inferred)*:** conclusions drawn from reading code or SQL without running it (v2 subscription ids producing HTTP 500, v2 mark-paid being filtered out, Split invite rejection ordering, corrections parked after offline). Confirm each with a short airplane-mode test before scheduling the fix.
- Line numbers drift; treat `~` references as approximate.
