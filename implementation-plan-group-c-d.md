# PandaPay — Implementation Plan: Group C (Cards) & Group D (Transactions)

**Companion to:** [`ui-spec.md`](./ui-spec.md) §Group C / §Group D · [`product-plan.md`](./product-plan.md) · [`database.sql`](./database.sql) · [`Userappimplementation_plan.md`](./Userappimplementation_plan.md) (the original aspirational architecture doc — superseded in practice by the Express `api/` + Riverpod/go_router stack actually running today; this plan is grounded in the **real** codebase, not that doc)

**Scope:** the 8 Group C screens (C1–C8) and 6 Group D screens (D1–D6) — 14 of the 66 spec'd screens. Companion to a separately-tracked Group B plan (Home/Recommendation) already in progress.

**Skill routing for every task below comes from this project's `CLAUDE.md`.** Don't re-derive it — the table there is already the routing table; this plan just says which row applies where.

---

## 0. Audit — what already exists (read before writing any code)

Do not re-scaffold what's already built. Current state as of this plan:

| Screen | State | File(s) |
|---|---|---|
| **C1 My Cards** | ~40% built as a flat list inside `CardsScreen` — no drag-reorder, no cap/utilization bars, no due date, no active/archived filter | [cards_screen.dart](app/lib/features/cards/cards_screen.dart) |
| **C2 Card Detail** | Does not exist | — |
| **C3 Add Card** | Built, but as an inline dropdown form bolted to the bottom of C1, not the searchable/issuer-grouped/multi-select picker the spec (and A7) describes | [cards_screen.dart:220-324](app/lib/features/cards/cards_screen.dart) |
| **C4 Edit Card** | Does not exist (nickname is set once at add-time only; `archiveCard` exists) | — |
| **C5 Benefits Cheat Sheet** | Does not exist | — |
| **C6 Points & Expiry** | Does not exist (lifetime `totalPointsEarned` is shown as a badge on C1's card tile only, no per-program breakdown, no expiry) | — |
| **C7 Report Wrong Data** | Does not exist, and no backend route to hit | — |
| **C8 Request New Card** | Does not exist, and no backend route to hit (same gap as A8) | — |
| **D1 Transaction List** | ~50% built — reverse-chron list with merchant/amount/card/category, but no date grouping, no search/filters, no sticky summary, no optimality indicator, no D4 badge | [activity_screen.dart](app/lib/features/activity/activity_screen.dart) |
| **D2 Transaction Detail** | Does not exist (list is not tappable) | — |
| **D3 Edit Transaction** | Does not exist, and no `PATCH /transactions/:id` | — |
| **D4 Needs Review Queue** | Does not exist. Backend writes `parser_failures` rows on SMS parse failure already (`POST /transactions/from-sms`), but nothing reads them back for a user-facing queue | [database.sql:820](database.sql) |
| **D5 Duplicate Review** | Does not exist. `duplicate_candidates` table exists in schema; nothing writes or reads it yet | [database.sql:671](database.sql) |
| **D6 Missed Opportunities** | Does not exist. Needs the recommendation engine re-run against historical transactions, which nothing does today | — |

**The one finding that reshapes this plan:** `v_card_catalogue_export` ([database.sql:1424](database.sql)) already returns `fee_waiver_rules`, `benefits` (`card_benefits`), `annual_fee_inr`, `joining_fee_inr`, `verified_at`, `issuer_name`, `art_asset`, `art_primary_color` in every `GET /catalogue` response — but `CardProduct.fromJson` ([card_rules_json.dart:122](packages/pandapay_domain/lib/src/card_rules/card_rules_json.dart)) silently drops all of them on the floor today. Most of C2's Fees/Benefits tabs and all of C5 need **zero new backend work** — the data is already on the wire. This is Task C-0 below and it unblocks four screens at once.

---

## 1. Cross-cutting foundations (build once, shared by C and D)

### Task C-0 ⭐ Extend `CardProduct` to carry what the catalogue already sends
**Why first:** every C2/C5/C6 task below depends on this; doing it once avoids three screens each growing their own partial parse of the same JSON.
- Add `FeeWaiverRule`, `CardBenefit` classes to [card_rules.dart](packages/pandapay_domain/lib/src/card_rules/card_rules.dart) (mirror `FeeWaiverProgress`'s field shapes already used client-side, plus `benefit_type`/`description`/`quota` from `card_benefits`).
- Add `annualFeeInr`, `joiningFeeInr`, `verifiedAt`, `issuerName`, `artAssetUrl`, `artPrimaryColor`, `feeWaiverRules`, `benefits` fields to `CardProduct`.
- Extend `CardProductJson.fromJson` in [card_rules_json.dart](packages/pandapay_domain/lib/src/card_rules/card_rules_json.dart) to parse them (same `_num`/`_moneyOrNull` helpers already there).
- Domain package is pure Dart, no Flutter — this is a `dagovalsusa-flutter-model` / plain Dart task, not UI.
- **Skill:** `flutter-riverpod-gorouter` (models feeding providers) as primary reference; `flutter-tester` for the new fixture-based parse tests.
- **DoD:** a golden fixture test in `packages/pandapay_domain/test/card_rules_json_test.dart` asserting a `GET /catalogue`-shaped fixture round-trips `benefits`/`fee_waiver_rules`/`annual_fee_inr` correctly.

### Task C-0b New backend routes: user-submitted `card_requests` and `data_error_reports`
Both tables exist ([database.sql:1106](database.sql), [database.sql:1119](database.sql)); only admin-side `GET`/resolve routes exist in `api/src/index.js` today. C7, C8 (and dormant A8) need the write side:
- `POST /card-requests` `requireAuth` → `{issuerName, productName, networkGuess?, imagePath?}` → insert with `profile_id = req.userId`. Mirror the `POST /user-cards` pattern (validate required fields, 400/201).
- `POST /data-error-reports` `requireAuth` → `{cardProductId, fieldPath, shownValue?, claimedValue?, sourceUrl?, attachmentPath?}` → insert with `profile_id = req.userId`, validate `cardProductId` exists.
- Photo/attachment upload: face-only card photo (A8/C8) and optional screenshot (C7) need a storage path. If Supabase Storage isn't wired yet for user uploads, scope this task to accept an already-uploaded `image_path`/`attachment_path` string and treat the actual upload widget as a follow-up — don't block C7/C8's core flow on building storage infra.
- **Skill:** `owasp-mobile-security-checker` — proactively, since this is new auth-gated write surface handling user-submitted card photos (never the card number, per spec) and touches `data_error_reports`/`card_requests`, both of which currently have `owner`-scoped RLS policies (`card_requests_owner`, `error_reports_owner` at [database.sql:1617](database.sql)) that must be re-verified once a new write path exists.
- **DoD:** RLS confirmed — a user can insert their own row and cannot read another user's `card_requests`/`data_error_reports` row.

### Task C-0c `PATCH /transactions/:id` and `DELETE`-as-ignore
D3 (Edit Transaction) and D2's "mark ignored" action need a write path that doesn't exist. `transactions.status` already supports non-`active` states per the `WHERE t.status = 'active'` filter in `GET /transactions` ([index.js:1301](api/src/index.js)) — confirm the enum's other values in `database.sql` (`transactions` table def) and reuse them rather than inventing new ones.
- `PATCH /transactions/:id` `requireAuth` → editable fields (amount, category, merchant, occurred_at, rail) → **recompute cap/milestone/points/fee-waiver state** the same way `insertTransactionAndUpdateState` does today, since ui-spec D3 requires "recomputes caps/milestones on save." Reuse that helper rather than duplicating its math — look at how it's invoked from both `POST /transactions` and `POST /transactions/from-sms` in [index.js](api/src/index.js) and factor the recompute step so edit can call it too.
- `POST /transactions/:id/ignore` `requireAuth` with a reason enum (`refund`, `reversal`, `transfer`) → sets status, excludes from cap/milestone totals (must also **reverse** the original contribution — a transaction that was already counted toward a cap and then gets marked ignored must give that headroom back, or caps drift wrong forever).
- No hard delete — this is a financial ledger; "delete" in D2's action list means ignore/soft-delete, consistent with `card_requests`/`user_cards` never-hard-delete precedent (R4) already followed elsewhere in this codebase.
- **Skill:** `systematic-debugging` before writing the recompute path — this is exactly the kind of "reversible side effect" logic that's easy to get subtly wrong (double-counting or under-reversing); trace the existing `insertTransactionAndUpdateState` cap/milestone math first rather than guessing at the inverse.
- **DoD:** a transaction logged, then edited to a different amount, produces the same cap-consumed total as if only the corrected amount had ever been logged. A transaction logged then marked-ignored returns cap/milestone state to exactly what it was before the transaction existed.

---

## 2. Group C — Cards (8 screens)

### C1. My Cards — rebuild as its own screen
Currently a flat list bolted into `CardsScreen`. Spec needs: card-art list, drag-to-reorder priority (`sort_order` already exists on `user_cards`, just unused for reordering from the UI), per-card cap-usage bar, utilization bar, next due date, active/archived filter, FAB → C3.
- Split `_UserCardTile` out of [cards_screen.dart](app/lib/features/cards/cards_screen.dart) into `features/cards/my_cards_screen.dart`; keep the existing tile's badge logic (fee-waiver pills already implemented — reuse, don't rewrite).
- Drag-reorder: `ReorderableListView`, `PATCH`/dedicated `POST /user-cards/:id/reorder` (new — `sort_order` has no write path today, only the initial insert order).
- Utilization bar needs `creditLimit` on `UserCard`, which doesn't exist client- or server-side yet — this is new (A9 spec's field 2 was never actually captured; check whether `user_cards` has a `credit_limit_inr` column in `database.sql` before assuming it needs a migration).
- Archived filter: `GET /user-cards` currently hardcodes `WHERE uc.is_archived = false` — needs an `?includeArchived=true` query param.
- **Skill:** `flutter-riverpod-gorouter` (new screen, new provider wiring, route registration in [router.dart](app/lib/app/router.dart) — note Cards is currently the tab root itself; C1 stays the tab root, C2/C4 become pushed routes reachable via deep link per ui-spec §1).
- **Skill:** `flutter-tester` for widget tests on reorder + filter; `alchemist-golden-testing` if a visual spec for the card-art tile is locked before building (check with the user — don't invent a golden baseline unprompted).

### C2. Card Detail — tabbed (new screen, biggest single build in this group)
Six tabs: Rewards (+ freshness date), Caps, Milestones, Fees, Benefits, Statement.
- Route: `AppRoute.cardDetail = '/cards/:id'`, deep-linkable per ui-spec §1 ("Deep links required for... card detail").
- Data: `ownedCardsWithProductProvider` (already exists — [providers.dart:217](app/lib/app/providers.dart), pairs `UserCard` + `CardProduct`) is exactly the right source; find the pair by `id` from the route param rather than building a new provider.
- Rewards tab: iterate `product.rewardRules`, resolve `categoryId` → name via `categoriesProvider` (existing pattern already used in `cards_screen.dart`'s `_resolvedSelectedCategoryIdProvider` — invert it). Freshness date = `product.verifiedAt` from Task C-0.
- Caps tab: `product.capRules` × `userCard.capConsumed` progress bars, reset date computed from `CapRule.period` via the existing `Clock` abstraction ([clock.dart](packages/pandapay_domain/lib/src/clock/clock.dart)) — don't hand-roll date math here, the engine package already has period-bounds logic used server-side for `cap_states`/`milestone_states` queries; check whether an equivalent needs porting to `pandapay_domain` for client-side date display (the server currently does this in raw SQL, and the client has no period-bounds calculator yet — flag this as a real gap, likely its own small task rather than folding it silently into C2's estimate).
- Fees tab: `product.feeWaiverRules` × `userCard.feeWaiverStates` (already parsed) — mostly assembly of data that already flows through the app.
- Benefits tab: `product.benefits` (new from Task C-0) — no per-user state, purely catalogue data.
- Statement tab: cycle dates from `userCard.statementDay`/`openedOn` (already added to `UserCard` in the in-flight Group B diff) — **reuse E7's billing-cycle float calculator rather than duplicating it**; check what Group B's Task 11 (E7) lands as before building this tab, since it's the same underlying math.
- Actions: edit → C4, archive → existing `archiveCard`, report wrong data → C7.
- **Skill:** `flutter-riverpod-gorouter` (tabbed detail screen, deep link route param). **Skill:** `dagovalsusa-flutter-screen` as a secondary scaffold reference for the tab-screen shape specifically.
- **DoD:** deep link `/cards/<id>` opens directly to this screen with no intermediate navigation, per ui-spec §1's hard requirement.

### C3. Add Card — rebuild as the real picker (shared with A7)
Spec: "same picker as A7" — issuer-grouped, searchable, card-art thumbnails, multi-select with running count, network filter chips (RuPay/Visa/MC/Amex-Diners), "my card isn't listed" → A8/C8.
- **Important:** A7 (onboarding) doesn't exist yet either per the audit — this task should build **one** shared `CardPickerScreen` widget used by both A7 and C3, not two copies. Confirm with whoever owns the Group A/onboarding thread before building, so this doesn't get duplicated later.
- Replace the current dropdown-based `_AddCardForm` in `cards_screen.dart` entirely.
- Multi-select + running count is a real behavior change from today's single-select dropdown — `addCard` today is called once per card; either loop client-side or add a batch `POST /user-cards/batch`.
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `dagovalsusa-flutter-provider` for the multi-select state (a `StateNotifier<Set<String>>` of selected card IDs, distinct from today's single `_selectedCardId`).
- **DoD:** cannot submit with 0 selected (matches A7's "cannot proceed with 0 cards" validation, reused here as "cannot Add with 0 selected").

### C4. Edit Card (new)
Fields: nickname, credit limit, statement/due dates, points balance, card art/colour. Archive action with "history preserved" copy.
- Needs `PATCH /user-cards/:id` — doesn't exist today (only `archive`). Add it alongside the credit-limit column work from C1.
- Manual points-balance correction here should write to `points_ledger` as a correction entry (not overwrite the lifetime sum directly), since C6 also needs manual correction and both should go through the same reconciliation path — see Task C-0's note and D-side `points_ledger` schema.
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `owasp-mobile-security-checker` isn't needed here (no new sensitive surface beyond what C0b already covers), but do apply `verification-before-completion` before marking this done given it's a financial-state-mutating form.
- **DoD:** archiving a card with existing transactions leaves those transactions fully intact in D1/D2 and removes the card from B1 ranking only.

### C5. Benefits Cheat Sheet (new, fully unlocked by Task C-0)
Cross-card view grouped by benefit type (lounge, insurance, warranty, dining, fuel, golf), offline, static.
- Pure client-side aggregation over `ownedCardsWithProductProvider` → `product.benefits`, grouped by `benefit_type`. No new backend call at all if Task C-0 is done first.
- Genuinely offline: this screen must render from whatever `catalogueProvider` last cached, with no network call in its own render path — same "offline-first" bar the rest of the spec holds every screen to (§S4).
- **Skill:** `flutter-riverpod-gorouter` for a straightforward derived-data screen; no new provider pattern needed beyond a `Provider` that groups the existing data.
- **DoD:** renders correctly with airplane mode on and no session, per ui-spec's own DoD for this screen (Userappimplementation_plan.md's UA-1.5 DoD already states this explicitly — keep it).

### C6. Points & Expiry (new)
Per-program balances, ₹ estimate, expiry dates with urgency colouring **(icon or text too, never colour alone — accessibility requirement)**, redemption hint, est/confirmed badges, manual balance correction.
- `points_ledger` ([database.sql:588](database.sql)) has `expires_on` and is already indexed for it (`idx_points_expiry`) — but nothing reads per-entry rows today, only the `SUM(delta_points)` used for `total_points_earned`. Needs a new `GET /user-cards/:id/points-ledger` (or a `?includeLedger=true` on the existing card-detail fetch) to expose individual entries with their expiry dates, not just the lifetime sum.
- ₹ estimate = `points × product.pointValueInr` (already available client-side, no new math).
- Manual correction writes a `points_ledger` adjustment row (see C4's note — same mechanism, don't build two).
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `ui-ux-pro-max` is worth a look specifically for the urgency-colour system (30/7-day expiry bands) since the accessibility rule (icon+text, not colour alone) is explicit in ui-spec's Cross-Cutting Requirements and easy to get visually-only by accident.

### C7. Report Wrong Data (new)
Pre-filled card + field, shown-vs-claimed value, optional source link/screenshot, confirmation copy.
- Depends on Task C-0b's `POST /data-error-reports`.
- Entry point: C2's "report wrong data" action, pre-filling `cardProductId` and `fieldPath` from whichever tab/row the user tapped from.
- **Skill:** `flutter-riverpod-gorouter` for the form screen. **Skill:** `owasp-mobile-security-checker` already covers the backend side (Task C-0b); on the client, make sure the optional screenshot picker doesn't accidentally grab more than the visible screen region if any card-number-adjacent UI is ever rendered near it (unlikely here since this is catalogue data, not the user's actual card — call it out once, verify, move on).

### C8. Request New Card (new — identical flow to A8, reused, not rebuilt)
"As A8, available any time" per spec. Build the underlying form once (shared with A8, same reasoning as C3/A7 above) and add a second entry point from C3's "my card isn't listed."
- Depends on Task C-0b's `POST /card-requests`.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** submission via either entry point (onboarding A8, or C3→C8 mid-app) produces the same `card_requests` row shape and shows up in the existing admin `GET /admin/card-requests` queue unchanged.

---

## 3. Group D — Transactions (6 screens)

### D1. Transaction List — extend the existing screen, don't rebuild
`activity_screen.dart` already does reverse-chron + merchant/amount/card/category. Missing: date grouping, search/filters (date, card, category, source, needs-review), sticky month summary (spend/points/missed value), optimality indicator (✓ best / ⚠ better existed), D4-count badge on the Activity tab itself.
- Date grouping + sticky summary: client-side aggregation over the existing `transactionsProvider` list — no backend change needed for grouping/summary math itself.
- Filters need query params on `GET /transactions` (today it's an unfiltered `LIMIT 50`, no filter support at all) — add `?cardId=&categoryId=&source=&needsReview=&from=&to=`.
- Optimality indicator (⚠ "a better card existed") is the same computation D6 (Missed Opportunities) needs — **build the "was this the best card?" calculator once**, shared by D1's row indicator and D6's full screen, rather than twice. This is a real new piece of engine-adjacent logic: re-run `RecommendationEngine` against the transaction's historical context (category, amount, date → which cap/milestone state existed *then*) and diff against what was actually used. Flag this as the largest single technical risk in Group D — it needs `CardSnapshot`-at-a-past-point-in-time, which nothing in the engine currently reconstructs (today's `CardSnapshot` is always "now").
- D4 badge: `Activity` nav label in [router.dart](app/lib/app/router.dart)'s `_AppShellState._destinations` needs a count source — a `needsReviewCountProvider` reading from D4's data (see below).
- **Skill:** `flutter-riverpod-gorouter` for filters/search state and the badge wiring into the shell. **Skill:** `flutter-tester` for the date-grouping/summary aggregation logic specifically (pure logic, easy to unit test in isolation from widgets).

### D2. Transaction Detail (new)
Full record incl. source, reconciliation status, "a better card existed" panel, actions: edit/recategorize/split/mark ignored/delete.
- Route: `AppRoute.transactionDetail = '/activity/:id'`, deep-linkable (ui-spec §1).
- `GET /transactions` doesn't return `source` today ([index.js:1301](api/src/index.js) selects `t.id, t.user_card_id, t.amount_inr, ...` — no `t.source`, despite the column existing and being written by `insertTransactionAndUpdateState`) — trivial one-line addition to the `SELECT`.
- "Split" is new scope not covered by Task C-0c — check `database.sql` for a `transaction_splits` table (referenced in the old architecture doc's RLS table list) before assuming it needs a migration; if it exists but is unused, this is the first consumer.
- "Better card existed" panel reuses D1/D6's shared calculator (see above) — do not build a third copy.
- **Skill:** `flutter-riverpod-gorouter`.
- **DoD:** deep link `/activity/<id>` opens directly, matching C2's same requirement.

### D3. Edit Transaction (new)
All fields editable, explicit save/cancel, changes logged, recomputes caps/milestones on save.
- Pure UI layer on top of Task C-0c's `PATCH /transactions/:id`.
- "Changes logged" — check whether an audit trail is expected here (the admin side already has `admin_audit_log` for admin actions; user-initiated edits may need their own lightweight log, or may be fine relying on Postgres row history / `updated_at`. Confirm scope before building — don't invent an audit table nobody asked for).
- **Skill:** `flutter-riverpod-gorouter`. **Skill:** `test-driven-development` — write the "edit changes the amount, cap-consumed total updates correctly" test *before* the UI, since that's the actual risk here, not the form itself.

### D4. Needs Review Queue ⭐ (new)
Unparsed messages with raw text shown, one-tap fill of missing fields, "not a transaction" dismiss (teaches the parser), bulk dismiss, never silently drop data.
- Backend gap: `parser_failures` ([database.sql:820](database.sql)) is written on every failed SMS parse today but has **no user-facing read/resolve route** — only implicitly feeding admin `parser_patterns` tuning. Need `GET /parser-failures` (scoped to the signed-in user — check whether `parser_failures` even carries a `profile_id`/user-scoping column today; if it doesn't, this is a schema gap, not just a missing route, since "raw text shown for context" implies the failure needs to be attributable to a user in the first place).
- "One-tap fill of missing fields" → effectively a mini D3 (edit) that also creates the transaction rather than editing an existing one, then dismisses the queue item.
- "Not a transaction" dismiss should feed back into `parser_patterns` tuning per the existing admin-side machinery (`success_count`/`failure_count` already tracked at [index.js:1268](api/src/index.js)) — at minimum, log it distinctly from a silent ignore so the admin console's existing parser-pattern telemetry can eventually use it.
- **Skill:** `flutter-riverpod-gorouter` for the queue UI. **Skill:** `systematic-debugging` before touching `parser_failures`' schema — confirm the actual column set in a live migration file, not just the aspirational `database.sql`, since this project has both an early aspirational schema and the real migrations under `db/supabase/migrations/` (per comments elsewhere in `index.js` referencing that path) — check which one `api/` is actually querying against before adding a column.
- **DoD:** "never silently drop data" is testable — every `parser_failures` row the user sees must resolve to exactly one of {transaction created, explicitly dismissed as not-a-transaction}, no third silent state.

### D5. Duplicate Review (new)
Side-by-side suspected duplicates (same amount+merchant+date across channels), merge/keep both/delete one, explains why flagged.
- `duplicate_candidates` table exists ([database.sql:671](database.sql)) but nothing writes to it — detection logic (§5.8 in the traceability matrix) needs to run somewhere. Natural home: inside `insertTransactionAndUpdateState`, check for an existing transaction with matching amount+merchant+date(±window) across a *different* source before/after insert, and write a `duplicate_candidates` row rather than silently allowing two rows to coexist forever.
- This is backend-heavy relative to the other D screens — the Flutter side is a fairly simple side-by-side comparison view once `GET /duplicate-candidates` + resolve routes exist.
- **Skill:** `systematic-debugging` for the detection-logic design specifically (matching window tolerance, what counts as "same merchant" across an SMS-parsed name vs a manually-typed one) — this is exactly the kind of fuzzy-matching problem worth designing on paper before coding blind.
- **Skill:** `flutter-riverpod-gorouter` for the resulting screen once the data contract is settled.

### D6. Missed Opportunities (new)
Sub-optimal transactions only: used vs. better card, ₹ lost, running 90-day total, filter by card/category.
- Entirely dependent on the shared "was this the best card, in hindsight?" calculator flagged under D1 above. **Do not start D6 before that calculator exists and is tested** — building D6's UI against a stubbed/fake version of it will just mean redoing the screen once the real thing lands.
- **Skill:** `flutter-riverpod-gorouter` for the screen; the actual hard work here is `dagovalsusa-flutter-dev`/domain-package territory (pure Dart historical-recompute logic), not UI.
- **DoD:** the golden-fixture pattern already used for the live engine (`packages/pandapay_domain/test/golden_fixtures_test.dart`) gets at least one new fixture proving a known-suboptimal historical transaction is correctly flagged with the correct ₹-lost figure.

---

## 4. Sequencing

```
Task C-0 (domain model extension)  ─┬─> C5 Benefits Cheat Sheet   (fully unblocked, no backend work)
                                     ├─> C2 Fees/Benefits tabs
                                     └─> C6 Points & Expiry (partial — still needs ledger route)

Task C-0b (card-requests / error-reports routes) ─> C7, C8 (and dormant A8)

Task C-0c (PATCH /transactions/:id, ignore)       ─> D3, D2's mark-ignored action

C1 rebuild ──> C2 Card Detail ──> C4 Edit Card
     │
     └─> C3 Add Card picker (coordinate with Group A owner — shared with A7)

D1 extend (filters/grouping) ──┬──> "best card in hindsight" calculator ──┬──> D1's optimality indicator
                                │                                          └──> D6 Missed Opportunities
                                └──> D2 Transaction Detail ──> D3 Edit Transaction

D4 Needs Review Queue  — mostly independent, gated on confirming parser_failures' real schema/migration
D5 Duplicate Review    — mostly independent, gated on detection logic landing in insertTransactionAndUpdateState
```

**Recommended build order:** Task C-0 → C5 → C1 rebuild → C2 → C4 → C3 (coordinate timing with A7) → C7/C8 (after C-0b) → C6.
Then, in parallel on the D side once free: D1 extensions → D2 → D3 (after C-0c) → the shared hindsight calculator → D6 → D4 and D5 (can run concurrently with anything above; both are largely backend-schema-confirmation-gated rather than dependent on C or the rest of D).

**Explore first, every task:** several tasks above ("confirm the real migration," "confirm whether `transaction_splits` exists," "confirm `parser_failures`' user-scoping") depend on facts about the live schema that this plan flags but doesn't resolve — resolve them with `Explore` against `db/supabase/migrations/` before writing the corresponding backend code, not by assuming `database.sql` (which reads as an early/aspirational combined schema doc, given Group B's own code comments already note discrepancies between it and what's live).

## 5. Cross-cutting, applies to every task above

Per this project's `CLAUDE.md` "workflow discipline" table, apply throughout rather than per-screen:
- **`brainstorming`** before starting any screen whose scope is ambiguous above (flagged explicitly: C3/A7 sharing, D2 split, D4 schema gap, D5 detection tolerance).
- **`test-driven-development`** for every backend recompute path (Task C-0c, D3, D5's detection logic) — these are exactly the "silent drift" bugs that are cheap to prevent with a test and expensive to find later.
- **`owasp-mobile-security-checker`** proactively on Task C-0b and C7 (new auth-gated write surfaces, one of which accepts a user-submitted card photo).
- **`verification-before-completion`** before marking any task done — every screen above has an explicit DoD; don't claim done without running it.
- **`requesting-code-review`** before merging each task, standard for this repo.

Every screen, per ui-spec's own Cross-Cutting Requirements (unconditional, not optional per-screen):
- Every financial figure through `MoneyText`/confidence-badged widgets — [widgets.dart](app/lib/app/design/widgets.dart) already has `EmptyState`/`ErrorState`/`StatusPill`; `MoneyText` currently lives in `main.dart` (imported by `activity_screen.dart` via `show MoneyText`) — worth relocating into `app/design/widgets.dart` proper as part of whichever task first needs it in a new file, so it stops being an odd cross-import from `main.dart`.
- Loading (skeleton, never blank) / empty / error / offline states on every new screen, using the existing `EmptyState`/`ErrorState` components — don't hand-roll new ones.
- 48dp touch targets, screen-reader labels, 200% text scale, never colour-alone for meaning (explicitly relevant to C1's cap/utilization bars and C6's expiry urgency).
