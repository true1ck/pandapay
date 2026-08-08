# PandaPay — Gap Analysis: Spec vs. Implementation

_Generated 2026-08-08 by comparing `ui-spec.md`, `Userappimplementation_plan.md`, `product-plan.md`, `admin-console-plan.md`, `adminimplementation_plan.md`, `implementation-plan-group-c-d.md`, `implementation-plan-group-e-f-g.md`, `PROGRESS.md`, `TODO_OWNER.md` against the current state of `app/`, `console/`, `api/`, `auth/`, `packages/pandapay_domain/`, and `db/supabase/migrations/`._

Legend: ✅ Done · 🟡 Partial / stub · ❌ Missing

---

## 1. Biggest gap: the flagship QR-scan → recommend → pay loop is not built

This is the single most important finding. The product plan calls the "scan a merchant's UPI QR code, get an instant card recommendation, launch the UPI app" loop the flagship feature (UA-4, "⭐ FLAGSHIP", product-plan §4.1). It does not exist.

| Spec screen | Status | Notes |
|---|---|---|
| B2 QR Scanner | ❌ Missing (wrong feature built instead) | `app/lib/features/scan/scan_card_screen.dart` exists but scans a QR/barcode printed on a **physical card mailer to add a card to your wallet** — not a merchant UPI-payment QR. No `upi://pay`, `pa=`, `pn=`, `mc=` parsing anywhere in `app/lib`. |
| B3 Scan Result | ❌ Missing | No merchant capture, no card-eligibility gating, no "Pay with [card]" UPI intent, no "always use this card here" override, no "wasn't accepted" recording. |
| B4 Comparison View | ❌ Missing | No file, no route. |
| B5 Merchant Search | ❌ Missing | No file, no route. |
| B6 Manual Quick-Add | ❌ Missing | No dedicated 3-tap quick-add flow (only a "log spend" button reusing an existing provider). |
| B7 Big-Purchase Calculator | ❌ Missing | No file, no route. |
| B8 Manual Overrides manager | ❌ Missing | No way to view/edit/delete "always use this card here" rules — and nothing creates them either, since B3 doesn't exist. |

The ranking **engine** itself (`packages/pandapay_domain/lib/src/engine/`) is real, tested, and complete — it's just not wired to any UI that would use it for point-of-sale recommendations.

---

## 2. Home screen (B1) — intentionally cut down

`app/lib/features/home/home_screen.dart` is a documented partial implementation: category chips + ranked list with reason lines only.

Missing vs. spec:
- Hero-card treatment
- Alerts strip
- Backup-card row
- Geofence-driven context line
- Offline bundling
- "Why this card?" as an expandable panel (currently a flat bullet list)

---

## 3. No offline-first local database — architecture-level gap

`Userappimplementation_plan.md` (UA-0.3) mandates drift/SQLite as the local source of truth with network sync as an opportunistic outbox: _"Any code path where a screen awaits a network call before rendering a recommendation is a defect."_

Reality:
- `app/pubspec.yaml` has no `drift`, `sqlite3`, or `sqlcipher` dependency.
- `app/lib/data/` contains only thin REST repositories (`account_api.dart`, `auth_api.dart`, `catalogue_repository.dart`, `user_cards_repository.dart`, etc.) — no local DB layer.
- The app is online-only today, contradicting the plan's "non-negotiable" architecture.

This underlies several other stubs below (F5 Sync, and the general "screens have no offline data to show" problem).

---

## 4. Data Import & Sync (Group F)

| Screen | Status | Notes |
|---|---|---|
| F1 Import Hub | ✅ Done | |
| F2 Statement PDF Import | 🟡 Stub | Real UI flow exists but is wired to a stub parser that **fabricates a fake preview**. `syncfusion_flutter_pdf` (required by UA-1.5) is not in `pubspec.yaml`. |
| F3 Email Forwarding | ✅ Done (UI) | See §6 — the backend email-ingestion worker that should feed it is missing. |
| F4 SMS Import | 🟡 Stub for on-device parts | Parsing logic is real and unit-tested, but the `RECEIVE_SMS` listener/permission prompt has never run on a real device (per `TODO_OWNER.md`). `sms_backup_import_screen.dart` explicitly notes stub file contents. |
| F5 Sync & Backup | 🟡 Stub | No client-side sync engine exists at all (see §3) — no offline write queue, no `change_log` producer. Scoped down to backup/restore **status only**; backup itself is a stub (`sync_backup_screen.dart`). |
| F6 Data Export | ✅ Done | |
| F7 IMAP Connection | ✅ Done (further along than F2/F5) | Migration `0018_imap_connections.sql` exists. |

---

## 5. Everything else in the Flutter app — largely complete

These groups have files for every planned screen and are wired into `app/lib/app/router.dart`:

- **Group A (Onboarding & Auth)** — A1–A5, A7–A11 done. **A6 Password Reset has no distinct screen/route** — likely folded into `login_screen.dart` but not confirmed as a separate flow.
- **Group C (Cards, 8 screens)** — all done (`my_cards_screen.dart`, `card_detail_screen.dart`, `edit_card_screen.dart`, `benefits_cheat_sheet_screen.dart`, `points_expiry_screen.dart`, `report_wrong_data_screen.dart`, `request_new_card_screen.dart`, shared `card_picker_screen.dart`). C2's internal tabs (Rewards/Caps/Milestones/Fees/Benefits/Statement) weren't individually re-verified.
- **Group D (Transactions, 6 screens)** — all done at file/route level, but since B3 (scan→transaction) doesn't exist and F2/F4 are stubs, most screens have little real automatic data flowing in — only manual entry / API-backed sources.
- **Group E (Trackers & Insights, 12 screens)** — all done; the most complete group.
- **Group G (Tools & Modes, 4 screens)** — all done (`travel_mode_screen.dart`, `split_planner_screen.dart`, `emi_advisor_screen.dart`, `emergency_card_info_screen.dart`).
- **Group H (Settings & Account, 10 screens)** — all done.

### System surfaces (S1–S6)

| Surface | Status | Notes |
|---|---|---|
| S1 Home-screen widget | 🟡 Built, unverified | Native Kotlin/Swift providers exist, but the **iOS widget extension is deliberately left unwired into the Xcode project**; neither platform has been exercised on real hardware. |
| S2 Quick Settings Tile | ❌ Not found | |
| S3 Location notifications | 🟡 Wrong mechanism | `geofence/` exists but is a foreground one-shot "check nearby merchants" location read using `geolocator`, not true OS background geofencing (`geofence_service`). |
| S4 Universal loading/empty/error states | ✅ Done | Shared `LoadingSkeleton`/`EmptyState`/`ErrorState` widgets used throughout. |
| S5/S6 Forced upgrade / Maintenance mode | ❌ Not found | No `min_supported_version` or kill-switch code located. |

---

## 6. Admin Console (`console/`)

Substantial real implementation (10 screens: alerts, catalogue, card requests, error reports, merchants, conflicts, acceptance rates, data-quality dashboard, anonymization audit, parser patterns) — not vaporware. Gaps:

- **`console/lib/app/router.dart` is dead code.** All routes point to `_StubScreen(...)`; real navigation happens via direct widget wiring in `main.dart`, bypassing go_router entirely. This means the planned route-guard security model (redirect non-admin sessions to a dead end) doesn't run as specced.
- `catalogue_screen.dart` is missing the tabbed rule-family editor (Rewards/Caps/Milestones/Fees/Benefits/Forex&Fuel/Cycle/Redemption tabs) and a confirmed "verification pass" workflow.
- Migrations for the admin console exist and are comprehensive (`0008_admin_console.sql`, `0016_queue_tables_admin_rls.sql`).

### Scraper (`scraper/`)

Real Python code exists (`fetcher.py`, `extractor.py`, `llm_extraction.py`, `robots.py`, `diff.py`, `alerts.py` + tests), but it is **inert**:
- Nothing has been scraped from any real site — 12 candidate sources sit in the DB with `tos_reviewed=false, is_enabled=false`, pending a human legal review that hasn't happened.
- LLM extraction is built but has no real Anthropic API key configured, so it runs heuristic-only.

---

## 7. Backend — deviates from the documented architecture

- **Plan says:** Supabase (Postgres RLS + `security definer` RPCs, e.g. `pandapay.approve_policy_alert()`) + a Cloudflare Email Routing Worker for F3/email-forwarding parsing and the admin console's keyword scanner.
- **Reality:**
  - `api/` is a thin Node/Express service (5 source files: `index.js`, `auth.js`, `cycles.js`, `db.js`, `sms_parser.js`).
  - `auth/` is a separate, large custom Node/JWT/OTP microservice, architecturally inconsistent with the plan's Supabase Auth (`supabase_flutter`, magic-link, UA-7.2). The app calls this custom service's REST endpoints instead.
  - No Cloudflare Worker code, no `pandapay.approve_policy_alert()` RPC, no email-ingestion pipeline processing `inbound_emails` — only the schema (`db/supabase/migrations/0006_ingest.sql`) exists, not the worker that would populate it.
  - Also unconfirmed/missing: `pandapay.detect_rate_divergence()` nightly job, Cloudflare Worker policy-keyword scan, catalogue delta-sync endpoint (`v_card_catalogue_export`), contribution-outbox ingestion endpoint.

This is a full backend substitution rather than an incremental gap, but it's a real deviation from the documented stack worth flagging to whoever owns the architecture decision.

---

## 8. What's actually solid

- **`packages/pandapay_domain/`** — the ranking engine, calculators, card rules, money/confidence/geo helpers, all tested (including golden fixtures). Strongest-implemented layer in the repo; just not exposed through the missing B2–B8 screens.
- **`db/supabase/migrations/`** — 19 migrations covering the full planned schema (catalogue, user domain, sync, ingest, crowdsource, admin console, RLS, cron jobs, IMAP). The DB layer is largely built even though the app doesn't consume it offline-first.
- **Groups C, E, G, H** — essentially complete against spec.

---

## Priority punch list

1. Build the flagship QR-scan → recommend → UPI-handoff loop (B2–B8) — the core differentiator described in the product plan is currently absent.
2. Decide on and build an offline-first local DB layer (drift/SQLite), or formally revise the plan to accept online-only architecture.
3. Fill out B1 Home (hero card, alerts strip, backup-card row, geofence context).
4. Replace the F2 PDF-import stub with real parsing (add `syncfusion_flutter_pdf` or equivalent).
5. Wire the admin console's actual navigation through `console/lib/app/router.dart` so route guards apply, or delete the dead router file.
6. Get scraper sources through legal/ToS review and enabled; configure a real LLM key.
7. Reconcile the backend: either migrate to Supabase Auth + Cloudflare Worker as documented, or update the planning docs to reflect the custom Node/JWT stack actually in use.
8. Verify SMS auto-read, camera/QR, geofencing, and home-screen widgets on real hardware; wire up the iOS widget extension in Xcode.
9. Confirm/implement A6 Password Reset as a distinct flow.
10. Implement S2 (Quick Settings Tile) and S5/S6 (forced upgrade / maintenance mode), or drop them from spec if out of scope.
