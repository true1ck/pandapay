# Stale reads, vanishing transactions, and what each API costs

Date: 18 Nov 2026. Branch: `dev`, nothing committed. Client-only change, no server deploy.

## 0. Short version

- **What you saw is real and has a code cause.** A transaction you add shows in spending, then disappears. The phone asked the server for a full list at about the same moment the add was being delivered. The list was answered from *before* the add, arrived *after* it, and the phone treated "not in the list" as "deleted on the server" and removed the row. By then the outbox entry that kept the row visible was already gone, so nothing brought it back.
- **Your guess was right in spirit.** The server has no ordering between one user's read and one user's write (each runs on its own connection through a shared first-come line, `api/src/admission.js`). The phone did not allow for that.
- **It was not only the edit page.** The same pattern existed for the card list, the saved server reports (spend report, budgets, recurring, monthly report, category spend), the self-transfer rules, and the way the transaction list was shared between callers. All of those are fixed in one place plus one rule.
- **Fixed on the phone, not the server.** A small "write fence" (`app/lib/data/connectivity/write_fence.dart`) sees every acknowledged write to the API. Any server list or report that was in flight when a write was acknowledged is dropped and asked for again, and is never stored over local data. A second change removes the heavy call altogether: after an edit push the phone now reads back only the rows it edited (one small request each), not the whole history.
- **Proof:** a test that replays the exact sequence failed before the fix (the new spend was deleted) and passes after. Every fix was also turned off one at a time to confirm a test goes red. Full app suite after every change in this report: 5,656 passed, 11 skipped, 0 failed. An earlier run had one failure, my own signature change breaking a test double, since fixed.
- **Not proven:** I could not reproduce it on your iPhone. The evidence is code reading plus a test that replays the sequence. See section 5.
- **API cost** is in section 6 with measured numbers. The expensive one is the call this bug rode on: the **unpaged full transaction list is 31.7 MB and 313 ms at 40,000 rows**, against 162 KB and 4.1 ms for the paged list the Activity screen uses.
- **Second pass (section 9).** Three client changes remove requests the app made for nothing, measured on the real app stack: no 2-month transaction window read on every save (and once after launch) for an SMS-v2 account (6.9 MB at 40,000 rows); no `GET /home-summary` on open or resume for an SMS-v2 account; and a conditional `If-None-Match` refresh of the catalogue (a 304 when unchanged, against the real server's `ETag`). Also corrected here: my first `/user-cards` timing was understated (12.5 ms, not 1.5 ms) and I overstated how often the 2-month read ran (9.6). Candidates I measured but did not ship, with the reason, are in 9.4. **Section 10 gives the same tables after the changes, with times:** an edit is confirmed in 0.46 s instead of 14 s on a 4G-like network (and finishes at all on a weak one), a save stops moving 6.9 MB, and opening the app moves 62% fewer bytes.

## 1. What happens, step by step

An account that has SMS v2 data reads spending from the phone's own copy of the ledger (`smsV2LedgerReadModelProvider`, `app/lib/features/sms_v2/ledger/providers.dart`), which is built from every transaction row in the local store, queued or delivered. So "disappears from spending" means "the row was deleted from the local store".

| Time | Phone | Server |
|---|---|---|
| T0 | Sync pushes an earlier edit (such as a merchant name) and the server applies it. | `POST /sync/push` |
| T1 | The sync engine then re-reads the **whole** transaction list to get the fresh copy of what it pushed. | `GET /transactions` (unpaged) starts; its snapshot is taken here |
| T2 | You add a transaction. The outbox sends it, the server stores it, the phone saves the real row and deletes the outbox entry. | `POST /transactions` commits |
| T3 | The list arrives. It has no new row, because it was answered before T2. | response of the T1 read |
| T4 | The old code saved the list as "complete" and stamped it with *now* (arrival time). The prune rule is "not in the list, older than the stamp, nothing queued for it, delete it". The new row matched. | |

The prune is `FinancialStore.saveTransactions` (`app/lib/data/local/financial_store.dart:915`). It is correct as long as the stamp is the time the request was *sent*. The Activity/utilization path already did that (`at: requestedAt`). The sync engine's refresh did not, so the window was the whole duration of the full-list read. That read is 31.7 MB at 40,000 rows, so over a phone connection the window is seconds long (14 s on a 4G-like network, section 10).

The same shape, with the card list: `ResponseCache.put` for the card snapshots called `replaceCards` with the arrival time too (`response_cache.dart`). Home refresh runs on open and resume, which are also the moments the outbox flushes, so a card the flush had just added could be deleted by a card list answered a moment earlier.

Second, quieter effect, for accounts still on server reports: while something is queued, the spend report is built from the phone's rows. The moment the outbox delivers, that rule stops, and the saved server report (fetched before the add) is shown, so the new spend vanishes from the total until a refresh lands.

Third: callers shared one in-flight list. After the outbox delivered and invalidated the providers, the new read joined the older in-flight read and got its answer back, so an edit that had just been delivered was put back to its old value.

## 2. Where else the same pattern exists (audit)

"Hazard" means: a server answer can replace or delete local data that a write on the phone has just made, with nothing left to protect it.

| # | Surface | How a server answer is applied | Hazard before | Status |
|---|---|---|---|---|
| 1 | Transactions, sync engine refresh after an edit push (`sync_engine.dart`) | Was: complete list, prunes absent rows. Now: the edited rows only, one by one, never prunes; the list remains only as a fallback above 100 edited rows | **Deleted rows newer than the request.** The bug. | **Fixed twice** (removed the list for normal edits; fenced and request-stamped for the fallback) |
| 2 | Transactions, `loadTransactionsWithOfflineCache` full path (utilization, filtered lists) | Complete list with `at: requestedAt` | Joined an older in-flight read; stored a pre-edit list over a delivered edit | **Fixed** |
| 3 | Transactions, Activity paged refresh (`transaction_page_refresh.dart`) | Additive pages, `at` set, never deletes | Can briefly show an old value after an edit is delivered | Unchanged, low risk |
| 4 | Sync pull delta (`sync_transaction_delta.dart`, `commitTransactionDelta`) | Per-id fetch; a 404 is skipped; only an explicit delete removes | None found | Safe |
| 5 | Cards: Home refresh, wallet loader, background card refresh, sync refresh | `ResponseCache.put` then `replaceCards(at: now)` | **Deleted a card the flush just added** | **Fixed** (4 call sites) |
| 6 | Card overrides snapshots | Blob replace | Older list over a newer one | **Fixed** |
| 7 | Saved server snapshots refreshed in the background (category spend, profile, spend report, budgets, recurring, monthly report, notifications) via `_warmDisplay` | `cache.put` of the answer | Older numbers stored over a change already on screen | **Fixed** (one shared path) |
| 8 | Spend report and monthly report, non-v2 path | Show saved server report once nothing is queued | New spend vanishes after delivery | **Fixed** |
| 9 | Home summary, Home refresh | `cache.put` | Same as 7 | **Fixed** (the cache-first reader `homeSummaryProvider` has no refresh of its own, noted in section 7) |
| 10 | Self-transfer rules (`replaceRemote`) | Deletes all local rules, inserts the server's | A rule confirmed during the read is erased | **Fixed** (skipped when stale) |
| 11 | Transaction tags (`transaction_tags_repository.dart` `_syncOnce`) | Uploads, then downloads and replays queued intent over the snapshot, single flight | None found | Safe by design |
| 12 | User state: bill-card links, typed balances, subscription edits (`user_state_sync.dart`) | Cursor delta with a client-edited-at rule | None found | Safe |
| 13 | Bills / commitments (`commitments_repository.applyRemote`) | Whole record arrives in the change | None found in the paths read | Read, not changed |
| 14 | Splits (shared expenses), SMS v2 facts sync, statement import, duplicate resolutions, foreign payments, budgets store | Their own queue and receipt designs | **Not audited in depth** | Open: section 7 |

## 3. What changed

All under `app/`:

- `lib/data/connectivity/write_fence.dart` (new). `WriteFence` counts acknowledged data writes. `readFenced` / `readAfterWrites` run a server read and run it again (up to 2 more times) if a write was acknowledged while it was in flight. If it still cannot be made certain it says so, and callers keep the phone's own copy.
- `lib/data/api_request_headers_client.dart`. The one wrapper every API call passes through marks the fence for every successful (2xx) write that is not on a short bookkeeping list (`/analytics`, `/sync/ack`, `/sync/register-device`, `/notification-devices`, `/sms/v2/client-metrics`, `/data-error-reports`, `/partner-clicks`, `/engagement`, `/acceptance-reports`, `/support-tickets`). A new endpoint is covered without anyone listing it.
- `lib/features/sync/sync_engine.dart`. After a push the engine now fetches only the edited transactions, one request each (4 at a time, at most 100 rows: `maxRowRefresh`), and stores them without ever removing a row. A row the server no longer has (404) is skipped. Above 100 edited rows it reads the list instead, as before, but through the fence and stamped with the real request time. In both cases, if the read cannot be made certain it throws, leaves the applied edits queued (they keep showing the edit) and tries on the next sync. Every other full read in this file (cards, overrides, self-transfer rules) goes through the fence too.
- `lib/data/local/sync_queue.dart`. `appliedEntityIds` and `purgeAppliedIds`, so only the rows that were refreshed lose their applied edit.
- Second pass (section 9): `lib/data/catalogue_v2.dart` and `lib/data/catalogue_repository.dart` (conditional catalogue refresh), `lib/app/design/refresh_views.dart`, `lib/app/providers.dart` and `lib/features/sync/sync_engine.dart` (no utilization-window read and no home-summary fetch for an SMS-v2 account).
- `lib/app/providers.dart`. The shared fetch-and-store for transaction lists, the card loaders, Home refresh (cards, overrides, home summary), `_warmDisplay` and `_backgroundDisplayRefresh` all use the fence. The spend and monthly reports no longer show a saved report older than the last acknowledged write. In-flight sharing no longer hands an older read to a reader who is asking because of a write.
- `lib/data/local/response_cache.dart`. `put(..., requestedAt:)` so the card replace uses the send time; `requestRefresh(key)`.
- `docs/PERFORMANCE_RULEBOOK.md`. One review-checklist line for the rule.

Tests (`app/test/`): `data/stale_read_race_test.dart` (new, 18 tests), `data/write_fence_test.dart` (new, 10), `data/api_request_headers_client_test.dart` (6 added), `data/sync_engine_queue_hygiene_test.dart` (one assertion changed: it now expects row fetches and no full list), and one existing test double updated for the new optional parameter. The file `stale_read_race_test.dart` also scans `lib/` and fails if any full-list save omits the request time.

Checks that the tests can actually fail: I turned off each fix in turn (card stamp, sync-engine stamp, sync-engine fence, `_warmDisplay` fence, in-flight sharing, the fence itself) and the matching tests went red each time.

## 4. Behaviour you will notice

- A transaction or card added by the outbox is no longer removed by a list that was in flight.
- An edit that has just been delivered stays at its new value.
- When writes keep arriving during a read (a long import), saved numbers stay as they are and refresh a few seconds later instead of being replaced by an older copy.
- Cost: when a read is dropped it is repeated, up to 2 more times. That is more traffic only when a write lands during a read; normally zero extra.

## 5. What I did not verify

- **Not run on the iPhone or any device.** I do not know that this exact path is what you hit. It is the strongest candidate and the test replays it, but another deleter I have not found could exist. I did read every other place that deletes local transactions and cards (`DELETE FROM financial_entities` and the card, command and sync queues); the others act on explicit user actions, explicit server deletes, or replace a queued copy with the delivered one.
- The 100-row cap before the edit read-back falls back to the list is a judgment call: each row costs 4.6 ms and 918 B (measured), so 100 rows is 460 ms of server time over 100 requests (4 at a time) against one list read of 313 ms at 40,000 rows, but about 90 KB instead of 31.7 MB. It follows the same bound the sync pull already uses for its per-row fetches.
- The fence lives in memory per isolate. After an app restart it starts empty, and writes made by the background SMS isolate are not seen by the foreground one (they only add rows).
- A write that times out on the phone but committed on the server is not seen by the fence until the outbox retries it. The row stays visible meanwhile (the outbox entry protects it).

## 6. What each API costs

"Cost" here means server time, database work, bytes on the wire, which admission lane it uses and how often the app calls it. It is not money.

### 6.1 How this was measured

- **Measured:** the repo's own benchmark (`api/scripts/bench_http.js`) against a scratch Postgres database built from the current migrations and the repo's synthetic seed: **one account with 40,000 transactions** (about 540 days). Local Mac, native Postgres, no network. Real phones add network time and TLS; real accounts are usually smaller; treat these as the application's own cost.
- **Static:** for all 181 non-admin routes, counts read from each route's handler source: SQL statements written inside the handler, loops, history-scan markers. A handler that delegates to a helper is under-counted (for example `POST /transactions` shows 2 statements inside the handler; the helper it calls, `insertTransactionAndUpdateState`, has about 11 more).
- **Correction (second pass):** my first run of the scratch database left its 5 synthetic card products as `draft`, which the row-level policy hides, so `/user-cards` returned no cards and looked far cheaper than it is. With the products published, `GET /user-cards` is **12.5 ms p50 / 14.2 ms p95** (3 cards), not 1.5 ms. The same fix let the write benchmark run (30 requests each): `POST /transactions` **19.5 ms p50 / 27.7 ms p95**, `POST /transactions/:id/ignore` 2.1 / 3.4 ms, `POST /transactions/:id/restore` 1.6 / 2.5 ms, `PATCH /transactions/:id/note` 0.4 / 0.6 ms, and `POST /sync/push` **3.2 ms for 1 change, 5.6 ms for 5, 22.6 ms for 20** (about 1.1 ms per change beyond the first). All other write routes are static counts only. The read table below is one consolidated run (25 requests per route), so it differs slightly from my first run (for example the 2-month window was 135 ms there and is 107 ms here).
- **Limits:** the scratch account has no budgets, so `/budgets` looks cheap here and costs more on a real account.

### 6.2 Measured reads (40,000-transaction account)

| Route (GET) | Payload | p50 ms | p95 ms | Note |
|---|---:|---:|---:|---|
| `/health` | 11 B | 0.3 | 0.6 | Liveness probe, never queued. |
| `/user-settings` | 45 B | 0.4 | 0.5 |  |
| `/notifications` | 36 B | 0.4 | 0.5 |  |
| `/lounge-usage` | 18 B | 0.5 | 0.6 |  |
| `/profile` | 417 B | 0.5 | 0.6 |  |
| `/self-transfer-rules` | 12 B | 0.6 | 0.7 |  |
| `/duplicate-candidates` | 26 B | 0.6 | 1.0 |  |
| `/categories` | 1.2 KB | 0.7 | 0.9 |  |
| `/card-overrides` | 16 B | 0.7 | 0.8 |  |
| `/transaction-tags` | 41 B | 0.7 | 0.8 |  |
| `/sync/pull (nothing new)` | 66 B | 0.9 | 1.0 | Runs on every sync cycle. |
| `/budgets` | 14 B | 0.9 | 1.0 | Empty here: a real account with budgets costs more. |
| `/transactions?pageSize=200` | 162.3 KB | 4.1 | 4.9 | What Activity loads (paged, newest first), about 830 B a row. |
| `/transactions/:id` | 918 B | 4.6 | 6.0 | The read-back of one edited row after a push, and of each row a pull names. Four correlated lookups per row, so about 4.6 ms each. |
| `/assistant/spending-summary` | 289 B | 9.1 | 10.1 |  |
| `/monthly-reports` | 502 B | 11.6 | 13.3 |  |
| `/user-cards` | 2.1 KB | 12.5 | 14.2 | Heavy lane. Takes an advisory lock and runs a cap reconcile and a reward credit sweep on every read. 3 cards here, so real accounts cost more. |
| `/home-summary` | 143 B | 16.9 | 17.9 | Aggregates over the whole history on every call. |
| `/spend-by-category` | 2.2 KB | 20.0 | 22.2 |  |
| `/account-summaries` | 15 B | 49.9 | 51.6 | Heavy lane. Legacy (non-v2) screens only. |
| `/recurring` | 32 B | 76.5 | 82.1 | Heavy lane; the handler also repairs and writes on a GET. |
| `/transactions?from=2026-09-01&to=2026-11-30` | 6.9 MB | 107 | 110 | The 2-month utilization window (about 4.4k rows). |
| `/export/transactions.csv` | 3.5 MB | 116 | 122 | Bulk lane (2 at a time). |
| `/spend-report?period=month` | 8.2 KB | 133 | 140 | Heavy lane. Legacy (non-v2) reports only. |
| `/spend-report?period=year` | 8.2 KB | 299 | 305 | Heavy lane. Legacy (non-v2) reports only. |
| `/transactions` | 31.7 MB | 313 | 317 | UNPAGED full history. The sync engine read this after every edit push. |
| `/catalogue?schema=2`, full answer | 268 KB gzipped (2.0 MB raw) | 51 | 63 | The real route and SQL on 202 real catalogue cards (no network variants or unlock rules, so a real catalogue is larger). It gzips itself. |
| `/catalogue?schema=2`, answer to a matching `If-None-Match` | 0 B (a 304) | 0.5 | 0.9 | What the app now gets while the catalogue is unchanged. |

Server lanes (`api/src/admission.js`): 20 requests at once in total, 200 waiting; a request that waits more than 8 s is answered `503` with `Retry-After` 5 to 60 s. Extra caps: 3 at once for `/sync/push`, 3 for the heavy reads (`/account-summaries`, `/spend-report`, `/monthly-reports`, `/recurring`, `/user-cards`), 2 for bulk (imports, exports, backups). One `/sync/push` at a time per account. There is **no ordering between a user's reads and writes**, which is the server half of section 1.

### 6.3 What one user action costs

| Action | Requests (from the code) | Heaviest part |
|---|---|---|
| Add a transaction (quick add) | `POST /transactions` (at least 13 SQL statements in one transaction), then after delivery: `GET /duplicate-candidates`, `GET /user-cards` when its snapshot is older than 15 s. **Before the second pass an SMS-v2 account also read the 2-month utilization window here (6.9 MB, 107 ms on the test account), once per save; it no longer does (section 9)** | `POST /transactions` itself (19.5 ms p50) |
| Edit merchant or note | `POST /sync/push`, then `GET /transactions/:id` for each edited row (**before this change: one unpaged `GET /transactions`, 31.7 MB, 313 ms at 40,000 rows**), then `GET /sync/pull`, `POST /sync/ack`, `GET /self-transfer-rules`, `GET /transaction-tags` | One small request per edited row: 4.6 ms and 918 B each |
| Edit amount, date, category, card | `PATCH /transactions/:id` through the command outbox (11 SQL statements, 6 writes in the handler) | The PATCH |
| Open or resume the app | Home refresh: `GET /user-cards`, `/catalogue` (now a conditional request: a 304 when unchanged), `/categories`, `/card-overrides`, `/home-summary` (not for SMS-v2 accounts any more), transactions page; plus a sync cycle, user-state pull, SMS v2 sync, split sync. The earlier traffic study estimated 12 to 20 requests on cold start (`docs/architecture/CLIENT_SERVER_TRAFFIC_ARCHITECTURE_2026-11-14.md`) | `/user-cards` (heavy lane, repairs on read) |

### 6.4 Highest static scores (all 181 routes are in the appendix)

| Method | Path | SQL | Writes | Loops | Scans | Ext | Lane | App call sites | Source |
|---|---|---:|---:|---:|---:|---:|---|---:|---|
| POST | `/transactions/category-bulk-apply` | 13 | 7 | 3 | 1 | 0 | bulk | 1 | index.js:5987 |
| PATCH | `/transactions/:id` | 11 | 6 | 0 | 4 | 0 | default | 4 | index.js:5461 |
| POST | `/duplicate-candidates/:id/resolve` | 10 | 5 | 1 | 1 | 0 | default | 1 | index.js:5291 |
| GET | `/recurring` | 10 | 1 | 2 | 0 | 0 | heavy | 1 | index.js:7046 |
| GET | `/transactions` | 1 | 0 | 0 | 8 | 0 | default | 4 | index.js:4942 |
| PUT | `/transactions/:id/splits` | 7 | 2 | 2 | 0 | 0 | default | 1 | transaction_splits.js:105 |
| GET | `/user-cards` | 7 | 0 | 2 | 2 | 0 | heavy | 6 | index.js:1873 |
| POST | `/card-discovery` | 3 | 0 | 4 | 0 | 0 | default | 1 | index.js:7432 |
| GET | `/transactions/:id` | 1 | 0 | 0 | 7 | 0 | default | 4 | index.js:5148 |
| GET | `/merchants/search` | 1 | 0 | 0 | 6 | 0 | default | 2 | index.js:1679 |
| GET | `/sms/rules/active` | 8 | 1 | 1 | 0 | 0 | default | 0 | sms_rule_bundle.js:203 |
| POST | `/user-cards/import` | 5 | 2 | 1 | 0 | 0 | bulk | 0 | index.js:2013 |
| GET | `/account-summaries` | 1 | 0 | 0 | 5 | 0 | heavy | 1 | index.js:4729 |
| GET | `/monthly-reports` | 6 | 1 | 1 | 0 | 0 | heavy | 3 | index.js:6496 |
| GET | `/foreign-payments` | 2 | 0 | 0 | 4 | 0 | default | 1 | foreign_payments_route.js:65 |
| GET | `/home-summary` | 4 | 0 | 0 | 3 | 0 | default | 1 | index.js:7676 |
| GET | `/transactions/:id/category-related-preview` | 4 | 2 | 0 | 1 | 0 | default | 1 | index.js:5847 |
| PUT | `/notification-preferences` | 2 | 2 | 1 | 0 | 0 | default | 2 | index.js:7960 |

### 6.5 Findings, most important first

1. **The unpaged `GET /transactions` is the most expensive read and it is on a hot path.** 31.7 MB and 313 ms at 40,000 rows (about 830 B per row), in the default lane, not the heavy one. The sync engine used to call it after every edit push; it now reads back only the edited rows and keeps the list only for a batch of more than 100. The filtered full-list path (utilization and reports with filters) still calls it with filters.
2. **The utilization window was re-read on every save** (and once after launch) (6.9 MB, 107 ms on this account) although accounts with SMS v2 data already read their reports from the phone's own copy. Fixed in the second pass (section 9).
3. **`GET /user-cards` and `GET /recurring` run repair writes on a read** (cap reconcile, reward credit sweep; true in the code I read today). They sit in the heavy lane (3 at a time), and the app reads `/user-cards` on each open or resume (Home refresh, at most once per 15 s). This is plan item 9 in the 14 Nov traffic study.
4. **`GET /spend-report?period=year`** is 334 ms p50 and about 1 s p95. It is only used on the legacy (non-v2) path.
5. **`/catalogue` supports `ETag`, and the 14 Nov traffic study found the app never sends `If-None-Match`** (finding 5; I did not re-check it today), so every open would pay the full body.
6. **`POST /transactions/category-bulk-apply`** (13 statements, 3 loops, bulk lane) and **`PATCH /transactions/:id`** (11 statements, 6 writes) are the heaviest user-triggered writes by static count.

## 7. Not done, and suggested next

1. Audit the surfaces in row 14 of section 2 with the same question: can a server answer replace or delete a local write that is not queued any more?
2. Persist the fence across restarts and observe the background isolate's writes if the audit finds a need.
3. `homeSummaryProvider` serves its saved value with no refresh of its own (only Home refresh updates it). Harmless in v2 mode, stale on the legacy path.
4. Fix the open item in 6.5 (3) on the server and client. Item 5 (conditional catalogue requests) is done: section 9.
5. The open items in 9.4 need an owner decision, not more engineering.

## 8. Reproduce

```bash
cd app
flutter test test/data/stale_read_race_test.dart test/data/write_fence_test.dart \
  test/data/api_request_headers_client_test.dart test/data/sync_engine_queue_hygiene_test.dart \
  test/data/local/financial_store_test.dart test/features/shared_expenses/data/shared_runtime_test.dart \
  test/data/catalogue_conditional_refresh_test.dart test/offline_e2e/request_budget_test.dart
```

Benchmark (scratch database only, never your dev data): build `pandapay_bench` from the migrations (`NODE_ENV=test DB_SSL=false`), insert a few synthetic card products, run `api/scripts/bench_seed.sql`, then `NODE_ENV=test BENCH_DATABASE_URL=postgres://app_user:...@127.0.0.1:5432/pandapay_bench node api/scripts/bench_http.js --n 30`. Note that the migration runner **rotates the password of an existing `rewards_worker_login` role** to the value you pass it.

## 9. Second pass: making the calls cheaper

Asked to apply the same thinking to other calls. The method was: measure what the real app asks for, find why, make the smallest change that removes the cause, and prove the data and queues are unchanged. Anything that could not be proven safe is in 9.4, not in the code.

### 9.1 What the measurements showed

**What the real app asks for.** `app/test/offline_e2e/` runs the real app stack against a request-logging fake server. For an SMS-v2 account:

| Step | Before | After |
|---|---|---|
| A save (quick add) reads the 2-month transaction window (`GET /transactions?from=`) | 1 per save, plus 1 at the first delivery or sync after the app starts | 0 |
| Opening the app asks for the server home summary (`GET /home-summary`, an aggregate over the whole history) | 1 per open or resume | 0 |
| Refreshing the catalogue when it has not changed | the whole catalogue downloaded, parsed and rewritten on every open or resume | one conditional request, answered 304 |

Totals from different measuring runs are not comparable, so only these specific deltas are quoted. The census also showed, on a first install only, two catalogue loads (the screen's load plus the refresh); with a saved catalogue only the refresh runs, so that is not changed. It also showed two category loads on every launch, but that is an artifact of the test server (see 10.2).

**Why the window read happened.** `refreshViews` re-reads every list a save touches, and the list of utilization rows was one of them, so every save read it. For an SMS-v2 account nothing shows that list (`cardSpendSummaryProvider` and `creditUtilizationProvider` both return from the phone's ledger before they would watch it); only the split planner reads it. A second path: **`Ref.invalidate` called from inside another provider builds a provider nobody has read yet, immediately** (tested on this Riverpod version: `container.invalidate` of a never-read provider builds nothing, `Ref.invalidate` from inside a provider builds it, but only that first time; once built it only marks the provider stale). The outbox flush and the sync engine both invalidate it that way, so the first delivery or sync after the app starts read two months of rows from disk and started a server read for them, even before any save.

**Where the server spends time on the big list.** `EXPLAIN ANALYZE` of the exact `GET /transactions` SQL, as the API's own role, on 40,000 transactions: 178 ms in the database, of which about 155 ms is four correlated lookups per row into `transaction_observations` (421,585 buffer reads). Most of the rest of the 313 ms request is serialising 31.7 MB. (These EXPLAIN figures are from my first scratch database; the route itself measured 312 to 336 ms across runs.)

### 9.2 What changed (client only, no server change)

1. **Conditional catalogue refresh.** The server already answers a matching `If-None-Match` with a 304 before any heavy query (its own tests confirm it). The app never asked. Now `CatalogueLoader.refreshCache` sends the stored `ETag` and, on a 304, does nothing: no download, no parse, no large write.
   - The validator is stored under its own key (`catalogue.v2.etag`) **after** the body, and is only sent while the cached body is still there and is a v2 body. A crash between the two writes leaves a validator the server does not recognise, so the answer is the whole body, never a stale copy. A 304 is only accepted for a validator that was sent.
   - An older server (v1 body for `?schema=2`) clears the body and the validator together. A transient failure keeps both. A response with no `ETag` removes the old validator. Header names are matched case-insensitively, because only the `dart:io` client lowercases them.
   - Done through a new optional interface (`ConditionalV2CatalogueSource`), so existing fakes that implement only `fetchV2()` compile and behave as before.
   - Files: `lib/data/catalogue_v2.dart`, `lib/data/catalogue_repository.dart`.
2. **No utilization-window read for an SMS-v2 account on a save, nor at the first delivery or sync after launch.** `refreshViews` skips reading it; the three provider-internal invalidation sites (outbox flush, sync engine, `invalidateTransactionViews`) go through one helper, `invalidateUtilizationTransactions`, that does nothing for a v2 account. The split planner still reads it on demand, local rows first, and refreshes itself whenever the transaction store changes. Widget and container invalidations (the other 15 sites) are lazy and untouched. An unknown state (the ledger has not loaded) counts as not v2, so the behaviour is exactly as before.
   - Files: `lib/app/design/refresh_views.dart`, `lib/app/providers.dart`, `lib/features/sync/sync_engine.dart`.
3. **No `GET /home-summary` on open or resume for an SMS-v2 account.** Its only readers are behind the v2 branch (`homeSummaryProvider` returns from the ledger first; the legacy monthly-report fallback is behind the same branch).
   - File: `lib/app/providers.dart`.

### 9.3 Proof that the data and the queues are unchanged

- **Catalogue, against the real server.** The real handler (`api/src/catalogue_route.js`, its real SQL) on the scratch database, driven by the real Dart repository and loader over a real socket with gzip: 200 stored the body and the `ETag`; the second refresh got a 304 with **no body write** and the same cards; changing a card in the database gave a new `ETag`, a rewritten body containing the change; the fourth refresh was a 304 again; and the cached feed matched the database card for card.
- **Catalogue, unit.** `test/data/catalogue_conditional_refresh_test.dart` (18 tests): first fetch, unchanged, changed, never a validator without its body or for a non-v2 body, unreadable store, missing `ETag`, validator that cannot be saved, older server, failed request, `load()` seeds the validator, plain `fetchV2` sources untouched, and the HTTP layer (header sent, 304, `ETag` read in any case, empty validator never sent, other statuses throw). Turning off the body check, the validator write, or the older-server clear each made the matching tests fail.
- **Requests, on the real stack.** `test/offline_e2e/request_budget_test.dart` (6 tests): a v2 save makes no window read and a legacy save still does; **the add is delivered exactly once, the server has it, every queue drains, and the phone shows one row, in both modes**; the utilization list is still available on demand with the saved row in it, read once; a v2 open makes no home-summary request while the rest of the refresh is untouched, and a legacy open still makes one. Reverting each of the three changes made the matching test fail.
- **Pipelines and queues.** All offline end-to-end scenarios (`test/offline_e2e`, `test/offline`, the sync-engine hygiene tests, the stale-read tests) pass: 216 tests across the touched areas. The full app suite after every change in this report: **5,656 passed, 11 skipped, 0 failed**.

### 9.4 Evaluated and deliberately not changed

| Candidate | What I measured | Why it is not in the code |
|---|---|---|
| Rewrite the four per-row lookups of `GET /transactions` as one lateral lookup | Database time 178 ms to 125 ms (−30%), buffer reads 421,585 to 121,585 (−71%); about −50 ms of the 313 ms request | When two observations of one transaction share an `observed_at` (two rows inserted in one database transaction get the same `now()`), "the latest one" is arbitrary today and would be arbitrary in a different way after. That can flip a displayed account or card number. For this app that risk outweighs a 17% gain on a route SMS-v2 accounts now rarely hit. It needs a tie-break chosen by the owner (for example `observed_at DESC, id DESC`) and a row-by-row differential test. The prototype SQL and its timing harness are not in the repo. |
| Make `GET /user-cards` cheaper (12.5 ms, heavy lane) | It takes an advisory lock and rebuilds cap states and credits rewards on every read | That is reward-accuracy logic interleaved with transaction ingestion. Calling it less is the safe lever, and Home refresh already limits it to once per 15 s. |
| Speed up `POST /transactions` (19.5 ms p50, at least 13 statements) | Measured | Financial state updates; a speed gain is not worth any risk to reward or cap numbers. |
| Fetch `/self-transfer-rules` and `/transaction-tags` less often | Each sync cycle makes 3 requests (pull, rules, tags) even when nothing changed; each is 0.5 to 0.8 ms on the server | The team's own traffic design (D2) already decides this (once per N minutes unless a change is known). It changes cross-device freshness and the tag sync also uploads queued changes, so it needs that design, not a quick edit. |
| Per-request authentication overhead | Already cached (5 s session, 10 s membership) in `api/src/auth.js` | Nothing to do. |
| Compress the 31.7 MB list | `deploy/nginx/api.conf.example` has gzip on for JSON; the production configuration was not checked | Deployment, not code, and not verifiable from here. |
| A batch endpoint for per-row reads | After a push or a pull the app reads edited or changed rows one request each (4 at a time, at most 100) | Needs a server route plus a fallback for the period before it is deployed. Usually 1 to 3 rows. |

### 9.5 Not verified

- The catalogue figures are from 202 real catalogue cards copied from the dev database into the scratch one (their network variants, unlock rules and cap targets were not available there, and 37 cards had a placeholder network so they could be published). A production catalogue has more cards and more detail per card, so its answer is larger than the 268 KB gzipped / 51 ms measured here; the 304 stays about 0.5 ms.
- The byte savings per save depend on account size (6.9 MB was the 2-month window of the 40,000-transaction test account); they are zero for a small account.
- Nothing was run on a device. UI-isolate time was not measured.

### 9.6 Corrections to earlier versions of this report

1. **How often the 2-month read ran.** I wrote that it ran "on every save, every delivery and every sync that touched transactions". That was wrong. Tested later on this Riverpod version: `Ref.invalidate` builds a provider only the first time it is invalidated before anyone has read it; once built, it only marks it stale. So the read ran **once per save** (the explicit read in `refreshViews`) and **once at the first delivery or sync after the app starts**. Both are removed for an SMS-v2 account; the fix is unchanged.
2. **`GET /user-cards`** is 12.5 ms p50 (14.2 ms p95) with real cards visible, not the 1.5 ms of my first run.
3. **The catalogue size** I extrapolated (about 190 KB gzipped, 65 ms) was too low. Measured on 202 real catalogue cards through the real route: **268 KB gzipped (2.0 MB raw), 51 ms**, against a 304 at 0.5 ms. Production has more cards (and the network variants and unlock rules my copy lacks), so it is larger still.
4. **The per-row read-back** was listed as not benchmarked. It is **4.6 ms and 918 B per row**. At the 100-row cap that is 460 ms of server time spread over 100 requests, more than one list read at 40,000 rows (313 ms), but about 90 KB instead of 31.7 MB. The cap is still a judgment call; edits are normally 1 to 3 rows.

## 10. After the changes: the same tables, with times

### 10.1 What changed and what did not

**No server file was changed**, so what one call costs the server is identical to section 6.2 (that table now carries the numbers of one consolidated run). What changed is **which calls the app makes and how many bytes come back**. This table lists only the calls whose frequency changed; every other call costs the same and is made as often as before.

| Call | Cost of one call (unchanged) | Calls per action, before → after |
|---|---|---|
| `GET /transactions` (unpaged full list) | 31.7 MB, p50 313 ms, p95 317 ms | After an edit push: **1 → 0** (now only for a batch of more than 100 edited rows) |
| `GET /transactions/:id` | 918 B, p50 4.6 ms, p95 6.0 ms | After an edit push: **0 → 1 per edited row** (at most 100) |
| `GET /transactions?from=` (2-month window) | 6.9 MB, p50 107 ms, p95 110 ms | Per save, SMS-v2 account: **1 → 0**, and once after launch: **1 → 0**. Legacy accounts: unchanged |
| `GET /home-summary` | 143 B, p50 16.9 ms, p95 17.9 ms | Per open or resume, SMS-v2 account: **1 → 0**. Legacy accounts: unchanged |
| `GET /catalogue?schema=2` | Full answer: 268 KB gzipped, p50 51 ms, p95 63 ms. Answer to `If-None-Match`: a 304, 0 B, p50 0.5 ms, p95 0.9 ms | Per open or resume: **full answer → 304** while the catalogue is unchanged |
| Not changed, for scale | `POST /transactions` p50 19.5 ms, p95 27.7 ms; `POST /sync/push` 3.2 ms for one change; `GET /sync/pull` 0.9 ms; `GET /user-cards` 12.5 ms, p95 14.2 ms | one per save; one per sync; one per sync; one per open |

### 10.2 What each action costs now

SMS-v2 account, on the 40,000-transaction test account. Sizes use 1,048,576 bytes to the MB, as everywhere in this report.

| Action | Requests | Server time (per-call times added up) | Downloaded | Finished in, 4G-like network | Finished in, weak network |
|---|---:|---:|---:|---:|---:|
| **Save a transaction** (until the network is quiet again) | 4 → 3 | 127 ms → 21 ms | 6.9 MB → 1.2 KB | 3.1 s → 0.24 s | 11.9 s → 0.48 s |
| **Edit a merchant name** (until the server's copy is confirmed) | 5 → 5 | 318 ms → 10 ms | 31.7 MB → 1.4 KB | 14.0 s → 0.46 s | **did not complete** → 1.1 s |
| **Open or resume the app** (second launch, saved data present) | 11 → 10 | 89 ms → 22 ms | 435 KB → 167 KB | refreshed in 0.30 s → 0.29 s | 0.73 s → 0.66 s |

- **4G-like** is 80 ms round trip and 20 Mbps; **weak** is 200 ms and 5 Mbps.
- **A save never made the screen wait on these reads**, before or after: the Save spinner lasted about 30 ms in every run (13 ms for a legacy account), because the lists answer from the phone's own rows and refresh behind the scenes. (The exception is an account with no saved rows at all in the window, where the first read waits for the server, up to the 2 s cap in `refreshViews`.) What the old version did was keep the network and the server busy for 3 to 12 seconds afterwards, which slows whatever else is waiting for the same connection and the same server; that contention is not in the simulation.
- **The old edit on a weak network could not finish.** The 31.7 MB list needs about 53 s at 5 Mbps and the app stops a request at 30 s overall (`AuthenticatedHttpTimeoutPolicy.standard`), so it fails; below about 9 Mbps it cannot finish uncompressed at all. Because the edit stays unconfirmed, the next sync tries the same read again. (In the simulation the failure shows at 15 s, the header limit, because the delay is applied before the response; the real cap is the 30 s overall limit.)
- **Opening the app is mostly unchanged in time**, because its requests run in parallel and the catalogue is not the slowest. What it saves is server work (−76%) and data (−62%) on every open and resume.
- The open count includes one `GET /categories` more than production makes (the test server's category list has no `emi` entry, which the app's cache check requires, so it re-fetches); the difference between before and after is unaffected.
- A `GET /user-state` (about 1 ms) sometimes appears after a save in both versions, depending on timing.

**Legacy accounts** (no SMS v2 data) change less: a save is unchanged (it still reads the window, 3.1 s / 11.9 s of network, because its screens show that list), an edit gets the same improvement (14.0 s → 0.45 s on 4G-like, did not complete → 1.0 s on weak), and an open keeps its 12 requests but drops from 139 ms to 89 ms of server time and from 435 KB to 167 KB.

### 10.3 In a day

A heavy day on the 40,000-transaction account (10 saves, 3 edits, 8 opens): about **166 MB less downloaded** (69 MB from saves, 95 MB from edits, 2 MB from opens) and about **2.5 s less server time** for that one account. This is an illustration: the mix is my assumption, this is the largest account I tested, and a small account saves almost nothing on saves and edits.

### 10.4 How these numbers were produced, and what they are not

- **Request counts** come from running the real app stack against a request-logging fake server (`app/test/offline_e2e`), with the same procedure on the committed code (`HEAD`) and on the current working tree, so the only difference is my changes.
- **Server times and sizes** are the per-route numbers measured in section 6.2 on a scratch Postgres with 40,000 synthetic transactions, and the real catalogue route on 202 real catalogue cards. They are from one laptop, with no network, TLS or authentication service in between.
- **Times on a phone** are a **simulation, not a phone measurement**. Each request is delayed by round trip + its measured server time + its bytes divided by the throughput, and the real app code decides what runs in parallel. Requests are modelled independently (no shared-bandwidth contention), so parallel large downloads come out optimistic.
- **Bytes are uncompressed.** The full transaction list compresses 16.6 times on this synthetic data (33.4 MB to 2.0 MB at gzip level 6); real data compresses less. If the production proxy compresses (the example nginx configuration does; I did not check production), the transfer part of the old edit would be much smaller and the gap in time smaller than shown, while the server time (313 ms), the phone's parsing of 33 MB of JSON (not measured) and the byte counts without compression are unchanged.
- The measuring test and its latency patch were kept out of the repository (scratch copies of the code were used). The numbers can be reproduced by re-running a request census like `test/offline_e2e/request_budget_test.dart` with delays added.

## Appendix: every non-admin route

Counts are static (see 6.1). Lane: `default`, `heavy`, `bulk`, `push` or `probe` as `admission.js` classifies it. SQL = `.query(` calls written in the handler. Writes = INSERT, UPDATE or DELETE statements written in the handler. Scans = history-scan markers (`GROUP BY`, `COUNT(`, observations joins, `ILIKE`, and similar). Ext = outbound network or mail calls. Tier is a rough ranking: High = measured 50 ms or more, a heavy, bulk or push lane, or several scans with many statements; Medium = 6+ statements, 2+ loops, 2+ scans or 3+ writes; Low = the rest. `*` = measured on an empty seed, so understated. "App call sites" is a string search of `app/lib`; `—` means none found (webhooks, internal routes, admin tools, or URLs the search cannot see). Of 181 routes: 15 High, 10 Medium, 156 Low; 30 have no app call site found. 68 admin routes are not listed.

#### `/${RESTORE_BASE_PATH}`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| DELETE | `${RESTORE_BASE_PATH}/:id` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `${RESTORE_BASE_PATH}/:id/commit` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `${RESTORE_BASE_PATH}/:id/preview` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| PUT | `${RESTORE_BASE_PATH}/:id/sections/:section` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `${RESTORE_BASE_PATH}/:id/status` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/.well-known`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/.well-known/assetlinks.json` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/acceptance-reports`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/acceptance-reports` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: acceptance_reports_repository.dart, write_fence.dart |

#### `/access`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/access` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: product_access_api.dart |

#### `/access-policy`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/access-policy` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: product_access_api.dart |

#### `/account`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/account/data-reset` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: account_api.dart |
| DELETE | `/account/delete-request` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: account_api.dart |
| POST | `/account/delete-request` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: account_api.dart |
| POST | `/account/erase` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: account_api.dart |

#### `/account-summaries`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/account-summaries` | heavy | 1 | 0 | 0 | 5 | 0 | High | 50 | 1: user_cards_repository.dart |

#### `/analytics`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/analytics/events` | default | 1 | 0 | 0 | 1 | 0 | Low |  | 1: analytics.dart |

#### `/app-status`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/app-status` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: app_status_repository.dart, reachability.dart |

#### `/assistant`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/assistant/spending-summary` | default | 1 | 0 | 0 | 1 | 0 | Low | 9.1 | — |

#### `/avatars`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/avatars/:profileId` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: member_avatar_api.dart, avatar_presets.dart |
| GET | `/avatars/:profileId/photo` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/avatars/:profileId/profile-name` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/backup-runs`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/backup-runs` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/backup-status`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/backup-status` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |

#### `/bills`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/bills/projections` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: bills_projection_api.dart |

#### `/budgets`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/budgets` | default | 1 | 0 | 1 | 0 | 0 | Low | 0.9* | 3: providers.dart, router.dart … |
| POST | `/budgets` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: providers.dart, router.dart … |
| DELETE | `/budgets/:id` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: spend_reports_repository.dart |

#### `/card-discovery`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/card-discovery` | default | 3 | 0 | 4 | 0 | 0 | Medium |  | 1: user_cards_repository.dart |

#### `/card-overrides`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/card-overrides` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.7 | 2: card_overrides_repository.dart, manual_overrides_screen.dart |
| POST | `/card-overrides` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: card_overrides_repository.dart, manual_overrides_screen.dart |
| DELETE | `/card-overrides/:id` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: card_overrides_repository.dart |
| PATCH | `/card-overrides/:id` | default | 2 | 1 | 0 | 0 | 0 | Low |  | 1: card_overrides_repository.dart |

#### `/card-requests`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/card-requests` | default | 3 | 2 | 0 | 0 | 0 | Low |  | 3: card_feedback_repository.dart, card_requests_api.dart … |

#### `/catalogue`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/catalogue` | default | 1 | 0 | 0 | 0 | 0 | High | 51 (202 real cards) / 0.5 (304) | 6: catalogue_repository.dart, catalogue_v2.dart … |

#### `/categories`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/categories` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.7 | 2: providers.dart, catalogue_repository.dart |

#### `/changelog`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/changelog` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: changelog_repository.dart |

#### `/consents`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/consents` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: consents_api.dart, product_access_api.dart |
| POST | `/consents` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: consents_api.dart, product_access_api.dart |
| GET | `/consents/history` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: consents_api.dart |

#### `/data-error-reports`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/data-error-reports` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: card_feedback_repository.dart, write_fence.dart |

#### `/duplicate-candidates`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/duplicate-candidates` | default | 2 | 0 | 1 | 0 | 0 | Low | 0.6 | 1: user_cards_repository.dart |
| POST | `/duplicate-candidates/:id/resolve` | default | 10 | 5 | 1 | 1 | 0 | Medium |  | 1: user_cards_repository.dart |

#### `/engagement`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/engagement/check-in` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |

#### `/export`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/export` | bulk | 3 | 0 | 0 | 0 | 0 | High |  | 2: authenticated_http_client.dart, import_repository.dart |
| GET | `/export/transactions.csv` | bulk | 1 | 0 | 0 | 0 | 0 | High | 116 | 1: spend_reports_repository.dart |

#### `/foreign-payments`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/foreign-payments` | default | 2 | 0 | 0 | 4 | 0 | Medium |  | 1: foreign_payments_repository.dart |
| POST | `/foreign-payments` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: foreign_payments_repository.dart |
| PATCH | `/foreign-payments/:id` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: foreign_payments_repository.dart |
| POST | `/foreign-payments/:id/confirm` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/foreign-payments/:id/reconcile` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/foreign-payments/refresh` | default | 2 | 1 | 1 | 0 | 0 | Low |  | 1: foreign_payments_repository.dart |

#### `/forwarding-addresses`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/forwarding-addresses` | default | 2 | 1 | 1 | 0 | 0 | Low |  | 1: import_repository.dart |
| GET | `/forwarding-addresses/me` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| GET | `/forwarding-addresses/verification` | default | 1 | 0 | 1 | 0 | 0 | Low |  | 1: import_repository.dart |

#### `/health`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/health` | probe | 0 | 0 | 0 | 0 | 0 | Low | 0.3 | — |

#### `/home-summary`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/home-summary` | default | 4 | 0 | 0 | 3 | 0 | Medium | 17 | 1: user_cards_repository.dart |

#### `/i`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/i/:code` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: router.dart, invite_friends_screen.dart … |

#### `/imap-connections`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/imap-connections` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: import_repository.dart, imap_connection_screen.dart |
| DELETE | `/imap-connections/:id` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| POST | `/imap-connections/:id/test` | default | 1 | 1 | 0 | 0 | 1 | Low |  | 2: import_repository.dart, imap_connection_screen.dart |
| GET | `/imap-connections/bank-senders` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/imap-connections/me` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |

#### `/inbound-emails`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/inbound-emails/:id/create-transaction` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| GET | `/inbound-emails/me` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| POST | `/inbound-emails/webhook` | default | 4 | 2 | 0 | 0 | 0 | Low |  | 1: providers.dart |

#### `/internal`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/internal/recovery/card-fact` | default | 1 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/internal/referral-outbox-event` | default | 3 | 1 | 0 | 0 | 0 | Low |  | — |

#### `/invitations`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/invitations/validate` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: product_access_api.dart |

#### `/issuer-emergency-contacts`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/issuer-emergency-contacts` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: providers.dart, emergency_contacts_repository.dart |

#### `/lounge-usage`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/lounge-usage` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.5 | 2: user_cards_repository.dart, lounge_access_screen.dart |
| POST | `/lounge-usage` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: user_cards_repository.dart, lounge_access_screen.dart |

#### `/merchant-category-rules`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/merchant-category-rules` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 4: app_database.dart, sms_learning_feedback.dart … |
| POST | `/merchant-category-rules` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 4: app_database.dart, sms_learning_feedback.dart … |
| DELETE | `/merchant-category-rules/:id` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 2: merchant_category_rules_repository.dart, merchant_issue_rules_repository.dart |
| PATCH | `/merchant-category-rules/:id` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 2: merchant_category_rules_repository.dart, merchant_issue_rules_repository.dart |
| POST | `/merchant-category-rules/preview` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: merchant_category_rules_repository.dart, merchant_issue_rules_repository.dart |

#### `/merchants`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/merchants/nearby` | default | 1 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/merchants/nearby/discover` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: nearby_merchants_repository.dart |
| POST | `/merchants/nearby/discover` | default | 1 | 0 | 0 | 1 | 0 | Low |  | 1: nearby_merchants_repository.dart |
| POST | `/merchants/nearby/google` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/merchants/nearby/search` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/merchants/nearby/search` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/merchants/resolve` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: merchant_search_repository.dart |
| GET | `/merchants/search` | default | 1 | 0 | 0 | 6 | 0 | Medium |  | 2: merchant_search_repository.dart, quick_add_screen.dart |

#### `/monthly-reports`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/monthly-reports` | heavy | 6 | 1 | 1 | 0 | 0 | High | 12 | 3: providers.dart, user_cards_repository.dart … |

#### `/my-contributions`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/my-contributions` | default | 1 | 0 | 0 | 2 | 0 | Medium |  | 3: router.dart, user_cards_repository.dart … |

#### `/notification-devices`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| DELETE | `/notification-devices` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: server_backoff.dart, write_fence.dart … |
| POST | `/notification-devices` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: server_backoff.dart, write_fence.dart … |

#### `/notification-preferences`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/notification-preferences` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: notification_preferences_repository.dart, notification_settings_screen.dart |
| PUT | `/notification-preferences` | default | 2 | 2 | 1 | 0 | 0 | Low |  | 2: notification_preferences_repository.dart, notification_settings_screen.dart |
| GET | `/notification-preferences/muted-merchants` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: notification_preferences_repository.dart |
| POST | `/notification-preferences/muted-merchants` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: notification_preferences_repository.dart |
| DELETE | `/notification-preferences/muted-merchants/:merchantId` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: notification_preferences_repository.dart |

#### `/notifications`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/notifications` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.4 | 3: providers.dart, user_cards_repository.dart … |
| POST | `/notifications` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: providers.dart, user_cards_repository.dart … |
| POST | `/notifications/read` | default | 2 | 2 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| POST | `/notifications/test` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: notification_devices_api.dart |

#### `/onboarding`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/onboarding/complete` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: product_access_api.dart |

#### `/partner-clicks`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/partner-clicks` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: write_fence.dart, partner_apply_repository.dart |

#### `/partner-conversions`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/partner-conversions/webhook` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/profile`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/profile` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.5 | 6: account_name_api.dart, auth_api.dart … |
| PATCH | `/profile` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 6: account_name_api.dart, auth_api.dart … |
| POST | `/profile` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 6: account_name_api.dart, auth_api.dart … |
| POST | `/profile/contributions-opt-in` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |

#### `/ready`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/ready` | probe | 1 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/recurring`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/recurring` | heavy | 10 | 1 | 2 | 0 | 0 | High | 77 | 1: spend_reports_repository.dart |
| POST | `/recurring` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: spend_reports_repository.dart |
| PATCH | `/recurring/:id` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: spend_reports_repository.dart |
| POST | `/recurring/:id/dismiss` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: spend_reports_repository.dart |

#### `/referrals`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/referrals` | default | 3 | 0 | 0 | 0 | 0 | Low |  | 2: referral_repository.dart, user_cards_repository.dart |
| POST | `/referrals/code` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: referral_repository.dart |
| GET | `/referrals/mine` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: referral_repository.dart |
| GET | `/referrals/v2` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: referral_repository.dart |

#### `/rewards`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/rewards` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 3: router.dart, referral_repository.dart … |
| POST | `/rewards/:entitlementId/spin` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 1: referral_repository.dart |
| GET | `/rewards/:entitlementId/spin-config` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: referral_repository.dart |

#### `/self-transfer-rules`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/self-transfer-rules` | default | 2 | 0 | 0 | 0 | 0 | Low | 0.6 | 1: sync_api.dart |

#### `/shared-expenses`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/shared-expenses/capabilities` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| POST | `/shared-expenses/commands` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| GET | `/shared-expenses/contexts/:contextId/invitations` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| GET | `/shared-expenses/directory` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| GET | `/shared-expenses/groups/:contextId/link` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| GET | `/shared-expenses/invitations/inbox` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| GET | `/shared-expenses/invitations/requests` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 1: shared_http_transport.dart |
| POST | `/shared-expenses/sources/admit` | default | 1 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/shared-expenses/sources/inspect` | default | 1 | 0 | 0 | 0 | 0 | Low |  | — |

#### `/sms`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/sms/rules/active` | default | 8 | 1 | 1 | 0 | 0 | Medium |  | — |
| POST | `/sms/v2/categories\\:batch` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| POST | `/sms/v2/client-metrics` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: write_fence.dart, client_metrics.dart |
| POST | `/sms/v2/corrections` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: corrections_sync.dart |
| POST | `/sms/v2/learning-signals` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: learning_signals.dart |
| POST | `/sms/v2/rule-stats\\:batch` | default | 0 | 0 | 0 | 0 | 0 | Low |  | — |
| GET | `/sms/v2/rules` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: sms_v2_runtime.dart |
| GET | `/sms/v2/sync` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: sync_pull.dart |

#### `/sms-import-batches`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/sms-import-batches` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| POST | `/sms-import-batches` | bulk | 0 | 0 | 0 | 0 | 0 | High |  | 1: import_repository.dart |

#### `/spend-by-category`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/spend-by-category` | default | 1 | 0 | 0 | 2 | 0 | Medium | 20 | 1: spend_by_category_repository.dart |

#### `/spend-report`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/spend-report` | heavy | 0 | 0 | 0 | 0 | 0 | High | 133 (month) / 299 (year) | 1: spend_reports_repository.dart |

#### `/split`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/split/join/:token` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 4: router.dart, shared_invitations.dart … |

#### `/statement-imports`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/statement-imports` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: import_repository.dart |
| POST | `/statement-imports` | bulk | 0 | 0 | 0 | 0 | 0 | High |  | 1: import_repository.dart |

#### `/subscription-credits`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/subscription-credits` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: subscription_credits_repository.dart |
| GET | `/subscription-credits/ledger` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: subscription_credits_repository.dart |

#### `/support-tickets`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/support-tickets` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 2: write_fence.dart, support_api.dart |

#### `/sync`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| POST | `/sync/ack` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: write_fence.dart, sync_api.dart |
| POST | `/sync/conflicts/:id/acknowledge` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: sync_api.dart |
| GET | `/sync/pull` | default | 2 | 0 | 0 | 0 | 0 | Low | 0.9 | 1: sync_api.dart |
| POST | `/sync/push` | push | 0 | 0 | 1 | 0 | 0 | High |  | 1: sync_api.dart |
| POST | `/sync/register-device` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 2: write_fence.dart, sync_api.dart |

#### `/transaction-tags`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/transaction-tags` | default | 4 | 0 | 0 | 0 | 0 | Low | 0.7 | 1: transaction_tags_repository.dart |
| POST | `/transaction-tags/changes` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: transaction_tags_repository.dart |

#### `/transactions`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/transactions` | default | 1 | 0 | 0 | 8 | 0 | High | 4.1 (paged) / 313 (unpaged) | 4: app_database.dart, user_cards_repository.dart … |
| POST | `/transactions` | default | 2 | 1 | 0 | 0 | 0 | Low |  | 4: app_database.dart, user_cards_repository.dart … |
| GET | `/transactions/:id` | default | 1 | 0 | 0 | 7 | 0 | Medium | 4.6 | 4: foreign_payments_repository.dart, user_cards_repository.dart … |
| PATCH | `/transactions/:id` | default | 11 | 6 | 0 | 4 | 0 | High |  | 4: foreign_payments_repository.dart, user_cards_repository.dart … |
| GET | `/transactions/:id/category-related-preview` | default | 4 | 2 | 0 | 1 | 0 | Low |  | 1: user_cards_repository.dart |
| POST | `/transactions/:id/ignore` | default | 3 | 1 | 0 | 0 | 0 | Low |  | 2: user_cards_repository.dart, quick_add_screen.dart |
| PATCH | `/transactions/:id/note` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 2: user_cards_repository.dart, transaction_detail_screen.dart |
| POST | `/transactions/:id/restore` | default | 3 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| PUT | `/transactions/:id/spend-exclusion` | default | 2 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| GET | `/transactions/:id/splits` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| PUT | `/transactions/:id/splits` | default | 7 | 2 | 2 | 0 | 0 | Medium |  | 1: user_cards_repository.dart |
| GET | `/transactions/amount-audit` | default | 1 | 0 | 1 | 1 | 0 | Low |  | 1: foreign_payments_repository.dart |
| POST | `/transactions/amount-audit/repair` | default | 2 | 1 | 1 | 0 | 0 | Low |  | 1: foreign_payments_repository.dart |
| POST | `/transactions/autopay-bill-correction` | default | 2 | 1 | 0 | 1 | 0 | Low |  | — |
| POST | `/transactions/category-bulk-apply` | bulk | 13 | 7 | 3 | 1 | 0 | High |  | 1: user_cards_repository.dart |

#### `/user-cards`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/user-cards` | heavy | 7 | 0 | 2 | 2 | 0 | High | 12.5 | 6: user_cards_repository.dart, edit_card_screen.dart … |
| POST | `/user-cards` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 6: user_cards_repository.dart, edit_card_screen.dart … |
| PATCH | `/user-cards/:id` | default | 1 | 1 | 1 | 0 | 0 | Low |  | 4: local_first_cards.dart, local_user_cards_repository.dart … |
| POST | `/user-cards/:id/archive` | default | 1 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| POST | `/user-cards/:id/default` | default | 3 | 2 | 0 | 0 | 0 | Low |  | — |
| POST | `/user-cards/:id/points-adjustment` | default | 3 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| GET | `/user-cards/:id/points-ledger` | default | 2 | 0 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| POST | `/user-cards/:id/unarchive` | default | 3 | 1 | 0 | 0 | 0 | Low |  | 1: user_cards_repository.dart |
| POST | `/user-cards/import` | bulk | 5 | 2 | 1 | 0 | 0 | High |  | — |
| POST | `/user-cards/reorder` | default | 1 | 1 | 1 | 0 | 0 | Low |  | 1: user_cards_repository.dart |

#### `/user-categories`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/user-categories` | default | 1 | 0 | 0 | 0 | 0 | Low |  | 1: sync_api.dart |

#### `/user-settings`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/user-settings` | default | 1 | 0 | 0 | 0 | 0 | Low | 0.4 | 1: user_settings_api.dart |
| PUT | `/user-settings` | default | 2 | 2 | 0 | 0 | 0 | Low |  | 1: user_settings_api.dart |

#### `/user-state`

| Method | Path | Lane | SQL | Writes | Loops | Scans | Ext | Tier | Measured p50 ms | App call sites |
|---|---|---|---:|---:|---:|---:|---:|---|---|---|
| GET | `/user-state` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: user_state_sync.dart |
| DELETE | `/user-state/:kind/:key` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: user_state_sync.dart |
| PUT | `/user-state/:kind/:key` | default | 0 | 0 | 0 | 0 | 0 | Low |  | 1: user_state_sync.dart |
