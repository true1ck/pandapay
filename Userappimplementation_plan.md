# PandaPay User App — Detailed Implementation Plan (Flutter, Android-first)

**Companion to:** [`product-plan.md`](./product-plan.md) · [`ui-spec.md`](./ui-spec.md) · [`database.sql`](./database.sql) · [`adminimplementation_plan.md`](./adminimplementation_plan.md)

**Scope:** the 66-screen + 6-system-surface consumer application defined in `ui-spec.md`, built to the v1.0 production standard in `product-plan.md` §2.

**Stack decision (locked):** **Flutter** for 100% of UI on both applications. Android-first. Native code is written only where Flutter has no plugin surface — App Widget, Quick Settings Tile, geofence broadcast receiver, SMS reader — and each of those is a thin Kotlin shim behind a `MethodChannel`, never business logic.

---

## 0. How to Read This Plan

| Concept | Meaning |
|---|---|
| **Workstream (UA-n)** | A shippable vertical slice. Maps to a product-plan phase. |
| **Task (UA-n.m)** | One engineer-week or less of work with a single owner. |
| **Sub-task (UA-n.m.k)** | The concrete engineering unit: one PR, one review, one merge. |
| **DoD** | Definition of Done — the assertion that must be true, testable. |
| **Blocks / Blocked by** | Hard sequencing dependency. |

**Universal Definition of Done** — no sub-task merges without all of these:
1. Unit tests for logic, widget tests for UI, golden test for any screen with a defined visual spec.
2. All four `S4` states implemented: loading (skeleton, never blank) · empty · error (plain language + cause + retry) · offline.
3. Strings externalized to ARB. No hardcoded user-facing text.
4. Accessibility: 48dp targets, semantic labels, 200% text scale without overflow, meaning never encoded in colour alone.
5. Every financial figure rendered through the shared `MoneyText`/`RewardBadge` widgets that force an estimated/confirmed badge (product-plan §5.10). **A raw `Text('₹$x')` for a financial value fails review.**
6. Analytics/crash breadcrumb added for the failure paths.
7. `flutter analyze` clean, `dart format` applied, CI green.

---

## 1. Architecture

### 1.1 Layering (strict, enforced by import lint)

```
lib/
├── main.dart
├── app/                      # bootstrap, router, theme, DI composition root
├── core/                     # pure Dart, zero Flutter imports
│   ├── money/                # Money value type, lakh/crore formatting
│   ├── result/               # Result<T,E>, no exceptions across layers
│   ├── clock/                # injectable clock — all date math is testable
│   └── logging/
├── data/
│   ├── local/                # drift DB, DAOs, migrations  (database.sql App. A)
│   ├── remote/               # Supabase client, DTOs, sync
│   ├── catalogue/            # card catalogue replica + data_version sync
│   └── repositories/         # the ONLY thing features may talk to
├── domain/                   # entities + use cases; pure Dart, unit-testable
│   ├── entities/
│   ├── engine/               # ⭐ recommendation engine — zero Flutter, zero IO
│   └── usecases/
├── features/                 # one folder per ui-spec group (a/, b/, c/ ...)
│   └── <group>/<screen>/     # screen.dart, controller.dart, widgets/
├── platform/                 # MethodChannel wrappers for the Kotlin shims
└── l10n/
```

**Enforced rules:**
- `domain/` may not import `package:flutter/*` or `data/`. Checked in CI by a custom `import_lint` config.
- `features/` may not import `data/local` or `data/remote` directly — only `data/repositories`.
- `domain/engine/` may not perform IO of any kind. It is a pure function of `(context, cards, state, rules) -> ranked list`. This is what makes the ranking spec in ui-spec B1 exhaustively testable.

### 1.2 State management
**Riverpod 2 (code-generated)**. Rationale: compile-time-safe DI, trivially overridable in tests, `AsyncValue` maps 1:1 onto the mandated loading/error/data states, and `keepAlive` gives us a natural home for the always-warm recommendation engine.

### 1.3 Navigation
**go_router**, declarative, with typed routes. Deep links are a hard requirement (ui-spec §1) for: scan result, transaction detail, card detail, every tracker, needs-review queue. Max 3 levels from tab root.

### 1.4 Offline-first data flow (non-negotiable)
```
UI  ->  Repository  ->  drift (SQLite)          [always, synchronously]
                          |
                          +-> sync outbox  ->  Supabase   [opportunistic]
```
The device SQLite is the source of truth for user data. The network is never in the read path. **Any code path where a screen awaits a network call before rendering a recommendation is a defect**, and CI asserts this by running the engine test suite with the network layer replaced by a throwing stub.

### 1.5 Package decisions

| Need | Package | Note |
|---|---|---|
| Local DB | `drift` | Typed, migration-tested, streams for reactive UI |
| DI/state | `riverpod` + `riverpod_generator` | |
| Routing | `go_router` | |
| QR | `mobile_scanner` | Free, no licence (product-plan §13) |
| UPI handoff | `url_launcher` + custom Android intent shim | `upi://pay` |
| PDF | `syncfusion_flutter_pdf` | On-device, password never leaves device |
| Geofence | `geofence_service` / native shim | OS geofence API only, never continuous GPS |
| Secure storage | `flutter_secure_storage` | Session tokens, biometric gate |
| Encryption at rest | `sqlcipher_flutter_libs` | product-plan §17 |
| Crash | `sentry_flutter` (self-hosted GlitchTip DSN) | |
| Backend | `supabase_flutter` | |
| Charts | `fl_chart` | E9/E11 only |
| Files | `file_picker`, `share_plus` | F2, F6 |
| Notifications | `flutter_local_notifications` | Local scheduling; FCM for pushes |

---

## 2. Workstream Map

| WS | Name | product-plan phase | Effort | Blocked by |
|---|---|---|---|---|
| **UA-0** | Foundation & scaffolding | — | 1.5 wk | DB-1 |
| **UA-1** | Card catalogue + card management | 1 | 2 wk | UA-0, DB-2 |
| **UA-2** | Recommendation engine | 1 | 2 wk | UA-1 |
| **UA-3** | Home, comparison, override, calculator | 1 | 2 wk | UA-2 |
| **UA-4** | QR scan → recommend → UPI handoff | 2 | 3 wk | UA-3 |
| **UA-5** | Transaction tracking (4 channels) | 3 | 5 wk | UA-1 |
| **UA-6** | Trackers & insights | 4 | 3 wk | UA-5 |
| **UA-7** | Auth, sync, backup, export | 5 | 4 wk | UA-0, DB-4 |
| **UA-8** | Location, geofence, widget, tile | 6 | 4 wk | UA-3 |
| **UA-9** | Crowdsource contribution client | 7 | 2 wk | UA-4, DB-6 |
| **UA-10** | Retention & tools (reports, travel, EMI…) | 8 | 3 wk | UA-6 |
| **UA-11** | Production hardening | 9 | 4 wk | all |
| **UA-12** | Legal & compliance | 10 | 2 wk | UA-7 |
| **UA-13** | Onboarding + closed beta | 9, 11 | 4 wk | all |

**Critical path:** UA-0 → UA-1 → UA-2 → UA-3 → UA-4 → UA-9 (the core loop and the moat).
**Parallelizable from week 4:** UA-5 (tracking) and UA-7 (backend) run alongside UA-3/UA-4.
**Start on day 1, blocking nothing:** Play SMS Permissions Declaration application (product-plan §5.1) and the 40–50 card data-capture task (UA-1.1).

---

# UA-0 · Foundation & Scaffolding  `1.5 wk`

### UA-0.1 Repository & toolchain
- **UA-0.1.1** Create Flutter project, pin SDK in `.fvmrc`, set package id `app.pandapay`, min SDK 24, target SDK current (Play requirement, product-plan §8.3).
- **UA-0.1.2** Flavors: `dev` / `beta` / `prod` — separate app ids, separate Supabase projects, separate Sentry DSNs. Beta users must never write to prod data.
- **UA-0.1.3** `analysis_options.yaml`: `flutter_lints` + custom rules — ban `print`, ban `DateTime.now()` outside `core/clock`, ban direct `Text` of a `Money`.
- **UA-0.1.4** CI (GitHub Actions): analyze → test → build APK → upload artifact. Fail on coverage drop below 70% in `domain/`.
- **DoD:** clean CI on an empty app; three flavors install side by side.

### UA-0.2 Core primitives
- **UA-0.2.1** `Money` value type — integer paise internally, never `double` for currency. Indian formatting (lakh/crore), ₹ symbol, `format(compact: true)`.
- **UA-0.2.2** `Result<T,E>` + typed `AppError` hierarchy (`NetworkError`, `ParseError`, `PermissionError`, `DataStaleError`). **No exceptions cross a layer boundary** — this is what makes "no silent failures" (product-plan §2.1) mechanically enforceable.
- **UA-0.2.3** `Clock` abstraction + `TestClock`. All cycle/period/expiry math depends on it. Without this, every tracker test is flaky.
- **UA-0.2.4** `Confidence` enum + `RewardBadge`/`MoneyText` widgets that *require* a confidence argument. Compile-time enforcement of product-plan §5.10.
- **DoD:** `Money` passes a property test for round-trip formatting across 0–10^9 and negative values; `MoneyText` cannot be constructed without a confidence.

### UA-0.3 Local database (drift)
- **UA-0.3.1** Implement the on-device schema from `database.sql` Appendix A as drift tables.
- **UA-0.3.2** Migration framework + `schema_v1.json` snapshot; a test that migrates v1→vN on a fixture DB and asserts row preservation.
- **UA-0.3.3** SQLCipher wiring; key in `flutter_secure_storage`, generated on first run. Add a "key lost" recovery path that offers restore rather than a crash loop.
- **UA-0.3.4** Seed loader for the bundled catalogue + POI bundle at first launch, with progress UI (screen A1 requires progress if >1s).
- **DoD:** cold install populates catalogue in <2s on a mid-range device; migration test green both directions; DB file unreadable without the key.

### UA-0.4 App shell
- **UA-0.4.1** `go_router` config with all routes + deep links declared upfront (stubs allowed).
- **UA-0.4.2** Bottom nav: Home · Cards · **raised SCAN FAB** · Activity (badge) · More.
- **UA-0.4.3** Theme: light/dark, WCAG AA verified pairs, text-scale-safe typography scale, card-art component.
- **UA-0.4.4** `S4` universal state widgets: `LoadingSkeleton`, `EmptyState`, `ErrorState`, `OfflineChip` — plus a `ScreenScaffold` that *requires* all four to be supplied. This is how "30–40% of real app work" (product-plan §9.6) stops being optional.
- **DoD:** a screen that omits an empty state does not compile.

### UA-0.5 Observability from day one
- **UA-0.5.1** Sentry/GlitchTip init per flavor, release tagging, PII scrubbing rules (**scrub: amounts, merchant names, VPAs, email addresses**).
- **UA-0.5.2** Structured logger with breadcrumb ring buffer, attached to crash reports and to the H9 feedback payload.
- **UA-0.5.3** Startup trace + a performance budget test asserting Home cold render <500ms on the reference device (ui-spec Performance).
- **DoD:** a forced test crash appears in the dashboard within 60s with no financial data in the payload.

---

# UA-1 · Card Catalogue & Card Management  `2 wk` → ui-spec A7–A9, C1–C8

### UA-1.1 ⭐ Card data acquisition (the largest single data task — start day 1)
> product-plan §14.2. 40–50 cards × ~30 fields, AI-extracted, **human-verified per card**. This is a data task, not a code task, and it is on the critical path for UA-2.
- **UA-1.1.1** Define the canonical card YAML schema mirroring `card_products` + child tables in `database.sql`.
- **UA-1.1.2** Build `tools/card_import.dart` — YAML → Postgres via the console API, with strict validation (rejects a card missing cap/milestone/fee/forex/fuel/lounge fields).
- **UA-1.1.3** AI first-pass extraction from official T&C pages into YAML. **Capture everything §10 needs in one pass per card** (caps, milestone thresholds, fee-waiver spend, lounge quotas, forex markup, fuel caps, benefits, cycle rules) — collecting once per card, not five times.
- **UA-1.1.4** Human verification pass with a signed-off checklist per card; sets `verified_at`. A card cannot reach `published` without it (enforced by the DB CHECK constraint).
- **UA-1.1.5** Your own cards first, hand-verified, used as the golden fixtures for engine tests.
- **DoD:** 40+ cards `published`; every one has non-null verified_at; the import tool round-trips DB→YAML→DB with zero diff.

### UA-1.2 Catalogue replica & incremental sync
- **UA-1.2.1** Bundle a seed catalogue snapshot in the APK so a fresh install works with zero network.
- **UA-1.2.2** `CatalogueSyncService`: pull `v_card_catalogue_export where data_version > local_max`. Delta only — never the full catalogue (admin-console-plan §4.5).
- **UA-1.2.3** Trigger sync on: app foreground, post-login, manual pull, and on the `force_catalogue_sync_after` remote-config flag (urgent corrections).
- **UA-1.2.4** On a version bump affecting a card the user holds, recompute affected cap/milestone states and surface it in H10 What's New when user-visible.
- **DoD:** changing a cap in the console makes the device show the new number within one foreground cycle, with no app update. **This is the propagation acceptance test for admin-console-plan §4.5 — run it end to end.**

### UA-1.3 Card picker & add flow (A7, A8, C3, C8)
- **UA-1.3.1** Searchable, issuer-grouped picker with card art; multi-select with running count.
- **UA-1.3.2** Network filter chips (RuPay/Visa/MC/Amex-Diners).
- **UA-1.3.3** Duplicate product handling — allow, force a distinguishing nickname.
- **UA-1.3.4** "My card isn't listed" (A8) → `card_requests`. Photo capture allows **card face only**, with an explicit warning never to photograph the number, plus a client-side reminder before upload.
- **DoD:** cannot proceed from A7 with 0 cards; duplicate add prompts for nickname; A8 submission appears in the console queue.

### UA-1.4 Card details & lifecycle (A9, C1, C2, C4)
- **UA-1.4.1** A9 per-card tracker inputs — each field states *why* it's needed; all skippable except nickname-on-duplicate. Skipping the credit limit disables E3 for that card **with an inline explanation, never a silent gap**.
- **UA-1.4.2** C1 My Cards: drag-reorder priority, per-card cap bar, utilization bar, next due date, active/archived filter.
- **UA-1.4.3** C2 Card Detail, six tabs: Rewards (+ freshness date) · Caps · Milestones · Fees · Benefits · Statement.
- **UA-1.4.4** C4 Edit + **archive, never hard-delete when history exists** (R4), with copy explaining history is preserved.
- **DoD:** archiving a card with transactions preserves every transaction and removes it from ranking.

### UA-1.5 Static reference screens
- **UA-1.5.1** C5 Benefits Cheat Sheet — cross-card, grouped by benefit type, fully offline.
- **UA-1.5.2** C6 Points & Expiry — per-program balance, ₹ estimate, expiry urgency colouring **plus icon/text** (never colour alone), manual balance correction feeding reconciliation.
- **UA-1.5.3** C7 Report Wrong Data — pre-filled card+field, shown vs claimed value, optional source link → `data_error_reports`. Confirmation sets the expectation: *"We verify before publishing."*
- **DoD:** C5 and G4 render with airplane mode on and no session.

---

# UA-2 · Recommendation Engine  `2 wk` ⭐ the product

> `domain/engine/` — pure Dart, no Flutter, no IO. Everything else in the app is a delivery mechanism for this.

### UA-2.1 Engine input contract
- **UA-2.1.1** `RecommendationContext { amount?, category?, mcc?, vpa?, rail, isP2P, travelMode, timestamp }`.
- **UA-2.1.2** `CardSnapshot { product, rules, capStates, milestoneStates, feeWaiverState, utilization, overrides, acceptanceHints }` — assembled by a repository, passed in whole. The engine never queries.
- **UA-2.1.3** `Recommendation { card, expectedValue, confidence, exclusionReason?, reasonLines[], isOverride }` — `reasonLines` is a **required** field, because "Why this card?" (§4.4) is not optional garnish.

### UA-2.2 Ranking implementation — exactly as specified (ui-spec B1)
- **UA-2.2.1** RuPay/UPI exclusion gate: in a UPI-QR context, non-RuPay cards are **excluded and shown greyed with a reason**, never silently dropped. *(product-plan §4.1: recommending a non-RuPay card for a QR = declined payment = instant trust death.)*
- **UA-2.2.2** `effective_rate = category_rate × point_value`, unit-normalized across cashback / points-per-₹100/150/200 / miles.
- **UA-2.2.3** Cap blending: when `cap_remaining < amount`, split the amount and blend capped and post-cap rates. Test at the exact boundary and 1 paisa either side.
- **UA-2.2.4** Milestone bonus: add value only when this spend *materially* advances a milestone; define "materially" as a configurable fraction of the remaining threshold and expose the reasoning line.
- **UA-2.2.5** Travel mode: subtract forex markup (incl. GST on markup).
- **UA-2.2.6** Manual override: force to top, labelled, with the un-overridden winner still visible so the user can see the cost of their own rule.
- **UA-2.2.7** Fuel surcharge waiver applied as an additive value at fuel MCCs.
- **UA-2.2.8** Deterministic tie-break: higher confidence → lower utilization impact → user's manual priority order.

### UA-2.3 Explanation generator
- **UA-2.3.1** Build `reasonLines` from the actual arithmetic used (base rate, cap remaining, ₹/point, milestone contribution, override chip) — generated **from** the computation, never re-derived, so an explanation can never disagree with the number.
- **UA-2.3.2** Freshness line: *"verified March 2026"* per card (§5.11).
- **DoD:** a golden test asserts that for every fixture the sum of the reason lines reconciles to the displayed expected value.

### UA-2.4 Adjacent calculators
- **UA-2.4.1** Credit utilization (E3): per-card and overall, 30% threshold, split recommendation.
- **UA-2.4.2** Multi-card split optimizer (G2/§10.3): respect caps **and** utilization thresholds simultaneously; greedy fill by marginal ₹/₹ with a bounded search.
- **UA-2.4.3** Billing-cycle float (E7/§10.6): interest-free days per card from statement day + grace period.
- **UA-2.4.4** EMI advisor (G3/§10.13): total interest, effective cost, **rewards forfeited**, verdict line.
- **UA-2.4.5** UPI-vs-swipe comparison (§10.7): rank both rails, surface the delta.

### UA-2.5 Engine test suite ⭐ the highest-value tests in the codebase
- **UA-2.5.1** Golden fixture set: ≥30 scenarios covering every rule interaction (cap boundary, milestone flip, override, P2P, travel, fuel, no-limit card, archived card, zero cards).
- **UA-2.5.2** Property tests: ranking is total and deterministic; excluded cards never rank; expected value is monotonic in amount within a cap band.
- **UA-2.5.3** Performance test: full ranking over 15 cards in <16ms so Home never drops a frame.
- **UA-2.5.4** Regression harness — every user-reported "wrong recommendation" becomes a permanent fixture before the fix lands.
- **DoD:** 100% branch coverage of `domain/engine/`. Non-negotiable; this is the one place where the number is the product.

---

# UA-3 · Home, Comparison, Overrides, Calculator  `2 wk` → B1, B4, B5, B6, B7, B8

### UA-3.1 B1 Home — most important screen
- **UA-3.1.1** Context line (location / near / "pick a category"), tappable to correct.
- **UA-3.1.2** Hero recommendation card — art, plain-language reward, est/confirmed badge.
- **UA-3.1.3** Expandable "Why this card?" rendering `reasonLines`.
- **UA-3.1.4** Backup card row from acceptance data (§10.8).
- **UA-3.1.5** Category chips that re-rank and override the geofence guess.
- **UA-3.1.6** Alerts strip: **max 2**, priority order cap-nearly-hit > fee-waiver deadline > points expiring > bill due > needs-review count.
- **UA-3.1.7** All B1 states: no location permission (chips primary, **no nag**) · unknown location · offline · no cards · cold-start skeleton.
- **DoD:** cold render <500ms measured in CI on the reference device; no network call in the render path (asserted with a throwing network stub).

### UA-3.2 B4 Comparison view — sortable table, per-row expandable "why", reachable from B1 and B3.
### UA-3.3 B5 Merchant search — trigram search over bundled + cached merchants, recent searches, category fallback.
### UA-3.4 B6 Manual quick-add — **under 3 taps**; amount keypad auto-focused, merchant autocomplete, card defaults to last used, category auto-filled; immediate cap/milestone/utilization update; undo snackbar.
### UA-3.5 B7 Big-purchase calculator — side-by-side ₹ across all cards, split → G2, EMI → G3, milestone-completion flag.
### UA-3.6 B8 Manual overrides manager — list, edit, disable, delete; empty state explains creation from B3. *(A forgotten override silently producing worse advice is a trust bug — this screen is why it exists.)*

---

# UA-4 · QR Scan → Recommend → UPI Handoff  `3 wk` ⭐ FLAGSHIP → B2, B3

### UA-4.1 Scanner (B2)
- **UA-4.1.1** `mobile_scanner` full-screen, framing guide, torch, haptic on detect.
- **UA-4.1.2** **Gallery import** — decode a QR from a screenshot (common for online/UPI-link payments).
- **UA-4.1.3** Camera permission flow: in-context rationale, denied state with settings deep link, never a hard block.
- **UA-4.1.4** Works fully offline — assert with a network-throwing stub in the widget test.

### UA-4.2 UPI QR parsing
- **UA-4.2.1** Parse `upi://pay` params: `pa`, `pn`, `mc`, `am`, `tn`, `tr`, `cu`. Tolerant to unknown params and case.
- **UA-4.2.2** **P2P detection**: absent `mc` + personal-VPA heuristics (handle patterns, known PSP suffixes) → *"Credit cards can't be used for personal transfers"* + suggest bank-account UPI.
- **UA-4.2.3** Non-UPI QR → *"That's not a UPI code."*
- **UA-4.2.4** ⚠️ **Field validation task (product-plan §18 risk):** `mc` coverage in the wild is unverified. **Week 1 of this workstream: scan 50+ real merchant QRs across categories/cities and record `mc` presence rate.** If coverage is poor, the VPA-lookup + user-pick fallback (UA-4.3.6) becomes the primary path and its UX budget must increase. *Do not build the rest of B3 before this number exists.*

### UA-4.3 Scan Result (B3)
- **UA-4.3.1** Merchant name + detected category, **both editable** — corrections feed the crowdsource DB.
- **UA-4.3.2** Amount pre-filled from `am`, else numeric entry.
- **UA-4.3.3** Ranked card list: card · rate · ₹ value · cap status · reason chip.
- **UA-4.3.4** RuPay/UPI eligibility rendering — greyed non-RuPay with *"Not usable via UPI — swipe this instead."*
- **UA-4.3.5** UPI-vs-swipe comparison when both rails are viable.
- **UA-4.3.6** `mc` absent → local VPA cache lookup → else one-tap category pick, **then remembered for that VPA**.
- **UA-4.3.7** "Always use this card here" → creates a VPA-keyed override (→ B8).
- **UA-4.3.8** "This card wasn't accepted" → records acceptance data and **re-ranks immediately**.

### UA-4.4 UPI handoff
- **UA-4.4.1** Build `upi://pay?pa=&pn=&am=&cu=INR&tn=` and launch via Android intent. **The user never rescans.**
- **UA-4.4.2** No UPI app installed → recommendation only + copy-VPA action.
- **UA-4.4.3** Return-from-UPI handling: prompt to confirm the payment happened and log it (bridging to UA-5 tracking).
- **UA-4.4.4** iOS degraded path — scan + recommend works, explicit copy that the user must switch apps manually (product-plan §4.1).
- **DoD:** scan → recommendation rendered in **<1s** end to end, offline, on the reference device.

### UA-4.5 Capture instrumentation (product-plan §6.5 — build rule)
- **UA-4.5.1** From the **first shipped scan**, write `{vpa, name, mcc, grid-snapped coords}` to the local `contribution_outbox`, gated on consent. *Data you didn't collect is gone forever.*
- **UA-4.5.2** Grid-snap coordinates to 4dp **on-device before they touch the outbox** — the app must be structurally incapable of transmitting a precise location.
- **DoD:** an instrumentation test asserts no outbox row ever contains >4dp coordinates, an amount, or a user id.

---

# UA-5 · Automatic Transaction Tracking  `5 wk` ⭐⭐⭐ → D1–D6, F1–F4, F7

> Built **redundantly** so no single external approval gates the product (product-plan §5).

### UA-5.1 Parser framework (shared by all channels)
- **UA-5.1.1** `TransactionParser` interface + registry keyed by (channel, issuer, sender pattern), fed by the `parser_patterns` table so **parsers can be fixed server-side without an app release**.
- **UA-5.1.2** Extraction contract: amount, merchant, date, card hint (issuer + last-4 as it appears in the *message* — used for matching only, never persisted), rail, direction (debit/credit/refund).
- **UA-5.1.3** Parser corpus + test harness: one fixture file per issuer per channel, ≥5 real samples each. **Closed beta (UA-13) exists primarily to grow this corpus.**
- **UA-5.1.4** Failure telemetry: on parse failure, emit the **redacted shape only** (digits→`#`, names→`X`) to `parser_failures`. The DB CHECK constraint rejects anything containing a digit — belt and braces.

### UA-5.2 Channel 2 — Email forwarding ⭐ THE GUARANTEED PATH (build first)
> Needs permission from nobody; works on Android and iOS identically; this is what makes v1.0 ship with automatic tracking.
- **UA-5.2.1** Cloudflare Email Routing → Worker: accept mail at `<local_part>@in.pandapay.app`, verify the sender is a known bank, insert `inbound_emails`, run parsers, insert transaction or `needs_review_item`.
- **UA-5.2.2** Worker also runs the **policy-keyword scan** (admin-console-plan §4.2 B2) and sets `policy_keyword_hit`. *Same pipeline, one extra pass — no new infrastructure.*
- **UA-5.2.3** F3 setup UI: unique address + copy button; **per-provider step-by-step with screenshots** (Gmail · Outlook · Yahoo · Other); explicit handling of Gmail's forwarding-address verification code; live status *"Waiting for first email…" → "Connected — 3 received"*; troubleshooting + test-email action; **skippable at any point**.
- **UA-5.2.4** Address rotation + revoke.
- **DoD:** a real forwarded HDFC/Axis/SBI alert produces a correctly parsed transaction on-device within 60s. Setup completes in ≤3 minutes in a timed usability run.

### UA-5.3 Channel 1 — SMS with Play declaration (Android)
- **UA-5.3.1** **Submit the Play Permissions Declaration on day 1 of the project** (free, slow, non-blocking). Treat approval as upside, never as the plan.
- **UA-5.3.2** `RECEIVE_SMS`/`READ_SMS` behind a runtime feature flag keyed to declaration approval — the build ships either way.
- **UA-5.3.3** Kotlin `BroadcastReceiver` shim → MethodChannel → Dart parser. **Parsing is 100% on-device; raw SMS never leaves the phone**, and only financial fields are extracted. Document this architecture in the declaration form itself.
- **UA-5.3.4** F4 toggle + in-context explanation of on-device parsing.

### UA-5.4 Channel 4 — Statement PDF import ⭐⭐ the accuracy anchor (F2)
- **UA-5.4.1** File picker → password prompt (*"processed on your device, never uploaded"*). **Password held in memory only, never persisted, never transmitted.**
- **UA-5.4.2** Per-issuer table extraction with `syncfusion_flutter_pdf`; layout profiles per issuer format.
- **UA-5.4.3** Preview of detected transactions → duplicate check → confirm import.
- **UA-5.4.4** **Reconciliation**: match statement rows to existing estimated transactions, flip `reward_state` to `confirmed`, write exact points to `points_ledger`, update balances. *This is what makes the estimated/confirmed distinction real.*
- **UA-5.4.5** Emit anonymized `effective_rate_samples` (bucketed spend, no identity) — **this is the data feeding Source B1 divergence detection** (admin-console-plan §4.2).
- **UA-5.4.6** Errors: wrong password · unsupported issuer format · corrupt file — each with a next step and a "report this format" action.

### UA-5.5 Channel 3 — SMS bulk import (F4) & IMAP fallback (F7)
- **UA-5.5.1** One-time SMS backup-file import for onboarding backfill; needs no special permission.
- **UA-5.5.2** F7 IMAP with app password, server auto-detect, sender filters, test connection. **Must warn** that Google is progressively restricting basic auth and to fall back to F3 if it breaks. Fallback only — do not architect around it.

### UA-5.6 Deduplication (§5.8) & transaction management
- **UA-5.6.1** Dedupe on (amount + merchant + date + card) using the same hash definition as `pandapay.dedupe_hash` in `database.sql` — **one algorithm, two implementations, one shared test vector file** so device and server can never disagree.
- **UA-5.6.2** D5 Duplicate Review: side-by-side, merge / keep both / delete one, with the reason explained.
- **UA-5.6.3** D1 list (search, filters, sticky month summary, D4 badge), D2 detail (source + reconciliation status + "a better card existed" panel), D3 edit (recomputes caps/milestones on save).
- **UA-5.6.4** Split, recategorize, mark ignored (refund/reversal/transfer), delete.
- **UA-5.6.5** D6 Missed Opportunities — used vs better card, ₹ lost, running 90-day total, filterable to reveal patterns.

### UA-5.7 D4 Needs Review Queue (§5.7)
- **UA-5.7.1** Raw text shown verbatim for context; one-tap fill of missing fields; "Not a transaction" dismiss that feeds parser learning; bulk dismiss.
- **DoD:** an injected unparseable message is **never** dropped — it always lands in D4 and the D1 badge increments. This is asserted by an integration test, because "never drop data silently" is a promise, not a preference.

---

# UA-6 · Trackers & Insights  `3 wk` → E1–E8, E11

### UA-6.1 Period engine
- **UA-6.1.1** Period resolver for statement-cycle / calendar-month / quarter / annual / card-anniversary, all through `Clock`. Handles the 29–31 day-of-month edge (statement day 31 in February) explicitly.
- **UA-6.1.2** State recomputation service: incremental on transaction write, full rebuild on catalogue `data_version` change or period rollover.
- **UA-6.1.3** Rebuild-on-demand for corrections (edit/delete/merge must be exact, not eventually-consistent).

### UA-6.2 Tracker screens
- **UA-6.2.1** E2 Caps & Limits — all capped benefits **including fuel-surcharge caps**, sorted closest-to-cap, actionable copy (*"₹300 left on SBI 5% — switch to Axis Ace after that"*).
- **UA-6.2.2** E3 Credit Utilization — per-card + overall, 30% threshold, Optimize action, **explicit disclaimer that it is informational and not a credit-score guarantee**; cards without a limit excluded with a prompt to add one.
- **UA-6.2.3** E4 Milestones — progress, ₹ remaining, days left, reward at stake, flag when chasing beats base rate.
- **UA-6.2.4** E5 Fee Waivers — threshold, progress, days to anniversary, urgency.
- **UA-6.2.5** E6 Lounge — visits vs quota per network/card, quarter reset, **manual "log a visit"** (banks rarely message this).
- **UA-6.2.6** E7 Float timeline · E8 Due-date calendar with per-card reminder toggles.
- **UA-6.2.7** E1 Insights hub — tiles with live headline numbers, ordered by nearest deadline.
- **UA-6.2.8** E11 Spending overview — context, explicitly not a budgeting tool.
- **DoD:** a transaction that crosses a cap updates E2, B1's alert strip, and the hero recommendation within one frame of saving.

---

# UA-7 · Auth, Sync, Backup, Export  `4 wk` → A3–A6, F5, F6, H2

### UA-7.1 Optional-account architecture (§7.2)
- **UA-7.1.1** Local-only mode is **first-class**: every repository works with a null session. No nag, no dark patterns, no degraded core loop.
- **UA-7.1.2** A3 account choice with plain-language consequences and a "recommended" badge on local mode.
- **UA-7.1.3** **Local → account upgrade with zero data loss**: local rows are assigned the new `profile_id` and replayed through the sync outbox in dependency order. Test with a 2,000-transaction local DB.

### UA-7.2 Auth lifecycle (A4, A5, A6, H2)
- **UA-7.2.1** Email+password and passwordless magic link (preferred); no phone OTP (costs money per SMS).
- **UA-7.2.2** Password rules shown *before* submission, strength meter, show/hide. Network failure **preserves entered data**.
- **UA-7.2.3** Login errors: generic wrong-credentials message that **does not reveal whether the email exists**; unverified; rate-limited; offline.
- **UA-7.2.4** Reset flow with deep link and clear token-expiry re-request path.
- **UA-7.2.5** Biometric unlock offer after first successful login; session expiry handling; silent refresh in A1.
- **UA-7.2.6** H2 **account deletion** — states exactly what is deleted and by when *including backups*, typed confirmation, grace period → `deletion_requested_at`/`deletion_due_at`. DPDP requirement (§8.2).

### UA-7.3 Sync + conflict resolution (F5) — *design resolution before writing sync code*
- **UA-7.3.1** Outbox pattern: every local write appends to `sync_outbox` with a monotonic `client_seq`.
- **UA-7.3.2** Push: batched, idempotent by `(device_id, client_seq)`; server appends to `change_log`.
- **UA-7.3.3** Pull: `server_seq > cursor`, apply with **per-field last-write-wins**, append-only transaction log as the tiebreaker.
- **UA-7.3.4** **Every resolution writes a `sync_conflicts` row** — F5 renders the conflict log. Silent resolution without a record is prohibited.
- **UA-7.3.5** Two-device test matrix: offline edits on both, delete-vs-edit, clock skew, app killed mid-push, token expiry mid-sync.
- **DoD:** the two-device matrix runs in CI as an integration test and **loses zero user edits** in all cases.

### UA-7.4 Backup, restore, export
- **UA-7.4.1** F5 backup status + restore entry point (destructive, double-confirmed).
- **UA-7.4.2** F6 export — scope (transactions/cards/all) × format (CSV/JSON) → share sheet. *"Your data is yours."*
- **UA-7.4.3** Import-back path so an export is a genuine exit route, not a gesture.

---

# UA-8 · Location, Geofencing, Widget, Tile  `4 wk` → B1 context, S1, S2, S3, H3, H5

### UA-8.1 Bundled OSM POI pipeline (₹0, no paid API)
- **UA-8.1.1** `tools/osm_extract/` — Geofabrik India extract → osmium filter to retail/fuel/dining POIs → normalized SQLite, few MB, shipped in-app.
- **UA-8.1.2** Category mapping from OSM tags to `spend_categories`. *Category beats brand: the engine needs "supermarket", not "DMart Powai".*
- **UA-8.1.3** **ODbL compliance**: attribution in H8, and publish the filtered derived extract under ODbL. Non-optional licence obligation.
- **UA-8.1.4** H5 re-download bundled POI data; versioned so it can refresh without an app release.
- **UA-8.1.5** ❌ **Explicitly out of scope: any scraping of Google Maps/Places.** For an app selling financial trust, being caught scraping is an extinction-level event (product-plan §11.1).

### UA-8.2 Geofencing (§11.2)
- **UA-8.2.1** OS geofence APIs only — **never continuous GPS**. Register the top-N nearest known merchants, re-registering on significant location change.
- **UA-8.2.2** Kotlin geofence receiver shim → notification with the recommendation, computed **on-device from local data**.
- **UA-8.2.3** Dwell debounce (`geofence_dwell_seconds` remote config) to avoid drive-by firings.
- **UA-8.2.4** Permission flow: in-context rationale only, background-location rationale separate, **app fully usable if denied** (B1 falls back to chips, no nag).

### UA-8.3 H3 Notification discipline ⭐ uninstall prevention
> Notification spam is the #1 uninstall driver for location-aware apps. Default conservative.
- **UA-8.3.1** Per-category toggles: location · caps · milestones · fee waivers · bills · expiry · monthly report · needs-review.
- **UA-8.3.2** **Per-merchant mute list** ("Mute here" action directly on the geofence notification).
- **UA-8.3.3** **Quiet hours** + **daily frequency cap** enforced centrally in a `NotificationGate` that every notification path must pass through — no bypass route exists in code.
- **UA-8.3.4** S3 notification set with deep links to the exact screen.

### UA-8.4 System surfaces
- **UA-8.4.1** S1 Home-screen widget (Kotlin Glance) — small (best card) / medium (best card + reason + top alert), sensible unknown-location fallback, tap → B1.
- **UA-8.4.2** S2 Quick Settings tile → B2 scanner. Plus app-icon long-press shortcut and lock-screen path — mitigations for "scanning needs a deliberate camera open" (product-plan §3).
- **UA-8.4.3** Widget data pipeline: the widget reads a small precomputed snapshot written by the app, so it never runs the engine on the UI thread of the launcher.

---

# UA-9 · Crowdsource Contribution Client  `2 wk` → E12, H4

### UA-9.1 Contribution pipeline
- **UA-9.1.1** Outbox flush with backoff; batched; drops silently on repeated rejection **but never blocks or slows a user action**.
- **UA-9.1.2** Payload construction that is **structurally incapable** of carrying identity: a typed `Contribution` sealed class with no user field, no amount field, and coordinates already snapped. Enforced by a unit test that reflects over the serialized JSON keys against an allowlist.
- **UA-9.1.3** Rotating salted `device_hash` for rate limiting only; rotates on schedule so it cannot become a durable identifier.
- **UA-9.1.4** Acceptance reporting from B3 ("wasn't accepted") → `acceptance_reports`.

### UA-9.2 Transparency & control
- **UA-9.2.1** E12 My Contributions — merchants mapped/confirmed, *"you've helped X other users"*, contribution toggle, and a plain restatement of exactly what is shared (never identity, amounts, or exact location).
- **UA-9.2.2** H4 Privacy & Permissions — per-permission state/purpose/settings link, plain-language on-device vs uploaded vs anonymized summary, **opt-out honoured immediately** (flush stops, outbox cleared), consent history with timestamps.
- **DoD:** toggling contributions off clears the outbox within one second and no further contribution request is ever issued; verified by a network-capture test.

---

# UA-10 · Retention & Tools  `3 wk` → E9, E10, G1–G4

- **UA-10.1** E9 **Monthly Savings Report** ⭐⭐ — headline ₹ extra earned, breakdown (earned / extra vs single-card baseline / value missed), category breakdown, best card, MoM trend, **share as image**. First month shows *"building your first report"*, never a misleading zero. *Strongest retention lever; costs nothing to compute.*
- **UA-10.2** E10 Portfolio Audit — annual fee vs rewards earned, break-even, usage frequency, unused benefits.
- **UA-10.3** G1 Travel Mode — re-rank by forex markup, per-card comparison, lounge eligibility, travel insurance, **DCC warning explainer**, destination acceptance notes.
- **UA-10.4** G2 Split Planner · G3 EMI Advisor (UI over the UA-2.4 engines).
- **UA-10.5** G4 Emergency Card Info — per-issuer hotline, block procedure, international collect number, one-tap dial. **Works with zero network and zero login** — bundled, not fetched.

---

# UA-11 · Production Hardening  `4 wk` → S4, S5, S6, H1, H5–H10

### UA-11.1 Remote control (§9.2)
- **UA-11.1.1** Feature-flag client with local cache + safe defaults (a flag fetch failure must never disable a working feature).
- **UA-11.1.2** S5 Forced upgrade — blocking screen with store link when below `min_supported_version`.
- **UA-11.1.3** **Kill switch** for the recommendation engine — when killed, the app shows an honest degraded state rather than bad advice. *A wrong recommendation is worse than no recommendation.*
- **UA-11.1.4** S6 Maintenance/degraded — *"Sync paused — recommendations still work offline."* Core function stays usable.

### UA-11.2 Quality states sweep (§9.6)
- **UA-11.2.1** Audit all 66 screens against the S4 four-state requirement; fix gaps. Track as a checklist with one row per screen — this is ~30–40% of the real work and will not survive being left implicit.
- **UA-11.2.2** Error-copy pass: every message names the cause and a next step, never a raw exception.

### UA-11.3 Accessibility & platform hygiene (§9.8)
- **UA-11.3.1** 200% text-scale sweep with golden tests at 1.0×/1.5×/2.0× on the 15 highest-traffic screens.
- **UA-11.3.2** TalkBack pass incl. card-art semantic labels; contrast audit both themes; verify no state is colour-only.
- **UA-11.3.3** Dark mode completion; target API level current.

### UA-11.4 Support (§9.5)
- **UA-11.4.1** H9 Feedback — free-text + optional diagnostics **shown to the user before sending**; separate paths (bug · wrong card data · request a card · general); states a response expectation.
- **UA-11.4.2** H7 Help & FAQ — searchable, **offline-readable**, covering setup, tracking channels, why a recommendation looked wrong, accuracy, privacy.
- **UA-11.4.3** H10 What's New — shown once after update, **especially when reward data or ranking logic changed**, so users understand why advice moved.
- **UA-11.4.4** H1 hub, H5 data & storage (counts, cache clear, POI re-download, reset-all double-confirmed), H6 appearance (theme, text size, card art, lakh/crore).

### UA-11.5 Performance & release engineering
- **UA-11.5.1** Startup budget enforcement in CI (Home <500ms, scan→rec <1s).
- **UA-11.5.2** R8/ProGuard rules, APK/AAB size budget, baseline profiles.
- **UA-11.5.3** Play internal-testing track wired to CI; signed release pipeline; staged rollout with a documented rollback (halt rollout + kill switch, since a store rollback is not instant).

---

# UA-12 · Legal & Compliance  `2 wk` → A2, A4, H2, H4, H8

- **UA-12.1** **Not-financial-advice disclaimer** — persistent and visible: A2 footer from the very first screen, H8, and inline on E3 (§8.1). Play separately requires financial apps to state they are not a regulated financial service.
- **UA-12.2** DPDP consent (§8.2) — A4 **separate, purpose-specific, unbundled** checkboxes: (required) Terms+Privacy · (optional) contribute anonymized merchant data · (optional) product emails. Consent version + timestamp persisted to `user_consents` for audit.
- **UA-12.3** Right to erasure — H2 deletion actually deletes **including backups within the stated window**; the stated window must be ≥ backup retention. Verify against the real retention configuration, not the intended one.
- **UA-12.4** Right to access/correct — served by F6 export and D3 transaction editing; document the mapping for the compliance record.
- **UA-12.5** ToS + Privacy Policy in plain language, hosted on the domain, covering: reward data may be inaccurate or stale · no liability for financial decisions · how contributions are used · the anonymization guarantee.
- **UA-12.6** **Play Data Safety declaration that matches actual behaviour exactly** — generated from a per-permission/per-data-type inventory checked against the code, not written from memory. A mismatch here is an enforcement event.
- **UA-12.7** Breach-notification procedure written down *before* it is needed.
- **UA-12.8** H8 open-source licences + **OpenStreetMap ODbL attribution**.

---

# UA-13 · Onboarding & Closed Beta  `4 wk` → A1–A11

### UA-13.1 Onboarding (§9.9) — *value before permissions; no permission prompt before A10*
- **UA-13.1.1** A1 splash: migrations with progress if >1s, silent session refresh, min-version check → S5. **Backend unreachable proceeds offline, never blocks.** Migration failure → recovery screen offering restore.
- **UA-13.1.2** A2 welcome + three value points + disclaimer.
- **UA-13.1.3** A3 → A7 → A9 → A10 → A11 flow with "set up later" always visible; **onboarding completion is never blocked on tracking setup**.
- **UA-13.1.4** A11 first-scan tutorial: animated demo → live camera with overlay → B3, skippable.
- **UA-13.1.5** Funnel instrumentation per step to find the real drop-off.

### UA-13.2 Closed beta (§9.10)
- **UA-13.2.1** Internal testing track → **20–30 real users** before opening to 500.
- **UA-13.2.2** ⭐ **Parser corpus collection** — real Indian bank messages across issuers are the only way to validate parsers. This is the primary purpose of the beta; instrument it deliberately with an in-app "share this message shape" flow rather than hoping for reports.
- **UA-13.2.3** Weekly triage: crash-free rate, D4 queue depth per user, wrong-recommendation reports (each becomes a permanent engine fixture), notification opt-out rate.
- **UA-13.2.4** Exit criteria to open to 500 users:
  - crash-free sessions ≥ 99.5%
  - parser success ≥ 90% across the top 6 issuers
  - zero unresolved data-loss reports
  - zero P0 wrong-recommendation defects open
  - median D4 queue depth < 3 per active user
  - restore drill passed on production backups

---

## 3. Testing Strategy

| Layer | What | Gate |
|---|---|---|
| Unit | `domain/` incl. engine, parsers, period math, dedupe | **100% branch coverage on `domain/engine/`**; 85% on `domain/` |
| Widget | Every screen × 4 S4 states | Every screen has all four |
| Golden | Top 15 screens × light/dark × 1.0/2.0 text scale | No unreviewed diffs |
| Integration | Onboarding, scan→pay, import→dedupe→reconcile, two-device sync | Green on every PR to `main` |
| Contract | Device dedupe hash == `pandapay.dedupe_hash`; catalogue export shape | Shared vector files, both sides |
| Manual | Real QR scans, real bank messages, real devices | Per release |

**Shared test-vector files** (`test/vectors/`) are consumed by the Flutter suite *and* by the DB pgTAP suite for dedupe and cap arithmetic. Two implementations agreeing on a shared vector set is the only defence against device/server drift on money math.

---

## 4. Risk Register (owned, with mitigations in-plan)

| Risk (product-plan §18) | Mitigation task | Trigger to act |
|---|---|---|
| Card data accuracy | UA-1.1.4 verification, UA-1.5.3 C7 reporting, freshness dates | Any C7 report on a published field |
| Parser fragility | UA-5.1.3 corpus, UA-5.1.4 telemetry, UA-5.7 queue | Parser success <90% for any issuer |
| SMS declaration rejected | UA-5.2 built **first** and independently | N/A — plan assumes rejection |
| QR `mc` coverage unknown | **UA-4.2.4 field study before building B3 fallbacks** | `mc` present in <70% of scans |
| Sync data loss | UA-7.3.5 matrix in CI, conflict log | Any lost-edit report |
| Notification spam → uninstall | UA-8.3 central `NotificationGate` | Opt-out rate >20% |
| Scope creep | §10 tracker list is endlessly expandable | Any new tracker before UA-11 completes |

---

## 5. Sequencing (solo + AI pairing, ~8–10 months)

```
M1  UA-0 ───────────── UA-1.1 (card data, runs continuously) ──────────────►
M2  UA-1 ── UA-2 ────────────────────────────────────────────────►
M3        UA-3 ── UA-4 (incl. mc field study wk1) ───►
M4                    UA-5 (email first) ─────────────────►
M5                    UA-5 ──── UA-6 ─────►      UA-7 ──────►
M6                              UA-8 ──────────────────────►
M7                                    UA-9 ── UA-10 ───────►
M8                                          UA-11 ─────────►
M9                                                UA-12 ── UA-13 beta ──►
M10                                                        launch to 500
```

**Do not skip UA-11 / UA-12 / UA-13 to launch sooner. For a financial application, they *are* the product.**
