# PandaPay Beta Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take PandaPay from 9 of 66 spec'd screens (14%) to a ~30-screen beta that real users can run on a phone, by surfacing the 8 already-built engine capabilities that currently have no UI, adding onboarding + tutorial, completing email+phone auth, and shipping all three card-detection channels (Gmail OAuth, SMS, email forwarding).

**Architecture:** Migrate navigation from int-index tabs + raw `MaterialPageRoute` to `go_router` with a `ShellRoute` bottom-nav and an auth/onboarding redirect guard — required before ~30 screens is tractable. Every new screen is a `ConsumerWidget`/`ConsumerStatefulWidget` reading Riverpod 2.6.1 providers, styled exclusively through `lib/app/design/app_theme.dart` tokens. Email scanning deliberately reuses the **existing** `parser_patterns` table (it already has a `channel` column that accepts `'email'`) and the existing `sms_parser.js` regex engine, so Gmail/forwarding/SMS all converge on one parser and one `insertTransactionAndUpdateState()` write path.

**Tech Stack:** Flutter 3.44 · Riverpod 2.6.1 (no codegen for new providers — match existing hand-written style) · go_router 14.6.2 · google_fonts · flutter_animate · Node/Express + Postgres RLS · `google_sign_in` + Gmail API v1 (readonly).

## Global Constraints

- **Riverpod 2.6.1**, not 3.0. `dagovalsusa-*` skill examples assume 3.0 — adapt, never upgrade the package on a skill's say-so (per `CLAUDE.md`).
- **All money renders through `MoneyText`** with an explicit `Confidence`. A bare `Text('₹$x')` is banned by `custom_lint` rule `no_bare_money_text`.
- **No bare `DateTime.now()`** in `app/` — use `clockProvider` (`custom_lint` rule `no_datetime_now_outside_clock`).
- **No raw hex colours or inline `TextStyle`** in screens. Use `AppColors` / `AppSpace` / `AppRadius` / `Theme.of(context).textTheme`.
- **R4: archive, never delete.** No `DELETE` routes for user data.
- **R3: nothing is `confirmed`** without real statement/SMS reconciliation. Auto-imported transactions are `estimated`.
- **Every admin mutation writes `admin_audit_log` in the same transaction** as the write.
- **Gmail restricted-scope ceiling: 100 users.** Beyond that Google requires a CASA Tier 2 assessment ($15k–$75k + annual recert). This is a hard launch gate, tracked in Task 21.
- Target: `flutter analyze` clean, `flutter test` green before every commit.

---

## Screen scope (30 of 66)

Chosen for one complete vertical slice a beta user can actually live in.

| Group | Screens in beta | Deferred |
|---|---|---|
| **A** Onboarding & Auth | A1 Splash, A2 Welcome, A3 Account Choice, A4 Sign Up, A5 Log In, A7 Add First Card, A11 First-Run Tutorial | A6 (no passwords — OTP only), A8, A9, A10 |
| **B** Home & Recommend | B1 Home (upgrade), B2 Scanner, B3 Scan Result, B4 Comparison, B7 Big-Purchase Calculator | B5, B6, B8 |
| **C** Cards | C1 My Cards (upgrade), C2 Card Detail, C3 Add Card, C5 Benefits Cheat Sheet | C4, C6, C7, C8 |
| **D** Transactions | D1 List (upgrade), D2 Detail | D3–D6 |
| **E** Insights | E1 Hub, E2 Caps, E3 Utilization, E4 Milestones, E7 Billing Float | E5, E6, E8–E12 |
| **F** Import | F1 Import Hub, F3 Email Forwarding, F4 SMS, **F8 Gmail Connect (new)** | F2, F5, F6, F7 |
| **H** Settings | H1 Settings, H2 Profile, H3 Privacy & Permissions, H4 Notifications | H5–H10 |

## File Structure

```
app/lib/
  app/
    router.dart                 NEW  go_router config, ShellRoute, auth+onboarding guard
    design/app_theme.dart       EXISTS
    design/widgets.dart         EXISTS  (+ InsightTile, SectionHeader, ProgressRing)
    providers.dart              MODIFY  add onboarding, insights, integration providers
  features/
    onboarding/                 NEW  splash, welcome, account_choice, tutorial
    auth/                       MODIFY  signup (email+phone), login
    insights/                   NEW  hub, caps, utilization, milestones, billing_float
    compare/                    NEW  comparison_screen, big_purchase_screen
    import/                     NEW  import_hub, gmail_connect, email_forwarding
    settings/                   NEW  settings, profile, privacy_permissions, notifications
    cards/                      MODIFY  card_detail, benefits_cheat_sheet
api/src/
  integrations/gmail.js         NEW  OAuth exchange, message list/scan
  integrations/inbound_email.js NEW  forwarding webhook
db/supabase/migrations/
  0020_email_integrations.sql   NEW  user_email_integrations, inbound_email_events
```

---

# PHASE 0 — Auth completion (gates everything)

### Task 1: Sign-up collects email + phone, OTP to email

**Files:**
- Modify: `app/lib/features/auth/login_screen.dart`
- Modify: `app/lib/data/auth_api.dart:96` (`verifyEmailOtp` — pass `phone_number`)
- Test: `app/test/features/auth/signup_test.dart`

**Interfaces:**
- Consumes: `AuthApi.requestEmailOtp(String email)`, `AuthApi.verifyEmailOtp(...)` (both exist)
- Produces: `AuthApi.verifyEmailOtp(String email, String code, String deviceId, {String? phoneNumber})`

The backend **already** supports this exact shape: `POST /auth/verify-email-otp` accepts `email` + optional `phone_number` and links them onto one `users` row, rejecting the case where they belong to different accounts (`authRoutes.js:881-903`). No backend change needed.

- [ ] **Step 1: Write the failing test**

```dart
// app/test/features/auth/signup_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pandapay/data/auth_api.dart';
import 'dart:convert';

void main() {
  test('verifyEmailOtp sends phone_number when supplied', () async {
    late Map<String, dynamic> sentBody;
    final client = MockClient((req) async {
      sentBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
    });
    final api = AuthApi(authBaseUrl: 'http://x', client: client);

    await api.verifyEmailOtp(
      'a@b.com', '1234', 'dev-1', phoneNumber: '+919876543210');

    expect(sentBody['email'], 'a@b.com');
    expect(sentBody['phone_number'], '+919876543210');
  });

  test('verifyEmailOtp omits phone_number when null', () async {
    late Map<String, dynamic> sentBody;
    final client = MockClient((req) async {
      sentBody = jsonDecode(req.body) as Map<String, dynamic>;
      return http.Response(
        jsonEncode({'access_token': 'a', 'refresh_token': 'r'}), 200);
    });
    final api = AuthApi(authBaseUrl: 'http://x', client: client);

    await api.verifyEmailOtp('a@b.com', '1234', 'dev-1');

    expect(sentBody.containsKey('phone_number'), isFalse);
  });
}
```

- [ ] **Step 2: Run it, confirm it fails**

Run: `cd app && flutter test test/features/auth/signup_test.dart`
Expected: FAIL — `verifyEmailOtp` has no named `phoneNumber` parameter.

- [ ] **Step 3: Add the parameter**

```dart
// app/lib/data/auth_api.dart
Future<AuthTokens> verifyEmailOtp(
  String email,
  String code,
  String deviceId, {
  String? phoneNumber,
}) async {
  final response = await _client.post(
    Uri.parse('$authBaseUrl/auth/verify-email-otp'),
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode({
      'email': email,
      'code': code,
      'device_id': deviceId,
      if (phoneNumber != null && phoneNumber.isNotEmpty)
        'phone_number': phoneNumber,
    }),
  );
  if (response.statusCode != 200) {
    throw ApiException('OTP verify failed: ${response.statusCode} ${response.body}');
  }
  final body = jsonDecode(response.body) as Map<String, dynamic>;
  return AuthTokens(
    accessToken: body['access_token'] as String,
    refreshToken: body['refresh_token'] as String?,
  );
}
```

- [ ] **Step 4: Run tests, confirm pass**

Run: `cd app && flutter test test/features/auth/signup_test.dart` → PASS

- [ ] **Step 5: Add the phone field to the sign-up flow**

In `login_screen.dart`, when the screen is in **sign-up** mode (new `AuthMode.signUp`), show *both* fields stacked — email (primary, receives the OTP) and phone (secondary, labelled "Phone number · for card SMS detection"). Pass `phoneNumber: _phoneController.text.trim()` into `verifyEmailOtp`. In **log-in** mode keep the existing single-identifier toggle.

- [ ] **Step 6: Commit**

```bash
git add app/lib/data/auth_api.dart app/lib/features/auth/login_screen.dart app/test/features/auth/signup_test.dart
git commit -m "feat(auth): collect email+phone at signup, OTP delivered to email"
```

### Task 2: Prove refresh-token rotation survives access-token expiry

`sessionKeepAliveProvider` was added this session (10-min timer, 15-min TTL) but has **no test**. Refresh rotation is security-critical — `verifyRefreshToken` revokes the whole device family on reuse.

**Files:**
- Test: `app/test/app/session_keepalive_test.dart`
- Modify: `app/lib/app/providers.dart` (extract interval into an overridable provider)

- [ ] **Step 1: Make the interval injectable**

```dart
// app/lib/app/providers.dart
final sessionRefreshIntervalProvider =
    Provider<Duration>((ref) => const Duration(minutes: 10));
```
Replace `_kSessionRefreshInterval` usage inside `sessionKeepAliveProvider` with `ref.read(sessionRefreshIntervalProvider)`.

- [ ] **Step 2: Write the failing test**

```dart
// app/test/app/session_keepalive_test.dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pandapay/app/providers.dart';

void main() {
  test('refreshes the access token before the 15-minute TTL elapses', () {
    fakeAsync((async) {
      final container = ProviderContainer(overrides: [
        sessionRefreshIntervalProvider
            .overrideWithValue(const Duration(minutes: 10)),
        // authApiProvider overridden with a fake recording refresh() calls
      ]);
      addTearDown(container.dispose);

      container.read(accessTokenProvider.notifier).state = 'initial-token';
      container.read(sessionKeepAliveProvider);

      async.elapse(const Duration(minutes: 11));

      expect(container.read(accessTokenProvider), isNot('initial-token'),
          reason: 'token must rotate before the 15-minute access TTL');
    });
  });
}
```

- [ ] **Step 3: Run, confirm fail, then wire the fake `AuthApi` until it passes**

Run: `cd app && flutter test test/app/session_keepalive_test.dart`

- [ ] **Step 4: Commit**

```bash
git commit -am "test(auth): cover proactive refresh-token rotation"
```

---

# PHASE 1 — Navigation + onboarding + tutorial

### Task 3: Introduce go_router with auth + onboarding guards

go_router 14.6.2 is in `pubspec.yaml` and **completely unused**. 30 screens on int-index tabs is not maintainable, and `CLAUDE.md` names go_router the project standard.

**Files:**
- Create: `app/lib/app/router.dart`
- Modify: `app/lib/main.dart` (→ `MaterialApp.router`)

**Interfaces:**
- Produces: `goRouterProvider`, route-name constants `AppRoute.{splash,welcome,accountChoice,signUp,logIn,tutorial,home,cards,activity,account,...}`

- [ ] **Step 1: Add the onboarding-complete flag**

```dart
// app/lib/app/providers.dart
final onboardingCompleteProvider =
    StateNotifierProvider<OnboardingController, AsyncValue<bool>>(
        (ref) => OnboardingController(ref));
```
Backed by `SharedPreferences` key `onboarding_complete_v1`, mirroring `TokenStore`'s load/save shape.

- [ ] **Step 2: Write `router.dart` with a `ShellRoute` for the four tabs**

The redirect guard, in order:
1. session still resolving → `/splash`
2. no access token → `/welcome` (allow `/signUp`, `/logIn`)
3. token but `onboardingComplete == false` → `/tutorial`
4. otherwise → requested route

- [ ] **Step 3: Convert `main.dart` to `MaterialApp.router`**

Delete `_AppShell`'s `int _tab` and the `switch (_tab)` body; the `ShellRoute` builder now owns the `Scaffold` + bottom nav + scan FAB. Keep `sessionKeepAliveProvider` watched in the shell builder.

- [ ] **Step 4: Verify every existing screen still reachable**

Run: `cd app && flutter analyze lib/ && flutter test`
Then launch on simulator and tap all four tabs + FAB.

- [ ] **Step 5: Commit**

```bash
git commit -am "refactor(nav): adopt go_router with auth and onboarding guards"
```

### Task 4: A1 Splash · A2 Welcome · A3 Account Choice

**Files:** create `app/lib/features/onboarding/{splash,welcome,account_choice}_screen.dart`

- A1 resolves `sessionInitProvider`; `AppLogoMark` centred, subtle `flutter_animate` fade+scale (≤300ms, respects reduced-motion).
- A2 states the value proposition in one line — *"Know which card to use, before you pay."* — plus three benefit rows (Best card per purchase / Never miss a milestone / Auto-import from SMS & email). This directly answers "user should have a clear view of what the application is doing."
- A3 → "Create account" / "I already have an account" / "Explore without an account" (preserves the existing signed-out browse path).

- [ ] Build the three screens using `AppSpace`/`AppColors` tokens only
- [ ] Widget-test each renders its CTAs
- [ ] Commit: `feat(onboarding): splash, welcome and account-choice screens`

### Task 5: A11 First-run tutorial (explicitly requested)

**Files:** create `app/lib/features/onboarding/tutorial_screen.dart`, `tutorial_step.dart`

Four coach-marked steps over the *real* Home screen, not static illustrations:
1. "Type what you're about to spend" → amount field
2. "Pick the category" → category chips
3. "This is your best card, and why" → top recommendation card + reason lines
4. "Scan a card to add it" → the centre FAB

Each step: dimmed scrim, cut-out highlight, one sentence, `Next` / `Skip tour`. Completion sets `onboardingCompleteProvider = true`. Re-runnable from H1 Settings → "Replay tutorial" so it's never a one-shot users can't recover.

- [ ] Write widget test: completing the last step flips the flag and routes to `/home`
- [ ] Write widget test: `Skip tour` also flips the flag (never trap the user)
- [ ] Implement, run tests, commit: `feat(onboarding): first-run coach-mark tutorial`

### Task 6: A7 Add-your-first-card, inline in onboarding

Reuses the existing catalogue picker and `ScanCardScreen`. Empty wallet is the single biggest cause of a hollow-feeling first session — an empty Cards tab is exactly what your screenshot shows.

- [ ] Add "Add your first card" as tutorial step 5 when `userCardsProvider` is empty
- [ ] Commit: `feat(onboarding): guide first card add`

---

# PHASE 2 — Surface the 8 hidden engine capabilities

**This is the highest value-to-effort phase in the plan.** All logic below is already written and unit-tested in `packages/pandapay_domain`. These tasks are almost entirely UI.

### Task 7: E1 Insights Hub

**Files:** create `app/lib/features/insights/insights_hub_screen.dart`; add `InsightTile` to `app/lib/app/design/widgets.dart`

Entry grid → E2 Caps, E3 Utilization, E4 Milestones, E7 Billing Float, C5 Benefits. Each tile shows a live headline number (e.g. "₹2,400 cap left"), never a static label. Add a 5th bottom-nav destination **Insights**, replacing nothing — nav becomes Home · Cards · [FAB] · Insights · Account, and Activity moves under Insights → "All transactions". Bottom nav stays at 5 max per Material spec.

- [ ] Build hub + `InsightTile`, widget-test the empty and populated states
- [ ] Commit: `feat(insights): insights hub with live headline metrics`

### Task 8: E2 Caps & Limits ← `CapRule` + `cap_states`

`GET /user-cards` already returns `cap_states` (consumed, cap_value_snapshot) per card. Currently parsed into `UserCard.capConsumed` and used only for ranking — never displayed.

- [ ] Per-card cap rows: category, `consumed / cap_value` as a `ProgressRing`, ₹ remaining, period end date
- [ ] Colour by headroom: >50% left `success`, 10–50% `warning`, <10% `error` — plus an icon, never colour alone (WCAG)
- [ ] Widget test: a cap at 95% renders the error treatment and the "₹X left" string
- [ ] Commit: `feat(insights): caps and limits screen`

### Task 9: E3 Credit Utilization ← `UtilizationResult`

**Files:** create `app/lib/features/insights/utilization_screen.dart`

`UtilizationResult` exists in the domain package with zero callers. Needs a `creditLimit` per `user_cards` — add `credit_limit_inr numeric` to `user_cards` (migration `0020`), captured in C4/Add-card, since utilization is meaningless without it.

- [ ] Migration: `ALTER TABLE user_cards ADD COLUMN credit_limit_inr numeric;`
- [ ] Expose in `GET /user-cards` + `POST /user-cards`
- [ ] Screen: overall utilization %, per-card bars, the 30% healthy threshold marked, plain-language impact line
- [ ] Widget test: 0 cards → empty state, not a divide-by-zero
- [ ] Commit: `feat(insights): credit utilization with per-card breakdown`

### Task 10: E4 Milestones ← `MilestoneRule` + `milestone_states`

Also already returned by `GET /user-cards` and unused in UI.

- [ ] Progress toward each milestone, ₹ remaining, days left in period, reward at stake
- [ ] Surface the engine's existing "chasing this beats base rate" judgement — do not recompute it in the widget
- [ ] Commit: `feat(insights): milestone progress screen`

### Task 11: E7 Billing Cycle / Float ← `BillingCycleFloat`

- [ ] Per-card timeline: statement day, due date, and the headline *"Use Card A today → 48 interest-free days"*
- [ ] Needs `statement_day` (already on `user_cards`, already read by `insertTransactionAndUpdateState`)
- [ ] Commit: `feat(insights): billing cycle float timeline`

### Task 12: B4 Comparison View ← `SplitOptimizer`

**Files:** create `app/lib/features/compare/comparison_screen.dart`

- [ ] Side-by-side of top 3 cards for the current amount+category, with `reasonLines`
- [ ] "Split this purchase" → `SplitOptimizer` allocations, each as `MoneyText`
- [ ] Widget test: a split across 2 cards renders both allocations and they sum to the input amount
- [ ] Commit: `feat(compare): comparison view with split optimizer`

### Task 13: B7 Big-Purchase Calculator ← `SplitOptimizer` + `EmiAdvice`

- [ ] Amount + tenure input → EMI vs full-payment comparison from `EmiAdvice`
- [ ] Total-interest and effective-reward-rate lines, all `MoneyText`
- [ ] Commit: `feat(compare): big-purchase EMI advisor`

### Task 14: C5 Benefits Cheat Sheet ← `ForexRule` + `FuelSurchargeRule` + `RailComparison`

- [ ] Per-card: forex markup %, fuel-surcharge waiver band, lounge quota, UPI-vs-swipe rail note
- [ ] Commit: `feat(cards): benefits cheat sheet`

### Task 15: B1 Home upgrade + C2 Card Detail + D2 Transaction Detail

- [ ] B1: promote rank-0 to a hero treatment; add a backup-card row; add a "Compare all" → B4 link
- [ ] C2: tabbed card detail (Overview / Rules / Caps / Benefits)
- [ ] D2: transaction detail with the card used, category, reward earned, confidence
- [ ] Commit: `feat(ui): hero home card, card detail and transaction detail`

---

# PHASE 3 — Card & points auto-detection (all three channels)

All three converge on the existing `parser_patterns` table (its `channel` column already accepts `'sms' | 'email' | 'statement'`) and the existing `insertTransactionAndUpdateState()` helper. **One parser, one write path, three sources.**

### Task 16: Migration — email integration tables

**Files:** create `db/supabase/migrations/0020_email_integrations.sql`

```sql
create table user_email_integrations (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null,
  provider text not null check (provider in ('gmail','forwarding')),
  email_address text,
  refresh_token_encrypted text,
  scopes text[],
  status text not null default 'active'
    check (status in ('active','revoked','error')),
  last_scanned_at timestamptz,
  connected_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique (profile_id, provider, email_address)
);
alter table user_email_integrations enable row level security;
create policy user_email_integrations_owner on user_email_integrations
  for all using (profile_id = pandapay.current_profile_id());

create table inbound_email_events (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid,
  provider text not null,
  from_address text,
  subject_redacted text,
  matched_pattern_id uuid references parser_patterns(id),
  parsed boolean not null default false,
  transaction_id uuid references transactions(id),
  received_at timestamptz not null default now()
);
alter table inbound_email_events enable row level security;
```

Note: `inbound_email_events` stores a **redacted** subject only — never raw email bodies — mirroring the `parser_failures.redacted_shape_has_no_digits` constraint precedent already in the schema.

- [ ] Apply migration, verify RLS isolation with two users
- [ ] Commit: `feat(db): email integration tables with RLS`

### Task 17: F8 Gmail OAuth connect (new screen + API)

**Files:** create `api/src/integrations/gmail.js`, `app/lib/features/import/gmail_connect_screen.dart`

Flow: `google_sign_in` on device requests scope `gmail.readonly` and yields a **`serverAuthCode`**; the app posts that to `POST /integrations/gmail/connect`; the **backend** exchanges it for a refresh token, encrypts it at rest (reuse `auth/src/utils/fieldEncryption.js`), and does all scanning server-side. Tokens never live on the device.

Scanning: `users.messages.list` with a narrow query, not a whole-inbox crawl —
`q=from:(hdfcbank.net OR icicibank.com OR sbicard.com OR axisbank.com) newer_than:90d`
— then match each body against `parser_patterns WHERE channel='email'`, and feed hits into `insertTransactionAndUpdateState(source='email')`.

- [ ] `POST /integrations/gmail/connect` · `GET /integrations/gmail/status` · `POST /integrations/gmail/scan` · `POST /integrations/gmail/disconnect`
- [ ] Screen shows: exactly which scope is requested, that the query is issuer-limited to 90 days, what is stored (parsed amounts, never raw email), and a one-tap **Disconnect** that revokes the Google grant
- [ ] Test: `api/test/gmail_scan.test.js` — a fixture HDFC email produces one `estimated` transaction; an unrelated email produces none
- [ ] Commit: `feat(import): Gmail OAuth connect with issuer-scoped scanning`

> **Launch gate:** Google caps unverified restricted-scope apps at **100 users**. Beyond that requires CASA Tier 2 ($15k–$75k, annual). Tracked in Task 21.

### Task 18: F3 Email forwarding (no Google gatekeeper)

Each user gets `u_<short-hash>@in.pandapay.app`. Inbound provider (SES/Postmark) posts to `POST /integrations/email/inbound`, signature-verified.

- [ ] Generate + display the address with a copy button and per-issuer forwarding instructions
- [ ] Webhook verifies signature, resolves hash → `profile_id`, runs the same parser path
- [ ] Test: unsigned webhook request → 401
- [ ] Commit: `feat(import): per-user email forwarding ingestion`

### Task 19: F1 Import Hub + F4 SMS wiring

- [ ] Status card per channel — Gmail / Forwarding / SMS — each `active | not set up | error`, with last-sync time
- [ ] Route the existing `SmsImportScreen` under the hub
- [ ] Commit: `feat(import): unified import hub`

---

# PHASE 4 — Permissions transparency & settings

### Task 20: H3 Privacy & Permissions (directly answers "does it ask for permissions?")

The app currently requests SMS, location, and camera with **no screen explaining why**. That is both a UX failure and an app-store review risk.

**Files:** create `app/lib/features/settings/privacy_permissions_screen.dart`

- [ ] One row per permission — SMS, Location, Camera, Gmail — each with: current OS status, one plain sentence of *why*, what is stored, and Grant/Revoke
- [ ] "Download my data" and "Delete my account" entry points (DPDP Act 2023 expectation for Indian users)
- [ ] Run the `owasp-mobile-security-checker` skill over the auth + storage paths and fix anything it flags
- [ ] Commit: `feat(settings): privacy and permissions transparency screen`

### Task 21: H1 Settings · H2 Profile · H4 Notifications + CASA gate doc

- [ ] H1: account, replay tutorial, import hub, privacy, sign out
- [ ] H2: display name, email, phone (all editable, re-verify on change)
- [ ] H4: per-category notification toggles
- [ ] Append to `TODO_OWNER.md`: **"Gmail 100-user ceiling — commission CASA Tier 2 before public launch ($15k–$75k, ~3–6 months, annual recert)."**
- [ ] Commit: `feat(settings): settings, profile, notifications; document CASA launch gate`

---

# PHASE 5 — Verification

### Task 22: Golden + E2E coverage

- [ ] `alchemist-golden-testing` skill → goldens for Home, Insights Hub, Login, Card Detail in light + dark
- [ ] `maestro-mobile-testing` skill → E2E flow: launch → sign up (email+phone) → OTP → tutorial → add card → log spend → see it in Activity
- [ ] `flutter analyze` clean; `flutter test` green; `npm test` green in `api/` and `auth/`
- [ ] Use `verification-before-completion` skill before declaring done
- [ ] Commit: `test: golden and E2E coverage for the beta slice`

---

## Self-review

**Spec coverage.** Every user request maps to a task: professional UI → Phases 1–2 (30 screens on the design system); missing per-page functionality → Phase 2 (the 8 engine features) + Phase 3; tutorial mode → Task 5; email+phone auth with OTP to email → Task 1; refresh token → Task 2; Gmail card/points detection → Task 17; permission clarity → Task 20; "clear view of what the app does" → Tasks 4, 5, 7.

**Known risks.**
1. **Gmail 100-user ceiling** is a hard external limit, not something code can solve — surfaced in Tasks 17 and 21 rather than buried.
2. **E3 Utilization needs `credit_limit_inr`**, which no existing table has — Task 9 adds the column *and* the capture UI, otherwise the screen renders nothing.
3. **Adding a 5th nav destination** (Task 7) hits Material's 5-item bottom-nav ceiling. Activity therefore moves under Insights; this is a deliberate trade, called out so it isn't discovered mid-build.
4. **go_router migration (Task 3) touches every screen.** It is sequenced before the 21 new screens precisely so the migration cost is paid once, at its smallest.
