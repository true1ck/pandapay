# iPhone live SMS, "Importing your history" and "Can't reach PandaPay" — investigation, 20 Nov 2026

**Status: F1–F4 implemented the same evening in the working tree (uncommitted, not built, not deployed); F5–F8 not started. See section 7.** The investigation itself changed no code. Evidence came from the owner's iPhone (build 192), the Mac's `chat.db`, the production API logs, nginx logs and a read-only SQL look at the production database. No message text or account id is kept in this file.

## 1. What happened (all times IST, 20 Nov)

| Time | Event |
|---|---|
| 19:03:35 | SBI Card SMS: Rs 215.45 spent at CTRLXTECHNOLOGIESPRIV (Ownly). The live shortcut put it in the phone's native spool. The app was closed. |
| 19:22 | Production API and auth containers restarted by a deploy (earlier restarts 17:30–18:30 gave 502/503). |
| 19:51:15 | PhonePe SMS: CTRLX TECHNOLOGIES **requested** Rs 215.45 (a payment request, not a debit). Live shortcut fired, spool `last_live_at` = 19:51:15, capture outcome `captured`. |
| 19:51:37 | App opened. About 50 API calls in 15 s, each 0.6–15 s. The probe to `/app-status` was aborted by the phone (nginx 499). |
| 19:51:40 | Server created the facts for both messages (SBI = `movement`, PhonePe = `attempt`). The batch upload was then aborted (499), failed once (500, Postgres 57014 after 15.2 s) and succeeded at 19:53 (18.8 s and 6.0 s). |
| 19:52 | Spending screen shows CTRLXTECHNOLOGIESPRIV Rs 215.45 (from the 19:03 message). |
| 19:53 | SMS on iPhone screen: "Importing your history / Nothing imported yet / 0 of 8 date windows / Resume import (greyed) / Stop". |

Live capture itself worked. Since 15 Nov the Mac received 8/8, 8/8, 9/9, 6/5 messages a day against live captures (the one gap per day is an OTP or the one never-delivered statement notice). Everything else the owner saw has the causes below.

## 2. Root causes

### R1 — A background "catch-up" plan is shown as an import and can never run
Phone spool (`handoff.sqlite`, metadata only): 10 jobs since 13 Nov. Six are `catchup`; five are `stopped` (replaced by history imports) and one is `active`. **Every one of them has window 0 in state `waiting`, zero receipts, zero captures.** No catch-up window has ever started, so the setting `reconciledThrough` was never written.

Why it is stuck by design:
1. `refresh()` creates a catch-up for every enabled account whenever no job is active (`ios_sms_intake_controller.dart:862-866` → `IncomingSmsSpool.prepareCatchup`, `IncomingSmsSpool.swift:768`). It issues window 0 at once (state `waiting`).
2. Only the **optional** Time-of-Day automation ("Prepare PandaPay SMS Catch-up", help sheet `ios_sms_import_screen.dart:862-869`) can run a catch-up. The app cannot: `canResumeImport` is false for a `waiting` window (`controller:304`), `_canAutoResume` accepts only `kind == 'history'` (`controller:1052`), `issueNextRange` serves only history jobs (`IncomingSmsSpool.swift:601,605`). The owner has two shortcuts (live, history) and no daily automation.
3. The anchor ignores history imports: `anchor = reconciledThrough ?? enabledAt` (`IncomingSmsSpool.swift:779`), and `skipImportedRanges` runs only for history jobs (line 536). So job 10 asks for 12 Nov → 19 Nov (8 windows) although the 2-year history import finished 19 Nov 18:01 and already holds those days ("45 messages read · 45 processed" are those). The window list grows every day.
4. The UI treats any active job as an import: card title `Importing your history` whenever a window is `waiting` (`ios_sms_import_screen.dart:688-689`), `Nothing imported yet` while `importedThrough` is null, top strip `Waiting for message import…` (`controller:254`), strip `visible` whenever `activeJob != null` (`controller:198`). The strip is mounted on every main tab (`router.dart:1519`).
5. Live messages are not in those numbers: `periodCounts` counts only `date_provenance='original'` (`IncomingSmsSpool.swift:658`); live captures are `estimated`. The only live indicator is the one-line "On · last SMS today, 7:51 pm" row near the top of the page.
6. Stop does nothing useful: a new catch-up is created again on the next refresh after 5 minutes (`lastCatchupRequestedAt`).

This logic has been in place since 31 Oct (commit f859c077), so it is not a regression. It is the default state for every iPhone user who has not built the optional daily automation.

### R2 — "Can't reach PandaPay" is a load alarm, not a connectivity test
- The strip shows after **two** failed probes 1.5 s apart (`reachability_monitor.dart:90`). A probe is `GET /app-status` with a **1.8 s total deadline** (`reachability.dart:43,144`) every 60 s while the app is open, and immediately on resume.
- `/app-status` is not exempt from the API's admission queue (only `/health` and `/ready` are, `admission.js:119`) and it runs a database query (`index.js:732`). It waits in line behind the app's own start-up burst.
- Server side, the probe request that nginx logs as **499 (client gave up)**: 24.7%, 32.3%, 23.8%, 17.7%, 26.1%, 13.5%, 7.9% of `/app-status` calls on 14–20 Nov; plus 502/503 during deploys (78+20 and 20+26 on 16 and 17 Nov). Before 14 Nov the same URL saw 6–112 calls a day and ~0–1% aborts. The 1-a-minute probe and the strip shipped 13–14 Nov (commits 2d0a092d, 03bc919d), which is why "it used to work": nothing told the owner before.
- Quiet server: `/app-status` answers in a median of 77 ms (p90 0.4 s, p99 1.4 s). During the app-open burst the same server needs 1–3.8 s per call, and `/user-cards` 11–15 s.

### R3 — The production host is starved, and the app-open burst makes it worse
- VM.Standard.E2.1.Micro (954 MB RAM): CPU steal 35–75% in `vmstat`, 61–112 MB free, **1.1 GB in swap**, memory stall (PSI full) 25% over 10 s and 12% over 60 s. The API container shows 18 MB resident because it is paged out.
- API durations since the 19:22 restart (40 min, 334 requests): authenticated calls median 1.3 s, p90 8.0 s, p99 16.5 s; 70 calls over 1.8 s.
- One app open fired about 50 requests in 15 s, among them 10 × `GET /user-cards/:id/points-ledger`, 3 × `/transactions`, `/user-cards` (11–15 s), `POST /foreign-payments/refresh` (15 s), `/home-summary` (3.8 s), plus SMS-AI uploads (`/sms/v2/unknown-templates`). The 10 Nov notes record the same shape (phone fires ~12 requests at once, steal 60–74%); it was never fixed.
- Deploys on this host are slow and cause minutes of 502/503 (two restarts today).

### R4 — SMS fact uploads are slow, repeatedly aborted, and a transient 500 looks like a bad record
- nginx, `POST /sms/v2/facts:batch`, 14–20 Nov: 277 calls, **60% answered 200, 27% aborted by the phone (499), 9% 503, 2.5% 500**.
- `facts_route.js:131` answers a bare **500** for Postgres `57014` (statement timeout). `http_db_errors.js:22` already classes 57014 as transient (503) but this route does not use it. The phone reads 500 as "something in this batch" (`facts_upload.dart:416`) and starts splitting the batch (up to 60 more requests per drain, `_isolationBudget`) which loads the same slow database; a record that fails alone can be set aside as refused when the empty-batch check (`_serverAnswers`) happens to pass.
- Server created-at minus SMS time for the 21 live-era messages that made facts: median **5 h 39 min**, 9 of 21 over 6 h, only 5 within 10 min. This is the sum of "app closed" (R5) and failed or aborted uploads.

### R5 — A live SMS is captured at once but is processed (and uploaded) only when the app runs; some outcomes have no UI
- The intent runs in a cold background launch of the app. There is no Flutter engine, so `IncomingSmsBridge.channel` is nil and `workArrived()` only drains immediately when a Flutter engine already exists (`SmsImportBackgroundHost.swift:64`); otherwise it asks iOS for a discretionary BGProcessingTask (`scheduleFallback`, line 79). The 19:03 message reached the server at 19:51 (48 min), the 19 Nov 20:36 SBI message at 12:54 the next day (16 h).
- The 19:51 PhonePe message is a **payment request**, stored as an `attempt` (pending, scheduled Rs 215.45). Nothing in `app/lib` shows an `attempt`, so the message has no trace in the app by design. Correctly it is not spending until approved.
- The headless drain processes on the phone but never uploads (`ios_sms_background.dart` header). So even a background-processed message waits for the next foreground for the server copy.

### R6 — Newest Ownly row labelled CTRLXTECHNOLOGIESPRIV (not proven)
All six November SBI debits have server ledger rows with merchant key OWNLY; the alias exists in `rules/sms/v2/merchant_aliases.json:448` since 7 Nov. The Spending screen labels a row from the ledger model (`reports.dart:306`, falls back to the row's raw name when the ledger model lacks the event). Five rows show OWNLY, only the row from one minute earlier shows the raw name, so the likely cause is a briefly stale ledger model. Check: reopen Spending; if it still shows the raw name, debug the projection path.

## 3. Mac vs app audit (read-only)

- Live era, since the 13 Nov reset: 51 messages on the Mac, 44 captured live (all 44 matched), 2 OTPs excluded by design, **4 missed live on 14 Nov 20:09–22:34 (during the build installs) but recovered by a later history import**, **1 never captured by anything**: the YES BANK Nov card statement notice, 17 Nov 16:01.
- Two years: 9,793 bank/service SMS on the Mac, 8,293 have a capture on the phone, 1,500 do not. Of those, 24 look like transactions: 22 from 6–11 Nov 2024 (before the history window starts) and 2 later (a Rs 750 appointment refund notice on 3 Jul 2026, a JioFiber overdue notice on 3 Nov 2026).
- Server, last 60 days: 791 messages, 347 have facts. The 59 money-looking messages without facts are bill reminders, loan offers, mandate and payment requests, card statements, one Rs 0.00 authorisation and spam; none is a debit or credit. A few bill/statement notices (YES BANK statements, an ICICI auto-debit reminder, JioFiber dues) make no fact at all: a Bills-tab rule gap, not a spending gap.
- Ownly / CtrlX, 155 messages since July: **all have server facts** — 71 card spends (all 71 with ledger rows) and 84 PhonePe payment requests. November: six SBI card spends (1, 5, 7, 17, 19, 20 Nov) match the six rows on screen (Rs 1,157.27 together).

## 4. Fix plan

| # | Fix | Where | Release | Size |
|---|---|---|---|---|
| F1 | **Probe that measures reachability.** Probe `GET /health` (no DB, no queue); timeout 5 s; flip to "can't reach" only after 3 connect-level failures over at least 20 s; any successful API response (2xx/3xx/4xx) counts as proof the server is reachable (hook the shared client / `ServerBackoff`); do not probe in the first 3 s after resume while the burst runs; say "Slow connection" when the radio is up and replies are merely slow. | `reachability.dart`, `reachability_monitor.dart`, `sync_status_providers.dart`, `sync_status_copy.dart` | app only | S |
| F2 | **Live status model and card.** New `LiveStatus`: Off / waiting for first SMS / **Live** (last message time, N captured since enable, N waiting, what happened to the last one: saved / not a bank message / needs review / already had it) / quiet 3 days / error. Show it at the top of SMS on iPhone. Show the import card only for history jobs or for a catch-up that has really started (any window running/finished/partial/complete). Remove Resume and Stop from an idle catch-up. Top strip only for an import in motion, processing of a backlog, an error, or "N waiting". | `ios_sms_import_screen.dart`, `ios_sms_intake_controller.dart`, `live_alert_status.dart`, `IncomingSmsSpool.swift` (`snapshot()`: `live_total`, `live_today`, `last_live_outcome`, no schema change) | app build | M |
| F3 | **Catch-up that works for everyone.** (a) Create it only when the daily automation has ever run (any catch-up receipt or `reconciledThrough`) or the user taps "Check for missed messages". (b) Anchor = max(`reconciledThrough`, end of covered ranges), minus one day; skip covered ranges for catch-up too. (c) Let `issueNextRange` and the in-app launch (`continueImport`) serve catch-up jobs, so the existing history shortcut runs it from the app, at most once a day, on a tap. | `IncomingSmsSpool.swift:536,598,768`, `ios_sms_intake_controller.dart:862,1052`, `ios_sms_import_screen.dart` | app build | M |
| F4 | **Server stops punishing slow moments.** `/app-status` exempt from admission and cached 30 s in memory; `facts:batch` (and other routes) answer 503 + Retry-After for 57014/40001/40P01 through `respondDbError`; the phone treats 503 `transient_db_error` as retry and never as a bad record. | `api/src/admission.js`, `index.js:732`, `sms_v2/facts_route.js:131`, `facts_upload.dart` | prod deploy (backward compatible, ship first) | S |
| F5 | **Fewer, calmer app-open requests.** One batch call for card points ledgers (10 → 1), `/user-cards` enrichment off the open path, no `/foreign-payments/refresh` at open, visible-screen data first, others after 10–30 s, a client-side cap of about 6 concurrent requests. | `app/lib/app/providers.dart` and the repositories behind them | app build | M |
| F6 | **Give the server room.** Quick wins now: check what must stay among the three admin containers and the PM2 `auth-service` (about 150 MB resident and swapped); real fix: move the API to a shape with at least 2 GB RAM and a full vCPU (or the always-free Ampere A1 if Hyderabad has capacity, which needs multi-arch images). Build images off the box; deploy off peak. | infrastructure, `deploy/deploy.sh` | owner decision | L |
| F7 | **Live messages ready sooner.** Allow the headless drain in a `beginBackgroundTask` also for a cold intent launch (drop the `channel != nil` gate), flagged and measured on the device first; show "N messages waiting; added when you open PandaPay" meanwhile. | `SmsImportBackgroundHost.swift:55-77` | app build, device test | M |
| F8 | Product choices: show pending payment requests (`attempt` facts) somewhere small; list the "last message" outcome in the Live card (included in F2). | UI | later | S |

Recommended order: **F4 → F1 + F2 + F3 in one build → F5 → F7 → F6** (F6 can start any time because it is the biggest cause of slowness).

### Edge cases the build must keep working
- Signed out or account switch: the spool is purged and the counters restart; no stale "Live" card for the old account.
- Live shortcut never installed: "Waiting for your first SMS", no nagging strip. Live shortcut removed: quiet state after 3 days with the "turn back on" button.
- Daily automation installed: catch-up windows complete by themselves; card appears only while a window runs; Resume works for a `partial` window; Find Messages cap (500) still splits.
- A gap of several days (phone off): one catch-up of N windows, run in one loop.
- User-started history import always wins and replaces an idle catch-up (existing `replacingJobID` rule, covered by tests).
- Old data: spool schema stays at user_version 2 (counters are derived from existing tables); the new Dart keys must default safely when absent.
- Locked phone after reboot: key unavailable, messages stay in the spool (existing behaviour), the card says "waiting for first unlock".
- iOS below 26 has no continued-processing task: copy must not promise "stays on your Lock Screen".
- Captive portal: `/health` returns JSON, so a 200 HTML page is still "not reachable".
- Radio down stays "Offline mode"; a real outage (502/503 for 3 probes over 20 s) still shows "Can't reach PandaPay".
- Android uses the same probe and strip, so F1 and F4 help it too; F2, F3 and F7 are iOS only.

### Tests to add or change
`reachability_test.dart`, `reachability_monitor_test.dart`, `sync_status_providers_test.dart` (strikes, passive evidence, resume delay); `ios_sms_import_screen_test.dart` (live card, idle catch-up hidden, history card unchanged); `ios_sms_intake_controller_test.dart` (`visible`, `label`, no auto catch-up creation); `app/test/native/incoming_sms_spool_test.swift` (anchor, covered ranges for catch-up, `issueNextRange` with catch-up, live counters); `api/test` (admission exemption, 57014 → 503, facts route). Then the performance guard (`flutter test test/performance_guards_test.dart`) and one device run with a profile build.

## 5. Not verified
- The phone's main database is SQLCipher, so I could not read when each message was processed on the phone, only when the server received it.
- R6 (label) and the cold-launch behaviour in R5 are inferred from code and timing; they need one device check.
- Why iOS never delivered the YES BANK statement notice (17 Nov 16:01) to either shortcut: possibly the Messages Promotions filter; not checked.
- The server shape and cost options in F6 are the owner's decision.

## 6. How to repeat the checks
- Phone spool (metadata only, the body column is sealed or empty): `xcrun devicectl device copy from --device <udid> --domain-type appDataContainer --domain-identifier app.pandapay.pandapay --source "Library/Application Support/PandaPaySmsIntake/handoff.sqlite" --destination <scratchpad>/handoff.sqlite`; read `jobs`, `windows`, `receipts`, `settings`, `captures`. Delete it afterwards.
- Mac messages vs captures: `extract_messages.py` (see `docs/sms-pipeline-v2/seed/real_sms_tools`), match by time to `captures.received_at` (history, ±2 s) and `captured_at` (live, ±3 min).
- Server: source key as in `smsSourceKey` (`sms_intake_repository.dart`), look up `sms_v2_facts`, `sms_v2_events`, `sms_v2_ledger_entries` through the backup container (read-only), never print the container environment.
- Probe health: count `GET /app-status` by status per day in `/var/log/nginx/access.log` (499 = the phone gave up); request durations come from the API container's JSON `request` lines.

## 7. What was built (20 Nov, uncommitted)

- **F4 server:** `api/src/app_status_cache.js` (30 s cache, one shared read, stale value served for up to 10 min if the database fails); `/app-status` exempt from admission (`admission.js`); `facts:batch` answers 503 + Retry-After for 57014/40001/40P01 and lost connections via `respondDbError` (`facts_route.js`). Tests: `api/test/app_status_cache.test.js`, `api/test/sms_v2/facts_route.test.js`. Needs a prod deploy.
- **F1 app:** probe is `GET /health` with a 5 s budget; `ReachabilityMonitor` flags "can't reach" only after 3 failures spanning 15 s, skips probes while a real API answer arrived in the last 20 s, treats any answer below 500 (and 429) as proof of reachability (`api_answer_evidence.dart`, fed by `AuthenticatedHttpClient`), clears an outage the moment an answer arrives, and waits 3 s after resume. Not built: a separate "Slow connection" strip (a slow-but-answering server now simply stays quiet).
- **F2 app:** `IosSmsIntakeState.catchUpIdle / showsImportCard / catchUpStarted`; the card, Resume, Stop and the top strip appear only for a history import or a catch-up that really started; the strip also says "N messages waiting to be added". The "Live bank alerts" panel now shows counts (total since enabling, today), the outcome of the last message, waiting messages, and the checked-through date. The current month counts as covered while live alerts work. Native `snapshot()` adds `live_total`, `live_today`, `last_live_state`, `last_live_processed`, `last_live_intake` (no schema change, one new index).
- **F3 app + native:** `prepareCatchup(explicit:)`; the app's own refresh passes `explicit: false` so no plan is made unless the daily check has run before, and an idle plan older than 15 minutes is retired; the plan starts one day before the end of what is already covered (history or earlier checks) and skips covered days; `issueNextRange` and the app's launch serve catch-up jobs; new button "Check for missed messages" (`checkMissedMessages`). Also fixed: `pending()` order is now insertion order (the two existing spool assertions were random before), and the Swift harness (`app/tool/test_ios_sms_intake_native.py`) compiles again (`SpoolCipher.swift` was missing).
- **Tests run:** API 2,887 pass; Flutter sms_import, sync_status, connectivity suites and the performance guard pass; Swift spool tests pass six runs in a row; full Flutter suite result in the hand-off message.
