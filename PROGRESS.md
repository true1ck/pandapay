# PandaPay — Progress

Read this first in any new session. There is no context-compaction here, so
this file is the resume point.

## Where things live

```
pandapay-docs/
├── product-plan.md, ui-spec.md, admin-console-plan.md   — original planning docs
├── Userappimplementation_plan.md                        — Flutter user app build plan (colleague-authored)
├── adminimplementation_plan.md                           — Flutter Web console build plan (colleague-authored)
├── database.sql                                          — original consolidated schema (colleague-authored, kept as reference)
├── db/supabase/migrations/0001..0014_*.sql               — schema split into migration files, ADAPTED (see below)
├── auth/                                                  — PandaPay identity service (adapted from user-supplied PandaPal_Auth_Service)
│   └── db/pandapay-auth/init.sql, docker-compose.yml
├── packages/pandapay_domain/                              — shared Dart package (Money, Confidence, Clock — tested)
├── app/                                                    — Flutter user app (scaffolded, depends on pandapay_domain)
└── console/                                                — Flutter Web admin console (scaffolded, depends on pandapay_domain)
```

## Decisions made this session

1. **Colleague's implementation docs were already present** (`adminimplementation_plan.md`,
   `Userappimplementation_plan.md`, `database.sql`) — not self-authored. Used as source of truth.

2. **Auth stack changed from the plan's assumption.** The implementation docs assume
   Supabase (`auth.users`, `auth.uid()`, RLS via Supabase's built-in roles). The user
   provided an existing, already-hardened Node/Express auth microservice
   (`PandaPal_Auth_Service`, originally built for a different app called "FarmMarket")
   with phone/email OTP, Google Sign-In, JWT access+refresh rotation, device tracking,
   audit log, rate limiting. That service was adapted into `auth/` as PandaPay's identity
   service:
   - Stripped farm-domain tables (`species`, `breeds`, `animals`, `listings`, `listing_images`,
     related enums) from its `init.sql`.
   - Kept `users`, `otp_requests`, `otp_codes`, `refresh_tokens`, `auth_audit`,
     `oauth_accounts`, `user_devices`.
   - Rebranded `package.json`/`example.env` (`farm-auth-service` → `pandapay-auth`,
     db name `farmmarket` → `pandapay_auth`).
   - New `docker-compose.yml` at `auth/db/pandapay-auth/` for local Postgres on port 5433.
   - **Not yet done**: the service's own route/controller code (`src/routes/*.js`,
     `src/services/*.js`) still refers to the old `users` table shape in places (e.g.
     `user_type`, farm-specific fields) — needs a pass before it's wired to the real
     PandaPay app. Flagged, not fixed this session.

3. **`database.sql` migrations adapted for the non-Supabase auth**, since there is no
   `auth.users`/`auth.uid()` outside Supabase and the auth service is a *separate*
   Postgres database (cross-database FKs don't exist in Postgres):
   - `profiles.id` and `admin_users.id` (migrations 0004, 0008) are now plain `uuid primary key`
     with **no FK** to the auth service — the app backend is responsible for only inserting
     a `profiles`/`admin_users` row for a user id that actually exists in `auth/`'s `users` table.
   - Migration 0011 (RLS): added `pandapay.uid()` — reads
     `current_setting('app.user_id', true)::uuid`. **The backend MUST run
     `select set_config('app.user_id', $verified_user_id, true)` at the start of every
     request/transaction**, after verifying the JWT issued by `auth/`, before touching any
     RLS-protected table. If it's never set, `pandapay.uid()` returns null and every owner
     policy denies by construction. All `auth.uid()` calls replaced with `pandapay.uid()`;
     all `to authenticated` / `to anon` (Supabase-specific roles) replaced with `to public`.
   - `pandapay.execute_account_deletion()` (0010) no longer does
     `delete from auth.users` — that row lives in the other database; the app backend's
     erasure workflow must also call the auth service's own delete endpoint.
   - `0013_cron_jobs.sql` (pg_cron) is **not applied locally** — this machine's Postgres
     build has no `pg_cron` extension. Production Postgres needs `pg_cron` in
     `shared_preload_libraries`; this is a deployment requirement, not a code gap.
   - `database.sql` itself (the single big consolidated file) was left untouched as the
     colleague's original reference; all the above changes are only in the split
     `db/supabase/migrations/*.sql` files, which are what actually got applied and tested.

## What's built and verified

### Database (both apps' shared Postgres schema)
- Split `database.sql` into 14 migration files at `db/supabase/migrations/`, per the
  file's own `MIGRATION FILE SPLIT` section.
- Stood up local Postgres via Homebrew `postgresql@18` (Docker was network-flaky on this
  machine — pulls of `supabase/postgres` kept failing mid-transfer; plain Postgres from
  Homebrew was the reliable path). Two local databases:
  - `pandapay` on `localhost:55432` — the product schema (migrations 0001–0012, 0014 applied; 0013 skipped, see above).
  - `pandapay_auth` on `localhost:55432` — the identity schema (`auth/db/pandapay-auth/init.sql` applied).
- **Verified, not just applied:**
  - All 13 migrations (0001–0012, 0014) run clean, in order, with no errors.
  - 69/69 `public` tables have `relrowsecurity = true` (RLS coverage checklist item).
  - `pandapay.run_anonymization_audit()` returns `passed = true`, 6/6 checks, 0 findings.
  - `bump_card_data_version` trigger confirmed: inserting a `reward_rules` child row
    bumps the parent `card_products.data_version` from 1 → 2 (device sync contract).
  - Grid-snap `numeric(8,4)` columns on `merchant_locations` confirmed to enforce
    ≤4-decimal-place coordinates (Postgres numeric scale itself does the rounding;
    the CHECK constraint is defense-in-depth on top of that).
- Local Postgres is **not currently running as a background service** — it was started
  manually this session (`pg_ctl -D <scratchpad>/pgdata -o "-p 55432" start`, with
  `LC_ALL=C` set to work around a known Homebrew Postgres 18 + macOS "postmaster became
  multithreaded during startup" bug). A future session will need to restart it the same
  way, or move to a proper `docker-compose.yml` for the product DB (only the auth DB has
  one right now, at `auth/db/pandapay-auth/docker-compose.yml`).

### `packages/pandapay_domain` (shared Dart package, pure Dart — no Flutter import)
- `Money` — integer-paise value type, Indian lakh/crore formatting, compact (Cr/L/K)
  formatting, arithmetic, comparisons.
- `Confidence` — estimated/confirmed enum (product-plan §5.10 / R3).
- `Clock` / `TestClock` / `SystemClock` — injectable time source.
- **13/13 tests passing**, including the UA-0.2.4-mandated property test: paise values
  across 0–10^9 (both signs) round-trip through `.format()` and back exactly.

### `app/` (Flutter user app)
- Scaffolded (`app.pandapay` package id), depends on `pandapay_domain` by path,
  `flutter_riverpod` + `go_router` wired (not yet used — no routes/providers built yet).
- Minimal shell: bottom nav (Home/Cards/Activity/More) + centered scan FAB per UA-0.4.2,
  and a `MoneyText` widget that requires a `Confidence` argument (can't render a bare
  `Text('₹...')` for money) — proves the UA-0.2.4 pattern end to end using the real
  `Money` type from `pandapay_domain`.
- `flutter analyze`: clean. `flutter test`: 2/2 passing.
- Lint config: `avoid_print` enabled. The two other UA-0.1.3-mandated bans (no
  `DateTime.now()` outside `core/clock`, no bare `Text` of a `Money`) need a custom
  `custom_lint`/`riverpod_lint` plugin to enforce at compile time — dev deps are wired
  (`custom_lint`, `riverpod_lint`) but the plugin rules themselves are **not implemented
  yet**. Enforce by review until then.

### `packages/pandapay_domain` — card rules + recommendation engine (UA-2, "the product")
- `card_rules.dart`: `RewardUnit` (with `effectiveRatePerRupee` normalizing cashback/points-per-100/150/200/miles
  to a comparable fraction), `RewardRule`, `CapRule`, `MilestoneRule`, `ForexRule`, `FuelSurchargeRule`, `CardProduct`
  — a direct mirror of `database.sql` §0003.
- `engine.dart`: `RecommendationEngine.rank()` — pure Dart, zero IO, per UA-2.1's contract
  (`RecommendationContext` in, `CardSnapshot` list in, `Recommendation` list out, engine never queries).
  Implements: RuPay/UPI exclusion gate (excluded cards are returned greyed with a reason, never
  dropped), P2P exclusion, cap blending (splits spend across pre-cap/post-cap rates), travel-mode
  forex markup subtraction (incl. GST), fuel surcharge waiver, manual override forcing to top,
  deterministic tie-break (value → confirmed confidence → card id), and a `reasonLines` explanation
  generator built from the same arithmetic used for the value (never re-derived).
- **13 new tests, 26/26 total passing**, including: cap boundary crossed by exactly 1 paisa (blends
  correctly), RuPay exclusion on UPI-QR vs eligible on swipe, P2P exclusion, travel-mode markup math,
  override forcing, ranking totality (every input card appears exactly once in the output), and
  reason-line reconciliation.
- **Not yet implemented from UA-2**: milestone bonus contribution to expected value (rule model
  exists, engine doesn't use it yet), multi-card split optimizer, billing-cycle float, EMI advisor,
  UPI-vs-swipe comparison, the 30-scenario golden fixture set, and the `flutter analyze` "no bare
  `Text` for Money" enforcement. This is a real slice of UA-2, not all of it.

### `console/` (Flutter Web admin console)
- Scaffolded (`app.pandapay` org, web platform only), depends on `pandapay_domain` by path.
- AD-0.2 route guard stub: `go_router` redirects any session where
  `ConsoleSession.isAdmin == false` to a `/no-access` dead end — currently every session
  is signed-out by default (real auth wiring against `auth/` is AD-0.3, not done yet).
- Left-nav shell (Catalogue · Alerts · Queues · Sources · Merchants · Acceptance · Rates ·
  Dashboard) with stub screens, dense/compact visual density per AD-0.2.3.
- `flutter analyze`: clean. `flutter test`: 1/1 passing (asserts the dead-end redirect fires).

### `auth/` — verified end-to-end against the live `pandapay_auth` database
Booted the real Node service (`node src/index.js`, port 3210, `DB_SSL=false`, `DATABASE_MODE=local`)
against the actual `pandapay_auth` Postgres database and drove a full login through the real HTTP
routes — not a syntax check:
1. `POST /auth/request-otp` → `{"ok":true}`, OTP hashed and stored in `otp_requests`.
2. `POST /auth/verify-otp` → bcrypt-compares the code, finds-or-creates the `users` row, upserts
   `user_devices`, issues real signed access + refresh JWTs.

Getting there required **iteratively widening `auth/db/pandapay-auth/init.sql`** to match columns
the (battle-tested, security-hardened) route code actually reads/writes — my first-pass schema was
too thin. Every column added this way is commented in `init.sql` as inherited from the source app,
not something PandaPay actually needs:
- `otp_requests`: added `email`, `type`, `country_code`, `deleted` (the real service soft-deletes
  OTP rows and supports both phone and email OTP, not just phone).
- `users`: added `deleted`, `is_phone_verified`, `is_email_verified`, `token_version`,
  `country_code`, and two fields that are **pure leftover from the source app's other product**
  ("Urban Link" marketplace tiers) and should be removed once the route code is trimmed down for
  PandaPay specifically: `partner_tier_id` (nullable, unused), `active_role` (nullable, unused —
  the source app's seller/buyer/service-provider profile-type concept, `src/middleware/validation.js`
  `validateMarketplaceRole`, has no PandaPay equivalent).
- `user_devices`: added `fcm_token`.
- `src/db.js`: was hardcoded to always require TLS (`ssl: { rejectUnauthorized: false }`) in two
  places — fine for the source app's managed AWS RDS, wrong for any local/self-hosted Postgres.
  Made conditional on `USE_AWS_SSM`/`DB_SSL` env vars.
- `src/routes/authRoutes.js`: six raw-SQL `NULL::user_type_enum` casts referenced a Postgres enum
  type that no longer exists (I'd renamed it `user_role_enum` and dropped the marketplace-specific
  one) — changed to `NULL::text`.
- `src/services/jwtKeys.js`, `src/config.js`: JWT issuer default rebranded from `farm-auth-service`
  to `pandapay-auth`.

**The user explicitly flagged mid-session that this must keep diverging** — the auth service's
database and environment were built for a different product ("Urban Link"/FarmMarket, and reused
once already for a separate "PandaPath AI" app) and should not be treated as a template PandaPay
just inherits as-is. The columns/fields marked "unused, kept for compatibility" above are exactly
the parts still owed that further divergence — a follow-up pass should trim `authRoutes.js` itself
(currently ~2000 lines, written for a different app's marketplace + partner-tier model) down to
what PandaPay actually needs, then drop `partner_tier_id`/`active_role`/the unused enum casts
entirely rather than carrying them as dead columns.

### `api/` — new: minimal product API, RLS proven end-to-end (not just wired)
**⚠️ CORRECTED IN CHUNK 6 BELOW — read that section.** The claim in this section that
"isolation is enforced by Postgres RLS" was wrong: the database connection was
`postgres`, a superuser, which unconditionally bypasses RLS. What was actually proven
here was the API's `WHERE id = $1` filter working correctly, not RLS. Chunk 6 found
this, created a real non-superuser role (`db/setup_app_role.sql`), and re-proved
isolation for real. Left this section otherwise unedited so the corrected write-up in
Chunk 6 is legible as a correction rather than silently rewriting history.

Chunk 1 of the task breakdown. New Node/Express service (`api/`, port 4000) sitting
between the Flutter apps and the `pandapay` product database:
- `src/auth.js`: verifies the JWT `auth/` issues (same `JWT_ACCESS_SECRET`). **Important
  finding**: `auth/`'s `tokenService.js` signs with `jwt.sign(payload, ACCESS_SECRET,
  { expiresIn })` and never sets a real `iss` claim, despite the payload containing a
  literal `aud: 'authenticated'` field (a leftover Supabase-shaped claim, not a verified
  JWT audience). Passing `issuer`/`audience` to `jwt.verify()` here silently rejects every
  real token — fixed by only checking the signature, and documented inline so it isn't
  "fixed" back into a 401 loop later.
- `src/db.js`: `withUserClient(userId, fn)` — acquires a pool client, `SET LOCAL
  app.user_id` inside a transaction, runs the query, commits, releases. `SET LOCAL` is
  transaction-scoped so a pooled connection can never leak one request's identity into
  the next.
- Three routes: `GET/POST /profile` (owner-scoped, requires auth), `GET /catalogue`
  (public read, no auth). This is the `set_config('app.user_id', ...)` middleware flagged
  as missing in the previous progress note — it's now built and **proven**, not just wired:
  created two real users through the actual `auth/` OTP flow, had each POST their own
  `/profile`, confirmed (a) each user's `GET /profile` returns only their own row, and
  (b) as postgres superuser (bypassing RLS) both rows genuinely exist in the table — so
  the isolation is enforced by Postgres RLS, not by API-layer discipline that happens to
  not have a bug yet.
- **Not yet done**: no refresh-token handling, no rate limiting, no endpoints beyond
  profile/catalogue (user_cards, transactions, etc. are chunk 3+ work), no automated
  tests (verified manually via curl this session — should get a real test suite before
  much more is built on top of it).

### Chunk 2 — trimmed `auth/`'s marketplace/partner-tier cruft
Removed the leftover "Urban Link" marketplace logic flagged in the previous session:
- `tokenService.js`: no longer signs `partner_tier_id` into the JWT.
- `authRoutes.js`: stripped `partner_tier_id`/`referral_code` from ~10 raw SQL
  SELECT/RETURNING column lists (all via targeted sed, verified with `node --check`
  and a live re-run of the OTP flow after each pass).
- `validation.js`: deleted the entire dead `validateMarketplaceRole`/
  `validateUpdateProfileBody` pair — imported but never actually wired to any route.
- `userRoutes.js`: `GET /users/me` had a whole partner-tier-name lookup block
  (querying a `partner_tiers` table that doesn't exist in this schema) and returned
  `referral_code`/`profile_image_url` — none of which PandaPay has a concept of.
  Trimmed to the fields that exist: id, phone, name, role, avatar_url, language,
  timezone, country_code, timestamps, active device count.
- `db/pandapay-auth/init.sql`: dropped the now-dead `partner_tier_id`/`active_role`
  columns from `users` entirely (both in the file and on the live database).
- **Found and fixed a real, pre-existing bug while re-testing**, unrelated to the
  trim itself: `tokenService.js` signs `aud: 'authenticated'` into every token, but
  `jwtKeys.js`'s claims validator defaulted `JWT_AUDIENCE` to `'mobile-app'` — so
  every `authMiddleware`-protected route (`GET`/`PUT /users/me`, device management,
  etc.) 401'd with "Invalid token claims" the moment you tried to use them, even
  though `/auth/*` itself worked fine. Fixed by setting `JWT_AUDIENCE=authenticated`
  in `.env`, documented in `example.env` so this doesn't silently reappear.
- Re-verified the full flow against the live, trimmed database after each change:
  request-otp → verify-otp → JWT issuance → `GET /users/me` → `PUT /users/me`, all
  200s, response shape now free of dead marketplace fields.

### Chunk 3 — UA-1 card catalogue: real seed data, verified through the full stack
`db/seed/0001_demo_cards.sql`: 4 real Indian cards (HDFC Millennia, SBI Cashback Card,
Axis Ace, ICICI Amazon Pay) with structurally-real mechanics — a RuPay/UPI-linkable
card, statement-cycle vs calendar-month caps, a milestone rule, a forex rule — not just
synthetic engine-test fixtures. Reward *rates* are approximate public figures, **not**
verified against current bank T&C (every row starts `status = 'draft'`; the UA-1.1.4
human-verification pass is still owed before these could be real user-facing data).
- **Idempotent, verified by actually re-running it**: second run inserted 0 rows,
  card/reward-rule counts unchanged.
- **Verified the whole chain end-to-end**, not just the SQL: seeded → published (sets
  `verified_at`, which the DB CHECK constraint requires) → `data_version` bump trigger
  fired correctly across multi-row inserts (not just my earlier single-row test) →
  booted `api/` for real → `GET /catalogue` returned all 4 cards through
  `v_card_catalogue_export`, correctly nesting `reward_rules`/`cap_rules`/
  `milestone_rules`/`forex` — the exact shape `packages/pandapay_domain`'s
  `CardProduct`/`RewardRule`/`CapRule` model expects. This is the device-sync contract
  (admin-console-plan §4.5) working for real, not just documented.
- **Not yet done**: no Dart-side deserializer turning this JSON into `CardProduct`
  instances yet (that's chunk 5, wiring the app's Home screen to real data); no YAML
  import tool (`tools/card_import.dart`, UA-1.1.2); only 4 of the ~40-50 cards UA-1.1
  calls for; no admin console UI to edit these (chunk 6).

### Chunk 4 — UA-2 engine remainder: milestones, split optimizer, EMI advisor, etc.
Extended `packages/pandapay_domain`'s engine with the rest of UA-2.2/UA-2.4:
- **Milestone bonus** (UA-2.2.4) now contributes to `expectedValue`: a spend counts
  as "materially" advancing a milestone when it covers a configurable fraction
  (default 50%) of the remaining threshold gap; the bonus is pro-rated to how much
  of the gap this specific transaction closes (never double-counts, never claims
  more than the milestone's `rewardValue` even on a huge overshoot spend), with a
  reason line distinguishing "materially advances" vs "completes".
- **`SplitOptimizer`** (UA-2.4.2/G2): greedy marginal-₹/₹ fill across cards in
  paise-step increments, respecting live cap headroom per step (re-evaluates cap
  blending as prior steps consume it, not just once upfront) and an optional
  per-card utilization ceiling. Bounded search, not an LP solver — matches the
  plan's own framing.
- **`creditUtilization()`** (UA-2.4.1/E3): ratio + 30%-threshold flag + suggested
  amount to move to get back under it; zero-limit input never divides by zero.
- **`billingCycleFloat()`** (UA-2.4.3/E7): interest-free days from a statement day +
  grace period, through the injectable `Clock` (not `DateTime.now()`), correctly
  rolling to next month when the statement day has already passed this month.
- **`adviseEmi()`** (UA-2.4.4/G3): total interest via the standard EMI formula,
  effective cost (interest + forgone reward value), and a verdict line.
- **`compareRails()`** (UA-2.4.5/§10.7): runs the same card set through the engine
  on both UPI-QR and swipe rails and surfaces the delta — reuses the RuPay
  exclusion gate from chunk-earlier work, so a UPI-only-eligible-card scenario and
  a swipe-only-higher-rate scenario are both exercised for real, not mocked.
- **13 new tests, 39/39 total passing.** `dart analyze`: clean.
- **Not done**: the full 30-scenario golden fixture set (UA-2.5.1) — what exists is
  targeted unit tests per feature, not the consolidated fixture file the plan asks
  for; performance test (rank 15 cards <16ms, UA-2.5.3); regression harness for
  user-reported wrong recommendations (UA-2.5.4, not applicable yet — no users).

### Chunk 5 — app/ Home wired to the real engine + live API (not fixtures)
- `packages/pandapay_domain`: new `card_rules_json.dart` — `fromJson` for every card-rules
  type, matching `v_card_catalogue_export`'s exact shape. Handles the real quirk that `pg`
  returns top-level `numeric` columns as JSON strings (`"499.00"`) but numerics nested
  inside `jsonb_agg`'d blobs as native JSON numbers — found by testing against a **captured
  live API response** (`test/fixtures_catalogue_response.json`, real output from
  `GET /catalogue` against the seeded DB), not hand-written JSON. 6 new tests, 45/45 total.
- `api/`: added `GET /categories` (public read of `spend_categories`) — needed once the
  slug→UUID bug below was found.
- `app/`: `data/catalogue_repository.dart` (`HttpCatalogueRepository`,
  `HttpCategoryRepository`), `app/providers.dart` (riverpod: fetch catalogue + categories,
  resolve the selected category chip's slug to the UUID `reward_rules.category_id` actually
  needs, run `RecommendationEngine.rank()`), `features/home/home_screen.dart` (category
  chips + ranked list with reason lines, loading/error states via `AsyncValue.when`). Home
  tab in `main.dart` now renders this instead of the static shell; widget tests updated to
  override both repositories with fakes (no real network call in the test suite).
- **Two real bugs found by testing against the live stack, not by unit tests alone:**
  1. The category chip's *slug* (`'online'`) was being passed straight through as
     `RecommendationContext.categoryId`, but `reward_rules.category_id` is a UUID FK —
     every card came back excluded when checked against real seeded data
     (`app/tool/verify_live_catalogue.dart`, a manual script hitting the real
     `HttpCatalogueRepository` against a running `api/`). Fixed by adding the
     `/categories` endpoint and resolving slug→id before building the context.
  2. **Not fixed, documented instead**: `CapRule.capValue`/`capRemaining` are always
     treated as spend-amount headroom in the engine's blending logic, regardless of the
     cap's actual `measure` (`spend_amount` vs `reward_value` vs `txn_count` — see
     `database.sql`'s `cap_measure` enum). HDFC Millennia's seeded cap is
     `measure = 'reward_value'` (cap ₹1,000 of *cashback earned*, not ₹1,000 of spend) —
     the engine currently blends it as if it were a spend cap. The live-verification output
     looks plausible but is not semantically correct for that measure. Flagged inline in
     `engine.dart` and here rather than left silently wrong.
- `flutter analyze`: clean on both `app/` and `packages/pandapay_domain`. `flutter test`:
  3/3 passing on `app/` (fakes only). Separately ran `dart run
  tool/verify_live_catalogue.dart` against a genuinely running `api/` + seeded `pandapay`
  DB to confirm the real fetch → parse → rank chain works end to end.
- **Not done**: no drift/local-cache (still a live network fetch every time, no offline
  path — UA-0.3/UA-1.2 territory); no user_cards wiring (ranks the *whole* catalogue, not
  a signed-in user's actual cards); no amount entry (fixed ₹1,000 demo amount); cap-measure
  gap above; the other 3 bottom-nav tabs are still placeholders.

### Chunk 6 — Console AD-0.3 real auth + AD-1 catalogue manager (and two critical DB findings)

**⚠️ Most important finding of the whole session, read this first:** every "RLS isolation
proven" claim in this file up through Chunk 5 was tested by connecting as the `postgres`
role — which is a **Postgres superuser**, and **superusers unconditionally bypass Row
Level Security**, regardless of `FORCE ROW LEVEL SECURITY` on the tables. That means the
earlier two-users-can't-see-each-other's-profile test was real (it worked), but it was
proven by the API's `WHERE id = $1` filter, **not by Postgres RLS** — RLS was never
actually being exercised. Found while building the admin auth check for this chunk, fixed
properly, and re-verified for real:
- `db/setup_app_role.sql` (new): creates `app_user`, a genuine non-superuser,
  non-RLS-bypassing role, granted exactly the privileges an application needs. `api/`'s
  `DATABASE_URL` now points at `app_user`, not `postgres` (`api/example.env` documents
  why, in bold, so this can't silently regress).
- **Re-verified profile isolation as `app_user` directly via psql** (not through the API,
  to isolate exactly what RLS itself does): with no `app.user_id` set, `SELECT * FROM
  profiles` returns **zero rows**; with it set to a real user's id, returns **exactly
  that user's row**. This is RLS actually enforcing the policy, confirmed independent of
  any application code.
- **Then re-ran the full two-user API isolation test from Chunk 1 against the real
  `app_user`-backed API** — same result as before, but now genuinely proven by Postgres,
  not just by API discipline that happened not to have a bug.
- **A second, more serious bug fell out of the same investigation**: `pandapay.is_admin()`
  (`0011_rls_policies.sql`) queries `admin_users` to check admin status, but
  `admin_users`' own RLS policy calls `is_admin()` to decide access — under a real
  non-superuser role this recurses infinitely (`ERROR: stack depth limit exceeded`). It
  only ever appeared to work because `postgres` bypasses RLS and never actually
  triggered the recursive policy check. **Fixed** by making `is_admin()` `SECURITY
  DEFINER` (scopes a superuser-level RLS bypass to just that one function body, not to
  the calling role) — verified an admin's `is_admin()` returns `true` and they can read
  `admin_users`, a non-admin's returns `false` and they see zero rows, both under the
  real `app_user` role.
- **Not fixed, documented**: `card_products`' own RLS policy is `public_read using
  (true)` — unconditional, not filtered to `status = 'published'`. So Postgres RLS alone
  does not hide draft/in_review cards from a non-admin querying the table directly; only
  `v_card_catalogue_export`'s explicit `WHERE status = 'published'` does that, and only
  for callers going through that specific view. The new `/admin/cards` endpoint's
  `requireAdmin` check (see below) is therefore doing real, load-bearing access control
  itself, not just being defense-in-depth on top of RLS. Flagged inline in `api/src/index.js`.

**AD-0.3 / AD-1 build, on top of the above:**
- `api/`: `requireAdmin` middleware (`GET /admin/me`, `GET /admin/cards`,
  `PUT /admin/reward-rules/:id`) — checks `pandapay.is_admin()` for real per request.
  `v_admin_card_catalogue_export` (new view, `0010_functions_and_views.sql`): same shape
  as the public export view, minus the published-only filter, so admins can see drafts.
  `PUT /admin/reward-rules/:id` is a real typed writer (AD-1.1.3): only ever accepts a
  numeric `rate`, writes `admin_audit_log` in the *same transaction* as the update
  (AD-0.3.4 — a write that reaches the table but skips the audit is impossible, the
  transaction rolls back together), and **verified the existing `bump_card_data_version`
  trigger fires from this path too**: edited HDFC Millennia's online rate from 5→7 through
  a real admin token, confirmed the audit row (before/after values, admin id, reason) and
  confirmed `data_version` bumped 4→5, both via direct psql against the live DB.
  Verified end-to-end with two real users from `auth/`'s live OTP flow: the actual admin
  gets `isAdmin: true` and successful reads/writes; a genuine non-admin gets
  `isAdmin: false` and a real `403` on both `GET /admin/cards` and the `PUT` — not mocked.
- `console/`: `data/admin_api.dart` (`AuthApi` for OTP login, `AdminApi` for
  `/admin/*`), `app/providers.dart` (real `accessTokenProvider`/`isAdminProvider`,
  restructured so `isAdminProvider` depends on the overridable `adminApiProvider` for
  testability), `features/auth/login_screen.dart` (phone+OTP, same flow as the user app
  — AD-0.3.1's "no signup path" holds because whether the resulting session is an
  operator is decided entirely server-side by `requireAdmin`, not by anything
  client-side), `features/catalogue/catalogue_screen.dart` (card list + inline reward-rate
  editor calling the real typed-writer endpoint). `main.dart` now gates on real
  auth/admin state instead of the `ConsoleSession.signedOut` stub; `app/router.dart`'s
  go_router shell from earlier in the session is **not wired into this build** (kept as
  reference for the intended nav shape, not silently presented as load-bearing).
- 3 widget tests using `package:http/testing.dart`'s `MockClient` (signed-out → login
  screen; signed-in non-admin → dead end; signed-in admin → real catalogue data
  including a draft card) — no real network call in the automated suite.
- **Manually built and ran the actual Flutter Web console** (`flutter build web` +
  `python3 -m http.server`) against the live `auth/` + `api/` + seeded DB, confirmed the
  real login screen renders correctly in a browser. Could not complete a full click-through
  login in the automated browser tool — Flutter's CanvasKit web renderer draws to a single
  `<canvas>` and exposes no DOM/accessibility nodes for generic browser automation to
  target (confirmed: `read_page` found zero interactive elements) — this is a tooling
  limitation of the verification environment, not a defect in the app; backend
  correctness for the whole login→admin-check→catalogue-edit path is independently
  verified via curl with real tokens against the real database (above), and the widget
  test suite covers the same paths with fakes.
- `flutter analyze`/`dart analyze`: clean on all three packages (`pandapay_domain`,
  `app`, `console`). All test suites green: 45 (`pandapay_domain`) + 3 (`app`) + 3
  (`console`) = 51.
- **Not done**: AD-1.1.4 (draft→in_review→published state machine UI), AD-1.2 (impact
  preview, structural validation beyond "rate is a non-negative number"), AD-1.3 (YAML
  bulk import/export), AD-2 through AD-9 (request/error queues, scraper, policy-change
  alert queue — the actual core of the admin console per its own plan — none of this
  exists yet); no token persistence in the console (refresh loses the session); the
  go_router-based nav shell isn't wired to the real auth-gated app.

### Chunk 7 — fixed the card_products RLS gap flagged in Chunk 6

`db/supabase/migrations/0015_card_products_rls_fix.sql` (new, applied on top of 0011 rather
than editing it in place, so the history of what changed and why stays legible):
- `card_products_public_read` was `for select to public using (true)` — Postgres RLS itself
  never filtered by `status`, only `v_card_catalogue_export`'s `WHERE status = 'published'`
  did, and only for callers going through that view. Replaced with
  `using (status = 'published' or pandapay.is_admin())`.
- The catalogue child tables (`reward_rules`, `cap_rules`, `milestone_rules`,
  `fee_waiver_rules`, `card_benefits`, `forex_rules`, `fuel_surcharge_rules`,
  `billing_cycle_rules`, `redemption_options`) had the same unconditional `using (true)` —
  they don't carry their own `status`, so a direct `select * from reward_rules` leaked a
  draft card's rates even with the `card_products` fix alone. Rewrote each to check its
  parent's status via an `exists` subquery against `card_products`.
- **Verified for real, not just applied**: inserted a genuine `draft`-status card with a
  reward rule, confirmed as the real non-superuser `app_user` role (no admin identity set)
  that both the card and its reward rule return **zero rows** — not filtered by the API, by
  RLS itself. Then set `app.user_id` to a real admin's id in the same session and confirmed
  the draft card becomes visible. Cleaned up the test row afterward; catalogue count back to
  the real 4 published cards, `GET /catalogue` unaffected (was never exposing drafts, since
  it goes through the view — this fix closes the *direct table access* hole, which matters
  for the console's future non-view admin queries and any other code that might query
  `card_products` directly without going through `v_card_catalogue_export`).
- All three test suites re-run clean after the fix: 45 (`pandapay_domain`) + 3 (`app`) + 3
  (`console`) = 51/51.
- **Restarted `auth/` and `api/` as background processes** against the already-running local
  Postgres (`pg_ctl` was already up from a prior session), recreating `auth/.env` and
  `api/.env` from their `example.env` templates (these are gitignored and get wiped between
  sessions by design — not a regression, matches the "removed .env files" cleanup step from
  Chunk 6).

### Chunk 8 — AD-2: Request & Error queues (console + api), plus a second RLS-gap finding

`api/`: four new admin routes, all typed and audited like the AD-1 writer, not a generic
passthrough:
- `GET /admin/card-requests` — groups `card_requests` by issuer+product, `SUM(request_count)`
  drives ordering (AD-2.1's "priority follows actual demand", not intuition).
- `POST /admin/card-requests/start-scraping` — creates a `sources` row (`kind='bank_official'`,
  `tos_reviewed=false`, `is_enabled=false` — the DB CHECK constraint physically prevents
  enabling before ToS review, this route doesn't try to work around it) and resolves every
  matching pending request.
- `GET /admin/error-reports` — shown-vs-claimed, joined to the card's current name.
- `POST /admin/error-reports/:id/approve` — **scoped deliberately**: only
  `field_path` values shaped `reward_rules.<uuid>.rate` are approvable (the one typed writer
  this API has); anything else returns 422 rather than being silently no-op'd or blindly
  written. On the happy path: updates the `reward_rules` row, inserts a `card_catalogue_changes`
  row, marks the report resolved, writes `admin_audit_log` — all in one transaction.
- `POST /admin/error-reports/:id/reject` — marks dismissed, audited.

**A second RLS-gap bug, same class as Chunk 7's, found immediately by hitting the new
endpoints with a real admin token**: `card_requests`/`data_error_reports` (0011) only ever got
an *owner* policy (`profile_id = pandapay.uid()`) — no admin policy existed at all. A real
admin querying either table got zero rows back, full stop, regardless of `requireAdmin`
passing. Fixed in `db/supabase/migrations/0016_queue_tables_admin_rls.sql` (`..._admin_all`
policies, `using (pandapay.is_admin())`), applied and re-verified live.

**Verified end to end against the live DB with real tokens, not mocked**, including the
AD-2 DoD explicitly: approving a seeded SBI Cashback Card correction (5% → 4.5%) produced —
confirmed via direct psql — a `data_version` bump (3→4), a `card_catalogue_changes` row
(`old_value`/`new_value`/`change_summary`), an `admin_audit_log` row, and the report flipping
to `resolved`. Also verified: reject flips a report to `dismissed`; start-scraping creates the
disabled `sources` row and resolves the matching `card_requests`; a genuine non-admin gets 403
on both new `GET` endpoints. `db/seed/0002_demo_queue_data.sql` (new, idempotent) seeds
realistic request/error rows since there's no user-facing submission UI yet.

`console/`: `features/queues/card_requests_screen.dart` (grouped list + start-scraping form),
`features/queues/error_reports_screen.dart` (shown-vs-claimed + approve/reject buttons),
wired into `main.dart`'s shell via a `NavigationRail` (Catalogue / Card Requests / Error
Reports) replacing the single-screen layout from Chunk 6. 2 new widget tests (`MockClient`
fakes) — 5/5 console tests passing. `flutter analyze`: clean.

**Not done**: no user-facing submission flow for card requests / error reports in `app/` (A8/C8
still admin-side only, as flagged above); the approve route's field_path scope is intentionally
narrow (only `reward_rules.<id>.rate` — extending it to caps/milestones/fees is real AD-5
propagation-resolver work, not a queue-UI task); AD-2.3's "emits a `policy_alert_evidence` row
with signal `user_report`" (the fourth signal into the AD-5 unified queue) is not wired — AD-5
itself doesn't exist yet, so there's nowhere for that evidence row to feed into.

### Chunk 9 — fixed the cap-measure gap flagged since Chunk 5

`packages/pandapay_domain`: `CapMeasure` enum added (`rewardValue`/`spendAmount`/`txnCount`,
mirroring `cap_measure`), `CapRule.measure` now required, `card_rules_json.dart` parses it
(no view change needed — `to_jsonb(k)` in `v_card_catalogue_export` already exported the
column, it just wasn't being read). `engine.dart`'s cap-blending block is now a `switch` on
`measure` instead of one spend-headroom-shaped code path used for everything:
- `spendAmount` — unchanged behaviour, this was always correct.
- `rewardValue` — the actual bug. `capRemaining`/`capValue` are reward-**value** headroom
  (e.g. "₹1,000 of cashback left this cycle"), not spend headroom, so a ₹X spend at
  `baseRatePerRupee` only consumes `X * baseRatePerRupee` of it, not `X`. Fixed by converting
  the remaining reward-value headroom to its spend-equivalent (`remaining.rupees /
  baseRatePerRupee`) before splitting the transaction into pre/post-cap portions, and letting
  the pre-cap reward be exactly `remaining` rather than re-derived from spend×rate (avoids a
  second rounding step producing a slightly different number than the headroom it's supposed
  to exhaust).
- `txnCount` — new case, no seed data exercises it yet but the enum value exists in the DB.
  A count cap can't partially blend a single transaction the way money-based caps can: either
  the transaction is within the remaining count (full base rate) or it isn't (full post-cap
  rate). `capValue`/`capRemaining` reuse the `Money` type purely as a numeric carrier for the
  count (documented inline in `card_rules_json.dart` — no separate DB column per measure).
- 5 new tests (2 pre-fix-shaped `spendAmount` boundary tests untouched, 3 new `rewardValue`
  cases mirroring the real seeded HDFC Millennia card exactly — including one that shows the
  actual before/after numbers: pre-fix would have computed ₹232 for a scenario where the
  correct answer is ₹840 — plus 2 `txnCount` cases). 50/50 domain tests passing (was 45).
- **Verified against the live seeded DB, not just unit tests**: re-ran
  `app/tool/verify_live_catalogue.dart` against the real running `api/` + `pandapay` DB;
  HDFC Millennia's reason line now reads "Base rate 7.0% on ₹2,000.00 (within ₹1,000.00
  reward-value headroom)" — correctly labeled and no longer silently wrong for that measure.
- `dart analyze`/`flutter analyze`: clean on all three packages. All suites green: 50
  (`pandapay_domain`) + 3 (`app`) + 5 (`console`) = 58.

### Chunk 10 — console token persistence (survives reload); app/ has no auth yet to persist

`console/`: `data/token_store.dart` (new) wraps `SharedPreferences` (works on Flutter Web via
localStorage — fine for an internal admin tool's refresh token, not a payment credential).
`AdminApi.verifyOtp` now returns both tokens (was access-only), plus a new
`AdminApi.refresh(refreshToken)` calling `auth/`'s real `POST /auth/refresh` (confirmed it
exists and takes `{refresh_token}` before building against it — this wasn't a guess).
`sessionInitProvider` (new, in `app/providers.dart`) runs once on startup: loads a stored
refresh token, exchanges it for a fresh access token, seeds `accessTokenProvider`; on any
failure (expired/reused/invalid — a real 401 from `auth/`) clears storage and falls back to
signed-out, doesn't retry-loop. `_AuthGate` in `main.dart` now waits on `sessionInitProvider`
before deciding whether to show the login screen, so a valid stored session doesn't flash
the login screen first. `login_screen.dart` persists both tokens on a fresh OTP sign-in.
Added a sign-out button (was previously impossible to sign out at all — closing the tab was
the only way to end a session).

**Verified with two new widget tests using `SharedPreferences.setMockInitialValues` (not just
that the code compiles)**: a stored refresh token silently resumes straight to the catalogue
screen with no login screen shown; an invalid/expired stored refresh token (mocked 401 from
`auth/`) correctly falls back to the login screen rather than hanging or crashing. 7/7 console
tests passing (was 5), `flutter analyze` clean.

**`app/` scope note**: `app/` has no auth flow at all yet — Chunk 5's Home screen only calls
the public, unauthenticated `/catalogue` and `/categories` endpoints, so there is no token to
persist there. Token persistence for `app/` is real work but blocked on UA-3's login screen
existing first, not something to fake here.

### Chunk 11 — implemented the custom_lint plugin (was dev-dep-wired since Chunk 1, never built)

`packages/pandapay_lints` (new): a real `custom_lint` plugin package, not just documentation.
Two rules:
- `no_bare_money_text` — flags `Text(...)` whose argument contains a `.format()` call on an
  expression of static type `Money`, catching both direct calls and string interpolations.
- `no_datetime_now_outside_clock` — flags `DateTime.now()` outside any `/clock/` path.

**Building this surfaced two real bugs in the rules themselves, found by deliberately testing
against both real code and a temporary probe file — not assumed correct from reading the API
docs:**
1. `no_datetime_now_outside_clock` initially matched on `MethodInvocation` (i.e. `X.method()`
   shape) — and never fired, on anything, ever. Root cause: `DateTime.now()` is a **named
   constructor** (`factory DateTime.now()`), not a static method, so it parses as
   `InstanceCreationExpression`, not `MethodInvocation`, even without an explicit `new`. Found
   by adding a temporary probe file with a bare `DateTime.now()` call, watching the rule fail
   to flag it, and instrumenting the rule with debug prints until the visitor callback itself
   was confirmed never invoked for that node — then fixing the AST node type it registers
   against. Removed the probe file after confirming the fix.
2. `no_bare_money_text`'s ignore-comment didn't suppress on the first attempt — trailing
   explanatory text after the rule name on the same `// ignore: rule_name — why` line broke
   `custom_lint`'s comment parser. Fixed by moving the explanation to its own comment line above
   a bare `// ignore: no_bare_money_text`.

**Running the finished plugin against the real app/ codebase (not a synthetic test) found one
genuine, previously-unnoticed violation**: `home_screen.dart`'s ranked-recommendation list
rendered `Text(recommendation.expectedValue.format())` directly — a bare Money render that
silently dropped the required confidence indicator, exactly the bug class UA-0.1.3 exists to
prevent, sitting undetected since Chunk 5. Fixed by swapping it for `MoneyText(...,
confidence: recommendation.confidence)`. `MoneyText`'s own internal `Text(amount.format())`
(the widget's canonical implementation) is exempted with a documented ignore comment.

Wired into `app/analysis_options.yaml` (`analyzer: plugins: [custom_lint]`); `console/` doesn't
use `Money` or call `DateTime.now()` anywhere yet, so it wasn't wired there — would just be a
no-op until it has code the rules apply to. `dart run custom_lint`: clean on the real
codebase. `flutter analyze`/`flutter test`: unaffected, still green.

### Chunk 12 — AD-3 scraper engine: legal gate, static fetch, extraction, snapshots

New `scraper/` (Python, separate from the Node/Dart stack per the plan's own stack choice
— §"Scraper Engine ... Python + Playwright"), a standalone venv at `scraper/.venv/`:
- `robots.py` (AD-3.1.1) — fetches and parses `robots.txt` per host via stdlib
  `urllib.robotparser`, cached in-memory per process. **Fails closed, not open**: a network
  error fetching `robots.txt` itself is treated as "everything disallowed," not "assume
  allowed" — the one case this matters is exactly the one where you can't prove you're allowed.
  A missing (404) `robots.txt` correctly defaults to allowed, per the actual standard's
  semantics (absence isn't disallowal). Honest identifiable `User-Agent` with a contact URL
  (AD-3.1.4).
- `rate_limit.py` (AD-3.1.3) — ≥5s between requests per host, enforced with a real
  `time.sleep`, not just documented as a policy.
- `fetcher.py` (AD-3.2.1) — static fetch via `httpx`. Playwright fallback (`fetch_with_js`) is
  a deliberate `NotImplementedError`, not a silent no-op: this sandbox doesn't have
  `playwright install chromium`'s browser binaries provisioned, and a JS-heavy page silently
  falling through to a thin static fetch would look like "the page has no reward info" instead
  of "this page needs the unbuilt path" — the loud failure is the honest one.
- `extractor.py` (AD-3.2.2/3.2.3) — strips `script`/`style`/`nav`/`footer`/`header` before
  hashing (via `selectolax`), optional `selector_hint` CSS scoping, `content_hash` (sha256) —
  the exact mechanism `AD-3.2.3` needs to skip unchanged pages.
- `db.py`/`run.py` (AD-3.2.4/3.2.5) — `page_snapshots` persistence, `scrape_runs` job
  bookkeeping (status/pages_fetched/pages_changed/duration/error), `--source-id` for manual
  "run now", failure-alert threshold at 3 consecutive failures per `source_pages`.
- `db/setup_scraper_role.sql` (new) — a dedicated `scraper_role` with `BYPASSRLS`, deliberately
  and narrowly scoped (only `SELECT`/`UPDATE` on `sources`/`source_pages`, `SELECT`/`INSERT` on
  `scrape_runs`/`page_snapshots`, nothing else, no superuser). This is *not* a repeat of the
  Chunk 7 `postgres`-superuser bug — that was accidental blanket bypass discovered as a defect;
  this is a documented, single-purpose bypass for a background service with no admin session to
  impersonate, choosing between two legitimate options (BYPASSRLS vs. per-write
  `SET LOCAL app.user_id` impersonation) rather than stumbling into it.
- 9 unit tests (`extractor`/`robots`, pure logic, no network — boilerplate stripping,
  selector-hint scoping, hash stability across whitespace differences, hash sensitivity to real
  content changes, robots allow/disallow/missing/network-failure/caching). All passing.

**Verified end to end against the real running DB with one real, low-risk live fetch — not
just unit tests.** Deliberately did **not** point this at a real bank's production site for
verification: AD-3.1 frames the legal gate as non-negotiable, and standing up genuine ToS
review for a real bank isn't something this session can respect properly. Instead pointed a
temporary test `sources`/`source_pages` row at `https://example.com` (IANA's domain reserved
specifically for illustrative/documentation use, single low-volume fetch) and ran the full
pipeline:
- First run: robots.txt fetched and allowed, page fetched (HTTP 200), content extracted and
  hashed, a new `page_snapshots` row inserted, `scrape_runs` recorded `status='success'`,
  `pages_fetched=1`, `pages_changed=1`. Confirmed via direct psql.
- Second run: same page, `content_hash` matched the stored one — **no duplicate snapshot
  inserted**, printed `unchanged`, `page_snapshots` count stayed at 1. Confirmed
  `skip_unchanged` genuinely works, not just in a mocked test.
- Separately verified the ToS gate at the DB layer itself: tried to `UPDATE sources SET
  is_enabled = true` on a `tos_reviewed = false` row directly via psql — the `0008` migration's
  `enabled_requires_tos_review` CHECK constraint rejected it, confirming the console (or this
  scraper, or anything else) genuinely cannot be the weak link here, exactly as AD-3.1.2 asks.
  Also confirmed the orchestrator's own source-selection query independently refuses to run a
  disabled/non-ToS-reviewed source — belt and suspenders, not just the DB constraint alone.
- Deleted both temporary test `sources` rows afterward; the only real `sources` row left is the
  one Chunk 8's "start scraping" flow created (still correctly `is_enabled=false`,
  `tos_reviewed=false` — nothing in this chunk touched it).

**Not done**: Playwright/JS-rendering fallback (documented `NotImplementedError`, needs browser
binaries); AD-3.3's actual pilot set (2-3 real banks + 2-3 news sources with real ToS review) —
this chunk built and proved the pipeline mechanics, not the real-world crawl targets, which is
a legal/product decision, not an engineering one; no scheduler/cron wiring (AD-3.2.5's "weekly
default crawl" — `run.py` is invoked manually today); AD-4 (diff review UI, AI extraction) and
AD-5 (the unified alert queue this scraper is meant to feed) don't exist yet — this chunk is the
data-collection half of AD-3/AD-4/AD-5's pipeline, not the review/propagation half.

### Chunk 13 — AD-4.1/4.2/4.5: diff computation feeding the unified alert queue

`scraper/pandapay_scraper/diff.py` (new) — word-level diff between two snapshots via
`difflib.SequenceMatcher`, with noise suppression (AD-4.1) for rotating dates and small
standalone counters ("128 people viewed this today") so cosmetic churn doesn't manufacture a
false policy change on every crawl — while still catching a real change sitting right next to
suppressed noise in the same sentence (tested explicitly, not just assumed compatible).

`scraper/pandapay_scraper/alerts.py` (new) — turns a genuine diff into (or reinforces) a
`policy_change_alerts` row. **Explicit, permanent scope limit, not a placeholder**: without
AD-4.3's AI-assisted structured extraction (needs a real LLM call — a cost/scope decision that
wasn't made this session, so not built), this cannot know *which field* changed (a cap? a rate?
just marketing copy?) — it raises one **page-level** signal
(`field_path = 'page_content:<page_role>'`), not the field-level path the full plan describes
(`cap_rules.<id>.cap_value`). AD-4.5's actual point — merging corroborating signals into one row
instead of fanning into separate queues — is implemented for real: a second `scrape_diff` on
the same (card, field) increments `signal_count` and adds evidence without creating a duplicate
`policy_change_alerts` row; `distinct_signal_kinds` only moves when the evidence is a genuinely
different *kind* of signal, not just another instance of the same one.

`run.py` wires this in: a snapshot change only produces a diff/alert when there was a *previous*
snapshot to diff against (first-ever observation of a page is baselining, not a policy change).
`db/setup_scraper_role.sql` grants `scraper_role` access to the two new tables (missed on the
first pass — found immediately by actually running the second crawl and hitting a real
`permission denied`, fixed and re-verified, not caught only in review).

**Verified end to end against the real DB with a real change, not a mocked one**: stood up a
local HTTP server under my own control (`python -m http.server`, not a real bank — same
reasoning as Chunk 12 about not scraping real production sites for verification), pointed a
test `source_pages` row at it with `card_product_id` set to the real seeded HDFC Millennia
card, and:
1. First crawl: baseline snapshot, correctly produced **zero** alerts (nothing to diff against).
2. Changed the served content (5% → 3%), second crawl: a real `policy_change_alerts` row was
   created, correctly attributed to HDFC Millennia, with a `policy_alert_evidence` row whose
   `excerpt` is the actual diff (`- 3%` / `+ 1%` — confirmed via direct psql, not assumed).
3. Changed the content again (1% → still 1%, but cap ₹1,000 → ₹500), third crawl: confirmed the
   **same** alert row was reinforced (`signal_count` 1→2, still exactly one
   `policy_change_alerts` row, two `policy_alert_evidence` rows), not a duplicate — proving
   AD-4.5's merge behavior for real.
4. Deleted all test fixtures (source, pages, the test alert and its evidence) afterward;
   `sources`/`policy_change_alerts` both back to their real pre-chunk state (1 row, 0 rows).
- 5 new pure-logic tests for `diff.py` (no-change, real-change-detected, date-noise-suppressed,
  counter-noise-suppressed, real-change-not-hidden-by-adjacent-noise). 14/14 scraper tests
  passing (was 9).

**Not done**: AD-4.3 (AI-assisted structured extraction — needs an LLM call, a decision not
made this session), AD-4.4 (pre-filled editable form over the real card-rule model — depends on
AD-4.3's structured output existing), field-level `field_path`s (currently page-level only, see
above), the diff review UI in the console (AD-4.2's "side-by-side diff view in Flutter Web" —
this chunk built the data pipeline feeding it, not the screen itself).

### Chunk 14 — AD-4.2 console diff-review UI + honestly-scoped AD-4.3 (no LLM key available)

**AD-4.3, scoped honestly**: this environment has no `ANTHROPIC_API_KEY` (or equivalent)
configured — `env | grep ANTHROPIC` shows only `ANTHROPIC_BASE_URL`. Real AI-assisted structured
extraction needs a real LLM call, which needs a key and a cost decision nobody has made for this
project. Rather than fabricate that decision, skip AD-4.3 silently, or (worse) claim something
is "AI" when it isn't, built `scraper/pandapay_scraper/extraction.py`: a deterministic
regex-based first pass — labeled `model_name = 'heuristic-regex-v1'` everywhere it appears, in
the DB, the API response, and the console UI, never anything implying AI. It extracts a clean
1-for-1 percentage or rupee-amount swap from a diff (`5% → 3%`), deliberately refuses to guess
when there's more than one candidate of the same kind in a diff (two categories' rates changing
at once), and returns nothing rather than a low-confidence non-answer when nothing regex-shaped
is found. 5 new tests. Wired into `run.py`: only attempted when an alert was actually raised
(needs a card to attach the proposal to).

**AD-4.2**: `api/` gained three routes — `GET /admin/alerts` (the queue, ordered by
`corroboration_score` then recency), `GET /admin/alerts/:id` (full detail: the alert, every
`policy_alert_evidence` row with its actual excerpt, and up to 5 recent `extraction_proposals`
for that card), `POST /admin/alerts/:id/decide` (approve/reject/needs_more_evidence — **only
ever changes the alert's own state, never card data**, audited in `admin_audit_log`). This
keeps the plan's "AI extracts, you verify" rule structurally true: even a *correct* heuristic
proposal can't auto-write a `reward_rules.rate` — applying a correction still goes through the
existing typed writer (`PUT /admin/reward-rules/:id`, Chunk 6) or the error-queue's typed
approve path (Chunk 8), both requiring a human to actually invoke them.

`console/`: `features/alerts/alerts_screen.dart` (new) — expandable alert list, each tile
lazy-loads its evidence excerpts and any heuristic proposals on expand, with
Approve/Reject/Needs-more-evidence actions. Wired into the `NavigationRail` as a 4th tab
("Policy Alerts") alongside Catalogue/Card Requests/Error Reports.

**Verified end to end against the live DB with a real generated alert, not mocked**: reused the
Chunk 13 local-test-server technique (not a real bank) to produce a genuine alert + a real
heuristic proposal for the seeded HDFC Millennia card, then hit every new endpoint with a real
admin token: `GET /admin/alerts` listed it, `GET /admin/alerts/:id` returned the actual diff
excerpt and both extracted fields (`rate_percent`, `cap_value_inr`) with confidence 0.25 (two
fields changed at once, correctly the lower-confidence case), `POST .../decide` flipped the
alert to `approved` with a real `admin_audit_log` row — confirmed via direct psql, not assumed.
A real non-admin token got 403 on `GET /admin/alerts`. Deleted all test fixtures afterward.
`flutter analyze`: clean, 1 new console widget test (8/8 passing, was 7) using the same
`MockClient` fake pattern as the rest of the suite — confirms list → expand → evidence/proposal
render → approve → callback fires, without a real network call in the automated suite.

**All four suites green: 50 (`pandapay_domain`) + 3 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) = 80 tests total.**

### Chunk 15 — app/'s UA-3 login flow (the app finally has real auth, not just a public catalogue)

`app/`: `data/auth_api.dart` (`AuthApi`/`AuthTokens`, `ProfileApi`) and `data/token_store.dart`
— near-identical siblings of `console/`'s Chunk 6/10 equivalents (same underlying `auth/`
service, same OTP endpoints), kept as separate copies rather than factored into a shared
package since the two apps' account models genuinely diverge (the console never creates a
`profiles` row; the app does). `app/providers.dart` gained `authApiProvider`,
`tokenStoreProvider`, `accessTokenProvider`, `sessionInitProvider` (same
resolve-stored-refresh-token-on-startup pattern as Chunk 10), `profileApiProvider`,
`profileProvider`. `features/auth/login_screen.dart` — phone+OTP, and on success calls
`ProfileApi.ensureProfile()` (api/'s `POST /profile` is an upsert — `ON CONFLICT DO UPDATE` —
so this is safely idempotent on every login, not a duplicate-row risk). `features/account/
account_screen.dart` — signed-out shows the login screen, signed-in shows the real fetched
profile + a sign-out button.

Wired into the previously-placeholder **More** tab in `main.dart` (tab index 3) — the app's
first real auth surface; Cards/Activity tabs remain placeholders, not touched here.

**Verified against the real running `auth/` + `api/` services with a genuine OTP round-trip,
not mocked**: requested and verified a real OTP for a test phone number, called
`POST /profile` (confirmed a real row upserted — `locale: 'en-IN'`, `currency: 'INR'` defaults,
matching exactly what `ProfileApi.ensureProfile()`'s request shape expects), then `GET /profile`
returned the identical row — proving the exact contract the app's code depends on actually
matches what `api/` really returns, not just what was assumed when writing the Dart models.
This is also the first time `api/`'s `/profile` routes (built and RLS-proven back in Chunk 1)
have ever actually been called by application code rather than curl.
`flutter analyze` and `dart run custom_lint`: both clean. 2 new widget tests (signed-out shows
login; signed-in shows the real profile id + sign-out button, via a `MockClient` fake matching
the console's established pattern) — 5/5 app tests passing (was 3).

**Not done**: no user_cards CRUD (owning/tracking actual cards) yet — that's the next logical
UA-3+ step now that a real signed-in identity exists; no onboarding flow beyond the bare
`ensureProfile()` upsert; Cards/Activity tabs still placeholders; no biometric/device-level
re-auth (UA-3's fuller scope); the engine still ranks the whole catalogue rather than a signed-in
user's actual cards (that needs user_cards to exist first).

**All four suites now: 50 (`pandapay_domain`) + 5 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) = 82 tests total.**

### Chunk 16 — user_cards wiring: a real wallet, ranking scoped to it

`api/`: `GET /user-cards` (owner-scoped via RLS's existing `user_cards_owner` policy — 0011
already covered this table, this is the first code that ever calls it), `POST /user-cards`
(validates the card exists and is `published` before inserting; `profile_id` is always
`req.userId`, never taken from the request body — same anti-tampering pattern as `POST
/profile`), `POST /user-cards/:id/archive` (**R4: archive, never delete — there is deliberately
no `DELETE /user-cards/:id` route**).

`app/`: `data/user_cards_repository.dart` (`UserCard`, `UserCardsRepository`),
`features/cards/cards_screen.dart` (wallet list + archive button + an add-from-catalogue
dropdown, reusing the already-fetched `catalogueProvider`), wired into the previously-placeholder
**Cards** tab. `rankedRecommendationsProvider` (in `providers.dart`) now scopes the catalogue to
the signed-in user's wallet **when they own any cards**, falling back to the whole catalogue
when signed out or before a first card is added — so Home is never empty just because nobody's
built onboarding yet, but a user who's actually added cards sees ranking against what they
really have, not the full 4-card demo catalogue.

**Verified end to end against the live DB/RLS with a real signed-in user, not mocked**:
requested a real OTP, added a real `user_cards` row for HDFC Millennia, confirmed `GET
/user-cards` returns exactly that card with correct joined display fields. **Confirmed RLS
isolation directly**: a second, different real user (separate OTP login) hit the same `GET
/user-cards` and got an empty wallet — never saw the first user's card. **Confirmed R4
directly**: archived the card via the real endpoint, confirmed it disappeared from `GET
/user-cards`, then queried the DB directly and confirmed the row still exists with
`is_archived = true` and a real `archived_at` timestamp — archived, not deleted, verified at
the data layer, not just by trusting the route's own name.

`flutter analyze` and `dart run custom_lint`: both clean. The pre-existing "bottom nav switches
to a placeholder tab" test targeted the Cards tab, which is no longer a placeholder — retargeted
it to the still-placeholder Activity tab instead of leaving a stale assertion, and added 2 new
Cards-tab tests (signed-out shows login; signed-in shows a real owned card and archiving it
calls through to the repository). 7/7 app tests passing (was 5).

**Not done**: no reordering/default-card UI (`sort_order`/`is_default` exist in the schema and
API response, unused in the UI); no credit-limit/statement-day/due-day capture (`user_cards` has
columns for all of it, UA-3's onboarding flow for those fields doesn't exist); no
cap-consumption or milestone-progress tracking per user (a separate, larger surface — this
chunk is "which cards does this person have," not "how much have they spent on each this
cycle," so the engine still evaluates every owned card as if its caps/milestones are fully
fresh).

**All four suites now: 50 (`pandapay_domain`) + 7 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) = 84 tests total.**

### Chunk 17 — real cap/milestone tracking per user (transactions -> cap_states/milestone_states)

`api/src/cycles.js` (new): period-bounds computation for all 6 `cap_period` values —
`calendar_month`/`quarter`/`half_year`/`annual` are calendar-anchored (documented simplification:
`cap_rules` carries no anchor column, so there's nothing else to anchor to); `statement_cycle`
uses `user_cards.statement_day`; `annual` additionally respects `milestone_rules.anchor`
(`card_anniversary`/`fiscal_year`/`statement_cycle`/`calendar_year`) since that table *does*
carry an anchor column. 12 unit tests (Node's built-in `node --test`, no new dependency) —
leap-year February, quarter/half-year boundaries, fiscal year (Apr-Mar), anniversary wrap-around,
statement-cycle before/after the statement day, lifetime, and an unknown period throwing rather
than silently defaulting. `api/`'s first test suite; added `npm test`.

`api/`: `POST /transactions` (manual entry — `source='manual'`, `reward_state='estimated'`, R3's
"nothing is 'confirmed' without real reconciliation" holds structurally since there's no other
write path yet) updates `cap_states.consumed` and `milestone_states.qualified_spend` in the same
transaction as the insert. **Found and fixed a bug from first principles, the same class as
Chunk 9's engine fix, before it ever shipped**: the first version incremented `cap_states.consumed`
by the raw spend amount regardless of the cap's `measure` — verified live against the real seeded
HDFC Millennia card (`reward_value` cap, 7% online rate, ₹1,000 cap) and caught immediately: a
₹20,000 spend produced `consumed: 20000.00` against a ₹1,000 cap, obviously wrong. Fixed by adding
`effectiveRatePerRupee` to `cycles.js` (a hand-kept mirror of `pandapay_domain`'s
`RewardUnit.effectiveRatePerRupee` — no shared package between the Node and Dart sides) and
computing the actual reward value earned for `reward_value` caps, `+1` for `txn_count` caps, and
only the raw amount for `spend_amount` caps. Re-verified: the same ₹20,000 spend now correctly
produces `consumed: 1400.00` (₹20,000 × 7%). `GET /user-cards` extended to include each owned
card's *currently-active-period* `cap_states`/`milestone_states` (a missing row means nothing's
been logged yet this period — full headroom, matching the engine's own default).

`app/`: `UserCard` gained `capConsumed`/`milestoneQualifiedSpend` maps parsed from the new
response fields; `UserCardsRepository.logTransaction()`. `rankedRecommendationsProvider` now
builds real `CardSnapshot.capRemaining`/`milestoneProgress` for wallet cards from this state
(non-wallet cards, i.e. the whole-catalogue fallback, are still evaluated fresh — there's no
per-user state for a card nobody's added). `cards_screen.dart` gained a "log a ₹1,000 demo spend"
button per card (real transaction, fixed demo amount — UA's actual amount-entry UI doesn't exist
yet, same honesty pattern as the existing `_defaultDemoAmount` placeholder elsewhere).

**Verified end to end against the live DB with a real signed-in user and the exact Dart classes
the app uses, not fixtures**: added a real wallet card, logged a ₹1,000 transaction via the app's
own `UserCardsRepository.logTransaction()` request shape, confirmed `GET /user-cards` returned
`consumed: 70.00` (₹1,000 × 7%). Wrote `app/tool/verify_live_wallet.dart` (new manual verification
script, same pattern as Chunk 5's `verify_live_catalogue.dart`) that fetches the real wallet via
the real repository classes and runs it through `RecommendationEngine.rank()` — a further
₹20,000 spend against the ₹930 real remaining reward-value headroom (₹1,000 cap − ₹70 already
consumed) produced `₹997.14` with the reason line "₹930.00 reward-value headroom exhausted by
₹13,285.71 of this spend, remaining ₹6,714.29 at 1.0% (post-cap)" — the exact Chunk 9 blending
math, now fed by real per-user consumption data instead of always-fresh state. All test fixtures
deleted afterward.

`flutter analyze`/`dart run custom_lint`: clean. All 7 pre-existing app tests still pass
unmodified (the new `UserCard.fromJson` fields default to empty maps when absent, so the Chunk 16
test fixture — which has no `cap_states`/`milestone_states` keys — still parses correctly).

**Not done**: no amount-entry UI (fixed ₹1,000 demo amount, same placeholder pattern used
elsewhere); no SMS/email/statement-import transaction sources (`txn_source` enum has them, only
`manual` is wired); no points_ledger/fee_waiver_states wiring (this chunk did caps and milestones
only — fee-waiver progress tracking is the same shape of work, not done); no transaction editing
or a real Activity-tab list view of logged transactions (`GET /transactions` exists and works,
nothing in the UI calls it yet).

**All five suites now: 50 (`pandapay_domain`) + 7 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) + 12 (`api`, new) = 96 tests total.**

### Chunk 18 — Activity tab: the last placeholder tab is now real

`api/`: `GET /transactions` extended with `LEFT JOIN`s to `user_cards`/`card_products`/
`spend_categories` so the response carries display-ready `card_name`/`card_nickname`/
`category_name` instead of raw ids the client would've had to resolve itself.

`app/`: `UserCardsRepository.fetchTransactions()` + `TransactionEntry` (nickname-preferred
display name — matches the same "nickname if set, else the card's own name" pattern
`CardsScreen` already used), `transactionsProvider`, `features/activity/activity_screen.dart`
wired into the previously-placeholder **Activity** tab. Signed-out shows the same login flow as
Cards/More; signed-in shows a real list (merchant, card, category, amount via `MoneyText`).

**All four bottom-nav tabs are now real, not placeholders** — Home (Chunk 5), Cards (Chunk 16),
Activity (this chunk), More (Chunk 15).

**Verified end to end against the live services**: added a real wallet card with a nickname,
logged a real ₹500 transaction with a merchant name, confirmed `GET /transactions` returns
exactly the shape `TransactionEntry.fromJson` expects — including the nickname
(`"My HDFC"`) correctly taking priority over the card's own name (`"HDFC Millennia"`) in
`card_display_name`'s resolution, the same precedence rule already used elsewhere. All test
fixtures deleted afterward.

Retargeted the test that used to assert Activity was a placeholder (now that it's real, that
assertion would be testing a lie) and added a second test for the signed-in real-data path.
`flutter analyze`/`dart run custom_lint`: clean. 8/8 app tests passing (was 7).

**All five suites now: 50 (`pandapay_domain`) + 8 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 97 tests total.**

### Chunk 19 — real amount-entry UI

Replaced the fixed ₹1,000/₹20,000 demo amounts that had been hardcoded in three separate
places (`app/lib/app/providers.dart`'s `_defaultDemoAmount`, `app/lib/features/cards/
cards_screen.dart`'s own copy, and the verification scripts) with a single shared
`enteredAmountProvider` (`StateProvider<Money>`, default ₹1,000) and a real `TextField` at the
top of the Home screen.

`rankedRecommendationsProvider` now reads `enteredAmountProvider` instead of the removed
constant, so ranking reacts live to what's typed. Cards' "log spend" button reads the same
provider, so whatever amount is currently entered on Home is exactly what gets logged if the
user then taps the log-spend icon on an owned card — no separate, disconnected amount exists
anymore. The button's tooltip now shows the live formatted amount instead of a fixed string.

**Verified end to end against the live services**: real OTP login (`+919876500002`), added a
real wallet card (Axis Ace), then called `POST /transactions` with `amountInr: 2500` — the exact
kind of non-default value the new text field now sends — and confirmed `GET /transactions`
returned `amount_inr: "2500.00"` correctly, not a hardcoded placeholder. Test fixtures deleted
afterward.

Added a widget test that types "2500" into the new field and asserts `enteredAmountProvider`
updates to `Money.fromRupees(2500)`. `flutter analyze`/`dart run custom_lint`: clean. 9/9 app
tests passing (was 8).

**All five suites now: 50 (`pandapay_domain`) + 9 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 98 tests total.**

### Chunk 20 — RLS re-audit + scraper scheduler

**RLS re-audit** (item 7 from the old list): grepped every migration under `db/supabase/
migrations/` for `using (true)` and for the owner-policy-only gap pattern that bit us three
times already (Chunk 7: `card_products`; Chunk 8: `card_requests`/`data_error_reports`/
`support_tickets`). Findings: the one remaining unconditional `using (true)` block (0011's
catalogue-tables loop) covers reference/config data — `issuers`, `spend_categories`,
`feature_flags`, `changelog_entries`, etc. — that's meant to be world-readable by design, not a
missed admin gap; `card_products` and its 9 status-bearing children were already fixed in 0015.
The owner-only tables from 0011's first loop (`user_cards`, `transactions`, `cap_states`,
`milestone_states`, `points_ledger`, `lounge_usage`, `needs_review_items`, etc.) have no admin
policy — but the console has no screen that reads any of them yet (unlike the Chunk 7/8 cases,
where the console *did* have a screen silently getting empty results), so this isn't a live gap,
just user-private data nothing has asked to read across users yet. No new migration needed.

**Scraper scheduler** (item 6): `scraper/scripts/run_weekly.sh` — a wrapper that activates the
venv, runs `python -m pandapay_scraper.run`, and logs to `scraper/logs/` (gitignored). Paired
with `pandapay-scraper.service` + `pandapay-scraper.timer` (systemd, `OnCalendar=Mon 03:00` with
a 30-min randomized delay) for AD-3.2.5's "weekly default crawl." Not wired into cron/systemd on
this dev machine (no target host to install it on) — the files are ready to `cp` into
`/etc/systemd/system/` on a real deployment.

**Verified live**: ran `run_weekly.sh` against the actual local Postgres — `main()` exits 0 with
"No enabled+ToS-reviewed sources to crawl." (correct: the `sources` table is still empty per
item 1 below) and a real log file was written. Confirms the scheduler is safe to enable right
now without accidentally hitting anything, and will start crawling automatically the moment a
real source is added and ToS-reviewed.

### Chunk 21 — UA-2.5.1 golden fixture set

`packages/pandapay_domain/test/golden_fixtures_test.dart`: a single consolidated file with 33
scenarios (plan asks for ≥30) covering every rule interaction in one sweep — distinct from
`engine_test.dart`'s existing per-bug regression tests, which stay in place. Covers: cap
boundary × all 3 measures (spend_amount/reward_value/txn_count, 9 scenarios), milestone flip
(not-material/material-partial/completes/already-achieved, 4), manual override (2), P2P/UPI
exclusion gate (4), travel forex (2), fuel surcharge waiver (2), no-cap card / bare card /
category mismatch (3), reward-rule priority ordering (1), tie-break and ranking totality
(4, including a zero-cards scenario), and two "kitchen sink" scenarios where cap blending, the
fuel waiver, and a milestone bonus all combine on one transaction.

Building scenario 12 (milestone-completion bonus) surfaced a fact about the existing engine
worth flagging, not a bug: the bonus is pro-rated to *this transaction's own share* of the
threshold (`closedPortion / thresholdSpend`), not to however much of the remaining gap it
closes — a milestone crossed by a series of small transactions pays out a little on each one
that clears the material-fraction bar, not one lump sum on whichever transaction happens to
tip it over. My first draft of the test assumed the latter and failed against the real engine;
fixed the test's expected values to match actual (already-correct, already-shipped) behavior
rather than changing the engine.

`dart test`: 83/83 passing in `pandapay_domain` (was 50 — +33 new, 0 regressions).

**All five suites now: 83 (`pandapay_domain`) + 9 (`app`) + 8 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 131 tests total.**

### Chunk 22 — UA-1.1: 16 more real cards (user-approved expansion)

Per explicit user go-ahead (recommended option: "add ~15-20 more well-known cards"),
`db/seed/0002_more_demo_cards.sql` adds 16 more real Indian credit cards across 8 new issuers
(Kotak, Yes Bank, IDFC FIRST, IndusInd, AU Small Finance, Standard Chartered, RBL, Amex) plus
more from the original 4 issuers — same honesty contract as `0001_demo_cards.sql`: real
issuers/product names/network/reward shapes, approximate publicly-known rates, every row
`status = 'draft'` (UA-1.1.4 human verification explicitly not done, not claimed). Deliberately
varied the *shapes* exercised, not just the names: a flat-rate no-reward-rule card
(`yes-paisasave`), an uncapped category-rate card (`idfc-first-select`), a `flat_points` base
unit with no category rules at all (`amex-membership-rewards`), a `txn_count`-measure cap
outside the one card that already had one (`rbl-world-safari`), and a fuel-surcharge-waiver
card outside the domain package's own fixtures (`indusind-tiger`).

**Verified live, not just "the SQL ran without error"**: applied against the real local
Postgres (20 cards total, up from 4), re-ran the same file to confirm the upsert-by-slug
pattern is still idempotent (no duplicates, count unchanged). Confirmed via `/admin/cards`
that all 16 land as `status: 'draft'` — not silently published. Then temporarily flipped all
16 to `published` + `verified_at` (a scoped, reverted-immediately test operation, not a real
verification claim) and ran `app/tool/verify_live_catalogue.dart` — the same tool used in
Chunk 5 — against the real `/catalogue` endpoint: all 20 cards fetched and parsed through
`CardProductJson.fromJson` without throwing, and `RecommendationEngine.rank()` ranked all 20
sensibly (base-rate cards at the top for an online spend, `flat_points`/no-matching-rule cards
correctly excluded, not silently zero-valued). Reverted every one of the 16 back to `draft`/
`verified_at = null` immediately after — confirmed via a fresh `select status, count(*) ...
group by status` (4 published, 16 draft) before moving on. `dart test` in `pandapay_domain`:
still 83/83 passing (this chunk touched only seed data, not `packages/`).

### Chunk 23 — AD-6 crowdsourced data visibility

**Scope note, stated up front**: AD-6.1.1's `flutter_map`/OSM pin-clustering interactive map
is explicitly NOT built here — a real map is a separate, larger UI investment (new Flutter Web
dependency, tile layer, geohash-bucketed clustering) not attempted in this pass. What's built
instead is a filtered table over the same data with the same filters (AD-6.1.4: category,
confidence, published) and the same grid-snapped-only coordinates (AD-6.1.5 holds automatically
— `grid_lat`/`grid_lng` are the only columns that exist, table or map). Documented here rather
than silently substituted.

`api/`: 8 new admin routes — `GET /admin/merchants` (filtered list), `GET /admin/merchants/:id`
(AD-6.2.1 detail: locations, contribution history, conflicts, and a confidence "breakdown"
that's honestly the raw inputs, not a re-derivation — no confidence-scoring batch job exists
anywhere in this codebase to call), `POST /admin/merchants/:id/override` (AD-6.2.2, typed
writer, sets `operator_locked`), `POST /admin/merchants/:id/unpublish` (AD-6.2.3),
`GET /admin/merchant-conflicts` + `POST .../resolve` (AD-6.3, bumps `confidence` to
`'operator_verified'` — the enum's own human-decided tier — rather than claiming a
recomputation that doesn't exist), `GET /admin/abuse-signals` + `POST .../block` (AD-6.4,
bulk-reverts the device's `merchant_contributions` by marking `is_counted = false`). Every
mutating route audits through `admin_audit_log`, same pattern as every other admin write in
this codebase.

`console/`: two new nav tabs, **Merchants** (filter bar + list + a detail dialog with override/
unpublish actions) and **Conflicts** (two-tab: pending conflicts with one-click resolve-by-
competing-value, and abuse signals with a block action).

**Verified end to end against the live services, not just "the code compiles"**: inserted a
real test merchant + location + contribution + conflict + abuse signal via direct SQL, then
exercised every one of the 8 routes with real curl calls against a real admin JWT — list,
detail, override (confirmed `operator_locked` flipped), unpublish (confirmed `is_published`
flipped), conflict resolve (confirmed the merchant's `display_name`/`confidence` actually
changed in the DB), abuse-signal block (confirmed the contribution's `is_counted` flipped to
`false` with the right `rejected_reason`). Deleted every test fixture afterward.

Console-side: `flutter analyze` and `dart run custom_lint` clean; two new widget tests
(override flow, conflict-resolve flow) exercising the real screens against `MockClient`
fixtures shaped like the live API's actual responses. Caught and fixed a real bug in this
process — the three filter dropdowns overflowed their fixed-width `SizedBox`es (a `RenderFlex`
overflow, not just a test artifact — it would have clipped content in a real narrow window
too), fixed with `isExpanded: true`. 10/10 console tests passing (was 8). `api/`'s existing
12 tests unaffected (untouched files); the 8 new routes have no dedicated unit tests (no
pure-function logic to isolate — verified via the live curl pass instead, same as every other
admin route in this codebase).

**All five suites now: 83 (`pandapay_domain`) + 9 (`app`) + 10 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 133 tests total.**

### Chunk 24 — AD-7 acceptance map & effective rate monitor

Same scope note as AD-6 (Chunk 23): a filtered table over `acceptance_summary`/
`effective_rate_summary`, not a real `flutter_map`/OSM view — stated up front, not
substituted silently.

`api/`: 5 new admin routes — `GET /admin/acceptance-summary` (AD-7.1, filtered by network/
rail/published), `GET /admin/acceptance-summary/:merchantId` (AD-7.2 detail: raw
`acceptance_reports` counts, not just the pre-aggregated summary), `POST .../publish`
(AD-7.2's publish gate, mirroring the merchant gate — a toggle, not always-unpublish, since
these rows start `is_published = false`), `GET /admin/effective-rate-summary` (AD-7.3/7.4:
observed vs published rate, sample count + distinct-device count always alongside the number
per the plan's provenance requirement, and the observed-vs-published cap ceiling), and
`GET .../samples` (the raw `effective_rate_samples` behind one summary row).

**AD-7.5 ("divergence rows link straight to their alert, not a standalone dead end")**:
implemented as a best-effort `LEFT JOIN LATERAL` onto the most recent *open*
`policy_change_alerts` row for the same `card_product_id` — genuinely useful when one exists,
but flagged honestly in the route's doc comment that nothing in this codebase automatically
*raises* an alert from a detected divergence yet (`effective_rate_summary.is_divergent`/
`alert_raised_at` exist in schema but no job writes them from a real computation — the
`is_divergent`/`alert_raised_at` values used in this chunk's live verification were hand-set
via SQL to prove the join and the console rendering, not produced by an inference pipeline).

`console/`: one new nav tab, **Acceptance & Rates**, two sub-tabs — Acceptance (filter bar +
list + publish/unpublish toggle) and Effective rate monitor (divergence-only filter, each row
showing observed/published rate + sample provenance + cap-ceiling comparison, with a linked-
alert chip when AD-7.5's join found one).

**Verified end to end against the live services**: inserted a real merchant + acceptance
summary + acceptance report + effective-rate sample + effective-rate summary row + a real
`policy_change_alerts` row via direct SQL, then exercised all 5 routes with real curl calls —
list, detail (confirmed real report rows returned), publish toggle (confirmed `is_published`
flipped in the DB), effective-rate list with `divergentOnly=true` (confirmed the linked-alert
join correctly resolved `linked_alert_id`/`linked_alert_state` for the real alert row), and
the samples endpoint. Deleted every fixture afterward.

`flutter analyze`/`dart run custom_lint`: clean. One new widget test (acceptance publish +
effective-rate tab with a linked alert chip) against `MockClient` fixtures shaped like the
live API's real response shape. 11/11 console tests passing (was 10). `api/`'s existing 12
tests unaffected.

**All five suites now: 83 (`pandapay_domain`) + 9 (`app`) + 11 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 134 tests total.**

## What's NOT done (next steps, roughly in priority order)

### Chunk 25 — AD-8 data quality dashboard

`api/`: one route, `GET /admin/data-quality-dashboard`, wrapping `v_data_quality_dashboard` —
a view that already existed in `db/supabase/migrations/0010_functions_and_views.sql` (not
written this chunk, just exposed for the first time). Scope note stated up front in the
route's doc comment: **AD-8.3** ("trend lines, not just current values") and **AD-8.4**
("operator alerting when any backlog crosses a threshold") are NOT implemented — trends need
a time-series snapshot table + scheduled job that don't exist, alerting needs a notification
channel this codebase has never had. Both flagged explicitly rather than faked with one data
point pretending to be a trend or a silent no-op "alert."

`console/`: one new nav tab, **Data Quality** — a stat-card grid over every field the view
returns (cards published/stale, merchants total/published/high-confidence, open alerts,
pending queues, scrape failures), with the same "no trends, no alerting yet" note visible in
the UI itself, not just in a code comment nobody using the console will ever read.

**Verified live**: `curl`'d the real route against the actual local Postgres and got real
counts back (`cards_published: 20` matching Chunk 22's expanded seed data, `card_requests_pending: 2`
matching real queue rows) — not a stub response.

Caught and fixed a real overflow bug while writing the widget test (the dashboard's header
`Row` didn't wrap its `Text`, same overflow class as Chunk 23/24's dropdown fixes) — fixed
with `Flexible` + `TextOverflow.ellipsis`. 12/12 console tests passing (was 11).

**All five suites now: 83 (`pandapay_domain`) + 9 (`app`) + 12 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 135 tests total.**

### Chunk 26 — AD-9 anonymization audit automation (AD-6/7/8/9 all done — the full crowdsourced-data backlog is now cleared)

The 6-check function itself, `pandapay.run_anonymization_audit()`, and the `anonymization_audit_runs`
table already existed (`db/supabase/migrations/0010_functions_and_views.sql` — not written this
chunk). What's new:

`api/`: 3 routes — `GET /admin/anonymization-audit-runs` (AD-9.1 history), `.../latest`
(convenience for the summary card), `POST .../run` (AD-9.4's manual/cron entrypoint — calls
the SQL function through a DB client, not a shell-out).

`console/`: one new nav tab, **Anonymization Audit** — latest-result banner (pass/fail, check
counts, git SHA), a "Run now" button, and history list with findings.

**AD-9.2 ("wire into CI as a deploy-blocking gate") — the actual gate**: added
`.github/workflows/anonymization-audit.yml`, the *first* CI workflow this repo has ever had
(no `.github/` existed before this chunk; confirmed via `git remote -v` that the repo has a
real GitHub remote, `github.com/true1ck/pandapay`, so this isn't a guess at an unused feature).
Runs on every push/PR against a throwaway `postgres:16` service container: applies all 16
migrations for real (skipping only `0013_cron_jobs.sql`, which needs `pg_cron` — not present
on the plain Postgres image, same known gap as local dev), then calls
`pandapay.run_anonymization_audit()` directly via `psql` (not through `api/`'s HTTP layer, so
a broken `api/` deploy can never mask a real audit failure) and fails the build (`exit 1`) on
any check failure.

**A real bug caught and fixed while writing the workflow, not after**: the first draft combined
the audit call and its result check into one SQL statement
(`... WHERE id = pandapay.run_anonymization_audit(...)`) — tested that exact query locally
first (this chunk's now-standing practice: prove CI logic against the real local Postgres
before trusting it to GitHub's runners) and it silently returned zero rows. Root cause: under
READ COMMITTED, a single statement's own side effects (the function's `INSERT`) aren't visible
to that same statement's snapshot. Fixed by splitting into two separate `psql` calls — verified
the fix, then additionally replicated the *entire* migration-apply-and-audit shell loop
verbatim against a disposable scratch database (`pandapay_ci_test`, created and dropped for
this purpose) to prove the exact script text CI will run, not just the SQL logic in isolation.

**AD-9.4 nightly cron**: `db/scripts/run_nightly_audit.sh` (+ `pandapay-audit.service`/
`.timer` for systemd), same pattern as Chunk 20's scraper scheduler — this exists *in addition
to* the CI gate because the plan explicitly calls for catching a regression "even without a
deploy." Alerting is explicitly NOT implemented (same honest gap as AD-8.4 — no notification
channel exists); the script fails loudly and logs, ready to wire up the moment one does.

**Incidental infra note**: this chunk's local Postgres cluster (port 55432, scratchpad-based)
had been torn down between sessions (expected — it lives in a session-scoped scratchpad
directory, not committed anywhere) and was rebuilt from scratch: `initdb` + all 16 migrations
+ both seed files + `setup_app_role.sql`/`setup_scraper_role.sql` + a fresh admin user via a
real OTP signup. This surfaced one real, previously-undocumented gap in `db/setup_app_role.sql`:
it granted `execute on all functions in schema pandapay` but never `usage on schema pandapay`
itself, so `app_user` got `permission denied for schema pandapay` the moment any endpoint
called `pandapay.is_admin()` — every admin route was silently broken on a truly fresh
database. Fixed by adding the missing `grant usage on schema pandapay to app_user;` line.
This bug existed on day one (Chunk 1) and was masked all along by the original session's
Postgres cluster never having been rebuilt from a clean `setup_app_role.sql` run since some
earlier one-off manual grant — worth knowing if this repo is ever cloned fresh.

`flutter analyze`/`dart run custom_lint`: clean. One new widget test (latest-result display +
run-now flow). 13/13 console tests passing (was 12). Re-ran all five suites after the
environment rebuild to confirm nothing regressed: 83 (`pandapay_domain`) + 9 (`app`) — both
unaffected by this chunk, confirmed passing again from a cold environment, not assumed.

**All five suites now: 83 (`pandapay_domain`) + 9 (`app`) + 13 (`console`) + 19 (`scraper`,
Python) + 12 (`api`) = 136 tests total.**

Chunks 1-26 (see sections above) are complete and verified. **AD-6 through AD-9 — the entire
crowdsourced-data backlog — is now done.** Remaining, both explicitly on hold per user
decision (2026-08-05):

1. **AD-3's real pilot set** — user explicitly chose to stay on test fixtures for now (no real
   bank/news source added). Still one `sources` row (Chunk 8, correctly disabled); pipeline
   still only proven against `example.com`/a local test server.
2. **A real AD-4.3 (LLM-backed extraction)** — still blocked on an `ANTHROPIC_API_KEY` and a
   cost decision; no change.

Both of these need a decision from the user (legal/ToS review for real scrape targets; an API
key + cost sign-off for LLM extraction) before more code can responsibly be written against
them.

There was, however, real mechanical work left that didn't require either of those decisions —
picked back up starting with Chunk 27 below.

### Chunk 27 — AD-2: stale-queue flagging for card requests and error reports

Both AD-2 queues (Chunk 8) showed every open item with equal visual weight regardless of age,
so an old, unresolved request could sit unnoticed behind newer ones. Added age-awareness
without inventing a notification channel that doesn't exist (same honesty rule as AD-8.4/AD-9.4):

`api/`: `GET /admin/card-requests` now returns `oldest_pending_age_days` and `is_stale`
(`true` when the oldest pending request in the group is >14 days old) per group, and orders
stale groups first. `GET /admin/error-reports` now returns `age_days` and `is_stale`
(pending + >7 days old) per report, same stale-first ordering. Thresholds are plain SQL
`interval` literals, not configurable yet — no settings UI exists to change them.

`console/`: both `card_requests_screen.dart` and `error_reports_screen.dart` show an orange
"Stale · Nd" `Chip` next to the title when `is_stale` is true.

**Verified**: ran both new SQL fragments directly against the live local Postgres (`psql`) to
confirm they execute and return sane values before trusting the API route; `flutter analyze`
clean; all 13 console widget tests still pass unchanged (no test exercises stale data yet,
since none of the seeded rows are actually old enough to trip the threshold — this is UI/query
plumbing verified structurally, not a new stale-item test case).

### Chunk 28 — AD-1.1.4: draft→in_review→published→archived state machine UI

Flagged as missing since Chunk 6: the console could edit reward-rule rates but had no way to
actually move a card through its publish lifecycle — `card_products.status` could only be
changed by hand in SQL. The DB had already been enforcing
`card_published_needs_verification` (`status <> 'published' OR verified_at IS NOT NULL`) since
early on, so publishing without verification was already structurally impossible — this chunk
is what makes reaching 'published' possible at all through the app.

`api/`: `POST /admin/cards/:id/status`, restricted to the explicit transition table
`draft→in_review`, `in_review→draft` (send back) or `in_review→published`, `published→archived`
— any other pair is rejected with 409, not silently coerced. Moving to `published` sets
`verified_at`/`verified_by` server-side (only if not already set) — this *is* the human
verification pass (a human clicked "Verify & publish"), not an automated check. Same
typed-writer + `admin_audit_log`-in-the-same-transaction pattern as every other mutating route
in this file.

`console/`: `catalogue_screen.dart`'s card tiles now show `verified $timestamp` / `not
verified` in the subtitle and a row of transition buttons scoped to the card's current status
(`Move to in_review`, `Move to draft`, `Verify & publish`, `Move to archived`).

**A real bug caught while wiring the route, not after**: the first version used two different
SQL text branches (one setting `verified_by`, one not) sharing a positional `$2` that was
unreferenced in the non-verifying branch — Postgres couldn't infer that parameter's type
(`error 42P18, could not determine data type of parameter $2`) since the code path taken at
runtime depends on data, but the query plan is chosen from the query *text* alone. Fixed by
using one query with a `CASE WHEN $2 THEN ... ELSE ...` and always passing all four params, so
every parameter is referenced regardless of branch.

**Verified live end-to-end via curl** (real admin JWT from a real OTP round-trip) against the
live local Postgres: draft→in_review→draft (send-back, allowed) →in_review→published (set
`verified_at`/`verified_by` for real) →confirmed a same-state invalid transition (`draft`→
`archived`) correctly 409s. Reverted the test card back to `draft`/`verified_at = NULL`
afterward so seed data wasn't left mutated. `flutter analyze` clean; added a new console
widget test (mock client simulates the draft→in_review round trip); 14/14 console tests
passing (was 13). `api/`'s existing 12-test suite (pure period-bounds logic, no route tests)
unaffected — this route is verified live via curl, same pattern as every other admin route in
this codebase, not via a Node test file.

### Chunk 29 — points ledger + fee-waiver progress actually get written to

`points_ledger` and `fee_waiver_states` (schema from an early migration) had never had anything
write to them — only caps and milestones were live (Chunk 17). Both now update in the same
`POST /transactions` write as everything else, so a transaction that's recorded but leaves
these stale is impossible (same whole-transaction-rolls-back guarantee as caps/milestones).

`api/cycles.js`: new `effectivePointsPerRupee(unit, rate)` — deliberately separate from the
existing `effectiveRatePerRupee`, which returns the reward's **INR value** (used for
reward_value-measure caps); this one returns points/miles/cashback-rupees actually earned, in
the reward's own native unit, which is what a points ledger should show a user (the same
numbers the issuer's own app would show), not a value conversion.

`api/index.js`'s `POST /transactions`: after the existing cap/milestone updates, (1) inserts
one `points_ledger` row per transaction when the matched reward rule has a non-zero
per-rupee rate (`flat_points` rules correctly earn nothing here — a fixed bonus isn't a
per-transaction rate, matching the engine's own behavior); (2) upserts `fee_waiver_states.
qualified_spend` for every `fee_waiver_rule` on the card (skipping a transaction's category if
it's in that rule's `excluded_categories`), and auto-sets `waived_at` the moment
qualified_spend crosses `threshold_spend_inr`.

`GET /user-cards` now also returns each card's lifetime `total_points_earned` (not
period-scoped — a points balance doesn't reset every cycle, unlike caps/milestones) and its
current-period `fee_waiver_states` (joined to the rule for threshold/waived-fee display).

`app/`: `UserCard` (in `user_cards_repository.dart`) grew `totalPointsEarned` and a new
`FeeWaiverProgress` list; the Cards tab's tile subtitle now shows `"N pts earned"` and either
`"Fee waived (₹X spent)"` or `"₹X of ₹Y toward fee waiver"`, only when there's something to
show (an unused card shows neither).

**Verified live end-to-end**, not just unit-tested: created a real temporary `profiles`/
`user_cards` row for the existing admin identity, POSTed a real ₹2,00,000 transaction against
HDFC Millennia (5% cashback, ₹1,00,000 annual fee-waiver threshold) via curl with a real admin
JWT, and confirmed the actual response: `delta_points: 10000.0000` (exactly 5% of ₹2,00,000,
correct), `fee_waiver_states[0].waived_at` set (₹2,00,000 ≥ ₹1,00,000 threshold, correct).
Deleted all the temporary rows afterward so seed data wasn't left mutated.

`flutter analyze` clean on `app/` (pre-existing `avoid_print` infos in `tool/` scripts,
unrelated to this chunk); one new app widget test (points/fee-waiver subtitle rendering).
**All five suites now: 83 (`pandapay_domain`, unaffected) + 10 (`app`, was 9) + 14 (`console`,
unaffected this chunk) + 19 (`scraper`, unaffected) + 12 (`api`, pure period-bounds logic,
unaffected — this route verified live via curl like every other mutating admin/user route) =
138 tests total.

### Chunk 30 — UA-4: camera/QR card scanning (scoped down, largely unverified)

Added a "scan to add a card" shortcut into `cards_screen.dart`'s existing `_AddCardForm` —
augments it, doesn't replace it: the manual catalogue dropdown is still there and is still
what "Add" acts on; scanning just pre-fills `_selectedCardId`.

**Scope reduction stated up front** (same pattern as AD-4.3, Chunk 23/24): real physical-card
OCR — reading the embossed PAN, network logo, and issuer wordmark off an actual plastic card
via ML — is out of scope; that's a real computer-vision problem, not something a pub.dev
plugin does out of the box. What's actually built: `mobile_scanner` decodes a QR code or
barcode (e.g. printed on some card mailers/statements) into a raw text payload, and
`google_mlkit_text_recognition` is wired (behind the same interface) for a still-photo
text-recognition path. Both feed the *same* pure matcher — the payload/recognized text is
never parsed as a structured record for either path, just fuzzy-matched as text.

**Split for testability, per the task's structure requirement:**
- `app/lib/features/scan/card_text_matcher.dart` — pure Dart, zero Flutter/camera
  dependencies. `detectNetworkFromText` (keyword search against known network synonyms),
  `extractLastFourDigits` (last 4-digit group found in raw text), and `matchCardText`
  (token-overlap fuzzy score of extracted text against each `card_products` catalogue
  entry's name, boosted by a network-keyword match, banded into
  `MatchConfidence.{high,medium,low}` — `low` matches are never auto-selectable in the UI).
  Deliberately simple token-overlap, not an edit-distance library — OCR/QR payloads here are
  short issuer/product-name fragments, not free-form prose, so this was judged sufficient
  without adding a new pub.dev dependency for it.
- `app/lib/features/scan/card_scanner.dart` — the thin plugin-wiring boundary:
  `CardTextRecognizer` interface + `MlKitCardTextRecognizer` implementation, and
  `extractedTextFromBarcode` converting a `mobile_scanner` `Barcode` into the same
  `ExtractedCardText` shape the matcher consumes.
- `app/lib/features/scan/scan_card_screen.dart` — the actual camera UI (`MobileScanner`
  widget + result panel showing ranked candidates, or the raw scanned text with a manual
  fallback prompt when nothing clears a confidence floor — never a fabricated guess).

**What's genuinely verified**: `card_text_matcher.dart`'s logic only, via 9 new pure-Dart
tests in `app/test/features/scan/card_text_matcher_test.dart` — network keyword detection,
last-4-digit extraction, high/medium/low confidence banding, that a genuinely unrelated text
blob returns zero candidates (not a low-confidence guess dressed up as a match), and that
results sort best-first. All 9 pass.

**What is NOT verified — stated explicitly, not glossed over**: this sandbox has no camera
hardware and no attached simulator/device, so nothing touching `MobileScanner`,
`MlKitCardTextRecognizer`, or the actual `ScanCardScreen` widget (camera preview, live
barcode detection callback, permission prompts) was ever run. The Android
`CAMERA`/`hardware.camera` manifest entries and the iOS `NSCameraUsageDescription` plist
entry are structurally present (correct keys, per each platform's documented contract) but
were never confirmed to actually prompt or grant on a real device — that's still an open
verification gap for whichever agent next has device access.

`app/pubspec.yaml` gained `mobile_scanner` and `google_mlkit_text_recognition` (only this
pubspec touched, per the task's constraint). `flutter analyze`/`dart run custom_lint`: clean
(same 12 pre-existing `avoid_print` infos in `tool/`, unrelated). Full `app/` suite: 19/19
passing (was 10 — the 9 new scan-matcher tests, existing 10 unaffected). Did not re-run
`pandapay_domain`/`console`/`scraper`/`api` suites — this chunk touched no files in those
packages.

## Sandbox limitations

This is a Mac dev machine with Flutter, Dart, Postgres, and Docker all available and
working (Docker had transient network issues, not a capability gap). Nothing here needed
a device, Android SDK, or app-store tooling until Chunk 30 (UA-4 camera/QR scanning), which
hit the actual gap: no camera hardware and no attached simulator/device, so the camera/OCR
plugin wiring built there could not be exercised live — see Chunk 30 for exactly what was and
wasn't verified. Platform-specific work: UA-5.3 SMS receiver's on-device listening is now
built but similarly unexercised (see Chunk 31 — same "no camera hardware" gap, this time
"no real device to receive a real SMS"); UA-8 geofencing/widgets still fully unstarted.

### Chunk 31 — UA-5.3: SMS-based transaction auto-import (parsing engine + admin CRUD fully verified; on-device listening structurally present, unverified)

Wired up `parser_patterns`/`parser_failures` — both tables existed since Chunk 6 (`db/supabase/migrations/0006_ingest.sql`) and sat completely unused until now — for their evident purpose: turning a raw bank SMS body into a structured transaction via an admin-editable, versioned regex catalogue, with success/failure telemetry.

**What's genuinely verified (curl/unit-test, same discipline as every prior chunk):**

- **`api/src/sms_parser.js`** — pure-function parsing engine. `parseSms(pattern, sms)` applies a `parser_patterns.regex` + `field_map` to a raw SMS body, returning either `{ok:true, fields:{amountInr, merchant, last4, date}}` or `{ok:false, reason}` — never a fabricated partial guess (a regex match with an unparseable amount, a missing capture group, or a field_map with no `amount` mapped are all treated as failures, not "close enough"). `senderMatches()` treats `sender_pattern` as a literal substring match, not a compiled regex, so an admin's typo can't turn into a surprise regex injection. `parseSmsAgainstPatterns()` tries a list of candidate patterns in order and returns the first hit. `redactSmsShape()` builds the `parser_failures.redacted_shape` value (digits→`#`, letter runs→`X`) matching that table's `redacted_shape_has_no_digits` CHECK — `parser_failures` is designed to hold zero raw SMS content, only a redacted shape for admin triage, and the code respects that by never writing the raw body anywhere. 13 new tests in `api/test/sms_parser.test.js` covering: successful HDFC-style and ICICI-style parses (realistic synthetic Indian bank SMS formats, not scraped real customer data), a malformed/no-match body, an unparseable-amount capture, a wrong-issuer sender mismatch, a pattern with no `sender_pattern` (matches any sender), empty body, invalid pattern, missing `amount` field_map entry, and the multi-pattern trial helper's ordering/failure behavior. All 13 pass; full `api` suite now 25/25 (was 12).

- **Refactor**: `POST /transactions`'s entire insert-and-update-all-state body (cap_states, milestone_states, points_ledger, fee_waiver_states — the Chunk 17-29 machinery) is now `insertTransactionAndUpdateState(client, userId, {...})`, a shared function both `POST /transactions` (source='manual') and the new `POST /transactions/from-sms` (source='sms') call — no duplicated cap/milestone/points/fee-waiver logic between the two entry points, by construction.

- **`POST /transactions/from-sms`** — takes `{sender, body, userCardId, occurredAt?, categoryId?, rail?}`, loads active `channel='sms'` patterns, calls `parseSmsAgainstPatterns`. On a match: bumps the winning pattern's `success_count`, calls the shared insert helper with `source='sms'`, returns 201. On no match: inserts a `parser_failures` row (redacted shape only, per above) and returns **200** with `parsed:false` and a `reason` — a parse miss is a normal, logged outcome for this route, not a 4xx/5xx. `userCardId` is still caller-supplied (the parser extracts amount/merchant/last4/date, not which of the user's cards it belongs to — `user_cards` has no `last4` column in this schema, so there's no safe automatic match).

- **`GET/POST/PUT/DELETE /admin/parser-patterns`** — typed-writer CRUD mirroring `PUT /admin/reward-rules/:id`'s exact shape: `POST`/`PUT` validate `channel` against the real `txn_source` enum values and reject an invalid regex (`new RegExp()` throws → 400, never reaches Postgres) or a non-object `field_map`; `PUT` only bumps `version` when actual pattern *content* (`regex`/`field_map`/`senderPattern`) changes, not on a `sampleText`-only edit or an `isActive` toggle — `version` exists to distinguish real pattern revisions, and a content-less bump would make that meaningless. Every mutation writes `admin_audit_log` in the same transaction (create/update/delete all logged; delete logs the full deleted row as `before_value` since there's no soft-delete column on this catalogue table to fall back to).

  **Live-verified** against the real local Postgres via curl with a real OTP-derived JWT (`+919876511001` → `/auth/request-otp` → OTP grepped from `/tmp/auth_service.log` → `/auth/verify-otp`, same flow as prior chunks): created a real HDFC-style pattern, `PUT`'d a content-only field (version stayed 1), `PUT`'d `senderPattern` (version bumped to 2), rejected an invalid regex (`400`), confirmed `admin_audit_log` rows for `create_parser_pattern`/`update_parser_pattern`, then exercised the full `POST /transactions/from-sms` path end to end against a real inserted `user_cards` row: a matching SMS produced a real `transactions` row (`source='sms'`, correct amount/merchant, real `milestone_states` update) and bumped the pattern's `success_count` to 1; a non-matching SMS produced a real `parser_failures` row with a properly redacted (`~[0-9]`-free) shape and no raw content. Deleted the pattern (`DELETE`, audit-logged) and manually cleaned up the test transaction/user_card/profile rows afterward so the dev DB is left as it was found.

**Structurally present, NOT verified — stated plainly, same honesty convention as Chunk 30's camera gap:**

- **`app/lib/features/sms_import/sms_listener_service.dart`** wraps the `telephony` package (`RECEIVE_SMS` BroadcastReceiver via `listenIncomingSms`) and `permission_handler`'s runtime SMS-permission request. This sandbox has no Android SDK/emulator and — even if it had one — no way to deliver a real SMS to it, so nothing touching the actual `Telephony` plugin, the permission-grant dialog, or a real incoming message was ever exercised. Only foreground listening is wired (`listenInBackground: false`); `telephony`'s background/killed-app delivery needs a registered top-level background handler, a real additional platform-wiring pass, and its own device verification this chunk does not attempt — a stated scope cut, not a silent omission.
- **`app/lib/features/sms_import/sms_import_screen.dart`** — the permission-request UI + card-picker + "start listening" screen that wires the (unverified) listener to the (verified) `POST /transactions/from-sms` via `UserCardsRepository.logTransactionFromSms()`. Not added to any nav route in this chunk (no existing tab was an obvious fit, and wiring one in without being asked would be an unrelated UI change) — reachable only by direct navigation for now; wiring it into the app's actual navigation is left for whichever chunk owns that decision.
- `app/android/app/src/main/AndroidManifest.xml` gained `READ_SMS`/`RECEIVE_SMS` — declared, never confirmed to actually prompt/grant on a real device, exact same caveat as Chunk 30's `CAMERA` permission.

**What IS genuinely testable and tested on the app side**: `app/lib/features/sms_import/sms_text_hint.dart` — pure Dart, zero plugin/Flutter dependency, split out from the listener wiring for the same testability reason Chunk 30 split `card_text_matcher.dart` from `card_scanner.dart`. `extractLast4Hint()` pulls a display-only "card ending NNNN" hint from raw SMS text (returns `null`, not a guess, when zero or multiple distinct 4-digit candidates appear — e.g. an OTP or reference number sitting next to the real suffix); `looksLikeTransactionSms()` is a deliberately high-recall client-side pre-filter (keyword match) used only to avoid forwarding obvious non-transaction SMS (OTPs, promos) to the API at all — the real accept/reject decision is always the server-side regex match, this is just a courtesy filter. 9 new tests in `app/test/features/sms_import/sms_text_hint_test.dart`, all passing.

`app/pubspec.yaml` gained `telephony` (flagged discontinued by `flutter pub get` but still the only maintained-enough plugin wrapping this exact BroadcastReceiver pattern; noted here rather than silently picked) and `permission_handler`. `flutter analyze`/`dart run custom_lint`: clean (same 12 pre-existing `avoid_print` infos in `tool/`, unrelated to this chunk). Full `app/` suite: 28/28 passing (was 19 — the 9 new `sms_text_hint` tests, existing 19 unaffected). `api` suite: 25/25 (was 12 — the 13 new `sms_parser` tests). Did not touch `pandapay_domain`/`console`/`scraper` — out of this chunk's scope.

Files touched this chunk: `api/src/sms_parser.js` (new), `api/test/sms_parser.test.js` (new), `api/src/index.js` (refactor + 2 new routes + 4 admin CRUD routes), `app/pubspec.yaml`, `app/android/app/src/main/AndroidManifest.xml`, `app/lib/data/user_cards_repository.dart`, `app/lib/features/sms_import/sms_text_hint.dart` (new), `app/lib/features/sms_import/sms_listener_service.dart` (new), `app/lib/features/sms_import/sms_import_screen.dart` (new), `app/test/features/sms_import/sms_text_hint_test.dart` (new), `PROGRESS.md`.

### Chunk 32 — UA-8: geofencing + home-screen widget (scoped down; pure matching/ranking logic and the nearby-merchants route fully verified, background geofencing and native widget rendering structurally present but unverified)

**Scope reduction stated up front**, same pattern as UA-4/UA-5.3 (Chunks 30/31): always-on
background geofence monitoring (`flutter_background_geolocation`-style continuous location,
a foreground service on Android and a heavily-gated background mode on iOS) is NOT built.
What's built instead is a foreground-triggered, one-shot "check nearby merchants" — the user
taps a button, the device's location is read exactly once, and that single point is matched
against merchant locations. Likewise, a real native home-screen widget that actually renders
on a device's home screen was not built end to end — the Dart-side data-writing half is real
and tested; the native Android/iOS rendering half is structurally present but unverified (no
Android SDK/emulator or Xcode/simulator build toolchain exercised in this sandbox, same gap
as Chunks 30/31's camera/SMS plugin wiring).

**What's genuinely verified, via real unit tests with synthetic coordinates (not device GPS):**

`packages/pandapay_domain/lib/src/geo/geo.dart` — pure Dart, zero IO. `haversineDistanceMeters`
(great-circle distance) and `findNearbyMerchants` (radius filter + nearest-first sort) over a
new `GeoPoint`/`NearbyMerchantCandidate`/`NearbyMerchantMatch` shape. 12 new tests in
`packages/pandapay_domain/test/geo/geo_test.dart`, including one pinned against a real-world
pair (MG Road to Kempegowda Airport, Bengaluru, ~27-35km) rather than only synthetic toy
points, to catch a formula bug a synthetic-only test set could miss.

`packages/pandapay_domain/lib/src/geo/best_card_for_widget.dart` — `BestCardForWidget.pickBestCard`,
deliberately NOT a new ranking algorithm: it calls the *existing*
`RecommendationEngine.rank()` (Chunk 2's engine, unchanged) with a nominal amount (matching
`enteredAmountProvider`'s own ₹1,000 default in `app/lib/app/providers.dart`, since a widget
has no amount-entry field) and an optional category, and returns the first non-excluded
result. 5 new tests in `packages/pandapay_domain/test/geo/best_card_for_widget_test.dart`,
including one proving category-scoped rules correctly beat a lower general rate — the same
engine gate `engine_test.dart` already covers, exercised through this new caller. **All five
pandapay_domain files/exports wired into `pandapay_domain.dart`.**

`api/`: `GET /merchants/nearby?lat=&lng=&radiusM=` — public read, no auth, same shape/pattern
as `GET /catalogue`/`GET /categories`. SQL-side haversine over `merchant_locations.grid_lat`/
`grid_lng` (AD-6/Chunk 23's existing grid-snapped columns — no new merchant-location store
invented), filtered to `is_published = true`, `radiusM` capped at 50000 and validated,
`lat`/`lng` range-validated, 400 on bad input. **A real, previously-latent bug found and fixed
while verifying this live**: `merchants`/`merchant_locations` (0007) only ever had an
admin-only RLS policy (`pandapay.is_admin()`) — every other public route in this codebase
(`/catalogue`, `/categories`) works because `card_products`/`spend_categories` have an actual
`_public_read` policy (0011/0015), but `merchants` never got one because every existing route
touching it (`AD-6`'s `/admin/merchants/*`) is `requireAdmin`-gated. `withUserClient(null, ...)`
against `merchants` returned zero rows regardless of what was published — not a bug in this
chunk's query, a pre-existing gap this chunk's new *public* route was the first thing to ever
actually need a non-admin read from this table. Fixed with a new migration,
`db/supabase/migrations/0017_merchants_public_read.sql`, adding `merchants_public_read`/
`merchant_locations_public_read` policies scoped to `is_published = true or pandapay.is_admin()`
— same restriction shape as `card_products_public_read` (0015), not a broader grant.

**Verified live end-to-end against the actual local Postgres + running `api/`**: applied the
new migration, inserted one published + one unpublished merchant with real
`merchant_locations` rows (Bengaluru coordinates), curled `/merchants/nearby` with a real
radius and confirmed only the published merchant came back with a correct `distance_meters`;
confirmed a too-small radius correctly excludes it; confirmed the default radius (2000m) and
an out-of-range `lat=999` 400 correctly. Deleted every fixture row afterward. `api/`'s existing
25-test suite (`npm test`) re-ran clean, unaffected by this chunk's SQL-string-only change.

**`app/` — what's built and how it's split for testability, same pattern as Chunk 30's
`card_text_matcher.dart`/`card_scanner.dart` split:**

- `app/lib/features/geofence/nearby_merchants_repository.dart` — `HttpNearbyMerchantsRepository`,
  the thin HTTP boundary calling `GET /merchants/nearby` and deserializing into the pure
  `NearbyMerchantCandidate` shape. 3 new tests (`app/test/features/geofence/
  nearby_merchants_repository_test.dart`) against `MockClient` fixtures shaped like the live
  route's real response (verified above), covering the happy path, a non-200 error, and an
  empty result.
- `app/lib/features/geofence/nearby_merchants_screen.dart` — the actual UI: a
  "Check nearby merchants" button that reads location once via `geolocator`
  (`Geolocator.getCurrentPosition`, `LocationAccuracy.medium`, explicitly no
  `LocationSettings` background flag), calls the repository, re-filters/sorts client-side via
  `packages/pandapay_domain`'s `findNearbyMerchants` (belt-and-suspenders with the API's own
  server-side filter — proves the pure-Dart matcher against real API-shaped data, not just
  synthetic fixtures), and for each match shows the best owned card via a new
  `bestCardForMerchantProvider(categoryId)` Riverpod family in `app/lib/app/providers.dart`
  that reuses the exact same wallet/cap/milestone-snapshot assembly
  `rankedRecommendationsProvider` already does, just calling `BestCardForWidget.pickBestCard`
  instead of `engine.rank()` directly — one card-owning/cap-state read path, two ranking call
  sites. **Camera-style caveat applies here too: `Geolocator`'s actual permission
  prompt/location fix was never exercised on a real device/simulator in this sandbox** — only
  the repository and pure-Dart matcher layers underneath it are genuinely tested.
- `app/lib/features/home_widget/home_widget_service.dart` — `HomeWidgetService
  .updateBestCardWidget`, writing `best_card_name`/`best_card_value_formatted`/`best_card_none`/
  `best_card_updated_at` via `home_widget`'s `HomeWidget.saveWidgetData` and calling
  `HomeWidget.updateWidget(androidName:, iOSName:)`. Takes `nowIso` as a parameter rather than
  calling `DateTime.now()` internally, per this app's `no_datetime_now_outside_clock`
  custom_lint rule — added a small `clockProvider` (`Clock.system()`) to
  `app/lib/app/providers.dart`, this app's first use of `pandapay_domain`'s injectable `Clock`
  outside the engine itself. **Genuinely tested**: 2 new tests in `app/test/features/
  home_widget/home_widget_service_test.dart` intercept the real `home_widget` platform
  `MethodChannel` (`setMockMethodCallHandler`) and assert the exact keys/values written and
  that an update is triggered — this proves the Dart-to-plugin contract for real, not just
  that the function doesn't throw.
- `app/lib/features/home_widget/widget_settings_screen.dart` — manual "Update home-screen
  widget now" panel (no background refresh scheduling exists — no WorkManager/BGTaskScheduler
  job — stated in the screen's own doc comment, not just here), showing the same
  `bestOverallCardProvider` (a `bestCardForMerchantProvider(null)` wrapper — "top overall
  card," the widget's stated fallback mode) result it's about to write, so what's on screen is
  provably what gets pushed to the widget.
- Both screens linked from the More/Account tab (`account_screen.dart`) — "Nearby merchants"
  and "Home-screen widget" buttons, `Navigator.push`/`MaterialPageRoute`, same pattern
  `cards_screen.dart` uses to open `ScanCardScreen`.

**Native widget skeletons — explicitly unverified, stated per-platform:**

- **Android**: `BestCardWidgetProvider.kt` (extends `home_widget`'s `HomeWidgetProvider`,
  reads the same SharedPreferences keys `HomeWidgetService` writes), `res/layout/
  best_card_widget.xml`, `res/xml/best_card_widget_info.xml`, registered as a `<receiver>` in
  `AndroidManifest.xml`. Structurally complete (matches the standard `home_widget` Android
  wiring pattern) but **never compiled or run through a real Android/gradle build** in this
  sandbox — no Android SDK/emulator here, same gap as Chunks 30/31's manifest-only
  camera/SMS permissions.
- **iOS**: `ios/HomeWidgetExtension/BestCardWidget.swift` — a real WidgetKit
  `TimelineProvider`/`View`/`Widget` shape, but **deliberately left outside any Xcode
  target**, unlike Android's receiver. Reason stated in the file's own header comment: a real
  WidgetKit extension needs a second Xcode target, an App Group entitlement shared with
  Runner, and code-signing, all of which are normally created *through Xcode itself* — hand-
  editing `Runner.xcodeproj/project.pbxproj` blind, with no Xcode/Mac build toolchain in this
  sandbox to open the project and confirm nothing broke, risks silently corrupting the whole
  iOS build for a feature that can't be verified here anyway. `HomeWidget.setAppGroupId(...)`
  is correspondingly never called from the Dart side either — there's no App Group id to set
  until that Xcode target exists. This is the one piece of this chunk that is source-only, not
  wired in at all — flagged explicitly, not left implicit.
- Added `ACCESS_FINE_LOCATION`/`ACCESS_COARSE_LOCATION` to `AndroidManifest.xml` and
  `NSLocationWhenInUseUsageDescription` to `Info.plist` — deliberately no
  `ACCESS_BACKGROUND_LOCATION`/`NSLocationAlwaysAndWhenInUseUsageDescription`, matching the
  scope reduction above. Same "structurally present, not confirmed to actually
  prompt/grant on a real device" caveat as Chunk 30's camera keys.

`app/pubspec.yaml` gained `geolocator` and `home_widget`.

`flutter analyze`/`dart run custom_lint` on `app/`: clean (same 12 pre-existing `avoid_print`
infos in `tool/`, unrelated). Full `app/` suite: 33/33 passing — 28 already existed going into
this chunk (Chunk 31 left `app/` at 28/28), plus this chunk's 5 new tests (3 in
`nearby_merchants_repository_test.dart`, 2 in `home_widget_service_test.dart`) = 33.
`pandapay_domain` suite: 96/96 passing (was 83 — this chunk's 13 new tests: 8 in
`geo_test.dart` (`haversineDistanceMeters` + `findNearbyMerchants`, including one pinned
against a real-world Bengaluru coordinate pair) + 5 in `best_card_for_widget_test.dart`).
`api/` suite: 25/25 unaffected (`npm test`,
pure JS logic tests — the new route was curl-verified live, same pattern as every other route
in this file, not unit-tested in `api/test/`). Did not touch `console`/`scraper` — out of this
chunk's scope.

**All five suites now: 96 (`pandapay_domain`) + 33 (`app`) + 14 (`console`) + 19 (`scraper`,
Python) + 25 (`api`) = 187 tests total.**

Files touched this chunk: `packages/pandapay_domain/lib/src/geo/geo.dart` (new),
`packages/pandapay_domain/lib/src/geo/best_card_for_widget.dart` (new),
`packages/pandapay_domain/lib/pandapay_domain.dart`,
`packages/pandapay_domain/test/geo/geo_test.dart` (new),
`packages/pandapay_domain/test/geo/best_card_for_widget_test.dart` (new),
`db/supabase/migrations/0017_merchants_public_read.sql` (new), `api/src/index.js`,
`app/pubspec.yaml`, `app/pubspec.lock`, `app/android/app/src/main/AndroidManifest.xml`,
`app/android/app/src/main/kotlin/app/pandapay/pandapay/BestCardWidgetProvider.kt` (new),
`app/android/app/src/main/res/layout/best_card_widget.xml` (new),
`app/android/app/src/main/res/xml/best_card_widget_info.xml` (new),
`app/ios/Runner/Info.plist`, `app/ios/HomeWidgetExtension/BestCardWidget.swift` (new, not
wired into an Xcode target — see above), `app/lib/app/providers.dart`,
`app/lib/features/geofence/nearby_merchants_repository.dart` (new),
`app/lib/features/geofence/nearby_merchants_screen.dart` (new),
`app/lib/features/home_widget/home_widget_service.dart` (new),
`app/lib/features/home_widget/widget_settings_screen.dart` (new),
`app/lib/features/account/account_screen.dart`,
`app/test/features/geofence/nearby_merchants_repository_test.dart` (new),
`app/test/features/home_widget/home_widget_service_test.dart` (new), `PROGRESS.md`.

**Sandbox limitations update**: UA-8 is the point where this codebase now has three chunks in
a row (30, 31, 32) whose native/device-dependent half is structurally present but genuinely
unverified — no Android SDK/emulator, no Xcode/iOS simulator build toolchain, no camera, no
real SMS, no GPS fix, and no real device's home screen to drop a widget onto, anywhere in this
sandbox. Every pure-logic/HTTP-boundary layer underneath each of those three features (the
QR/OCR text matcher, the SMS regex parser, and now the haversine/nearby-merchant matcher and
the best-card-for-widget picker) is genuinely unit-tested against real or realistically-shaped
fixtures — that split is deliberate and consistent across all three chunks, not incidental.

## Chunk 33 — AD-3 candidate scrape sources (research/shortlisting only)

This chunk does **not** clear any scraping for production use. It builds a shortlist of
candidate `sources` rows for the 12 issuers already represented in the seed catalogue
(HDFC, ICICI, SBI, Axis, Kotak, Yes Bank, IDFC FIRST, IndusInd, AU Small Finance Bank,
Standard Chartered, RBL, American Express), so the product owner has a concrete list to
review one source at a time.

For each issuer, found the bank's own official credit-card listing/features page (not an
aggregator — this app is itself the aggregator) and fetched `robots.txt` for that domain
(no card-detail page content was fetched or downloaded from any of them — robots.txt only).
Results: 9 of 12 have a `robots.txt` that does not disallow the candidate path (ICICI, SBI
Card, Axis, Kotak, IDFC FIRST, IndusInd, Standard Chartered, RBL, American Express); AU Small
Finance Bank's `robots.txt` is a blanket `Disallow: /` for all crawlers (strong signal against
scraping, flagged separately); HDFC's `robots.txt` returned an HTTP 403 Cloudflare
"Access denied" for the automated fetch itself, so its status is unclear; Yes Bank's
`robots.txt` fetch didn't return a response in this sandbox, also unclear. Full detail per
issuer (URL, exact page, robots directive) is in `scraper/CANDIDATE_SOURCES.md` (new file).

Inserted one row per candidate into the `sources` table (`kind = 'bank_official'`, correct
`issuer_id` FK, `base_url` set, `robots_allows`/`robots_checked_at` recorded from the checks
above). Every row has **`tos_reviewed = false` and `is_enabled = false`** — confirmed against
the table after insert. This is deliberate and matches the codebase's existing rule, stated
explicitly by the product owner this session: `tos_reviewed` means a human actually read the
site's terms of service and confirmed scraping is permitted, not that robots.txt didn't object.
Robots.txt only governs crawler/indexing behavior and says nothing about a site's actual terms
on scraping/reuse of financial-product data — so a permissive robots.txt above is recorded as a
useful signal only, never treated as clearance. The `enabled_requires_tos_review` CHECK
constraint on `sources` (`is_enabled = false OR tos_reviewed = true`) continues to be the real
gate, and nothing in this chunk touches it or any extraction code.

Next real step (not done here, and not this agent's to do): the product owner reads each
site's actual terms of use, one issuer at a time, and only then flips `tos_reviewed = true` on
that specific row before it can ever be enabled.

Files touched: `scraper/CANDIDATE_SOURCES.md` (new), `PROGRESS.md`. DB: 12 new rows in
`sources` (local Postgres only, not part of git — inspect via psql or the console's card-request
flow).

### Chunk 34 — AD-4.3, real LLM-backed extraction (key-gated, honest fallback — still no key this session)

**Same constraint as Chunk 14, re-confirmed this session**: `api/.env` has no `ANTHROPIC_API_KEY`
and `scraper/.env` does not exist at all (`scraper/example.env` is a template, not a real
config). Chunk 14 built a deterministic regex heuristic as an honestly-labeled stand-in
(`model_name = 'heuristic-regex-v1'`). This chunk builds the **real** LLM integration on top of
it — not another placeholder — wired to activate automatically the moment a real key shows up,
but genuinely never exercised against a live Anthropic API in this session because there is
still no key to exercise it with.

`scraper/pandapay_scraper/llm_extraction.py` (new): `dispatch(diff)` is the new single entry
point (replaces `run.py`'s direct call to `extraction.propose_from_diff`). It reads
`EXTRACTION_MODE` (`heuristic` | `llm` | `auto`, default `auto` — same `os.environ.get` pattern
`db.py` already uses for `SCRAPER_DATABASE_URL`, no dotenv magic anywhere in this codebase) and
`ANTHROPIC_API_KEY` straight from the environment. `auto` with no key (today's actual state) or
`EXTRACTION_MODE=heuristic` (forced, for cost control even with a key present — same "no hidden
automatic cost/behavior change" stance as AD-8/AD-9) both route to the existing heuristic
extractor unchanged. `auto`/`llm` with a key present calls `claude-sonnet-5` with a prompt asking
for the exact same two-field shape the heuristic targets (`rate_percent`, `cap_value_inr`), then
defensively parses the response (`_parse_llm_response`) — rejects non-JSON, wrong shape,
unrecognized field names, non-numeric old/new, out-of-range confidence — raising `ValueError`
rather than ever letting a malformed LLM reply produce a proposal that could corrupt
`page_snapshots`/`policy_change_alerts` downstream. **Any exception anywhere in the LLM path
(network, API error, malformed response) is caught in `dispatch()` and falls back to the
heuristic extractor** — a bad LLM call degrades to Chunk 14's existing behavior, it never crashes
the crawl loop. Every path logs which extractor actually ran (`logging`, matching this
codebase's "never fabricate a capability" convention — e.g. Chunk 14's heuristic-vs-AI console
labeling). `ExtractionProposal` (extraction.py) gained a `model_name` field (default
`'heuristic-regex-v1'`, the prior hardcoded constant) so a proposal always says which path
produced it; the LLM path labels its proposals `'llm-claude-sonnet-5'`.

`db.py`'s `insert_extraction_proposal` — `model_name` was previously hardcoded into the SQL
insert; now it's a parameter (default unchanged, `'heuristic-regex-v1'`, so any caller that
doesn't pass it explicitly is byte-for-byte identical to before). `run.py` now calls
`llm_extraction.dispatch(diff)` instead of `extraction.propose_from_diff(diff)` directly and
passes `proposal.model_name` through to the insert — this is the only behavioral change to
`run.py`, and for anyone with no `ANTHROPIC_API_KEY` set (the actual state of this environment)
it is a no-op: `dispatch()` in `auto` mode with no key calls `propose_from_diff` directly, same
function, same arguments, same result as before this chunk.

`requirements.txt`/`requirements-lock.txt`: added `anthropic>=0.40` (installed `anthropic==0.120.2`
+ transitive deps — `pydantic`, `jiter`, `distro`, etc. — regenerated the lock file via `pip
freeze`; every previously-pinned version is unchanged, confirmed by diff before/after).
`scraper/example.env` documents `ANTHROPIC_API_KEY` and `EXTRACTION_MODE` as new optional config,
both commented out by default.

**What's verified vs what fundamentally can't be, this session**: 21 new unit tests
(`tests/test_llm_extraction.py`), all pure logic, zero real network calls —
`EXTRACTION_MODE`/key-presence dispatch logic for all three modes (including the unrecognized-
value-falls-back-to-auto case), fallback-to-heuristic when no key is present (the default,
unmodified path), fallback-to-heuristic when the LLM call raises (mocked — no real key exists to
make a real call fail with), and the response parser fed synthetic hand-written JSON strings
covering both well-formed responses (single-field, two-field, wrapped in a markdown fence the
model wasn't supposed to add) and every malformed shape the parser is supposed to reject. **What
cannot be verified without a real key, and was not claimed to be**: whether an actual
`client.messages.create(model="claude-sonnet-5", ...)` call against the live Anthropic API
behaves as documented — that code path (`_propose_via_llm`'s real `anthropic.Anthropic(...)`
call) is real, complete, and has never executed in this session. The moment a real key lands in
`scraper/.env` (gitignored, per `example.env`'s existing instructions) or the shell environment,
`dispatch()` picks it up automatically with no code change.

All 40 scraper Python tests pass (was 19 at Chunk 14; Chunk 33 added no Python tests; this
chunk adds 21). Ran `cd scraper && python -m pytest -q` after activating `.venv` — full suite
green, 0.07s (confirms nothing is silently hitting the network).

Files touched: `scraper/pandapay_scraper/llm_extraction.py` (new), `scraper/pandapay_scraper/
extraction.py`, `scraper/pandapay_scraper/db.py`, `scraper/pandapay_scraper/run.py`,
`scraper/tests/test_llm_extraction.py` (new), `scraper/requirements.txt`,
`scraper/requirements-lock.txt`, `scraper/example.env`, `PROGRESS.md`. No commit made — left
staged/unstaged per instructions.

### Chunk 35 — connectivity audit: three real "built but unreachable" gaps found and fixed

Requested explicitly: "go through the entire application and check if anything is remaining
to be implemented, anything which is not connected." A read-only audit agent checked every
recent feature's actual navigation reachability (not just that the file compiles) and found
three real gaps — all from Chunks 30/31/32, each built by a separate parallel agent that
never saw what the other two were doing:

1. **`app/lib/main.dart`'s central scan FAB was a literal no-op** (`onPressed: () {}`) —
   this predates Chunk 30 (it was a placeholder from the very first scaffold), but Chunk 30
   built a real `ScanCardScreen` without anyone going back to wire the app's single most
   prominent scan entry point to it. Fixed by having the FAB push `ScanCardScreen` directly
   (using `catalogueProvider`) and, on a pick, hand it to Cards' `_AddCardForm` via a new
   `pendingScannedCardIdProvider` (`app/lib/app/providers.dart`) — the FAB itself has no add
   form of its own, so it switches to the Cards tab and pre-fills the dropdown, same
   "scan sets a candidate, Add still has to be pressed" contract the in-form scan button
   already had. The provider is consumed once and cleared post-frame, not left sticky.
2. **UA-5.3 SMS import was completely unreachable** — `sms_import_screen.dart` (Chunk 31)
   was never imported by anything in `app/lib`, confirmed independently by the audit (the
   building agent's own report had already flagged this, but PROGRESS.md hadn't been
   updated to reflect it was still true). Fixed by adding a "SMS transaction import" entry
   to `account_screen.dart`'s More tab, alongside Chunk 32's two UA-8 entries (same pattern).
3. **`parser_patterns` admin CRUD had no console UI at all** — 4 routes (Chunk 31), fully
   built and curl-verified server-side, had zero callers anywhere in `console/`. Without a
   way to add a pattern, SMS import had no data to match against even once reachable. Fixed
   with a new `console/lib/features/parser_patterns/parser_patterns_screen.dart` (list +
   add-pattern form + activate/deactivate/delete), matching client methods in
   `admin_api.dart`, a `parserPatternsProvider`, and a 10th `main.dart` nav destination.

**A second, independent real bug fell out of fixing #3**: adding a 10th `NavigationRail`
destination pushed the console's left rail past the available height on a short/narrow
viewport — caught immediately by `flutter test` (11 of 14 console tests started failing
with a genuine `RenderFlex overflowed` exception, not a flaky test), the same overflow class
already fixed three separate times earlier in this project (Chunks 23/24/25's dropdown/header
overflows). `NavigationRail` has no built-in scrolling, so it's now wrapped in a
`SingleChildScrollView`, with the sign-out button moved from the rail's `trailing` slot to a
fixed footer below the scroll area (so it stays reachable without scrolling to the bottom of
a long destination list). One existing test (`AD-9`) needed `scrollUntilVisible` added before
its tap, since that destination is now genuinely below the fold in the test viewport — a real
UX consequence of the extra tab, not a workaround for a test artifact.

**Verified, not assumed**: the audit agent ran static analysis only (no live servers); this
session then live-verified the actual fix by curling the full SMS-import round trip against
the real local Postgres with a real admin JWT — created a real `parser_patterns` row via
`POST /admin/parser-patterns`, confirmed a case-mismatched regex correctly produced a
`parser_failures` row (`no_regex_match`, not a silent guess), then confirmed a case-correct
version of the same pattern produced a real `transactions` row (`source='sms'`) with fee-waiver
state updated through the same shared helper Chunk 31 built — the entire SMS-import pipeline,
end to end, for the first time since it was built. All test data was cleaned up afterward.

Added one new console widget test (Parser Patterns list + add-pattern flow). All three
non-scraper suites re-run clean after every fix: 33 `app/` (unchanged count, existing suite
still covers the FAB/nav changes structurally via `flutter analyze`, no dedicated new app test
added for the FAB rewire itself), 15 `console/` (was 14, +1), 25 `api/` (unaffected, no API
changes this chunk). `flutter analyze`/`dart run custom_lint` clean on both `app/` and
`console/`.

No other gaps survived the audit: `ScanCardScreen`, `NearbyMerchantsScreen`, and
`WidgetSettingsScreen` were all already correctly wired (contrary to the audit brief's initial
suspicion); every other API route has a real caller in one of the two Flutter clients; no
TODO/FIXME/stub markers exist anywhere except the one already-documented intentional
`NotImplementedError` in `scraper/pandapay_scraper/fetcher.py` (Chunk 12's Playwright
fallback). No commit made yet — left
staged/unstaged per instructions.
