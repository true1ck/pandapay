# Offline-first — implementation status (branch `feature/offline-first`)

Base: `dev` at `0cb453a7`. Master plan: [OFFLINE_FIRST_MASTER_PLAN.md](OFFLINE_FIRST_MASTER_PLAN.md) (per-screen inventory: [OFFLINE_FIRST_AUDIT.md](OFFLINE_FIRST_AUDIT.md)).
Each package has its own note in this folder (`WP-*.md`): what changed, files, how to test, known gaps.

## Done and merged (Wave 1, "critical fixes first")

| Package | What it fixes |
|---|---|
| WP-S0/S1 (server) | Strict push mode (`ignoredFields`), device pre-check (409), clock clamp, transient vs permanent results, 1 MiB `/sync/push` body limit, uuid guards (400 instead of 500), migration restoring dropped `last4` / `annual_fee_override_inr` and adding `instrument` / `entry_kind` to the legacy list |
| WP-C1 | Seeded connectivity, server-reachable probe, `isOfflineLike`, server-time offset for field clocks, app-status re-check on reconnect |
| WP-C2 | Queue hygiene: park poison rows, network errors don't burn attempts, backoff reset on reconnect, byte-bounded push chunks, device re-registration, pull-poison skip, `QueueRegistry`, `LocalFirstSchema` + app DB v3 |
| WP-C3 | A rejected session (401) no longer deletes local data; sign-out report/flush covers every queue with an explicit offline warning; backup lists derive from `QueueRegistry`; token-store write-order fix |
| WP-C4 | Notifications work offline (cached/default preferences, banner first, inbox row queued) |
| WP-C8 | Split: ordered offline commands, 403-while-create-unconfirmed retried, needs-attention list, reconnect backoff reset, unknown capability flags allow queueing, approve/confirm offline |
| WP-C9 | SMS: capture before network, 8 s timeouts on App Check/headers, offline errors don't burn upload backoff, corrections never parked because of an offline spell, shared-learning consent mirror, Gemini bar offline state |
| WP-C12a | Bundled Outfit + IBM Plex Sans (hash-verified, OFL), runtime font fetch disabled, `INTERNET` + https `<queries>` in the manifest, FCM token timeout, guarded `launchUrl` |
| WP-banner | Small top strip across the whole app (offline / can't reach PandaPay / syncing / needs attention) with a Sync status sheet (reverses the 2026-10-18 banner removal, per owner decision) |

## Verification
- Full app suite on this branch: 4715 passed, 11 skipped. The only failures were `widget_test.dart` Chunk 19 (a pending timer from the new strip; fixed by stubbing the strip in that test) and two timing flakes under full-suite load (`transaction_attachments_repository_test`, `capture_worker_test`) which pass in isolation on both base and this branch.
- API suite on the server package: 2471 pass, 0 fail. The new migration's SQL test was verified against PGlite, **not** a real Postgres (no `psql`/Docker available) — run `db/tests/20261123010000_*_test.sql` on a migrated scratch DB before deploy.
- Not run: `scripts/perf_smoke_android.sh` (needs a phone), any on-device airplane-mode test. See master plan section 9.

## Things the investigation found that change the plan (read before continuing)
1. **Legacy sync writer** (`SYNC_TYPED_WRITES_ENABLED=false`) assigns every field as `($1 ->> field)::text`; Postgres only accepts that for text-like columns, so most numeric/date/enum edits are **rejected** in legacy mode. The migration therefore only really helps `last4` in legacy mode; `instrument`, `entry_kind`, `annual_fee_override_inr` need the typed writer. **Find out what production actually runs** (the repo default is `false`) before deciding whether to enable typed writes (see `deploy/DEPLOY.md`, `db/scripts/release_security_check.js`).
2. `POST /notifications` upserts on `dedupe_key` and resets `read_at`/`created_at`; a replayed inbox row re-marks a notification unread until WP-S5 adds a client mutation id column.
3. WP-C2 marks pushed edits applied (`in_flight=2`) instead of removing them before the refetch, otherwise an edit visibly reverts; the delta-path materialize was deliberately not done (belongs with the prune work in C7).
4. After a 401, TokenStore.clear still resets the native iOS SMS spool (not verifiable here).
5. Locally learned merchant-category rules are still never uploaded (`pendingSync` has no callers); the upload contract does not fit (layout-scoped rule vs merchant-wide server rule). Needs an owner decision.
6. The baseline SMS rules bundle is still empty; shipping a signed one is an owner task (see `WP-C9.md`).

## Not started (next waves, in plan order)
Server: S2 (card/override idempotent create), S3 (budgets), S4 (recurring), S5 (append-only mutation ids), S6 (privilege manifest / typed-writes rollout).
Client: C5 (local-first transaction writes: bulk, voice, payment-sent, receipts), C6 (cards offline: add card, edit card, overrides), C7 (budgets, subscriptions v2, card-bill payment), C10 (import/export), C11 (account/settings), C12b (offline-aware ErrorState, cold-start caps, categories bundle), C14 (scheduled reminders), C16 (read-path polish), Split local reads (C8 wave 2), WP-Q (device test matrix). C15 (background sync) is a spike only.
