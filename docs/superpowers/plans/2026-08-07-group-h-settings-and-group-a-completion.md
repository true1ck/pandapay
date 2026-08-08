# Group H (Settings & Account) + Group A completion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the 10 Group H screens (Settings & Account) — the only spec group with zero prior plan — and finish Group A's 5 remaining screens (A6 Password Reset, A7 Add Your First Card, A8 Request Unsupported Card, A9 Card Details Setup, A10 Tracking Setup), so all of Groups A and H match `ui-spec.md`.

**Architecture:** Same stack as every sibling plan (`implementation-plan-group-c-d.md`, `implementation-plan-group-e-f-g.md`): Express routes in `api/src/index.js` behind `requireAuth`/`withUserClient` (RLS via `SET LOCAL app.user_id`), Riverpod providers in `app/lib/app/providers.dart`, screens under `app/lib/features/`, go_router entries in `app/lib/app/router.dart`. New Postgres tables ship as additive migrations (`db/supabase/migrations/0019+`), never edits to already-applied files.

**Tech Stack:** Flutter (Riverpod 2.6.1 codegen-free `Provider`/`StateNotifierProvider`, go_router 14.x), Node/Express `api/`, Postgres (RLS), `pandapay_domain` (pure Dart).

## Global Constraints

- DPDP §8.2: consent must be purpose-specific, unbundled, timestamped, versioned, auditable — never a single "I agree to everything" checkbox (`user_consents` table, already exists, currently has zero write path — Task H-0).
- Account deletion is double-confirmed with **typed** input and a **grace period** — never an immediate hard delete from the UI (spec §Destructive actions, H2).
- Local (no-account) mode must stay genuinely first-class — H settings that require a signed-in profile must degrade, not nag (mirrors A3's existing "no dark patterns" principle already in `account_choice_screen.dart`).
- Notification defaults are conservative (H3) — every category ships **off or minimal** by default, matching `0014_seed_reference.sql`'s existing `geofence_notifications: false` seed.
- Never encode meaning in colour alone; 48dp minimum touch targets; text scales to 200% (spec §Accessibility) — applies to every new screen below same as existing ones.
- Every financial figure carries an estimated/confirmed badge — not applicable to H (no financial figures) but applies to A9's credit-limit/points fields, which reuse `MoneyText`/`Confidence` exactly like C4's pattern.
- `custom_lint`'s `no_bare_money_text` / `no_datetime_now_outside_clock` rules apply to every new file (`dart run custom_lint` must stay clean).
- Skill routing for every task below comes from this project's `CLAUDE.md` — `flutter-riverpod-gorouter` is the default for all screen/provider/route work; `flutter-tester` for new tests; `owasp-mobile-security-checker` before Task H-2 (account deletion) and Task H-4 (consent/privacy) ship, since both touch auth/PII.

---

## 0. Audit — what already exists (read before writing any code)

| Screen | State | File(s) / table(s) |
|---|---|---|
| **A1-A3, A5, A11** | Built | `splash_screen.dart`, `welcome_screen.dart`, `account_choice_screen.dart`, `login_screen.dart`, `tutorial_overlay.dart` |
| **A4 Sign Up** | Built, but non-compliant with the spec's consent requirement — `LoginScreen(mode: signUp)` shows one bundled footer sentence ("By continuing you agree to..."), not the three separate purpose-specific checkboxes (required Terms, optional data-contribution, optional product emails) | [login_screen.dart:254-260](app/lib/features/auth/login_screen.dart) |
| **A6 Password Reset** | **Does not apply as specced.** This app is OTP-only (phone or email code, `AuthMode`/`_SignInMethod` in `login_screen.dart`) — there has never been a password to reset. `auth/`'s route surface confirms this (`request-otp`/`verify-otp`/`request-email-otp`/`verify-email-otp`, no password routes at all). Treated below as a documented divergence + a small real gap (no path exists today for "my OTP isn't arriving") rather than inventing a password system nothing else uses |
| **A7 Add Your First Card** | Does not exist as an onboarding screen. `cards_screen.dart`'s `_AddCardForm` is a single dropdown (C3's known gap, out of this plan's scope) — not reused here; A7 needs the spec's actual search/group-by-issuer/multi-select/network-filter picker | — |
| **A8 Request Unsupported Card** | Screen does not exist. Backend **already exists**: `POST /card-requests` ([index.js:550](api/src/index.js)) inserts into `card_requests` scoped to `req.userId` | — |
| **A9 Card Details Setup** | Does not exist. Backend gap: `POST /user-cards` only accepts `cardProductId`/`nickname` ([index.js:1076](api/src/index.js)) — no route writes `credit_limit_inr`, `statement_day`, `due_day`, or an initial points balance after add | — |
| **A10 Tracking Setup** | Does not exist as an onboarding screen. F1-F4 (email forwarding, SMS, statement import) all exist as post-onboarding Account→Tools screens already | [import_hub_screen.dart](app/lib/features/import/import_hub_screen.dart) |
| **H1 Settings Hub** | Does not exist. `AccountScreen`'s "Tools" tile list is the closest thing today, but it mixes G/F entry points with account actions, not a real Account·Notifications·Privacy·Data·Appearance·Help·About hub | [account_screen.dart](app/lib/features/account/account_screen.dart) |
| **H2 Account** | ~15% built — shows signed-in state + sign-out only. No biometric toggle, no "upgrade from local mode" entry, no delete-account flow at all. Backend: `pandapay.execute_account_deletion()` SQL function exists ([0010_functions_and_views.sql:329](db/supabase/migrations/0010_functions_and_views.sql)) and `profiles.deletion_requested_at`/`deletion_due_at` columns already exist ([0004_user_domain.sql:10](db/supabase/migrations/0004_user_domain.sql)) — **nothing calls either today**. `auth/`'s own `DELETE /users/:id`-shaped route exists too (`auth/src/routes/userRoutes.js`) | [account_screen.dart](app/lib/features/account/account_screen.dart) |
| **H3 Notification Settings** | Does not exist, and no schema at all — `remote_config` only has global (not per-user) `notification_daily_cap`/`geofence_notifications` defaults ([0014_seed_reference.sql:35](db/supabase/migrations/0014_seed_reference.sql)). Genuine new-table gap, not a wiring gap | — |
| **H4 Privacy & Permissions** | Does not exist as a screen. `user_consents` table exists ([0004_user_domain.sql:29](db/supabase/migrations/0004_user_domain.sql)) — purpose/policy_version/granted/timestamps, exactly DPDP-shaped — but has **zero read or write routes**. `profiles.contributions_opt_in` + `POST /profile/contributions-opt-in` already work (E12 built this, explicitly flagged in its own doc-comment as "H4 out of scope, this becomes its first consumer") | [my_contributions_screen.dart](app/lib/features/insights/my_contributions_screen.dart) |
| **H5 Data & Storage** | Does not exist. Storage-used/cache-clear/record-counts are device-local concerns (`path_provider`, existing repositories for counts) — no new backend needed. "Reset all data" (destructive, double-confirmed) is local-cache-only here; it must NOT be confused with H2's account deletion | — |
| **H6 Appearance** | Does not exist. `profiles.number_format` exists server-side (default `'lakh_crore'`) but nothing reads/writes it from the client; `Money.format()` in `pandapay_domain` doesn't yet branch on a format preference — confirmed by reading [money.dart] there's exactly one lakh/crore formatter today | [packages/pandapay_domain/lib/src/money.dart](packages/pandapay_domain/lib/src/money.dart) |
| **H7 Help & FAQ** | Does not exist. Spec requires it offline-readable — this is static bundled content, no backend | — |
| **H8 Legal** | Does not exist. Terms/Privacy Policy text is static; OSS licences can use Flutter's built-in `showLicensePage()`; ODbL attribution is static copy (the geofence feature already uses OSM-sourced merchant data per `nearby_merchants_repository.dart`, so this attribution is a real legal obligation, not decorative) | — |
| **H9 Feedback & Support** | Screen does not exist. Backend **already exists**: `support_tickets` table ([0009_platform_ops.sql:48](db/supabase/migrations/0009_platform_ops.sql)) with `kind` enum (`bug`/`wrong_card_data`/`card_request`/`general`) and a `diagnostics jsonb` column matching the spec's "shown to user before sending" requirement exactly — but **no route reads or writes it** | — |
| **H10 What's New** | Does not exist. `changelog_entries` table exists ([0009_platform_ops.sql:39](db/supabase/migrations/0009_platform_ops.sql), `app_version`/`title`/`body_markdown`/`highlights_data_change`/`published_at`) — no route, and no client-side "last version seen" tracking | — |

**The one finding that reshapes this plan:** exactly like the C/D and E/F/G plans before it, the backend has already run ahead in three places — `execute_account_deletion()`, `user_consents`, `support_tickets`, and `changelog_entries` are all fully-shaped tables with **zero routes**. H2, H4, H9, and H10 are "write the route + build the screen," not "design new persistence." The one **real** schema gap in this whole plan is **H3 Notification Settings** — no per-user preference storage exists anywhere, confirmed by grepping every migration for `notification`.

---

## 1. Cross-cutting foundations (build once, shared by H and A)

### Task H-0 ⭐ `user_consents` read/write routes (unblocks A4's real checkboxes, H4, and H2's audit trail)
**Why first:** A4 (this plan), H4, and H8's Terms link all need a single consistent way to record/read consent.
- **File:** `api/src/index.js`, add near the existing `/profile/contributions-opt-in` route (~line 1859).
- `GET /consents` `requireAuth` → returns the latest row per `purpose` for `req.userId` (a `DISTINCT ON (purpose) ... ORDER BY purpose, granted_at DESC` query), so H4 can show current state without replaying full history for now/later use in H4's "consent history" list (which just orders the same table unfiltered).
- `POST /consents` `requireAuth` → body `{purpose, granted, policyVersion, sourceScreen}`. Validates `purpose` is one of `'terms' | 'crowdsource' | 'marketing'` (matches the column comment in `0004_user_domain.sql`), `granted` is boolean, `policyVersion` is a non-empty string. Inserts a **new row** every call (never updates in place — `user_consents` is an append-only audit log by design, confirmed by its column shape: `granted_at`/`revoked_at` per row, not a single mutable state).
- **DoD:** `curl -X POST /consents` with a real token inserts a row; a second call with `granted:false` inserts a second row rather than mutating the first; `GET /consents` returns only the latest-per-purpose view. Verify via psql directly (same verification style as every prior chunk in `PROGRESS.md`), not just "the code looks right."

### Task H-0b `PATCH /user-cards/:id` — unblocks A9 and (later, out of scope) C4
- **File:** `api/src/index.js`, add after `POST /user-cards/:id/archive` (~line 1110).
- Body: `{nickname?, creditLimitInr?, statementDay?, dueDay?}` — all optional, only provided fields are updated (`COALESCE`-style dynamic `UPDATE`). `statementDay`/`dueDay` validated `1-31` if present; `creditLimitInr` validated `>= 0` if present.
- Scoped `WHERE id = $1 AND profile_id = $2` (never trust a client-supplied owner).
- **DoD:** patching a card's `creditLimitInr` then calling `GET /user-cards` reflects it immediately (same card the E3 Credit Utilization screen already reads `creditLimit` from — this is a real, not cosmetic, unblock).

### Task H-0c Migration `0019_notification_preferences.sql`
- **File:** create `db/supabase/migrations/0019_notification_preferences.sql`.
```sql
-- >>> MIGRATION 0019 — NOTIFICATION PREFERENCES (H3) ==========================
create table notification_preferences (
  profile_id          uuid primary key references profiles(id) on delete cascade,
  category_location   boolean not null default false,
  category_caps       boolean not null default true,
  category_milestones boolean not null default true,
  category_fee_waivers boolean not null default true,
  category_bills      boolean not null default true,
  category_expiry     boolean not null default true,
  category_monthly_report boolean not null default false,
  category_needs_review boolean not null default true,
  quiet_hours_start   time,                 -- null = no quiet hours set
  quiet_hours_end     time,
  daily_cap           int not null default 3 check (daily_cap between 0 and 20),
  updated_at          timestamptz not null default now()
);
create trigger trg_notification_preferences_touch before update on notification_preferences
  for each row execute function pandapay.touch_updated_at();

create table notification_muted_merchants (
  profile_id          uuid not null references profiles(id) on delete cascade,
  merchant_id         uuid not null references merchants(id) on delete cascade,
  muted_at            timestamptz not null default now(),
  primary key (profile_id, merchant_id)
);

alter table notification_preferences enable row level security;
alter table notification_preferences force row level security;
create policy notification_preferences_owner on notification_preferences
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());

alter table notification_muted_merchants enable row level security;
alter table notification_muted_merchants force row level security;
create policy notification_muted_merchants_owner on notification_muted_merchants
  for all to public using (profile_id = pandapay.uid()) with check (profile_id = pandapay.uid());
```
- Apply it against the local Postgres the same way `0018_imap_connections.sql` was applied (`psql ... -f db/supabase/migrations/0019_notification_preferences.sql`).
- **DoD:** `\d notification_preferences` in psql shows `rowsecurity = t`; as `app_user` with no `app.user_id` set, `select * from notification_preferences` returns zero rows (same RLS-proof pattern Chunk 6/7 used, not assumed).

### Task H-0d Notification preference routes
- **File:** `api/src/index.js`, new routes near Task H-0c's table.
- `GET /notification-preferences` `requireAuth` → returns the row, or the column defaults (as a plain object, not a DB round-trip) if none exists yet — a user who never touched H3 must still see sane conservative defaults, not a loading error.
- `PUT /notification-preferences` `requireAuth` → upsert (`INSERT ... ON CONFLICT (profile_id) DO UPDATE`) accepting any subset of the boolean/time/int columns.
- `GET /notification-preferences/muted-merchants` `requireAuth` → list with merchant name joined.
- `POST /notification-preferences/muted-merchants` `requireAuth` → body `{merchantId}`, upsert into `notification_muted_merchants`.
- `DELETE /notification-preferences/muted-merchants/:merchantId` `requireAuth`.
- **DoD:** a fresh user's `GET /notification-preferences` returns `category_caps: true, category_location: false, ...` (the conservative defaults) with no row ever inserted; `PUT` then `GET` round-trips.

### Task H-0e Backend: account deletion, support tickets, changelog — three small routes together (same shape, batch them)
- **File:** `api/src/index.js`.
- `POST /account/delete-request` `requireAuth` → sets `profiles.deletion_requested_at = now()`, `deletion_due_at = now() + interval '30 days'`. Returns `{deletionDueAt}`. **Does not call `execute_account_deletion()`** — that fires later from a scheduled job outside this plan's scope (flagged explicitly in Task H-2's screen below, not silently assumed).
- `DELETE /account/delete-request` `requireAuth` → clears both columns (cancels a pending deletion — the grace-period escape hatch the spec requires).
- `POST /support-tickets` `requireAuth` → body `{kind, message, diagnostics?, appVersion?}`, validates `kind` against the same 4-value check the DB enum already enforces (`bug|wrong_card_data|card_request|general`) so a bad value 400s before hitting the DB constraint.
- `GET /changelog` — **no auth required** (release notes aren't PII) — `SELECT * FROM changelog_entries ORDER BY published_at DESC LIMIT 20`.
- **DoD:** each route tested with a real token/no token as appropriate via curl against the live seeded DB; `POST /account/delete-request` then `GET /profile` shows `deletion_due_at` 30 days out; `DELETE /account/delete-request` then `GET /profile` shows it cleared again.

### Task H-0f `Money` gains a lakh/crore-vs-plain formatting switch (unblocks H6)
- **File:** `packages/pandapay_domain/lib/src/money.dart`.
- **Interfaces:** `Money.format({NumberFormat format = NumberFormat.lakhCrore})` — add a `NumberFormat` enum (`lakhCrore`, `international`) as an optional named parameter with the existing behaviour as the default, so every one of the ~40 existing call sites keeps compiling unchanged.
- `international` formats with a plain thousands-separator (`₹12,34,567` → `₹1,234,567`) — the spec's only other option (§Localization: "Indian number formatting (lakh/crore)" implies the alternative is the plain international grouping, not a made-up third mode).
- **Test:** `packages/pandapay_domain/test/money_test.dart` — add cases for `Money.fromRupees(1234567).format(format: NumberFormat.international) == '₹12,34,567'`... — write the actual expected string for both formats and assert it, not a vague "formats correctly."
- **DoD:** existing `dart test` suite (58 tests) still green with zero call-site changes required elsewhere; new format cases pass.

---

## 2. Group A — remaining 5 screens

### A4 delta: real purpose-specific consent checkboxes
**Files:**
- Modify: `app/lib/features/auth/login_screen.dart`
- Modify: `app/lib/app/providers.dart` (add `consentsApiProvider`/`ConsentsApi`, mirroring `ProfileApi`'s shape)

- Replace the single footer sentence (lines 254-260) with three `CheckboxListTile`s, shown only when `_isSignUp`:
  1. **Required** — "I accept PandaPay's Terms & Privacy Policy" (purpose `terms`) — sign-up's submit button stays disabled until this is checked.
  2. **Optional, default off** — "Contribute anonymized merchant data to improve the app" (purpose `crowdsource`) — this is deliberately the same `contributions_opt_in` concept E12 already toggles; checking this here calls the existing `POST /profile/contributions-opt-in` after account creation, not a second table.
  3. **Optional, default off** — "Send me product update emails" (purpose `marketing`).
- On successful `verifyEmailOtp`/`verifyOtp` in `_verifyOtp()`, after `ensureProfile()`, call `POST /consents` once per checkbox with `sourceScreen: 'A4'` and `policyVersion` (a compile-time constant `currentPolicyVersion = '2026-08-07'` near the top of the file — versioned per the spec's own requirement, bumped by hand when Terms/Privacy text changes).
- **DoD:** signing up with the required box unchecked shows an inline validation message and never calls `verifyOtp`; signing up with all three checked produces 3 rows in `user_consents` (verified via psql) plus `profiles.contributions_opt_in = true`.

### A6: "trouble receiving your code?" (documented divergence, not a rebuilt password flow)
**Files:** Modify `app/lib/features/auth/login_screen.dart`'s `_OtpStep`.
- Add a third `TextButton` next to "Change"/"Resend code": **"Trouble receiving it?"** → pushes to a route that will exist after Task H-9's screen is built (`AppRoute.feedbackSupport`, kind pre-filled to `'general'`, message pre-filled with "I'm not receiving my OTP code."). This is the real functional equivalent the spec's "clear re-request path" asks for, in a system that has no password to reset.
- **DoD:** tapping it from mid-sign-in lands on Feedback & Support with the message field pre-filled; no dead-end.

### A7: Add Your First Card
**Files:**
- Create: `app/lib/features/onboarding/add_first_card_screen.dart`
- Modify: `app/lib/app/router.dart` (new route + `preOnboarding` membership)
- Modify: `app/lib/features/onboarding/account_choice_screen.dart` (both paths now continue to A7 instead of completing onboarding directly)

- Screen layout: search `TextField` (filters by card or issuer name, case-insensitive substring), network filter chips (`RuPay`/`Visa`/`Mastercard`/`Amex/Diners` — map to `CardNetwork`, `amex`/`diners` share one chip per the spec's own grouping), results grouped under issuer-name headers (`CardProduct.issuerName`, sorted alphabetically, cards within an issuer sorted by name), each row a checkbox tile with card art placeholder + name, running "N selected" count in the app bar.
- Data source: reuse `catalogueProvider` (already fetches the full published catalogue — same provider `_AddCardForm` in `cards_screen.dart` already watches).
- Footer: "My card isn't listed" → `context.push(AppRoute.requestUnsupportedCard)` (Task A8). Primary button "Continue" disabled at 0 selected, label shows count ("Add 3 cards").
- On Continue: call `userCardsRepositoryProvider.addCard(id)` for each selected id (sequential `await`s are fine — this is a handful of cards, not a bulk import), collect the resulting `userCardId`s, then `context.go(AppRoute.cardDetailsSetup, extra: addedUserCardIds)` (Task A9). If zero cards were successfully added because catalogue is empty (a real edge case per spec: "cannot proceed with 0 cards" is about the *picker*, but an empty catalogue is a fetch-error state, not a validation state) show `ErrorState` with retry, same as every other screen's catalogue-loading failure.
- **Route wiring:** `AppRoute.addFirstCard = '/onboarding/add-card'`, added to `preOnboarding`. In `account_choice_screen.dart`, `_useWithoutAccount` and `_createAccount` both `context.go(AppRoute.addFirstCard)` instead of completing onboarding — onboarding now only completes at the end of A10 (Task A10 below), matching the spec's actual screen order (A3 → A7 → A9 → A10 → A11 → Home).
- **DoD:** from a fresh install, choosing either A3 path lands on A7; selecting 2 cards and continuing calls `POST /user-cards` twice (verified via `read_network_requests` in a manual run) and lands on A9 with both new `userCardId`s.

### A8: Request Unsupported Card
**Files:** Create `app/lib/features/onboarding/request_unsupported_card_screen.dart` (also reachable later from C8 — same screen, no rebuild, per the C/D plan's own note that A8 and C8 are identical).
- Fields: issuer name (`TextField`, required), product name (`TextField`, required), optional network guess (dropdown of `CardNetwork` values, matches `POST /card-requests`'s `networkGuess` field which already exists server-side), optional photo — **explicit warning text above the photo picker**: *"Photograph the card face only — never the number, CVV, or expiry."* Use `image_picker` (check `pubspec.yaml` — add if not already a dependency) to attach a face-only photo; the picked file path is sent as `imagePath` (already an accepted field on `POST /card-requests`, currently unused by any client).
- Submit → `POST /card-requests` (already exists, [index.js:550](api/src/index.js)) via a new `CardRequestsApi` in `app/lib/data/`. On success, show a confirmation: *"Thanks — we've logged this. We'll let you know when it's added."* then pop back to A7.
- **DoD:** submitting without a photo still succeeds (photo is optional per spec); the request row appears in `card_requests` scoped to the real user id (verified via psql, same pattern every prior chunk used for a new write path).

### A9: Card Details Setup
**Files:** Create `app/lib/features/onboarding/card_details_setup_screen.dart`, accepts `List<String> userCardIds` via go_router `extra`.
- One card at a time (a `PageView` or simple index counter — "Card 2 of 3"), each with: nickname (pre-filled from the card's default name, editable), credit limit (`MoneyText`-style numeric entry, caption *"used to protect your credit score"*), statement generation date (day-of-month picker, caption *"used to maximise interest-free days"*), payment due date (day-of-month picker, caption *"for bill reminders"*), current points balance (numeric, caption *"starting point; we'll track from here"*) — **all fields skippable except nickname is pre-filled so it's never blank.**
- Points balance: since `points_ledger` (not `user_cards`) is the source of truth for `totalPointsEarned` and no route writes an initial balance yet, skip actually persisting the starting points number in this pass — show the field, but if the user enters one, call `logTransaction`-adjacent... **no** — do not invent a fake transaction to fake a points balance. Instead: only nickname/creditLimit/statementDay/dueDay are wired to `PATCH /user-cards/:id` (Task H-0b); the points-balance field is visibly present (spec requirement: field exists, explains why) but its submit handler is a documented no-op with an inline note *"Balance tracking starts from your next transaction"* until a real `POST /user-cards/:id/points-adjustment` route exists — **flag this explicitly in the screen's doc-comment**, don't silently drop the field's stated purpose.
- Skipping a field just leaves it null/default — same "skippable, no silent gap" pattern C4's own doc-comment (in the C/D plan) already commits to.
- "Next" / "Finish" (on the last card) → `PATCH /user-cards/:id` per card, then `context.go(AppRoute.trackingSetup)` (A10).
- **DoD:** setting a credit limit on card 1 of 2, skipping card 2 entirely, and finishing leaves card 1 with `credit_limit_inr` set and card 2 unchanged (verified via `GET /user-cards`).

### A10: Tracking Setup
**Files:** Create `app/lib/features/onboarding/tracking_setup_screen.dart`.
- Three channel cards, each with a one-line honest trade-off (copied verbatim from `ui-spec.md` A10): Email forwarding (~3 min, any phone) · SMS auto-read (Android only, instant — **only shown if `Platform.isAndroid`**) · Manual/statement import (no setup).
- "Recommended" badge on SMS auto-read when `Platform.isAndroid`, else on Email forwarding — mirrors A3's existing `_ChoiceCard` badge visual pattern.
- Tapping a channel pushes straight to the real screen: Email → `EmailForwardingScreen` (F3, exists), SMS → `SmsConsentScreen` (F4's consent step, exists), Manual → `StatementPdfImportScreen` (F2, exists) — reuses built screens, does not fork new onboarding-only copies.
- **"Set up later"** always visible, always enabled (spec: "never block onboarding completion on this"). Both this and returning from any of the three pushed screens call `ref.read(onboardingCompleteProvider.notifier).complete()` then `context.go(AppRoute.home)` — **this is where onboarding now actually completes**, moved from `account_choice_screen.dart`.
- **DoD:** tapping "Set up later" immediately reaches Home with onboarding marked complete (verify by relaunching — no more Welcome screen); on Android, SMS auto-read shows the RECOMMENDED badge, on iOS it isn't shown at all.

---

## 3. Group H — 10 screens

### H1. Settings Hub
**Files:** Create `app/lib/features/settings/settings_hub_screen.dart`.
- Section list per spec: Account · Notifications · Privacy & Permissions · Data · Appearance · Help · About — each a tappable row to its own screen (H2/H3/H4/H5/H6/H7/H8), plus a Feedback & Support row (H9) and a "What's New" row (H10) at the bottom with a small unread-dot if `changelogHasUnseenProvider` (Task H10) is true.
- `AccountScreen`'s current sign-out button and profile-row header move here (H2 owns account actions now); `AccountScreen` becomes a thin signed-in/signed-out gate that renders `SettingsHubScreen`'s content for the "Account" tab — i.e. **`AccountScreen` is not deleted, its body is replaced** by `SettingsHubScreen`, keeping the existing signed-out→`LoginScreen` gate exactly as-is (don't touch that gate, it's correct).
- The 5 existing `_AccountTile`s (Nearby merchants, Home-screen widget, SMS import, Import & sync, Travel & tools) move under a "Tools" section at the top, unchanged — this hub is additive, not a rewrite of what already works.
- **DoD:** the Account tab shows Tools (existing 5) + the 7 new H-section rows + Feedback + What's New; each row navigates; nothing existing regresses (`flutter test` still green for any existing `account_screen`-referencing test).

### H2. Account (real)
**Files:** Create `app/lib/features/settings/account_settings_screen.dart`; modify `app/lib/app/providers.dart` (biometric-toggle local pref, same `SharedPreferences` pattern as `dueDateRemindersProvider`).
- Shows: email/identifier (from `profileProvider`), sign-out (moved from `AccountScreen`), "Upgrade from local mode" — visible only when `accessTokenProvider` is null (local/guest mode) — pushes to `LoginScreen(mode: signUp)`; per spec, local data "migrates up" — **scoped honestly**: this pass wires the navigation and the account-creation call only; local→cloud data migration (moving locally-cached cards/transactions onto the new account) is flagged as a real, separate gap, not silently implied to work, since there is no local persistence layer for cards/transactions to migrate from yet (everything Cards/Activity show today is server-fetched once signed in — confirmed in `cards_screen.dart`/`activity_screen.dart`, neither has an offline cache). Biometric lock toggle: a local `SharedPreferences` bool (`biometric_lock_enabled_v1`) with a caption noting it gates app-open, not any individual screen (actual biometric-prompt enforcement is out of scope — this pass ships the toggle + persisted state, matching H1's "toggle exists, wiring is real, enforcement is a documented follow-up" honesty pattern used elsewhere in this codebase's history).
- **Delete account** flow: a red destructive section.
  1. Explains exactly what's deleted and when: *"Your account, cards, and transaction history will be permanently deleted in 30 days. Crowdsourced merchant data you've contributed stays anonymous and is never linked back to you."* (matches `execute_account_deletion()`'s actual scope — don't overclaim backups are purged on a schedule this app doesn't control; state the DB comment's own honest caveat instead: *"Backups are purged on their own retention schedule."*)
  2. Typed confirmation: a `TextField` requiring the user to type `DELETE` exactly before the confirm button enables.
  3. Confirm → `POST /account/delete-request` (Task H-0e). Shows the returned due date, a "Cancel deletion" button (calls `DELETE /account/delete-request`), then signs the user out locally (clear token, same as the existing sign-out path) — **the account isn't gone yet**, just scheduled; this must never claim otherwise.
- **DoD:** typing `delet` (typo) keeps confirm disabled; typing `DELETE` enables it; confirming sets `deletion_due_at` (verified via psql) and signs the device out; a second sign-in within 30 days can reach this screen again and cancel (verified: `deletion_due_at` becomes null).

### H3. Notification Settings
**Files:** Create `app/lib/features/settings/notification_settings_screen.dart`; `app/lib/data/notification_preferences_repository.dart` (new, mirrors `user_cards_repository.dart`'s shape); providers in `app/lib/app/providers.dart`.
- Per-category `SwitchListTile`s for the 8 categories in `notification_preferences` (location/caps/milestones/fee waivers/bills/expiry/monthly report/needs-review) — labels and default states must visibly match the conservative defaults from Task H-0c's migration (location and monthly-report default OFF, the rest default ON — shown as pre-toggled, not fetched-then-flipped).
- Quiet hours: two time pickers (start/end), "Off" state when either is null.
- Daily frequency cap: a `Slider` or stepper, 0-20, bound to `daily_cap`.
- Per-merchant mute list: a simple list of currently-muted merchants (name + unmute button) fed by `GET /notification-preferences/muted-merchants` — this screen only **manages** existing mutes (spec doesn't require a merchant search here; muting is created contextually elsewhere, e.g. a future "mute this place" action on a geofence notification, which is out of this plan's scope and flagged as such — the list/unmute half is real and complete).
- Every toggle/change calls `PUT /notification-preferences` immediately (no separate Save button — matches the pattern every other settings-style toggle in this codebase uses, e.g. `contributions_opt_in`'s immediate-write toggle in `my_contributions_screen.dart`).
- **DoD:** toggling "Caps" off then relaunching the app shows it still off (round-trips through the real backend, not just local state); setting quiet hours 22:00-07:00 and reading back via `GET` returns the same values.

### H4. Privacy & Permissions
**Files:** Create `app/lib/features/settings/privacy_permissions_screen.dart`.
- Permission rows (Location, Camera for QR scan, SMS if Android): each shows current OS-level state via `permission_handler` (already a dependency — confirmed used by `nearby_merchants_repository.dart`/`sms_listener_service.dart`), a one-line purpose ("used to detect which store you're at"), and a "Settings" deep link (`openAppSettings()` from `permission_handler`) when denied.
- Plain-language data-handling summary: three static sections — "Stays on this phone" / "Uploaded to sync your account" / "Anonymized before it ever leaves your phone" — copy pulled directly from `product-plan.md`'s own §6 language (read that file's crowdsource section before writing final copy, don't invent new claims about what's anonymized).
- **Crowdsource contribution toggle** — reuses `setContributionsOptIn`/`contributions_opt_in` exactly as E12 already does (literally the same provider call, not a duplicate).
- **Consent history** — a read-only list from `GET /consents`'s full (not latest-only) variant: add `GET /consents/history` `requireAuth` returning every row ordered by `granted_at DESC`, each line "Terms — accepted 12 Mar 2026" / "Marketing — declined 12 Mar 2026" (declined = a `granted:false` row, per Task H-0's append-only design).
- **DoD:** a denied camera permission shows "Settings" and tapping it opens the OS settings page (manual verification, permission dialogs aren't automatable in this environment — document that it was checked, don't fake a screenshot of an OS dialog); consent history shows all rows written by A4 in order.

### H5. Data & Storage
**Files:** Create `app/lib/features/settings/data_storage_screen.dart`.
- Storage used: `path_provider`'s `getApplicationCacheDirectory()` recursive size sum (a small local util, no backend).
- Record counts: reuse `userCardsProvider`/`fetchTransactions()` lengths already fetched elsewhere — **do not add a new counting endpoint**, `GET /user-cards` and `GET /transactions` already return full lists client-side.
- "Clear cache": deletes the cache directory contents (images/temp files only — never `SharedPreferences`/tokens).
- "Re-download bundled POI data": `ref.invalidate(nearbyMerchantsProvider)` (forces a re-fetch) plus `ref.invalidate(catalogueProvider)` — a real, if simple, forced refresh, not a fabricated progress bar over nothing.
- **"Reset all data"** — destructive, double-confirmed (a confirm dialog with an explicit "This clears local cache only — your account and cards are untouched" caption, to avoid the exact confusion the spec is careful to distinguish from account deletion): clears cache dir + all local `SharedPreferences` **except** the token store (so it doesn't accidentally sign the user out — that's H2's job, not H5's).
- **DoD:** clearing cache measurably reduces the reported storage-used number on next screen visit; reset-all-data does not clear `TokenStore` (verified: still signed in afterward).

### H6. Appearance
**Files:** Create `app/lib/features/settings/appearance_screen.dart`; providers in `app/lib/app/providers.dart` (new `numberFormatProvider`, `textScaleProvider` — both local `SharedPreferences`-backed, same `OnboardingController` pattern).
- Theme: light/dark/system — wires into `MaterialApp`'s `themeMode` (check `main.dart`/`app_theme.dart` for whether dark theme data exists yet; if `AppColors`/`app_theme.dart` is light-only today, this task includes adding a minimal dark `ThemeData` variant, not just a switch with nothing to switch to).
- Text size: a stepper (`85% / 100% / 115% / 130%`), applied via `MediaQuery.textScalerOf` override at the app root — must be verified against the spec's own "200%" accessibility ceiling (§Accessibility) by also testing the OS-level system text-scale still stacks correctly, not fighting it.
- Card art style: out of scope for a real toggle (no alternate art assets exist in this catalogue yet — flag this explicitly rather than shipping a toggle with one option).
- Number format: lakh/crore vs international, using Task H-0f's new `Money.format(format:)` parameter — this needs a way for **every** `MoneyText` call site to read the preference without threading a parameter through 40+ call sites. Add a `Provider<NumberFormat> numberFormatProvider` and change `MoneyText` (in `app/lib/app/design/widgets.dart`) to `ref.watch` it internally and pass it to `.format()` — this is the one call site that needs editing, not all its callers.
- **DoD:** switching number format and revisiting Home shows the hero recommendation's ₹ value in the new format; switching theme to dark and relaunching persists it.

### H7. Help & FAQ
**Files:** Create `app/lib/features/settings/help_faq_screen.dart`.
- A static, searchable (client-side substring filter over an in-memory `List<({String question, String answer})>`) list covering exactly the 5 topics the spec names: setup, tracking channels, why a recommendation looked wrong, accuracy, privacy. Write real answers (2-4 sentences each) grounded in what this app actually does — e.g. "why a recommendation looked wrong" should reference the real `RecommendationEngine.rank()` factors (cap headroom, milestone contribution, RuPay/UPI eligibility) so the copy doesn't drift from the actual logic.
- Fully offline — no network calls, satisfies the spec's "offline-readable" requirement trivially since it's bundled Dart data.
- **DoD:** searching "wrong" surfaces the relevant FAQ entry; screen renders with airplane-mode-equivalent (no provider that requires network).

### H8. Legal
**Files:** Create `app/lib/features/settings/legal_screen.dart`.
- Terms of Service / Privacy Policy: static text sections (source from `product-plan.md` if it has drafted copy; otherwise placeholder legal text clearly labelled `[Draft — pending legal review]` in a comment, never presented to the user as finalized language it isn't — this is a real product-honesty requirement, not a style choice).
- Not-financial-advice disclaimer: the exact copy already used in spirit by `product-plan.md`/other H8 references — one clear paragraph, own section (not buried).
- Open-source licences: `showLicensePage(context: context)` — Flutter's built-in, already aggregates every package's licence from `pubspec.lock`, zero new content to maintain.
- OpenStreetMap ODbL attribution: *"Merchant location data includes information © OpenStreetMap contributors, available under the Open Database License."* — required copy, not optional, since `nearby_merchants_repository.dart` already consumes OSM-derived data.
- **DoD:** licence page opens and lists real dependencies (e.g. `flutter_riverpod`, `go_router`); ODbL line renders exactly as required by the licence (verify wording against osm.org's own attribution guideline page before finalizing).

### H9. Feedback & Support
**Files:** Create `app/lib/features/settings/feedback_support_screen.dart`, accepts optional `{String? prefilledKind, String? prefilledMessage}` via go_router `extra` (consumed by A6's "Trouble receiving it?" link).
- Kind selector (segmented control: Bug · Wrong card data · Request a card · General) — "Request a card" here should visibly link to A8/C8's dedicated flow instead of duplicating it (a `TextButton`: "Request a specific card instead" → pushes `RequestUnsupportedCardScreen`), keeping this screen's own `kind: 'card_request'` submissions for cases that don't fit that structured flow.
- Free-text message field.
- Optional diagnostics toggle: when on, **shows the exact JSON that will be sent** (app version, platform, a redacted last-few-log-lines placeholder — keep it real: `{"appVersion": ..., "platform": ...}`, don't fabricate a fake stack trace) in a collapsible preview **before** the user can submit — literal spec requirement ("shown to user before sending").
- Submit → `POST /support-tickets` (Task H-0e). Confirmation states a response expectation: *"We typically respond within 2 business days."*
- **DoD:** the diagnostics preview shows real, current `appVersion`/platform values (via `package_info_plus`, add if absent) before submit; a submitted ticket appears in `support_tickets` scoped to the real user (psql-verified).

### H10. What's New
**Files:** Create `app/lib/features/settings/whats_new_screen.dart`; providers in `app/lib/app/providers.dart` (`changelogProvider` fetching `GET /changelog`, `lastSeenAppVersionProvider` — local `SharedPreferences`, same pattern family as the rest of this plan's local prefs).
- Shown **once per version bump**, automatically, right after Home first renders post-launch if `lastSeenAppVersionProvider.value != currentAppVersion` (from `package_info_plus`) **and** at least one changelog entry's `app_version` is newer than the last-seen value — a modal bottom sheet, not a blocking route (never gate Home behind it).
- Also reachable any time from H1's "What's New" row (manual re-read).
- Each entry renders `title` + `body_markdown` (a minimal markdown renderer — check `pubspec.yaml` for an existing markdown package before adding one; if none exists, render `body_markdown` as plain text with basic `**bold**`/`- bullet` stripping rather than pulling in a new heavy dependency for a settings screen) and a highlighted badge when `highlights_data_change` is true (per spec: "especially important when reward data or recommendation logic changes").
- On dismiss, sets `lastSeenAppVersionProvider` to `currentAppVersion`.
- **DoD:** seeding one `changelog_entries` row with a newer `app_version` than the stored last-seen value and relaunching shows the sheet automatically once, and not again on a second relaunch without a version bump (verified by checking `SharedPreferences` state, not just visual inspection).

---

## 4. Sequencing

1. **H-0, H-0b, H-0c, H-0d, H-0e, H-0f** (backend + domain foundations) — independent of each other, can run in parallel across separate subagents.
2. **A4 delta, A6** — small, depend only on H-0 (consents) and H9 existing (A6 links to it, so build H9 first or stub the route and wire the link last).
3. **A7 → A8 → A9 → A10** — strictly sequential (each hands off state/routes to the next); A9 depends on H-0b, A10 depends on F1-F4 already existing (they do).
4. **H1** after H2-H10 exist (it's the index linking to all of them) — or build H1 first with placeholder rows and fill links in as each screen lands; either order works, but **do not ship H1 linking to a route that 404s** — build leaf screens before or alongside the hub, verify each link as it's added.
5. **H2, H9, H10** before A6's link and H1's unread-dot depend on them — sequence-sensitive.
6. **H3, H4, H5, H6, H7, H8** — independent of each other and of Group A, can run fully in parallel.

## 5. Cross-cutting, applies to every task above

- Every new route follows the existing `withUserClient(req.userId, ...)` + RLS pattern — never a raw pool query for anything user-scoped.
- Every new screen follows the existing `sessionInit.isLoading` → `accessTokenProvider == null → LoginScreen` → `provider.when(loading/error/data)` gate already established in `account_screen.dart`/`cards_screen.dart`, except where a screen is explicitly spec'd to work signed-out (H7 Help, H8 Legal — both must render without auth; G4 Emergency Card Info already sets this precedent).
- Every new migration is additive-only (`0019+`), applied and verified the same way `0018_imap_connections.sql` was — never edit an already-applied migration file.
- `flutter analyze` / `dart analyze` / `dart run custom_lint` clean, and the full existing test suite green, before any task is considered done — regressions in already-shipped Groups B/C/D/E/F/G screens are not acceptable collateral from this plan.
