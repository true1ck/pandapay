# Offline-first: final status (branch `feature/offline-first`)

Base: `dev` at `0cb453a7`. Master plan: [OFFLINE_FIRST_MASTER_PLAN.md](OFFLINE_FIRST_MASTER_PLAN.md) (written before the work; its
"not started" sections are now done, see below). Per-screen inventory: [OFFLINE_FIRST_AUDIT.md](OFFLINE_FIRST_AUDIT.md).
Every package has a note in this folder (`WP-*.md`, `H1-H3.md`). Manual checks that need a phone/backend: [WP-Q1.md](WP-Q1.md).

## What was built
| Area | Packages |
|---|---|
| Server | S0/S1 sync hardening + allowlist migration; S2 idempotent card/override create; S3-S5 budgets, recurring, notification/consent/support-ticket/import-batch client ids; S6 privilege manifest + rollout note; S7 `user_local_state` (encrypted bank balances) |
| Connectivity, queues, session | C1 seeded connectivity + reachability probe + server clock; C2 queue hygiene, QueueRegistry, schema v3; C3 session-rejected keeps data, sign-out counts/flushes every queue |
| Writes offline | C5 transactions (bulk, voice, payment-sent, receipts, edit), C6 cards + overrides, C7 budgets/subscriptions/bills, C10 import/export, C11 account/consents/support, C17 sync of bill-card picks, balances and subscription choices |
| Reads offline | C16 read paths, C8 Split fixes + local reads, bundled categories/fonts |
| Notifications | C4 offline prefs/inbox, C14 scheduled reminders (Android boot receiver, inexact alarms) |
| UX | top sync strip (18 dp) + Sync status sheet, offline-aware ErrorState, one "saved on this phone" message, background timeouts |
| SMS | C9 capture before network, timeouts, corrections never parked offline, consent mirror |
| Review rounds | H1-H3 fixed the findings of an adversarial review (403 gates parking queued work, proxy 404 deleting commands, 500 attempt burning, clock poisoning, notification gate race, privacy of queued corrections, and more) |

## Verification (final)
- Flutter: full suite 5,003 passed, 11 skipped, 0 failed (after fixing 4 test-side issues found by the final runs).
  `flutter analyze lib`: 0 errors, 1 warning (pre-existing on base: unused shown name in `spend_answers.dart`).
- Offline scenario tests: `app/test/offline_e2e/` scenarios a-s (fake server that goes offline/online, idempotent like the real contract).
- API: `node --test`: 14 failures, all `*_postgres.js` fixtures needing `initdb`; the same 14 fail on base `0cb453a7`.
- Emulator (Pixel 9a, debug build): installs, first launch offline works, bundled fonts render, strip shows and clears, offline/online
  toggles do not crash; INTERNET + boot receivers present in the manifest. Not testable without a backend: anything behind sign-in.

## Not verified / needs you
1. Real Postgres: run `db/tests/20261123*_test.sql` (010000, 030000, 040000, 050000, 060000) with `psql -v ON_ERROR_STOP=1` on a migrated
   scratch DB, plus the `*_postgres.js` fixtures. Only checked on a stand-in database here.
2. Real phone with sign-in: the checklist in `WP-Q1.md`; profile build + `scripts/perf_smoke_android.sh`. First cold start on the
   emulator was 3-5 s (debug build).
3. Production value of `SYNC_TYPED_WRITES_ENABLED` (repo default `false`; the legacy writer rejects numeric/enum edits). See `WP-S6.md`.
4. Signed SMS rules bundle (baseline is empty), and whether locally learned merchant rules should sync (`WP-C9.md`).
5. Reminders and the iOS notification delegate are untested on a device; a bill can show both a scheduled reminder and the in-app alert.
6. Encryption key for balances: they use the server's IMAP key ring (`WP-S7.md`); end-to-end (user-held key) is an optional future step.

## Deployment order (recommended)
Migrations and API first (backward compatible), then the app build. New clients tolerate an old server (404 / ignored fields).
