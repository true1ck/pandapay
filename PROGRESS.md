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

### `console/` (Flutter Web admin console)
- Scaffolded (`app.pandapay` org, web platform only), depends on `pandapay_domain` by path.
- AD-0.2 route guard stub: `go_router` redirects any session where
  `ConsoleSession.isAdmin == false` to a `/no-access` dead end — currently every session
  is signed-out by default (real auth wiring against `auth/` is AD-0.3, not done yet).
- Left-nav shell (Catalogue · Alerts · Queues · Sources · Merchants · Acceptance · Rates ·
  Dashboard) with stub screens, dense/compact visual density per AD-0.2.3.
- `flutter analyze`: clean. `flutter test`: 1/1 passing (asserts the dead-end redirect fires).

## What's NOT done (next steps, roughly in priority order)

1. **Restart local Postgres** (see note above) before resuming DB work; consider adding
   a `docker-compose.yml` for the product DB matching the auth DB's pattern.
2. **Wire `auth/` service code to its new schema.** The Node routes/services still
   reference some farm-app-specific fields; needs a pass to confirm nothing references
   dropped tables/columns, then get it actually running (`npm install && npm run dev`)
   against `pandapay_auth`.
3. **Implement `set_config('app.user_id', ...)` middleware** in whatever backend sits
   between the Flutter apps and Postgres — nothing calls this yet, so RLS is currently
   unreachable by any real request path (this is expected at this stage, just flagging
   it's the next hard dependency for any authenticated feature).
4. **UA-1: card catalogue + card management** — next real feature slice once the above
   is stable. This is explicitly the critical-path item in `Userappimplementation_plan.md`
   (blocks UA-2 the recommendation engine, which is the actual product).
5. **AD-0.3 console auth** — wire real session state into `ConsoleSession` so the route
   guard does something beyond "always false".
6. The custom_lint rules mentioned above (DateTime.now() ban, bare Money Text ban).

## Sandbox limitations

This is a Mac dev machine with Flutter, Dart, Postgres, and Docker all available and
working (Docker had transient network issues, not a capability gap). Nothing here needed
a device, Android SDK, or app-store tooling yet — that becomes relevant once UA-4
(camera/QR scanning) or platform-specific work (UA-5.3 SMS receiver, UA-8 geofencing/widgets)
starts. No such work has started, so no limitation to report yet on that front.
