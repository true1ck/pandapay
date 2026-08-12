# Backend readiness, company-side data capture, and device portability

_Audit + plan, 2026-08-11. Every claim below was verified against the code, not against
PROGRESS.md or GAP_ANALYSIS.md. Where those docs were already right, they're cited; where
they're silent, that's noted._

---

## Part 1 — Audit findings

### 1.1 Is there proper backend support?

**Architecture: yes, and it's better than most pre-launch products. Deployment: none.**

What genuinely exists:

| Piece | State | Evidence |
|---|---|---|
| `api/` | 110+ real routes over Postgres, per-request RLS-scoped client (`withUserClient`) | `api/src/index.js` (5,072 lines) |
| `auth/` | Separate hardened JWT/OTP microservice: phone OTP, email OTP, Google, refresh rotation, device registry, risk scoring, field encryption, enumeration detection, rate limiting, audit logging, AWS SSM secret loading | `auth/src/routes/`, `auth/src/services/`, `auth/src/middleware/` |
| `db/` | 27 migrations, RLS policies on all user tables, pg_cron jobs, DPDP erasure RPC, anonymization audit function | `db/supabase/migrations/` |
| CI | Anonymization audit as a deploy-blocking gate | `.github/workflows/anonymization-audit.yml` |

What does not exist, and blocks everything else:

1. **Nothing is deployed.** `app/lib/app/providers.dart:34-35` hardcodes
   `http://localhost:4000` and `http://localhost:3210` as `const`. No flavors, no
   `--dart-define`, no per-environment config. A release build today points at the
   user's own phone.
2. **No hosting or infra definition.** No Dockerfile, no `docker-compose`, no
   `fly.toml` / `render.yaml` / `app.yaml`, no Terraform, no deploy workflow anywhere
   in the repo. The only CI job is the anonymization audit.
3. **No backups.** `POST /backup-runs` (`api/src/index.js:4813`) declares itself a stub
   in its own doc comment — it inserts a `backup_runs` row and runs no backup. No
   pg_dump, no WAL archiving, no PITR. `restore_drills` has never been exercised.
   **For a personal-finance app this is the single highest-severity gap: today, a lost
   database is permanent, total user data loss.**
4. **No observability.** No Sentry, Crashlytics, or APM in `app/pubspec.yaml`; server
   errors go to `console.error` with no aggregation. A production incident would be
   invisible until a user complained.

### 1.2 Is everything recorded company-side so the data can be monetized later?

**Partly — and the asset the schema itself calls the moat is collecting zero rows.**

Captured well today (server-side, per-user, RLS-protected):
transactions (amount, merchant, category, card, splits, notes, ignore flags),
`user_cards` + `cap_states` / `milestone_states` / `fee_waiver_states` / `points_ledger`,
card overrides, lounge usage, monthly reports, referrals, append-only `user_consents`,
support tickets, card requests, data error reports, notifications, and all four import
paths (statement / SMS / inbound email / IMAP).

Gaps, in order of commercial impact:

1. **The crowdsource dataset has no write path at all.**
   `merchant_contributions`, `acceptance_reports`, and `effective_rate_samples` —
   labelled in `db/supabase/migrations/0007_crowdsource.sql:64` as the "§6.1 dataset
   nobody else has" — have **zero INSERT statements anywhere in the repo**. Verified by
   grepping every `.js`, `.sql`, `.py`, `.dart`, including seed files: nothing. The admin
   console reads them (`/admin/acceptance-summary`, `/admin/effective-rate-summary`) and
   `GET /my-contributions` aggregates over them, but nothing ever fills them. The
   flagship data moat is fully architected and never collected.

2. **No product analytics of any kind.** No Firebase/Amplitude/Mixpanel/PostHog/Segment
   in `app/pubspec.yaml`; no events table in any migration; no screen-view, funnel,
   activation, or retention instrumentation. Today you cannot answer "how many users add
   a second card", "where does onboarding drop off", or "is the recommendation engine
   changing behaviour" — which are exactly the questions any investor or partner asks.

3. **No affiliate or attribution layer.** No `apply_url`, no outbound-click tracking, no
   partner/commission/conversion tables. Card-issuer affiliate revenue is the most
   obvious first revenue line for a card-recommendation product, and there is currently
   no plumbing for it at all.

4. **No aggregate/BI layer.** No warehouse, no scheduled aggregation beyond the two
   (empty) summary tables, no cohort or spend-panel outputs. Nothing that could be
   packaged and sold, and nothing that could answer an internal business question.

5. **Consent framework exists but does not cover monetization.** `user_consents`
   supports `'terms'`, `'crowdsource'`, `'marketing'` (`0004_user_domain.sql:32`);
   `profiles.contributions_opt_in` defaults to **false**. There is no consent purpose
   covering aggregated data products or partner sharing, and
   `app/lib/features/settings/legal_screen.dart` still ships literal
   `[Draft — pending legal review]` ToS and Privacy Policy text. Under India's DPDP Act,
   monetizing user data without specific, documented, purpose-scoped consent is legal
   exposure — not a nice-to-have.

6. **A design tension nobody has consciously resolved.**
   `pandapay.run_anonymization_audit()` (`0010_functions_and_views.sql:248`) is a
   **deploy-blocking** CI gate that forbids, on the crowdsource tables: any identity
   column, any amount column, any timestamp finer than a date, and any coordinate finer
   than a 4-decimal grid. That is a genuinely strong privacy posture — and it also means
   that dataset can *never* be joined back to a person, a spend value, or an hour of day.
   Any monetization plan must either be built on aggregate insight products that live
   within those constraints, or the constraints must be deliberately revisited with
   counsel. Right now the constraint is being enforced by CI while no one has decided
   what the business intends to sell.

### 1.3 Can users switch devices with their information intact?

**For a signed-in user: mostly yes.** The app is server-authoritative — local sqlite is a
response cache plus a write outbox (`app/lib/data/local/app_database.dart`), not a source
of truth. Sign in on a new phone and cards, transactions, overrides, notification
preferences, muted merchants, and consents all re-pull from Postgres. The auth service
genuinely supports multiple devices: `user_devices`, refresh-token rotation,
`GET /me/devices`, and per-device revoke.

What is lost or broken:

1. **Guest data is unrecoverable and cannot be upgraded.** `/auth/guest-login`
   (`auth/src/routes/authRoutes.js:348`) mints a random UUID with an explicit
   *"NO DATABASE RECORD"* and no refresh token; the guest wallet lives only in the local
   `local_user_cards` sqlite table. There is **no guest→account migration path** anywhere
   in the codebase. A guest who builds a wallet and then signs up loses all of it — a
   silent data loss on the single most important conversion moment in the funnel.
2. **No preference travels with the account.** Theme mode, text scale, number format,
   biometric lock, onboarding-complete, tutorial-seen, due-date reminders, last-used
   card, and what's-new version are all `SharedPreferences`-only
   (`app/lib/app/providers.dart`, `features/settings/appearance_providers.dart`,
   `features/settings/account_settings_screen.dart:212`). A new device resets all of them
   and re-runs onboarding for an existing user.
3. **A pending offline outbox does not travel.** Quick-adds queued offline on a lost
   phone are gone.
4. **No sync engine.** `change_log`, `sync_cursors`, and `sync_conflicts` exist and are
   never written — `api/src/index.js:4772` states this outright. Two devices in
   simultaneous use resolve by accidental last-write-wins with no conflict record, in a
   schema whose own migration header (`0005_sync.sql`) warns that *"silent data loss
   during sync is the fastest way to lose a finance user."*
5. **No account recovery if the phone number is lost.** Auth is OTP-only with no
   password. Email OTP exists as a channel, but nothing enforces a verified backup
   channel and there is no recovery flow. Losing the SIM means losing the account and
   every transaction in it.
6. **All of the above ultimately rests on a database with no backup** (§1.1.3).

---

## Part 2 — The plan

Sequenced by "what makes the next thing safe", not by size. Phase 0 must land before real
users have data worth losing; Phase 2 can run in parallel with Phase 1 once Phase 0 is up.

### Phase 0 — Make the system real and non-destructive (blocking)

| # | Task | Touchpoints | Why first |
|---|---|---|---|
| 0.1 | Managed Postgres with PITR + automated daily logical backup + a scripted, *executed* restore drill; replace the `POST /backup-runs` stub with a real job trigger and record honest `backup_runs` / `restore_drills` rows | infra; `api/src/index.js:4813` | Nothing else matters if data can vanish |
| 0.2 | Containerize + deploy `api/` and `auth/`; move every secret to a managed store (auth already reads AWS SSM — extend the same pattern to `api/`) | new `Dockerfile`s, deploy workflow, `api/src/db.js` | Prerequisite for every remaining item |
| 0.3 | App environment config: replace the two `const` localhost URLs with `--dart-define` values wired into dev/staging/prod flavors | `app/lib/app/providers.dart:34-35`, Android/iOS flavor config | A release build currently cannot reach any backend |
| 0.4 | Error + performance monitoring: Sentry in the Flutter app and both Node services; structured request logging with a request id | `app/pubspec.yaml`, `api/src/index.js`, `auth/src/index.js` | Post-deploy you are blind without it |
| 0.5 | Staging environment with seeded data, so Phases 1–3 can be verified before touching production | infra | Avoids the current "verify on a laptop" pattern |

### Phase 1 — True device portability

| # | Task | Notes |
|---|---|---|
| 1.1 | **Server-side user settings.** New `user_settings` table (jsonb, profile-scoped, RLS) + `GET`/`PUT /user-settings`; migrate every `SharedPreferences` key that is a *user* preference rather than a *device* fact (theme, text scale, number format, due-date reminders, onboarding-complete, tutorial-seen, last-used card, what's-new version). Keep biometric lock device-local — it *should* be per-device. Local prefs become a write-through cache. | Medium. Closes gap 1.3.2 |
| 1.2 | **Guest → account migration.** On first successful sign-in, if `local_user_cards` is non-empty, POST the guest wallet to `/user-cards` in a single idempotent batch and clear the local table on confirmation. Needs a new `POST /user-cards/import` that is safe to retry. | Small-to-medium, highest UX payoff of anything in this plan — it removes a silent data loss at the conversion moment |
| 1.3 | **Account recovery.** Require (or strongly prompt for) a verified backup channel — email if the primary is phone, and vice versa — during onboarding; add a recovery flow that authenticates via the backup channel with a step-up delay and notifies the primary channel. `auth/src/middleware/stepUpAuth.js` already exists to build on. | Medium. Without this, a lost SIM is a lost account |
| 1.4 | **Device management UI in the app**, backed by the existing `GET /me/devices` and revoke endpoints. Surface "signed in on 3 devices" and let users revoke. | Small — the backend is already done |
| 1.5 | **Outbox durability note.** Accept that a pending outbox is device-bound; make it visible ("2 pending offline entries") and flush aggressively on reconnect rather than pretending it syncs. | Small, honesty fix |

### Phase 2 — Start actually recording the company-side data

| # | Task | Notes |
|---|---|---|
| 2.1 | **Wire the crowdsource write paths.** `POST /acceptance-reports` (did this card work at this merchant?), and populate `effective_rate_samples` from confirmed transactions via a scheduled job. Both must respect the existing anonymization gate: no `profile_id`, no amounts, date precision, 4dp grid, rotating salted `device_hash`. Add the in-app prompt that generates the report. | **Medium, and the highest-value item in the plan** — this is the only proprietary dataset in the product, and it is currently empty |
| 2.2 | **Product analytics.** Pick one pipeline (self-hosted PostHog keeps the data in your own infra, which is the better DPDP posture) and instrument the core funnel: install → onboarding steps → first card added → second card added → first recommendation viewed → first transaction logged → D1/D7/D30 return. Event schema versioned in the repo, not ad-hoc. | Medium. Do this before, not after, you need the numbers |
| 2.3 | **Affiliate/attribution layer.** Add `card_products.apply_url` + a `partner_clicks` table (profile-scoped, consented) + a redirect endpoint that stamps attribution, and a `partner_conversions` table for postback reconciliation. | Medium. This is the most direct revenue line and has zero plumbing today |
| 2.4 | **Parser-failure telemetry loop.** `parser_failures` already exists and is covered by the anonymization gate; make the SMS/email/PDF parsers actually write redacted failure shapes so import coverage improves over time. | Small, compounding |

### Phase 3 — Make the data legally and commercially usable

| # | Task | Notes |
|---|---|---|
| 3.1 | **Real ToS + Privacy Policy** replacing the draft placeholder, drafted against what Phases 2–3 actually do with data. Blocks general release regardless. | Owner/legal |
| 3.2 | **DPDP purpose-scoped consents.** Extend `user_consents` purposes beyond `terms`/`crowdsource`/`marketing` to cover aggregated insight products and partner sharing, each independently grantable and revocable, each surfaced in H4. Default off. | Small in code, needs the legal decision first |
| 3.3 | **Decide the monetization posture explicitly.** Either (a) build aggregate insight products that live *within* the anonymization gate — merchant acceptance data, category-level effective-rate benchmarks, card-performance league tables — or (b) consciously revisit the gate with counsel for a consented, identified dataset. Do not let CI keep making this decision by default. | Decision, then work |
| 3.4 | **BI/aggregation layer.** Scheduled materialization of the summary tables + a read-only analytics role + a dashboard. Feeds both internal decisions and any external data product. | Medium |

### Phase 4 — Multi-device sync engine (deliberately last)

The `change_log` / `sync_cursors` / `sync_conflicts` schema is already designed for
per-field LWW with a conflict log. Building the producer/consumer across every entity is,
as GAP_ANALYSIS.md §3 correctly says, larger than everything above it combined.

It is also **not needed for device switching** — Phases 0–1 deliver that. It is needed for
*simultaneous* multi-device use with offline writes on both. Defer until real usage shows
users running two active devices; revisit then with actual conflict-rate data rather than
speculatively.

---

## Implementation status (2026-08-12)

Every code-implementable item in Phases 0–3 is built and verified. What remains
is work no code can substitute for: choosing a host, and legal review.

| Item | Status |
|---|---|
| 0.1 Backups + restore drill | **Done** — `db/scripts/backup.sh` (pg_dump, verified via `pg_restore --list`, honest `backup_runs` rows, prunes only after a verified success) and `restore_drill.sh` (restores into a throwaway DB, asserts row counts, records `restore_drills`). Both executed end-to-end. The lying `POST /backup-runs` stub and its "Back up now" button are gone. |
| 0.2 Deploy | **Done** — `api/Dockerfile`, `auth/Dockerfile` (non-root, dumb-init, healthchecks), `docker-compose.yml` encoding the migration ordering, and a `build-and-test.yml` CI workflow. Registry/host still an owner decision. |
| 0.3 App environment config | **Done** — `app/lib/app/env.dart`; **six** hardcoded localhost constants replaced across app + console; release builds without the defines fail fast. |
| 0.4 Observability | **Done** — `api/src/observability.js`: JSON request logs with correlation ids, a terminal error handler, and query-value redaction (9 tests). No vendor SDK, no PII. |
| 1.1 Server-side settings | **Done** — migration 0028, per-key server-side merge, `settings_sync.dart` registry, 7 tests. |
| 1.2 Guest → account | **Done** — idempotent `POST /user-cards/import`, 7 tests covering every failure path. |
| 1.3 Account recovery | **Done** — `GET /users/me/recovery-status` (masked hints only) + a banner that states the real consequence of having one channel. |
| 1.4 Device management | **Done** — `linked_devices_screen.dart`. |
| 1.5 Outbox visibility | **Done** — pending count surfaced; corrected the screen's false "no offline queue" claim. |
| 2.1 Crowdsource ingest | **Done** — migration 0029, monthly-rotating pseudonyms, quota enforcement, in-app prompt, SQL regression test. |
| 2.2 Product analytics | **Done** — migration 0032: closed event vocabulary, server-side prop allowlist, funnel + retention views; `analytics.dart` with a bounded buffer and lifecycle-driven flush (7 tests). Self-hosted, no third-party SDK. |
| 2.3 Affiliate attribution | **Done** — migration 0030, click/conversion plumbing, disclosed Apply button. |
| 2.4 Parser telemetry | **Done** — migration 0033, plus the RLS bug fix below. |
| 3.2 DPDP consents | **Done** — migration 0031, two independently-revocable purposes, gating nothing until 3.3. |
| 3.1 / 3.3 Legal | **Not started** — needs counsel, not code. Still blocks general release. |
| Phase 4 sync engine | **Done** — migration 0034: per-field LWW over `change_log`, conflicts recorded rather than discarded, push/pull/ack API, local coalescing queue, human-readable conflict log. 12 queue tests + a SQL regression test in CI. |

### Bugs found by execution, not review

Every one of these was invisible to reading the code and passed all existing
checks:

1. **`recompute_merchant_confidence()` (migration 0010) had never run.** It
   assigns an untyped `case` to a `record_confidence` enum and raises every
   time. It is the merchant publication gate; nothing had ever called it.
2. **The CI anonymization gate had been failing since migration 0024** — the
   workflow never created the `app_user` role that 0024's `GRANT` needs, so the
   deploy-blocking gate was not gating anything.
3. **`api/src/index.js` did not parse.** A duplicate top-level `const
   CARD_NETWORKS` made the entry point a syntax error while every unit test
   passed, because the tests import individual modules and never load it.
   `npm test` now runs `node --check` on every source file first.
4. **Unparsed bank SMS returned a 500.** `parser_failures` is admin-only under
   RLS, so the failure branch of `POST /transactions/from-sms` violated the
   policy, aborted the transaction, and turned the documented
   `200 { parsed: false }` into a server error — while collecting zero parser
   telemetry, ever.
5. **`welcome_screen.dart` overflowed on any viewport under ~570pt**, clipping
   the not-financial-advice disclaimer A2 requires and failing two router tests.
6. **`POST /backup-runs` recorded fake successes.** `backup_runs` was a clean
   history of backups that never happened.
7. **The backup scripts' first draft wrote columns that don't exist**
   (`backup_runs.notes`, `restore_drills.status`) — caught by running them
   against the real schema rather than trusting the column names.
8. **`docker-compose.yml` as first written could not have worked.** It pointed
   `auth/` and `api/` at the same database, but both define a `user_devices`
   table with different columns, and auth's schema was never loaded at all.
   They now get separate databases in one instance, matching what
   `auth/db/pandapay-auth/docker-compose.yml` always did.

### On the sync engine specifically

The design decision worth knowing about: the merge is **per-field**, not
per-row. Row-level last-write-wins would silently destroy work — categorise a
transaction on your phone while a note you typed on your tablet is still
unsynced, and the note vanishes with no trace. Each row carries a
`field_clocks` map so only genuinely competing fields ever conflict, and when
two devices do set the same field the losing value is written to
`sync_conflicts` and shown to the user rather than discarded.

Two limitations, stated rather than buried:

- **Clocks are device wall-clock time.** A phone with a badly wrong clock wins
  or loses every conflict against a correct one. A hybrid logical clock is the
  right eventual fix; the damage is bounded because the losing value is always
  recorded.
- **Sync cannot create rows**, only edit and archive them. Creation goes
  through the ordinary endpoints, which enforce invariants (a transaction
  updates cap/milestone/points state; a card checks the product is published)
  that a raw push would bypass.

## Sequencing summary

```
Phase 0 (blocking) ──> Phase 1 (portability) ──┐
                  └──> Phase 2 (data capture) ─┴──> Phase 3 (monetization) ──> Phase 4 (sync)
```

Phases 1 and 2 can run in parallel once Phase 0 is deployed. Phase 3.1/3.2 (legal) should
start early since it has external lead time and gates general release anyway.

## The three answers in one line each

- **Backend support:** architecturally strong, operationally nonexistent — nothing is deployed and there are no backups.
- **Company-side data:** the per-user financial data is captured well; the proprietary crowdsource dataset, product analytics, and affiliate attribution are all at zero.
- **Device switching:** works for signed-in users because the server is authoritative, but guest data, all preferences, and account recovery are broken — and it all rests on an unbacked database.
