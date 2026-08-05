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

## What's NOT done (next steps, roughly in priority order)

Chunks 1-10 (see sections above) are complete and verified. Next:

1. **AD-3 through AD-9** (admin console's remaining core purpose per `adminimplementation_plan.md`):
   the scraper engine, diff review + AI extraction, and especially the unified policy-change
   alert queue (AD-5, "the core requirement driving this entire application" per the plan's own
   words) — none of this exists yet. AD-2's queues (Chunk 8) only handle two of the four signal
   sources AD-5 is meant to unify.
2. **UA-1.1 real data**: only 4 of the ~40-50 cards exist, none human-verified (UA-1.1.4); no YAML
   import tool (UA-1.1.2).
3. **UA-2.5.1**: the full 30-scenario golden fixture set (what exists is targeted unit tests per
   feature, not the consolidated fixture file the plan describes).
4. **`app/` has no auth/login flow (UA-3) at all** — Home only hits public endpoints. This blocks
   user_cards/transaction wiring (the engine still ranks the whole catalogue, not a signed-in
   user's actual cards), any local drift/cache, and app-side token persistence (Chunk 10 only
   covered `console/`, which already had a login flow to persist a session for).
5. The custom_lint rules mentioned in the app section (DateTime.now() ban, bare Money Text ban).
6. **Audit remaining RLS tables for the same owner-policy-only gap** found twice now (Chunk 7:
   `card_products` and children; Chunk 8: `card_requests`/`data_error_reports`, plus
   `support_tickets` pre-emptively fixed in the same migration once the pattern was clear) — a
   final grep across 0011 for any other `_owner`-only policy on a table an admin will eventually
   need to read turned up nothing else (checked: `profiles`/`transaction_splits` are legitimately
   user-only by design, not a gap).

## Sandbox limitations

This is a Mac dev machine with Flutter, Dart, Postgres, and Docker all available and
working (Docker had transient network issues, not a capability gap). Nothing here needed
a device, Android SDK, or app-store tooling yet — that becomes relevant once UA-4
(camera/QR scanning) or platform-specific work (UA-5.3 SMS receiver, UA-8 geofencing/widgets)
starts. No such work has started, so no limitation to report yet on that front.
