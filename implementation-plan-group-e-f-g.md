# PandaPay — Implementation Plan: Group E (Trackers & Insights), Group F (Data Import & Sync), Group G (Tools & Modes)

**Companion to:** [`ui-spec.md`](./ui-spec.md) §Group E / §Group F / §Group G · [`product-plan.md`](./product-plan.md) · [`database.sql`](./database.sql) (the aspirational combined schema doc — see the note in the audit below on why the *real* schema is `db/supabase/migrations/0001–0017`, not this file, past line ~1800) · [`implementation-plan-group-c-d.md`](./implementation-plan-group-c-d.md) (Group C/D plan — several tasks below reuse or extend things it built) · [`Userappimplementation_plan.md`](./Userappimplementation_plan.md) (superseded architecture doc)

**Scope:** the 12 Group E screens (E1–E12), 7 Group F screens (F1–F7), and 4 Group G screens (G1–G4) — 23 of the 66 spec'd screens.

**Skill routing for every task below comes from this project's `CLAUDE.md`.** Don't re-derive it — the table there is already the routing table; this plan just says which row applies where.

---

## 0. Audit — what already exists (read before writing any code)

Do not re-scaffold what's already built. Current state as of this plan:

| Screen | State | File(s) |
|---|---|---|
| **E1 Insights Hub** | Built and routed (`/insights`, a bottom-nav tab). Tile grid with live headline counts for Caps and Milestones; Billing Float and "All Activity" tiles have no headline number. **Not priority-ordered by urgency** (spec requires nearest-deadline-first sort; today it's a fixed 4-tile order) and only has 4 of 12 E-screens tiled — E3/E5/E6/E8/E9/E10/E11/E12 have no tile at all yet | [insights_hub_screen.dart](app/lib/features/insights/insights_hub_screen.dart) |
| **E2 Caps & Limits** | Built and routed (`/insights/caps`). Progress bars, reset-adjacent headroom text, icon+text urgency (not colour-alone — good). **Not sorted closest-to-cap first** (iterates cards→cap rules in insertion order) and has no actionable "switch to X after that" copy — those are both explicit spec requirements, not yet done. Fuel-surcharge caps: included automatically since it iterates all `CapRule`s off `CardProduct.capRules`, no special-casing needed — confirm a fuel surcharge rule actually round-trips as a `CapRule` today (it's currently modeled separately as `FuelSurchargeRule`, see note in Task E-0 below) | [caps_screen.dart](app/lib/features/insights/caps_screen.dart) |
| **E3 Credit Utilization** | Does not exist. Blocked on a real gap, smaller than the hub screen's own comment claims: `user_cards.credit_limit_inr` **already exists in the live schema** ([0004_user_domain.sql:60](db/supabase/migrations/0004_user_domain.sql)) but `GET /user-cards`'s `SELECT` ([index.js:1002](api/src/index.js)) doesn't return it and `UserCard` (Dart) has no `creditLimit` field — this is a one-line backend fix + one-field model addition, not a migration. The actual calculator (`creditUtilization()`) is **already built and correct** in the domain package with zero callers | [calculators.dart:9-38](packages/pandapay_domain/lib/src/engine/calculators.dart) |
| **E4 Milestones** | Built and routed (`/insights/milestones`). Progress bar, reward value, REACHED/Repeats pills. Missing: **days-left** and **"flags when chasing beats base rate"** — neither is computed today | [milestones_screen.dart](app/lib/features/insights/milestones_screen.dart) |
| **E5 Annual Fee Waivers** | Does not exist as a screen. Data is fully live server-side: `fee_waiver_states` is written on every transaction (Chunk 29) and `GET /user-cards` already returns it joined to `fee_waiver_rules` (threshold, waived-fee, qualified-spend) — `UserCard.feeWaiverStates`/`FeeWaiverProgress` already parse it client-side and are shown today only as a one-line badge on the Cards tab tile. This is close to a pure assembly task | — (data source: [user_cards_repository.dart](app/lib/data/user_cards_repository.dart)) |
| **E6 Lounge Access** | Does not exist. `lounge_usage` table exists ([0004_user_domain.sql:198](db/supabase/migrations/0004_user_domain.sql)) with `used_on`/`airport`/`logged_manually` columns — matches the spec's "manual log a visit" note exactly — but has **zero backend routes** (no `GET`/`POST /lounge-usage` anywhere in `api/src/index.js`) and no client model. `CardBenefit` (domain) already carries `quotaCount`/`quotaPeriod`/`networkProgram` for lounge-kind benefits, so the quota side is ready; only usage tracking is missing | — |
| **E7 Billing Cycle / Float** | Built and routed (`/insights/billing-float`), and the most complete E screen. `billingCycleFloat()` calculator fully tested in the engine, wired to a real screen using `UserCard.statementDay`, degrades gracefully when unset | [billing_float_screen.dart](app/lib/features/insights/billing_float_screen.dart) |
| **E8 Due Date Calendar** | Does not exist. `UserCard.statementDay`/`dueDay` — wait, confirm: schema has both `statement_day` and `due_day` columns ([0004_user_domain.sql:60-61](db/supabase/migrations/0004_user_domain.sql)), but `GET /user-cards` only selects `statement_day`, not `due_day`, and `UserCard` (Dart) has no `dueDay` field either — same one-line gap pattern as E3's `credit_limit_inr`. No per-card reminder-toggle storage exists anywhere (no column, no table) — this is genuinely new schema/scope, not just a wiring gap | — |
| **E9 Monthly Savings Report** | Does not exist. `monthly_reports` table exists, pre-shaped exactly to the spec's field list (`total_spend_inr`, `rewards_earned_inr`, `baseline_single_card_inr`, `extra_earned_inr`, `value_missed_inr`, `breakdown jsonb`) ([0004_user_domain.sql](db/supabase/migrations/0004_user_domain.sql), search `monthly_reports`) but nothing writes or reads it — no cron/job populates it, no route serves it | — |
| **E10 Portfolio Audit** | Does not exist, and no dedicated table — this is a live aggregation over `user_cards` (annual fee), `points_ledger`/reward totals (rewards earned), and `transactions` (usage frequency), not a stored-state screen | — |
| **E11 Spending Overview** | Does not exist. Pure aggregation over `GET /transactions` (category/merchant/month), same shape of work as D1's date-grouping in the C/D plan — no new backend table needed, but `GET /transactions` today has no date-range/aggregation query params (same gap D1 flagged) | — |
| **E12 My Contributions** | Does not exist. `merchant_contributions` table exists and is written to by the crowdsource pipeline (admin-side, Chunks 23-26 built the *admin* consumption of this data) but there is no user-facing `GET` route scoped to "contributions by this profile_id", and no opt-out toggle exists client-side (mirrors H4, which is also not built — out of this plan's scope, flagged as a cross-plan dependency) | — |
| **F1 Import Hub** | Does not exist as a single hub. Individual channels are scattered: SMS import has a real (if basic) screen reachable from Account→Tools ([sms_import_screen.dart](app/lib/features/sms_import/sms_import_screen.dart)); PDF/Email/IMAP have no screens or backend at all. No single "status card per channel" view exists | — |
| **F2 Statement PDF Import** | Does not exist. `statement_imports` table exists, matches the spec's accuracy-anchor role exactly (`statement_from`/`statement_to`/`closing_balance_inr`/`points_posted`/`txn_count`/`reconciled_count`) but nothing writes to it — no on-device PDF parser, no upload/parse route (correctly, per spec: "processed on your device, never uploaded" means no upload route should ever exist for the PDF itself) | — |
| **F3 Email Forwarding Setup** | Does not exist. `forwarding_addresses` and `inbound_emails` tables exist, fully shaped for this exact flow (unique `local_part`, `verified_at`, `first_email_at`, `email_count` for live status) — this is the single biggest F-group build, flagged ⭐ highest-friction in the spec itself, and genuinely nothing (screen or backend route) exists for it yet | — |
| **F4 SMS Import** | **Partially built** — real screen, real permission request, real foreground listener, real `POST /transactions/from-sms` call. What's missing vs spec: the **one-time backup-file import** path (spec explicitly separates this from the live auto-read toggle — "always available" regardless of the Android-only auto-read declaration) is not built at all; `sms_import_batches` table exists for exactly this but nothing writes to it. Also missing: the "on-device parsing explanation" copy and an explicit declaration/consent step before the permission request (today it goes straight to the OS permission dialog) | [sms_import_screen.dart](app/lib/features/sms_import/sms_import_screen.dart), [sms_listener_service.dart](app/lib/features/sms_import/sms_listener_service.dart) |
| **F5 Sync & Backup** | Does not exist client-side. `change_log`, `sync_cursors`, `sync_conflicts` tables (§7.3) and `backup_runs`/`restore_drills` tables (§9.3, admin/ops-facing) all exist in schema but there is no client sync engine, no conflict-log UI, and no user-facing backup/restore entry point. This is the largest single technical risk in Group F — genuinely new sync-protocol work, not an assembly task | — |
| **F6 Data Export** | Does not exist. No `GET /export` route, no scope/format picker, no share sheet integration | — |
| **F7 IMAP Connection** | Does not exist. No `imap_connections`-shaped table found in the migrations at all (checked `0006_ingest.sql` in full — only `forwarding_addresses`/`inbound_emails`/`statement_imports`/`sms_import_batches`/`parser_patterns`/`parser_failures` are defined) — this is a real schema gap, not just a missing route. Flagged ⭐ "was missing" in the spec itself, consistent with this finding | — |
| **G1 Travel Mode** | Does not exist as a screen, but the underlying engine support is substantial: `ForexRule.effectiveMarkupFraction()` and `RecommendationContext.travelMode` already exist and are already load-bearing in ranking (`SplitOptimizer`, `compareRails` both thread `travelMode` through). No lounge-eligibility-while-abroad, travel-insurance, or DCC-explainer content exists anywhere | — |
| **G2 Multi-Card Split Planner** | Does not exist as a screen, but `SplitOptimizer`/`SplitAllocation` — the actual "optimal split respecting caps + utilization" algorithm the spec asks for — is **already fully built and is the single most complete piece of unbuilt-UI logic in this entire plan** (bounded greedy-fill optimizer, cap-headroom-aware, tested) | [calculators.dart:44-134](packages/pandapay_domain/lib/src/engine/calculators.dart) |
| **G3 EMI Advisor** | Does not exist as a screen, but `adviseEmi()` — total interest, effective cost, forfeited rewards, verdict line — is **already fully built** in the domain package, zero callers | [calculators.dart:171-224](packages/pandapay_domain/lib/src/engine/calculators.dart) |
| **G4 Emergency Card Info** | Does not exist. `issuer_emergency_contacts` table exists ([0002_reference_data.sql:26](db/supabase/migrations/0002_reference_data.sql)) — matches the spec's "per-issuer lost-card hotline" requirement directly — but no route serves it and, critically, the spec's **"works with zero network and zero login"** requirement means this can't be a plain `GET`-on-demand screen; it needs to ship bundled/cached with the catalogue the same way offline-first works elsewhere (§S4) | — |

**The one finding that reshapes this plan:** three of Group G's four calculators (`creditUtilization` for E3, `SplitOptimizer` for G2, `adviseEmi` for G3) and one of Group E's (`billingCycleFloat`, already shipped for E7) are **already written, already correct, and have zero UI callers**. G2 and G3 in particular are not "build the logic + the screen" tasks — they're "build the screen" tasks, full stop. This mirrors the C/D plan's Task C-0 finding (`CardProduct` fields dropped on the floor) almost exactly: the backend/domain layer has consistently run ahead of the UI layer across this codebase's chunk history, and Group E/F/G is no exception. Don't let a task estimate assume calculator work that isn't needed.

**Second finding, schema-wide:** every E/F/G table the spec implies (`lounge_usage`, `monthly_reports`, `forwarding_addresses`, `inbound_emails`, `statement_imports`, `sms_import_batches`, `sync_cursors`, `sync_conflicts`, `backup_runs`, `merchant_contributions`) already exists in the **real, live** migrations (`db/supabase/migrations/0001–0017`) — confirmed by reading each migration file directly, not `database.sql`. `database.sql`'s first ~1800 lines are a near-verbatim copy of those same migrations (safe to cross-reference), but its **tail** (lines ~1812 onward, `catalogue_meta`/`poi_bundle`/`merchant_cache`/etc.) is a **separate, smaller SQLite on-device cache schema** — do not confuse the two when a task below cites a table name; the migrations directory is the one source of truth for the Postgres server schema. The one schema gap this plan found that's real, not just unwired, is **F7's IMAP connection table** — nothing in any migration models stored IMAP credentials/config.

**Third finding, navigation:** ui-spec's own Navigation Architecture (§1) specifies a `More` tab hosting "E1 hub + G tools + H settings." The **live app already diverged from this** (Chunk 7's router comment explains why: Material's 5-item bottom-nav ceiling forced a choice, and Insights displaced Activity as the 4th tab rather than joining a `More` tab that was never built). Today: bottom nav is Home / Cards / Insights / Account, where **Account is functioning as the de facto `More` tab already** — it has a "Tools" section pattern already in production use for exactly this purpose (SMS import, nearby merchants, home-widget settings all live there as `_AccountTile` entries, [account_screen.dart:72-96](app/lib/features/account/account_screen.dart)). **Recommendation baked into this plan:** G1–G4 and F1–F7's entry points go into Account's existing "Tools" section as more `_AccountTile`s, not into a net-new `More` tab — matches the shipped pattern, avoids reopening the bottom-nav-ceiling debate Chunk 7 already resolved. Flag this decision for confirmation before F1/G-group work starts (see Sequencing).

---

## 1. Cross-cutting foundations (build once, shared by E, F, and G)

### Task E-0 ⭐ `GET /user-cards` gap-fill: `credit_limit_inr`, `due_day`
**Why first:** E3 and E8 both stall on the exact same one-line-per-screen backend gap — a column that already exists in Postgres but isn't selected or parsed anywhere client-side. Doing both in one pass avoids two near-identical tiny PRs.
- Add `uc.credit_limit_inr` and `uc.due_day` to the `SELECT` in `GET /user-cards` ([index.js:1002](api/src/index.js)), alongside the existing `statement_day`/`opened_on` it already returns.
- Add `creditLimit` (`Money?`) and `dueDay` (`int?`) fields to `UserCard` in [user_cards_repository.dart](app/lib/data/user_cards_repository.dart), parsed the same way `statementDay` already is.
- **Skill:** `flutter-riverpod-gorouter` (model + provider-adjacent change) as primary reference; this is a small enough change that a dedicated `dagovalsusa-flutter-model` pass isn't needed.
- **DoD:** a card with `credit_limit_inr`/`due_day` set in Postgres shows non-null values in `ownedCardsWithProductProvider` without any new fetch.

### Task E-0b Confirm fuel-surcharge caps actually appear as `CapRule`s
E2 spec explicitly calls out "including fuel-surcharge caps." `FuelSurchargeRule` (surcharge %, waiver %) is currently modeled as its own type in [card_rules.dart](packages/pandapay_domain/lib/src/card_rules/card_rules.dart), separate from `CapRule` — before assuming E2's plain iteration over `product.capRules` already covers fuel surcharges, confirm whether a fuel-surcharge waiver is *also* represented as a `cap_rules` row server-side (a `CapMeasure` variant) or whether it only ever surfaces via `FuelSurchargeRule`, which E2 doesn't touch at all today. If it's the latter, E2 needs an explicit second data source folded in, not just its existing loop.
- **Skill:** `systematic-debugging` — this is exactly the kind of "read the actual seed data, don't assume from the type names" check worth doing before writing E2's sort/actionable-copy logic on an incomplete data set.

### Task E-0c Sort/urgency-ranking helper, shared by E1 and E2
E1 ("priority-ordered by urgency, nearest deadline first") and E2 ("sorted by closest-to-cap") are two different sort keys over overlapping data (caps, milestones, fee waivers, billing float, all have some notion of "how close to a deadline/limit"). Build one small `Comparable`-style urgency scorer in `pandapay_domain` (pure Dart, testable) that each tracker screen's own list can sort by, rather than every E-screen inventing its own ad hoc `.sort()` — E5's "days to anniversary" and E6's "quota reset" need the same shape of comparison.
- **Skill:** `flutter-riverpod-gorouter` isn't the right lead skill here — this is domain-package logic; treat it like the C/D plan treated the "best card in hindsight" calculator (a `dagovalsusa-flutter-dev`-adjacent pure-Dart task with `flutter-tester` for its unit tests).
- **DoD:** a fixture with three caps at 95%/60%/10% consumed and two milestones at 3-days-left/40-days-left produces a single merged urgency ordering that matches hand-computed expectations.

### Task F-0 ⭐ Import/Sync backend surface — decide scope before building any F screen
Group F is the only group in this plan where **every single screen** needs new backend routes, and several (F3, F5, F7) are substantial protocol work, not CRUD. Before starting F2–F7 individually:
- Inventory exactly which of `forwarding_addresses` / `inbound_emails` / `statement_imports` / `sms_import_batches` / `sync_cursors` / `sync_conflicts` / `backup_runs` need a first `GET`/`POST` route at all (none currently have one) and which need write access from a background job (email-forwarding ingest, IMAP polling) that isn't a per-request API route in the first place — those need a job runner/queue decision that's out of scope for a single Express route and should be flagged to the product owner rather than silently scoped down.
- **Skill:** `brainstorming` — this is the one place in the whole plan where the ambiguity is architectural (queue vs. cron vs. webhook), not just "which field," and deserves an explicit design pass before code.
- **DoD:** a short written scope decision per F-screen (even one line: "F3 needs an inbound-email webhook receiver, out of scope for this pass; build the forwarding-address issuance + status-polling UI only") that the per-screen tasks below can point back to.

### Task G-0 Wire the three existing-but-unwired calculators into providers
`creditUtilization`, `SplitOptimizer`, `adviseEmi` all exist with zero Riverpod providers wrapping them. Add three thin providers (`creditUtilizationProvider`-per-card, `splitOptimizerProvider`, `emiAdviceProvider`, parameterized the way `rankedRecommendationsProvider` already is in [providers.dart](app/lib/app/providers.dart)) so E3/G2/G3 each consume a provider, not a bare static function call from inside a widget.
- **Skill:** `flutter-riverpod-gorouter` — this is squarely provider-wiring work, the default skill for this exact shape of task per `CLAUDE.md`.
- **DoD:** each of the three providers has at least one `ProviderContainer`-based test proving it recomputes when its underlying `ownedCardsWithProductProvider`/`enteredAmountProvider` input changes.

---

## 2. Group E — Trackers & Insights (12 screens)

### E1. Insights Hub — extend the existing screen, don't rebuild
Currently 4 tiles (Caps, Milestones, Billing Float, All Activity), no urgency sort.
- Add tiles for E5 (Fee Waivers), E6 (Lounge), E8 (Due Dates), E9 (Savings Report), E10 (Portfolio Audit), E11 (Spending Overview), E12 (Contributions) as each screen lands — don't block E1 on all 8 landing at once; add a tile the same commit its target screen ships, same incremental pattern the existing 4 tiles followed (per-chunk, not a single mega-PR).
- Re-sort the grid using Task E-0c's urgency scorer once at least caps+milestones+fee-waivers are feeding it (E3 has no natural "urgency," so it stays pinned or unordered).
- E3 gets no tile until Task E-0 lands (same "don't link to a screen that can't render anything real" discipline the current hub already follows for E3, per its own code comment).
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** the grid re-renders in urgency order without a full-screen rebuild flash when a new transaction changes which item is most urgent.

### E2. Caps & Limits — extend the existing screen
Add closest-to-cap sorting (Task E-0c) and actionable "₹300 left on X — switch to Y after that" copy.
- The "switch to Y" half needs a same-category next-best-card lookup — reuse `RecommendationEngine.rank()` filtered to the cap's category, excluding the current card, rather than inventing a second ranking path.
- Resolve Task E-0b (fuel-surcharge data source) before finalizing the row list.
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `flutter-tester` for the sort-order and actionable-copy logic specifically, since both are pure functions of already-fetched data and cheap to unit test outside widget rendering.

### E3. Credit Utilization (new, unblocked by Task E-0 + G-0)
Per-card + overall bars, 30%-threshold colour coding, plain-language explanation, "Optimize" → redistribution suggestion, explicit not-a-credit-score-guarantee disclaimer, exclude cards with no limit entered (prompt to add it).
- Data: `creditUtilizationProvider` from Task G-0, fed `UserCard.creditLimit` from Task E-0. A card with `creditLimit == null` is excluded from the aggregate and shown with an inline "add your credit limit" prompt routing to C4 (Edit Card) — reuse C4 rather than building a second limit-entry field here (coordinate with whoever's building C4 per the C/D plan; if C4 hasn't landed yet, a minimal inline entry field is an acceptable stopgap, but don't duplicate the full edit form).
- "Optimize" → redistribution suggestion is a second, smaller use of `SplitOptimizer` (Task G-0's provider) — cap the recommendation to "move ₹X from card A to card B" phrasing, not a full G2-style multi-way split, since that's a different UX weight than G2's dedicated planner.
- Never colour-alone: icon or text alongside every utilization-threshold colour, same rule C6/E2 already apply.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** the not-a-credit-score-guarantee disclaimer is present and un-dismissable (not a toast that vanishes) per the spec's "explicit" wording.

### E4. Milestones — extend the existing screen
Add days-left and "chasing beats base rate" flag.
- Days-left needs a period-end date per milestone, which the client doesn't currently compute (server returns `period_start`/`period_end` implicitly via which `milestone_states` row is "current," but `GET /user-cards` doesn't return the dates themselves today — check whether adding `period_end` to that same milestone-states query, alongside Task E-0's other additions, is a natural fold-in).
- "Chasing beats base rate" flag: compare the milestone's implied marginal ₹/₹ (reward ÷ remaining spend needed) against the card's base reward rate — this is a genuinely new small calculation, not reuse of an existing calculator; scope it as a pure function in `pandapay_domain` next to `calculators.dart`'s other one-off comparisons (`compareRails` is the closest existing shape to mirror).
- **Skill:** `flutter-riverpod-gorouter` for the screen; `flutter-tester` for the new marginal-rate comparison function.

### E5. Annual Fee Waivers (new, mostly assembly)
Fee, threshold, progress, days-to-anniversary, urgency colouring.
- Data is already flowing: `UserCard.feeWaiverStates` (`FeeWaiverProgress`: rule id, qualified spend, threshold, waived-fee, `waived_at`) is parsed today and shown only as a Cards-tab badge — this screen is close to a pure `ListView.builder` over data that already exists client-side, same shape as C5's "fully unlocked, no new backend" framing in the C/D plan.
- Days-to-anniversary: needs `UserCard.anniversaryOn` — check whether it's already selected by `GET /user-cards` (it isn't, per Task E-0's audit of that same query) — fold `anniversary_on` into Task E-0's column-gap-fill rather than opening a third near-identical PR.
- Urgency colouring: reuse Task E-0c's scorer.
- **Skill:** `flutter-riverpod-gorouter` for a straightforward derived-data screen, same framing as C5.

### E6. Lounge Access (new, needs a real backend route)
Visits used vs. quota per network/card, quarter reset, manual "log a visit."
- `lounge_usage` table exists and matches the spec shape exactly; needs `GET /lounge-usage` (scoped to signed-in user, joined to `card_benefits` for quota) and `POST /lounge-usage` (`{userCardId, benefitId, usedOn, airport?}`) — neither exists today.
- Quota-vs-used: `CardBenefit.quotaCount`/`quotaPeriod` (already parsed, Task C-0 in the C/D plan) gives the denominator; count of `lounge_usage` rows in the current `quotaPeriod` window gives the numerator — reuse Task E-0c's/Clock's period-bounds logic rather than hand-rolling quarter-boundary math a third time (C2's Caps tab in the C/D plan already flagged needing a client-side period-bounds calculator port from the server's SQL — if that lands first, E6 is its second consumer, not its first; check before building a fourth copy).
- **Skill:** `flutter-riverpod-gorouter` for the screen and the manual-log form. **Skill:** `owasp-mobile-security-checker` isn't strictly needed (no new sensitive data class), but do apply `verification-before-completion` given quota state feeds a "you have N lounge visits left" claim users may rely on while traveling.

### E7. Billing Cycle / Float — no work needed
Already built, routed, and tested end-to-end. Not touched by this plan except as a reuse target for other screens' period-bounds logic (see E6, E9 above).

### E8. Due Date Calendar (new — schema gap beyond the E-0 column fill)
Month view of statement + due dates, amounts where known, per-card reminder toggles.
- Calendar view itself: pure client-side rendering over `UserCard.statementDay`/`dueDay` (Task E-0) across all owned cards — no new backend route for the read side.
- Reminder toggles: **no storage exists anywhere** for "remind me about card X's due date" — this is genuinely new scope. Scope narrowed to a local-only (on-device) toggle stored via whatever local-preferences mechanism this app already uses elsewhere (check `home_widget`'s settings-persistence pattern in [widget_settings_screen.dart](app/lib/features/home_widget/widget_settings_screen.dart) before inventing a new one), rather than a server-synced `user_card_reminders` table — the spec doesn't require cross-device sync of reminder preferences, and building one would be new schema work with no clear ui-spec mandate. Flag this scoping call explicitly if picked up.
- Actual notification delivery (the reminder firing) is H3's territory (Notification discipline) — out of this plan's scope; E8 only owns the toggle UI and the calendar view.
- **Skill:** `flutter-riverpod-gorouter`.

### E9. Monthly Savings Report ⭐⭐ (new, backend-heavy)
Headline ₹ extra earned, breakdown, category breakdown, best card, month-over-month trend, share-as-image; first month shows "building your first report," never a misleading zero.
- `monthly_reports` table exists, matches the spec's field list closely — but **nothing populates it**. This needs either a scheduled job (monthly cron, mirroring how `admin_console`'s scraper scheduler already runs periodic work — check `api/`'s existing cron pattern, referenced in `database.sql`'s `0013_cron_jobs.sql`-equivalent migration, before inventing a new scheduling mechanism) or an on-demand recompute-on-open path. Recommend on-demand for the current month (cheap, always fresh) and cron-materialized for past months (matches the table's own "materialized monthly so the report opens instantly" comment at [0004_user_domain.sql](db/supabase/migrations/0004_user_domain.sql)).
- **Real reuse opportunity, flagged per this task's own ask:** E9's `baseline_single_card_inr`/`value_missed_inr` fields need the exact same "what would a single best-overall card have earned instead" and "what did a suboptimal choice cost" math as **D6 Missed Opportunities** (the C/D plan's Task D6, which itself depends on a not-yet-built "best card in hindsight" historical-recompute calculator). **Do not build this math a second time for E9.** Whichever of D6/E9 lands first should build the shared calculator in `pandapay_domain`; the second should consume it. This is a real, not forced, overlap — both need `CardSnapshot`-at-a-past-point-in-time reconstruction, which today's engine doesn't do at all (today's `CardSnapshot` is always "now," per the C/D plan's own flag on this exact gap).
- Share-as-image: client-side render-to-image of the report card (Flutter has `RepaintBoundary`/`toImage` for this) + platform share sheet — no backend involvement.
- **Skill:** `flutter-riverpod-gorouter` for the screen; the hard part is `dagovalsusa-flutter-dev`/domain-package territory (the shared historical-recompute calculator), same framing the C/D plan gave D6.
- **DoD:** a fixture-driven test proves a known first-month user sees "building your first report" copy, not `₹0 extra earned`.

### E10. Portfolio Audit (new, live aggregation, no dedicated table)
Per card: annual fee vs. rewards earned, break-even, usage frequency, unused benefits.
- Annual fee: `CardProduct.annualFeeInr` (already parsed, Task C-0 in the C/D plan). Rewards earned: sum `points_ledger` value for that card (× `pointValueInr`, same conversion E9/C6 both already use). Usage frequency: transaction count for that card over a trailing window — needs `GET /transactions?cardId=` filter support, same gap D1 (C/D plan) already flagged as needed for its own filters; **build that query-param support once, in whichever of D1/E10/E11 lands first.**
- Unused benefits: `CardProduct.benefits` minus whatever's referenced in `lounge_usage`/other consumption signals — for benefit kinds with no consumption tracking at all (e.g. `insuranceTravel`, `concierge`), "unused" can't be measured and should say so honestly rather than guessing — this is a direct instance of the Cross-Cutting "never display a number the app can't justify" rule.
- **Skill:** `flutter-riverpod-gorouter`.

### E11. Spending Overview (new, pure aggregation)
Category/merchant breakdown by month; explicitly "context, not a budgeting tool."
- Client-side aggregation over `GET /transactions`, same "no new backend needed for the aggregation math itself" shape the C/D plan gave D1's date-grouping — but needs the same `?from=&to=` date-range param gap D1/E10 both also need. **Third consumer of the same missing query param — strong signal to build it once, early, rather than three times.**
- "Context, not a budgeting tool" — keep the copy descriptive (spend happened here) not prescriptive (spend less here); flag this in the screen's copy review rather than letting it drift into budget-app territory by default UI patterns (progress bars toward a "limit" the app never asked the user to set).
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `flutter-tester` for the aggregation logic in isolation.

### E12. My Contributions ⭐ (new, needs a scoped read route + opt-out wiring)
Count of merchants mapped/confirmed, "you've helped X other users," contribution toggle, plain restatement of what's shared.
- Needs `GET /my-contributions` (scoped to `profile_id`, aggregating `merchant_contributions`) — doesn't exist; the admin side already consumes this table (Chunks 23-26) but never as a per-user read.
- **The contribution opt-out toggle is explicitly the same toggle as H4** ("mirrors H4" per the traceability matrix) — H4 is out of this plan's scope (Group H), so E12's toggle either (a) is stubbed as read-only display of whatever H4's eventual state provider exposes, or (b) this task builds the toggle's actual state provider now and H4, when built, becomes a second consumer. Recommend (b) — the toggle's backing state (`user_consents` table, already exists per [0004_user_domain.sql:29](db/supabase/migrations/0004_user_domain.sql)) is small enough that building it once here, correctly, is cheaper than two teams half-building it independently. Flag this to whoever owns Group H before starting.
- "You've helped X other users" — this is an aggregate/anonymized cross-user count, not a per-contribution attribution (matches "never identity, amounts, or exact location" from the spec's own feature description) — needs a `COUNT(DISTINCT ...)`-shaped aggregate query on the backend, not raw row exposure.
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `owasp-mobile-security-checker` proactively — this route aggregates cross-user data even if anonymized; confirm the aggregate query can't be used to fingerprint a specific other user's contribution pattern before shipping it.

---

## 3. Group F — Data Import & Sync (7 screens)

### F1. Import Hub (new, depends on F2-F4/F7 existing enough to report status)
Status card per channel (active / not set up / error) → F2–F4, F7.
- Needs at least a minimal status source per channel: SMS (permission granted? listening?), Email (forwarding address issued? verified?), IMAP (connection configured?), PDF (has no persistent "connected" state — it's a one-shot action per statement, so its "status" tile is really just an entry point, not a live status).
- Build this **last** among the F screens, once F2/F3/F4/F7 exist enough to have a real status to report — an F1 built first would just be four static "not set up" tiles with no real backing state.
- **Skill:** `flutter-riverpod-gorouter`.

### F2. Statement PDF Import (new)
File picker → password prompt (on-device only, never uploaded) → parse progress → preview of detected transactions → duplicate check → confirm import; reconciles estimates to confirmed and updates point balances; error states for wrong password / unsupported format / corrupt file, each with a next step + "report this format" action.
- **On-device PDF parsing is real, non-trivial scope** — this needs a PDF-parsing package capable of handling password-protected bank statement PDFs entirely client-side (check what's already a dependency in `pubspec.yaml` before adding a new one; if nothing suitable exists, flag the package choice as its own decision point rather than silently picking one).
- Duplicate check reuses D5's detection logic once it exists (C/D plan) — a statement-imported transaction and an SMS-imported transaction for the same real-world spend is exactly D5's use case, not a separate mechanism.
- "Report this format" reuses C7's `data_error_reports` write path (C/D plan Task C-0b) with a `fieldPath` convention like `statement_format:<issuer>` rather than a card-field path — confirm this framing is acceptable before building, since C-0b's route was designed around card catalogue fields, not import-format fields.
- `statement_imports` row written on successful import (Task F-0's scope decision governs exactly which route shape).
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `owasp-mobile-security-checker` proactively — a password-protected financial statement is processed on-device; verify the password itself is never logged, cached to disk, or included in any error-report payload sent to the backend (a real, specific risk if the "report this format" action naively serializes screen state).

### F3. Email Forwarding Setup ⭐ highest-friction flow (new, largest F build)
Unique forwarding address + copy button, provider-specific step-by-step (Gmail/Outlook/Yahoo/Other) with screenshots, Gmail forwarding-verification-code handling (app sends code, user pastes it), live status ("Waiting for first email…" → "Connected — N received"), troubleshooting + test-email action, skippable at any point.
- Address issuance: `POST /forwarding-addresses` generates and returns a `local_part` (doesn't exist today) — straightforward once Task F-0 scopes it.
- **Live status requires an inbound email ingestion path that isn't a request/response API route** — something has to receive mail sent to `<local_part>@in.pandapay.app`, parse it, write `inbound_emails`, and update `first_email_at`/`email_count` on the matching `forwarding_addresses` row. This is real infrastructure (an SMTP receiver or a third-party inbound-email webhook like SendGrid/Mailgun/SES inbound parsing) that doesn't fit inside `api/`'s existing Express-route pattern — **this is the single item in this whole plan most likely to need a scope conversation with the product owner before any code is written.** Task F-0 exists specifically to force that conversation early rather than letting F3 quietly become "the screen exists but nothing ever arrives."
- Screenshots for the provider-specific steps are static content (asset images + copy), not computed — genuinely just asset production + a simple stepper UI once the address-issuance and status-polling parts exist.
- Gmail's verification-code flow needs the app to both send an email (from the ingestion path above) and accept a pasted code — sequencing-wise this can't be built before the ingestion path exists at all.
- **Skill:** `brainstorming` before starting (per Task F-0's own DoD) given the infra-scope ambiguity. **Skill:** `flutter-riverpod-gorouter` for the stepper/status-polling UI once the backend contract is settled.

### F4. SMS Import — extend the existing screen, don't rebuild
Real permission flow + live listener already work; missing: one-time backup-file import (always available, independent of the auto-read toggle) and the on-device-parsing explanation copy.
- Backup-file import: Android's SMS backup/export format (typically an XML file from a backup app, or the OS's own export) needs a file picker + parse-in-bulk path that reuses the **same parser** `logTransactionFromSms`/`POST /transactions/from-sms` already calls per-message — batch it rather than building a second parser. Writes to `sms_import_batches` (message/parsed/failed counts) — table exists, nothing writes to it today.
- Add an explicit consent/explanation screen **before** the OS permission dialog (today it's a direct `requestPermissions()` call) — matches F3's "explicit handling" bar and the app's own DPDP-consent posture used elsewhere (A4/H2, per the traceability matrix) — don't gate this behind Group A/H work landing first; a self-contained explanation step within F4 is enough.
- **Skill:** `flutter-riverpod-gorouter` for the new backup-import flow and consent step.

### F5. Sync & Backup (new — largest technical risk in Group F)
Last sync, pending changes, manual sync, conflict log (never resolve silently without a record), backup status, double-confirmed restore entry point.
- `change_log`/`sync_cursors`/`sync_conflicts` (§7.3) model a real last-write-wins-with-logged-conflicts sync protocol — this app currently has **no client-side sync engine at all**; every screen today talks directly to `GET`/`POST` REST routes against the live server with no offline queue or local-first write path. Building F5 as "just a UI over existing sync state" is not accurate — the sync engine itself doesn't exist yet, and this screen is only as real as that engine.
- Scope call needed: is this plan expected to build the actual bidirectional sync engine (multi-device conflict resolution, offline write queueing), or only the **user-facing surface** assuming a sync engine lands separately? Given the size of that gap, **recommend scoping F5 in this pass to backup/restore only** (which is more self-contained — `backup_runs`/`restore_drills` are ops-facing tables that a status-display screen can read without the client needing its own sync engine) and treating the multi-device `change_log`/`sync_conflicts` UI as blocked on a separate, larger "build the sync engine" effort not appropriate to scope inside a single screen task. Flag this narrowing explicitly if picked up — don't silently ship a fake "0 pending changes" sync status with no engine behind it.
- Restore: destructive, double-confirmed per spec — reuse whatever confirmation pattern C4/account-deletion (H2, out of scope) use elsewhere for double-confirm-with-typed-input, don't invent a third confirmation UX.
- **Skill:** `brainstorming` before starting, explicitly — this is the other item in this plan (alongside F3) where the ambiguity is architectural, not detail-level. **Skill:** `systematic-debugging` for whatever backup-status read path is actually built, since backup/restore correctness bugs are exactly the "silent data loss" class of bug ui-spec's own §7.3 comment calls out by name.

### F6. Data Export (new)
Scope (transactions/cards/all) + format (CSV/JSON) → generate → share; "Your data is yours" copy.
- Needs `GET /export?scope=&format=` (doesn't exist) — a straightforward query-and-serialize route once scope is defined; CSV serialization for `transactions` should reuse whatever field set `GET /transactions` already returns rather than inventing a separate export shape.
- No dedicated table needed — this reads existing data, doesn't write anything.
- Share: platform share sheet with the generated file, same mechanism as E9's share-as-image.
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `owasp-mobile-security-checker` proactively — an "export everything" route is by definition a full-PII-and-financial-data dump; confirm it's `requireAuth`-gated to the caller's own `profile_id` only (same discipline as every other write route in this codebase) and that the generated export file isn't left in a world-readable app-cache location on-device.

### F7. IMAP Connection (fallback) ⭐ (new — real schema gap, not just missing routes)
Email + app password (with a "how to generate one" link), server auto-detection, sender-filter config, test connection; must warn that Google is progressively restricting basic auth, with an explicit fall-back-to-F3 message.
- **No table for this exists in any migration** — this needs a new `imap_connections`-shaped table (email, encrypted app password, IMAP server/port, sender filter, last-poll status) before any route or screen can be built. Given this stores a live credential (an app password, even though scoped, is still a credential), the storage design itself needs security review before implementation, not after.
- Polling an IMAP mailbox on a schedule is the same "not a plain request/response Express route" problem F3's live-status has — needs a background poller, not just a route. Sequence this after Task F-0's architectural scope decision, and likely after F3 if F3 ends up building shared ingestion infrastructure this can reuse (a received email needs the same downstream parsing/`inbound_emails`-writing regardless of whether it arrived via forwarding or IMAP poll — don't build two separate ingestion pipelines).
- The Google-basic-auth-restriction warning is static copy, cheap to add, but functionally this screen's entire value proposition degrades over time per the spec's own admission — build the F3 fallback messaging prominently, not as a footnote.
- **Skill:** `owasp-mobile-security-checker` proactively and first, before any schema is written — this is the one credential-storage design in the entire E/F/G scope, and per `CLAUDE.md`'s payments-app stance this needs to be checked before code, not just before release. **Skill:** `brainstorming` for the new-table design specifically.

---

## 4. Group G — Tools & Modes (4 screens)

### G1. Travel Mode (new — engine partially ready, no screen)
Toggle re-ranks by forex markup; per-card markup comparison, lounge eligibility abroad, travel insurance info, DCC warning explainer, destination acceptance notes.
- The toggle itself: `RecommendationContext.travelMode` already exists and is already threaded through `RecommendationEngine.rank()`, `SplitOptimizer`, and `compareRails` — flipping it on is largely a `StateProvider<bool>` (mirrors `selectedCategoryProvider`'s existing shape) plus passing it into the existing ranking calls Home (B1/B3) already makes. This is the cheapest part of G1.
- Per-card markup comparison: `ForexRule.effectiveMarkupFraction()` exists and is correct; needs a simple ranked list view, no new math.
- Lounge eligibility abroad: depends on E6 (Lounge Access) existing first — reuse its quota/usage data, filtered to international-network benefits (`BenefitKind.loungeInternational`), rather than building a second lounge data path.
- Travel insurance info: `CardBenefit` with `kind == BenefitKind.insuranceTravel` — pure catalogue display, same shape as C5's cheat sheet.
- **DCC warning explainer**: static educational copy (Dynamic Currency Conversion — "always choose to be charged in the local currency, not INR, at a foreign POS terminal") — content task, not a data task; don't over-engineer this into anything computed.
- Destination acceptance notes: no data source exists for this (network acceptance by country isn't modeled anywhere in the schema) — scope this down to a static "RuPay has limited international acceptance; carry a Visa/Mastercard backup" style note rather than fabricating per-destination data the app has no way to back with real information. Flag this narrowing explicitly.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** toggling travel mode on changes Home's top recommendation for a card with a real `ForexRule` set, verifiable against a fixture.

### G2. Multi-Card Split Planner (new — the algorithm is done, build the screen)
Total amount → optimal split respecting caps + utilization; visual allocation with per-card reward totals.
- `SplitOptimizer.optimize()` (Task G-0's provider) already returns exactly `List<SplitAllocation>` (card, amount, expected value) — this screen is an amount-entry field (reuse `enteredAmountProvider`'s existing pattern) + a result list/chart, no new domain logic.
- "Respecting... utilization" — `SplitOptimizer` already accepts an `Map<String, Money> utilizationCeiling` parameter; wire it from Task E-0's `creditLimit` × the 30% threshold (`creditUtilization`'s own threshold constant) once E3's data is available — if E3 hasn't landed yet, this can degrade to "respecting caps only" with utilization as a documented follow-up, rather than blocking G2 entirely on E3.
- Visual allocation: a simple stacked bar or per-card row list is sufficient per spec wording ("visual allocation") — don't over-build this into a custom chart component unless a design reference says otherwise.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** a fixture with two cards, one near its cap, produces a split that stays under that cap's headroom — same style of DoD the C/D plan used for its own recompute-path tasks.

### G3. EMI Advisor (new — the algorithm is done, build the screen)
Amount, tenure, rate → total interest, effective cost, rewards forfeited, verdict line.
- `adviseEmi()` (Task G-0's provider) already returns exactly this shape — this screen is three input fields (amount, tenure, rate) + a results panel rendering `EmiAdvice`, no new domain logic needed.
- `forgoneRewardValue` (an input to `adviseEmi`, not something it computes) needs to come from somewhere — likely "what this card would have earned on this amount at its base rate," computable via the existing `RecommendationEngine`/`CardProduct.rewardRules` for whichever card the user is considering the EMI on. Confirm which card is "the" card before building — is this per-card (user picks one from their wallet) or the currently-recommended card? Spec doesn't say; default to letting the user pick from owned cards, since EMI is typically initiated from an existing purchase context.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** a fixture with a 0% teaser-rate EMI produces `EmiAdvice.verdictLine` reflecting "no real cost" per `adviseEmi`'s own existing branch for that case — confirms the screen surfaces the calculator's actual output rather than a hardcoded message.

### G4. Emergency Card Info (new — must work with zero network and zero login)
Per-issuer lost-card hotline, block procedure, international collect number, one-tap dial.
- `issuer_emergency_contacts` table exists and matches this exactly, but needs a route (`GET /issuers/emergency-contacts`, unauthenticated — this data has no per-user sensitivity and the spec requires it reachable with zero login) that doesn't exist today.
- **"Zero network" is the hard requirement here**, not just an optimization — this data must be bundled/cached on-device the same way the catalogue already is for offline-first elsewhere (§S4). Reuse whatever local-cache mechanism `catalogueProvider`/`categoriesProvider` already use (check their caching layer — likely a local persistence step this plan should point to rather than duplicate) so emergency contact info survives app-cold-start-with-no-network, not just "was fetched once this session."
- One-tap dial: `url_launcher`'s `tel:` scheme (check it's already a dependency — likely yes given `nearby_merchants_repository.dart`'s launch-adjacent needs, confirm before adding a new package).
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** the actual DoD the spec gives — this screen renders correctly in airplane mode with the app freshly cold-started and no prior session, same bar C5 (C/D plan) holds itself to, and the hardest DoD in this entire plan to satisfy honestly (most other "offline" screens are just "don't need network right now"; this one needs to have never needed network at any point up to this render).

---

## 5. Sequencing

```
Task E-0 (credit_limit_inr/due_day/anniversary_on gap-fill) ─┬─> E3 Credit Utilization
                                                               ├─> E5 Fee Waivers (anniversary_on)
                                                               └─> E8 Due Date Calendar (due_day)

Task E-0b (fuel-surcharge cap data source) ──> E2 (finalize row list)

Task E-0c (shared urgency-sort calculator) ──┬──> E1 re-sort
                                              ├──> E2 sort
                                              └──> E5/E6 urgency colouring

Task G-0 (wire creditUtilization/SplitOptimizer/adviseEmi to providers) ─┬─> E3
                                                                          ├─> G2
                                                                          └─> G3

Task F-0 (import/sync backend scope decision — do this BEFORE any F2-F7 code)
    ├──> F2 (PDF parsing package choice)
    ├──> F3 (inbound-email ingestion path — biggest single decision in this plan)
    ├──> F4 extension (backup-file import)
    ├──> F5 (sync-engine-vs-backup-only scope narrowing)
    └──> F7 (new imap_connections table design, likely reuses F3's ingestion pipeline)

E6 Lounge Access ──> G1's lounge-eligibility-abroad section
E9/D6 shared historical-recompute calculator (cross-plan with implementation-plan-group-c-d.md's D6) ─┬─> E9 Monthly Savings Report
                                                                                                        └─> D6 Missed Opportunities (other plan)

D1/E10/E11's shared `GET /transactions` date-range + filter query params ─┬─> E10 Portfolio Audit
                                                                           ├─> E11 Spending Overview
                                                                           └─> D1 (other plan)

F2/F3/F4-backup-import ──> F1 Import Hub (build last — needs real channel status to report)

F3 (ingestion pipeline) ──> F7 (reuses it if it lands first; otherwise F7 builds its own)

Nav-architecture decision (Account "Tools" section hosts F/G entry points, not a new "More" tab)
    ──> gates where every F and G screen's entry point actually goes; confirm before wiring routes
```

**Recommended build order:** Task E-0 → Task E-0b → Task E-0c → Task G-0 (small, unblocks three screens fast) → G2 → G3 (both near-pure-UI given G-0) → E3 → E5 → E4 extension → E8 → E1 re-sort/tile expansion (incremental, ongoing) → E6 → G1 (after E6) → E10/E11 (after the shared `GET /transactions` filter work, coordinate with whoever's doing D1 in the C/D plan) → E9 (after the shared historical-recompute calculator, coordinate with whoever's doing D6) → E12 (coordinate with Group H owner on the H4-shared toggle).

Then, separately and only after Task F-0's scope conversation happens: F4 extension (lowest-risk F task, extends existing working code) → F2 → F6 (self-contained, no architecture risk) → F3 → F7 (reuses F3's pipeline if possible) → F5 (narrowed to backup/restore per the scope call above) → F1 (last, needs real channel status).

**Explore first, every task:** confirm the real migration file (`db/supabase/migrations/`) for any table this plan cites before writing backend code against it — this plan's audit already did that read for every table named above, but a fact can go stale between this plan's writing and implementation; don't trust `database.sql`'s tail section (`catalogue_meta` onward) for any server-side work, it's the on-device cache schema, not Postgres.

## 6. Cross-cutting, applies to every task above

Per this project's `CLAUDE.md` "workflow discipline" table, apply throughout rather than per-screen:
- **`brainstorming`** before starting any screen whose scope is architecturally ambiguous above (flagged explicitly: F3's ingestion infrastructure, F5's sync-engine-vs-backup-only scope, F7's new credential table, G1's destination-acceptance-notes narrowing, E9's/D6's shared calculator ownership, E12's H4-toggle ownership).
- **`test-driven-development`** for every new pure-calculation function (E4's chasing-beats-base-rate flag, E0c's urgency scorer, the E9/D6 shared historical-recompute calculator) — same reasoning the C/D plan gave for its own recompute paths: cheap to test up front, expensive to debug as a silent-drift bug later.
- **`owasp-mobile-security-checker`** proactively on F2 (statement password handling), F6 (full-data export route), F7 (new stored-credential table — the single highest-risk item in this plan), and E12 (cross-user aggregate query) — per `CLAUDE.md`'s explicit "lean toward running this proactively... even without an explicit ask" instruction for a payments app.
- **`verification-before-completion`** before marking any task done — every screen above has an explicit DoD (or an explicit scope-narrowing note in place of one where the spec was genuinely ambiguous); don't claim done without running it.
- **`requesting-code-review`** before merging each task, standard for this repo.

Every screen, per ui-spec's own Cross-Cutting Requirements (unconditional, not optional per-screen):
- **Data honesty:** every financial figure through `MoneyText`/confidence-badged widgets (already in [main.dart](app/lib/main.dart), imported the same cross-file way the C/D plan already flagged as worth relocating into `app/design/widgets.dart` — if any E/F/G task is the first to touch a new file needing it, do that relocation then rather than adding a fourth cross-import). Data-freshness dates wherever a figure derives from catalogue data (E5's fee-waiver amounts, G1's forex markups). Never a number the app can't justify — this plan explicitly narrowed several screens (G1's destination notes, E10's unmeasurable "unused benefits") specifically to avoid violating this rule.
- **Accessibility:** text scaling to 200%, WCAG AA contrast both themes, screen-reader labels, 48dp touch targets, never colour-alone for meaning — explicitly relevant to E2/E3/E5/E6's urgency/utilization colour coding (all must carry icon or text too, matching E2's existing icon+text pattern, not just G4's hotline list which has no colour-meaning to begin with).
- **Performance:** all recommendation logic stays local/no-network-in-critical-path — relevant to G1's travel-mode toggle and G2's split optimizer, both of which must rank instantly off already-fetched data, not re-fetch on toggle.
- **Destructive actions:** F5's restore is double-confirmed with no shortcut; no F/G task in this plan hard-deletes anything.
- **Offline-first:** every new screen declares its offline behaviour explicitly in its widget doc-comment (matching this codebase's existing convention, visible in every file read during this audit) — G4 is the hard case (must genuinely work offline, not just degrade gracefully), most others in E/F/G can legitimately require connectivity (imports, sync, contribution counts) as long as they say so with the existing `EmptyState`/`ErrorState` components rather than hanging silently.
