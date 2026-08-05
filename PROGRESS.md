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

## What's NOT done (next steps, roughly in priority order)

1. **Restart local Postgres** before resuming DB work (see note above) — both the `pandapay` and
   `pandapay_auth` databases were live and verified this session but are not running as background
   services; also restart the `auth/` Node service the same way if resuming API testing
   (`cd auth && DB_SSL=false node src/index.js`, needs a `.env` — see `auth/db/pandapay-auth/init.sql`
   for the schema it now expects). Consider a `docker-compose.yml` for the product DB matching the
   auth DB's pattern.
2. **Trim `authRoutes.js` for PandaPay specifically** — remove the marketplace/partner-tier logic
   and its now-dead columns (`partner_tier_id`, `active_role`), per the user's explicit direction
   that this environment must diverge from the source app, not just patch around its shape.
3. **Implement `set_config('app.user_id', ...)` middleware** in whatever backend sits between the
   Flutter apps and the *product* Postgres DB (`pandapay`, not `pandapay_auth`) — nothing calls
   this yet, so RLS is correctly designed but unreachable by any real request path. This is also
   where the `auth/` service's issued JWT needs to be verified before every product-DB transaction.
4. **UA-1: card catalogue + card management** — next real feature slice once the above is stable.
   Explicitly the critical-path item in `Userappimplementation_plan.md` (blocks UA-2, see below).
5. **UA-2 remainder**: milestone bonus value, split optimizer, billing-cycle float, EMI advisor,
   UPI-vs-swipe comparison, the full 30-scenario golden fixture set (engine skeleton is built and
   tested, see `packages/pandapay_domain` section above).
6. **AD-0.3 console auth** — wire real session state into `ConsoleSession` so the route guard does
   something beyond "always false".
7. The custom_lint rules mentioned above (DateTime.now() ban, bare Money Text ban).

## Sandbox limitations

This is a Mac dev machine with Flutter, Dart, Postgres, and Docker all available and
working (Docker had transient network issues, not a capability gap). Nothing here needed
a device, Android SDK, or app-store tooling yet — that becomes relevant once UA-4
(camera/QR scanning) or platform-specific work (UA-5.3 SMS receiver, UA-8 geofencing/widgets)
starts. No such work has started, so no limitation to report yet on that front.
