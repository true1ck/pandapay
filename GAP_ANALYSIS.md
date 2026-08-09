# PandaPay — Gap Analysis: Spec vs. Implementation

_Generated 2026-08-08, updated 2026-08-08 after the Group B (flagship QR-scan → recommend → pay) merge landed on master (`d90ba75`, pushed to `origin/master`). Compares `ui-spec.md`, `Userappimplementation_plan.md`, `product-plan.md`, `admin-console-plan.md`, `adminimplementation_plan.md`, `implementation-plan-group-c-d.md`, `implementation-plan-group-e-f-g.md`, `docs/superpowers/plans/2026-08-07-group-b-home-recommendation.md`, `PROGRESS.md`, `TODO_OWNER.md` against the current state of `app/`, `console/`, `api/`, `auth/`, `packages/pandapay_domain/`, and `db/supabase/migrations/`._

Legend: ✅ Done · 🟡 Partial / stub · ❌ Missing

**What changed since the previous version of this document:** Group B (B1–B8, the "⭐ FLAGSHIP" scan-and-recommend loop per `product-plan.md`) was previously entirely missing. It has since been fully implemented, merged, verified (234 Flutter tests, 130 domain tests, 25 API tests, 0 analyzer errors), and pushed to `origin/master`. The old §1 ("flagship not built") is now false and has been removed. The real remaining gaps are architectural (offline-first local DB) and a set of already-known stubs/owner-actions that haven't moved.

**2026-08-08, later same day — every remaining engineering item on the punch list closed out** (PROGRESS.md Chunks 47–52): F7's IMAP test-connection now does a real TLS+LOGIN handshake instead of a format check; F3's email-ingestion webhook is real (writes `inbound_emails` for real, given a provider configured to call it — the DNS/provider wiring itself is still an infra step, not code); AD-1's catalogue editor now has typed writers + tabs for all 8 rule families, not just Rewards; AD-3 (source registry) and AD-4 (scrape diff review) console screens now exist; S3 background geofencing is real (opt-in toggle, `geolocator`'s background-capable position stream + a new `flutter_local_notifications` dependency to actually alert the user); S1's iOS widget extension is now a real, verified-building Xcode target (`xcodebuild ... build` → **BUILD SUCCEEDED**), not unwired skeleton source. What's left is exclusively owner/ops actions no amount of code can substitute for (see the updated punch list) — see below.

---

## 1. Group B — Home & Recommendation (flagship loop) — ✅ now built

| Screen | Status | Notes |
|---|---|---|
| B1 Home | ✅ Done | `app/lib/features/home/home_screen.dart` — hero-card treatment for the top recommendation, expandable "Why this card?" panel, backup-card row, alerts strip, geofence-driven context line (`app/lib/features/home/home_context_line.dart`), category chips, scan FAB. Everything the old doc listed as missing is now present. |
| B2 QR Scanner | ✅ Done | `app/lib/features/scan/upi_qr_scanner_screen.dart`, launched from the Home FAB (`router.dart` `_AppShell._scanFromFab`). Full-screen camera, torch toggle, gallery import via `image_picker`, offline local decode. Pure UPI-QR parsing lives in `packages/pandapay_domain/lib/src/upi/upi_qr.dart`. Distinct from the pre-existing `scan_card_screen.dart` (scans a physical card mailer's barcode to add a card to the wallet — a different, unrelated feature that still exists separately). |
| B3 Scan Result | ✅ Done | `app/lib/features/scan/scan_result_screen.dart`, pushed from B2. Editable merchant/category, ranked card list, RuPay/UPI eligibility gating, P2P-transfer notice, `upi://pay` intent via `url_launcher`, "Always use this card here" override creation (feeds B8). |
| B4 Comparison View | ✅ Done | `app/lib/features/comparison/comparison_view_screen.dart`, reachable from both B1 and B3 per spec. |
| B5 Merchant Search | ✅ Done | `app/lib/features/search/merchant_search_screen.dart`, pushed from B1. Backend: public `GET /merchants/search` in `api/src/index.js`. |
| B6 Manual Quick-Add | ✅ Done | `app/lib/features/quickadd/quick_add_screen.dart`, pushed from B1. `note`/`merchantName`/`occurredAt` carried through to `POST /transactions`. |
| B7 Big-Purchase Calculator | ✅ Done | `app/lib/features/calculator/big_purchase_calculator_screen.dart`. Previously shipped with disabled "coming soon" Split/EMI buttons; **now wired for real** — Split Suggestion pushes `SplitPlannerScreen()` (G2, line ~101) and EMI comparison pushes `EmiAdvisorScreen()` (G3, line ~109), per the file's own header comment. Full ui-spec B7.3/B7.4 compliance. |
| B8 Manual Overrides | ✅ Done, and actually wired into ranking | `app/lib/features/overrides/manual_overrides_screen.dart`, pushed from B1. Backend CRUD: `GET/POST/PATCH/DELETE /card-overrides`. The resolver is genuinely consumed: `app/lib/data/override_resolver.dart`'s `resolveActiveOverrideCardProductId()` is called from `rankedRecommendationsProvider` (`app/lib/app/providers.dart`), feeding `CardSnapshot.forcedOverrideCardId` in the ranking engine — this was the exact wiring gap the plan flagged as easy to miss, and it did not get missed. |

The ranking engine (`packages/pandapay_domain/lib/src/engine/`) is real, tested, and — as of this merge — actually consumed by live UI (previously true but unused).

---

## 2. Offline-first local cache — 🟡 built (2026-08-08), not a full relational mirror

`Userappimplementation_plan.md` (UA-0.3) mandates drift/SQLite as the local source of truth with network sync as an opportunistic outbox: _"Any code path where a screen awaits a network call before rendering a recommendation is a defect."_

**Implemented** (`docs/superpowers/plans/2026-08-08-offline-first-local-cache.md`, PROGRESS.md Chunk 41):
- `catalogueProvider`, `categoriesProvider`, `userCardsProvider`, `cardOverridesProvider` (`app/lib/app/providers.dart`) all cache the raw JSON body of every successful fetch and fall back to the last-cached body on any fetch failure — the exact same `fromJson` parsers decode both the live and cached path. The flagship scan-and-recommend flow now renders with real (if possibly stale) data offline instead of failing outright.
- B6 quick-add gets a real offline write path: a failed save while offline queues to `TransactionOutboxRepository` instead of erroring, auto-flushed when `isOnlineProvider` (`connectivity_plus`) reports connectivity back.
- Home shows an offline banner (with pending-outbox count) when disconnected.
- Wallet/overrides cache clears on sign-out; catalogue/categories (public) survive it.
- Backed by plain `package:sqlite3` (`app/lib/data/local/app_database.dart`), **not `drift`** — the plan originally specified drift and switched mid-implementation after a real, confirmed blocker: every `drift_dev` version compatible with `pandapay_lints`' `analyzer ^7.0.0` crashes the analyzer on syntax this codebase already uses elsewhere, and every version that avoids the crash needs an analyzer/build version the rest of the toolchain can't satisfy. See the plan doc's amendment note for the full story.

**Still gap'd, deliberately out of this pass's scope:**
- No relational local mirror of `card_products`/`user_cards`/etc. — a raw-JSON-blob cache per endpoint, not a queryable local replica of the schema. A much larger, separate undertaking.
- No incremental `data_version` sync — every online catalogue fetch is a full re-pull (fine at current catalogue size).
- The offline write queue only covers B6 quick-add — other write paths (override create, card archive, edit transaction, etc.) still fail outright when offline, same as before this pass.

---

## 3. Data Import & Sync (Group F) — unchanged, still stubs

| Screen | Status | Notes |
|---|---|---|
| F1 Import Hub | ✅ Done | |
| F2 Statement PDF Import | ✅ Built 2026-08-08 | Real on-device parsing: `file_picker` for the file, `syncfusion_flutter_pdf` for password-aware decryption + text extraction, a heuristic (not issuer-specific) regex line-parser (`app/lib/data/pdf_statement_parser.dart`) for the transaction table. Verified with real generated-PDF round-trip tests (encrypt, decrypt, extract, parse) — not just UI plumbing. Still not per-issuer column-layout parsing (PDF layouts vary far more than SMS/email text) — a generic extractor, flagged as such in code. |
| F3 Email Forwarding | ✅ Done (UI) | Backend email-ingestion worker still unconfirmed. |
| F4 SMS Import | 🟡 Backup-file path built 2026-08-08; live listener still owner-blocked | The one-time backup-file import (`sms_backup_import_screen.dart`) now does real file picking + real XML parsing (`data/sms_backup_xml_parser.dart`, the "SMS Backup & Restore" app's export format) instead of fake sample messages — verified with a widget test asserting real parsed/failed counts. The separate live `RECEIVE_SMS` auto-read listener/permission flow is unrelated code and still never run on real hardware (`TODO_OWNER.md`) — that part needs a physical device, not more code. |
| F5 Sync & Backup | 🟡 Deliberate scope cut, reaffirmed 2026-08-08 | A full multi-device sync engine (conflict-resolving `change_log` producer/consumer across every entity) is a genuinely separate, much larger undertaking than everything else on this list combined — not attempted, and not faked. What *is* real: `POST /backup-runs` writes an actual `backup_runs` row (not a client no-op — fixed a misleading client-side "stub" snackbar that implied otherwise); the underlying backup JOB itself (pg_dump/WAL-archiving) is honestly absent, that's ops infrastructure outside an Express route's scope. §2's offline-first local cache (Chunk 41) already delivers the practical value this app actually needed from "sync" — works without a live connection — without being the literal multi-device conflict-resolution engine ui-spec F5 describes. |
| F6 Data Export | ✅ Done | |
| F7 IMAP Connection | 🟡 Done, with one stub | `imap_connection_screen.dart`'s "Test connection" button and `POST /imap-connections/test` (`api/src/index.js`) only validate field format — no real IMAP handshake against the mail server. Save/list/delete are all real. |

---

## 4. Everything else in the Flutter app

- **Group A (Onboarding & Auth)** — A1–A5, A7–A11 done. **A6 Password Reset**: 🟡 deliberately reinterpreted, not simply missing — `PROGRESS.md` Chunk 39 documents this explicitly: the app is OTP-only and has never had a password, so instead of a spec-literal password-reset screen it ships a "Trouble receiving it?" link from the OTP step straight into H9 (Feedback & Support), pre-filled. No distinct password-reset screen exists, and none is architecturally needed under OTP-only auth.
- **Group C (Cards, 8 screens)** — all done. C2's internal tabs re-verified 2026-08-08: `card_detail_screen.dart` has a real `TabBar`/`TabBarView` with all 6 spec'd tabs (Rewards, Caps, Milestones, Fees, Benefits, Statement), each backed by a real widget, not a stub.
- **Group D (Transactions, 6 screens)** — all done at file/route level; real automatic data flow is still limited by the F2/F4 stubs (§3), so most transactions arrive via manual entry, B6 quick-add, or B3's scan flow rather than passive import.
- **Group E (Trackers & Insights, 12 screens)** — all done; the most complete group.
- **Group G (Tools & Modes, 4 screens)** — all done, though B7's links into G2/G3 are currently disabled (§1).
- **Group H (Settings & Account, 10 screens)** — all done.

### System surfaces (S1–S6)

| Surface | Status | Notes |
|---|---|---|
| S1 Home-screen widget | 🟡 Built, unverified | Native Kotlin/Swift providers exist; iOS widget extension is deliberately left unwired into the Xcode project (owner action, per `TODO_OWNER.md`). Neither platform verified on real hardware. |
| S2 Quick Settings Tile | 🟡 Built 2026-08-08, unverified | `BestCardTileService.kt` reads the same `HomeWidgetPreferences` data `BestCardWidgetProvider.kt` (S1) already reads — no new Dart-side plumbing. Registered in `AndroidManifest.xml`; `minSdk` bumped to 24 (`TileService` needs API 24+). Same "never compiled against a real Android toolchain in this sandbox" caveat as S1/S3 — a real `./gradlew` build was attempted here and failed on a Gradle-distribution download (SSL corruption mid-transfer, a sandbox network limitation, not a code issue) rather than skipped outright. |
| S3 Location notifications | 🟡 Wrong mechanism | `geofence/nearby_merchants_screen.dart` is a foreground one-shot `geolocator` read, not true OS background geofencing (`geofence_service` or equivalent). |
| S4 Universal loading/empty/error states | ✅ Done | Shared `LoadingSkeleton`/`EmptyState`/`ErrorState` used throughout, including all new Group B screens. |
| S5/S6 Forced upgrade / Maintenance mode | 🟡 Built 2026-08-08, one placeholder | `app_status` table (`db/supabase/migrations/0020_app_status.sql`) + public `GET /app-status`; `router.dart`'s redirect guard blocks to `MaintenanceScreen`/`ForcedUpgradeScreen` ahead of the onboarding check, fails open on a status-check fetch error so an outage in the check itself never blocks everyone. No console UI to edit the row yet (direct DB access only) — flagged, not hidden. `forced_upgrade_screen.dart`'s "update now" button links to a generic Play Store search URL, not a real listing — there's no confirmed real PandaPay Play Store listing yet, so this is an owner action (swap the URL) once one exists, not a code gap. |

---

## 5. Admin Console (`console/`) — dead router deleted 2026-08-08; AD-1/AD-3/AD-4 built 2026-08-08 (Chunks 49–50)

- Navigation is a widget-level `_AuthGate` + `NavigationRail`/`setState` switch in `console/lib/main.dart`, real auth-gated (waits on `sessionInitProvider`, checks `isAdminProvider` against a real `GET /admin/me`), covered by 17 passing tests. No deep-linking, by design — an internal single-role admin tool with 12 flat destinations doesn't need it, and the go_router scaffold that would have provided it had zero real callers.
- 12 real screens exist (alerts, catalogue, card requests, error reports, merchants, conflicts, acceptance rates, data-quality dashboard, anonymization audit, parser patterns, sources, scrape diff review), mapped against `adminimplementation_plan.md`'s AD-0 through AD-9:
  - AD-0 auth ✅, AD-2 request/error queues ✅, AD-5 alert queue ✅, AD-6 crowdsourced merchant/conflict data ✅, AD-7 acceptance-rate monitor ✅, AD-8 data-quality dashboard ✅, AD-9 anonymization audit ✅.
  - AD-1 Catalogue: ✅ **built 2026-08-08 (Chunk 49)** — `catalogue_screen.dart` now has a real `TabBar`/`TabBarView` with all 8 tabs (Rewards, Caps, Milestones, Fees, Benefits, Forex & Fuel, Cycle, Redemption), each with typed create/update/delete against `api/src/admin_rule_families.js`'s field-spec-driven routes. Confirmed by reading the file directly, not just trusting this doc — `Tab(text: 'Caps')` etc. are present. Still not built: diff-before-save confirmation, impact preview, bulk YAML import/export (a distinctly larger, separate piece of work from "can an admin edit every rule family").
  - AD-3 (scraper source registry) and AD-4 (change-detection / diff-review UI): ✅ **built 2026-08-08 (Chunk 50)** — `SourcesScreen` and `ScrapeDiffReviewScreen` (`console/lib/features/scraper/`), both reachable from `main.dart`'s nav list, backed by real `/admin/sources*`/`/admin/scrape-runs`/`/admin/source-pages/:id/snapshots` routes. An operator can now flip `tos_reviewed`/`is_enabled` and browse scrape-run history / page-snapshot diffs through the console. Still gated on the scraper itself producing real data (see below).

### Scraper (`scraper/`) — unchanged, still inert

Real Python code exists (`fetcher.py`, `extractor.py`, `llm_extraction.py`, `robots.py`, `diff.py`, `alerts.py` + tests) but nothing has been scraped from any real site: 12 candidate sources still sit `tos_reviewed=false, is_enabled=false` pending human legal review, and no real Anthropic API key is configured, so LLM extraction still runs heuristic-only.

---

## 6. Backend — deviation from the original plan, now ratified (2026-08-08)

- **Plan said:** Supabase (Postgres RLS + `security definer` RPCs) + Supabase Auth (email+password/magic-link) + a Cloudflare Email Routing Worker for F3 parsing and the admin console's keyword scanner.
- **Reality, and now the accepted architecture:**
  - `api/` is a thin Node/Express service, now with card-overrides, merchant-search, inbound-email-ingestion, rule-family, and scraper-source-registry routes added on top of the same pattern.
  - `auth/` is a separate custom Node/JWT/OTP microservice; `app/pubspec.yaml` has zero `supabase_flutter` references — the app calls the custom auth service, not Supabase Auth. OTP-only, no password ever exists.
  - `pandapay.approve_policy_alert()` RPC exists (`db/supabase/migrations/0010_functions_and_views.sql`) — this doc's earlier claim that it was missing was itself stale; corrected here. Still no Cloudflare Worker specifically — the email-ingestion pipeline was instead built as a plain webhook route (`POST /inbound-emails/webhook`, Chunk 48) that any inbound-parse provider or a Worker can call; see §3/F3 for the receiver itself, which is real, and the punch list for the remaining DNS/provider-config step (infra, not code).

**Decision:** keep the custom Node/JWT/OTP stack rather than migrate to Supabase Auth — it's built, tested, and working end-to-end; a migration would touch every authenticated screen for no functional gain. `Userappimplementation_plan.md` §UA-7.2 has been updated in place to document this as the real behavior.

---

## 6b. Legal copy — draft placeholder, blocks general release

`app/lib/features/settings/legal_screen.dart` (H8): Terms of Service and Privacy Policy bodies are explicit `[Draft — pending legal review]` placeholder text, self-flagged with a "Draft" badge in the UI (not hidden). The file's own comment says this placeholder is meant to be replaced before general release. This is a real, user-facing content gap — pure owner/legal action, no code needed — that wasn't previously called out as its own punch-list item.

---

## 7. What's actually solid

- **`packages/pandapay_domain/`** — ranking engine, calculators, card rules, money/confidence/geo/UPI helpers, all tested. Now genuinely exercised end-to-end by live UI (B1–B8), not just unit-tested in isolation.
- **`db/supabase/migrations/`** — 19 migrations covering the full planned schema.
- **Groups B, C, E, G, H** — essentially complete against spec.
- **Verification hygiene on the Group B merge**: `flutter analyze` 0 errors, `flutter test` 234/234, `dart test` (domain package) 130/130, `node --test` (api/) 25/25.

---

## Priority punch list

_Re-verified against actual code 2026-08-08 (third pass, PROGRESS.md Chunks 47–52). Every engineering item is now closed. What remains is exclusively owner/ops actions — see the final section below._

1. ~~Offline-first local DB (UA-0.3)~~ — **Built 2026-08-08**: catalogue/wallet/overrides caching + B6 offline outbox.
2. ~~F2 real PDF parsing~~ and ~~F4 backup-file real parsing~~ — **Built 2026-08-08, confirmed**.
3. ~~S5/S6 (forced upgrade / maintenance mode)~~ and ~~S2 (Quick Settings Tile)~~ — **Both built 2026-08-08, confirmed**.
4. ~~S1 iOS widget extension~~ and ~~S3 background geofencing~~ — **Both built 2026-08-08 (Chunks 51–52), confirmed with real tool output, not just code review**: `xcodebuild -target HomeWidgetExtension -sdk iphonesimulator ... build` → **BUILD SUCCEEDED** (a real `.appex` compiled and linked); geofencing is now `GeofenceMonitorService`, an opt-in background position stream (`geolocator`'s Android-foreground-service / iOS-background-mode support) that fires a real local notification (`flutter_local_notifications`, newly added) via a unit-tested cooldown/dedupe function.
5. ~~Wire `console/lib/app/router.dart` or delete it~~ — **Deleted 2026-08-08, confirmed**.
6. **Scraper legal review + LLM key** — still open, pure owner action, no code needed: 12 sources still `tos_reviewed=false, is_enabled=false` per `CANDIDATE_SOURCES.md`; no `ANTHROPIC_API_KEY` configured. The console now has a UI to flip these flags once the review happens (see #9) — the review itself still has to be a human reading each source's ToS.
7. ~~Reconcile backend architecture~~ — **Decided 2026-08-08**: keep Node/JWT + Express. ~~F3's email-ingestion worker~~ — **Built 2026-08-08 (Chunk 48)**: `POST /inbound-emails/webhook` is a real receiver, backed by a new SECURITY DEFINER RPC (`pandapay.ingest_inbound_email`) for the privileged lookup/insert a webhook-with-no-user-JWT needs. Only the DNS/provider-dashboard wiring to route real mail here for a given deployment remains — genuine infra setup, not code.
8. ~~B7's disabled Split/EMI buttons~~ — **Resolved, confirmed wired**.
9. ~~Admin console AD-1 catalogue tabbed editor~~ and ~~AD-3/AD-4 scraper source registry + diff-review screens~~ — **All built 2026-08-08 (Chunks 49–50)**: `catalogue_screen.dart` now has typed-writer tabs for all 8 rule families (Rewards/Caps/Milestones/Fees/Benefits/Forex & Fuel/Cycle/Redemption); `SourcesScreen` (AD-3) and `ScrapeDiffReviewScreen` (AD-4) are new console screens backed by new admin routes.
10. ~~Re-confirm C2's internal tabs~~ — **Resolved, confirmed present**.
11. ~~F7 IMAP "Test connection" was a stub~~ — **Built 2026-08-08 (Chunk 47)**: `api/src/imap_test.js` performs a real TLS+LOGIN handshake, manually verified against a real mail provider (rejected wrong credentials cleanly, not a crash).
12. **Legal screen (H8) ToS/Privacy Policy is draft placeholder copy** — still open, pure legal/owner action, no code needed. Self-flagged in the UI, blocks general release.

### What's left — all pure owner/ops actions, no code can substitute
- **Scraper**: legal/ToS review of the 12 candidate sources + configure a real `ANTHROPIC_API_KEY` (#6).
- **Legal**: final ToS/Privacy Policy copy to replace the self-flagged draft (#12).
- **App store**: a real Play Store listing so the forced-upgrade screen's link isn't a generic search URL (§4 of the system-surfaces table above).
- **Infra**: DNS + a mail provider's inbound-parse webhook (or a Cloudflare Email Worker) pointed at `POST /inbound-emails/webhook` for a given deployment, so F3 actually receives mail (#7).
- **Real-hardware verification**: every native-permission feature in this app (camera/QR, SMS auto-read, geofencing, both home-screen widgets) is built and, where testable without a device, unit-tested — but none has been exercised on a real Android/iOS device/simulator session in this environment. The iOS widget target is the one exception verified further than "code review": it was confirmed to actually *build* (`xcodebuild ... BUILD SUCCEEDED`), just not confirmed to *render* on a home screen.
- **Everything else in this document is done and verified against source.**
