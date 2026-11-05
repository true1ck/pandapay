# Lane N handoff: client-reported release metrics

Branch `sms-v2/lane-n-client-metrics` from `sms-v2/claude-lanes` (1baab86). Local only: nothing pushed, deployed or flagged. No Gmail code touched.

The sync error rate and migration failure rate gates in `GET /admin/sms/v2/metrics` were `available:false` because nothing recorded them. The phone now reports aggregate counters, the server stores daily totals, and both gates take real values, so `decision` can reach `go`.

## What was built

**App** (`app/lib/features/sms_v2/telemetry/client_metrics.dart`, new).
- `ClientMetrics` counts: sync runs and failures by coarse reason (`network`, `timeout`, `server`, `storage`, `data`, `other`), history migration started/completed/failed, bundle download failures. Reasons come from the exception type only; no message, URL or status text is kept.
- Counts are durable: rows in the account's existing `v2_sync_state` table under `metrics:d:<UTC day>:<counter>` (no schema change, account-isolated).
- Upload: closed days only, oldest first, at most 3 days per pass, at most once every 24 hours after a success (a failed attempt waits an hour). A `202` or `400` finishes the day; anything else keeps it. Days older than 7 are dropped (the server accepts 8).
- Consent: the same `hasSharingConsent` the template upload uses (`sms_shared_learning`). Without it nothing is counted, nothing is sent, and stored counts are deleted at the next upload pass.
- Failures never reach the user: every method swallows its own errors; `measureSync` and `measureMigration` rethrow only the original failure. An account-switch `StateError` is neither an attempt nor an error.
- Runtime wiring (`sms_v2_runtime.dart`, 5 small touch points, not one line, because there are five events to observe): the field, `sync()` calls `_syncAndReport()` (measures the sync, then uploads in a `finally`, so a phone whose sync keeps failing still reports), `replay.run()` wrapped by `measureMigration`, `bundleDownloadFailed()` in the rules-refresh failure branch and its catch.

**Server** (`api/src/sms_v2/client_metrics_route.js`, new; one registration line in `api/src/sms_v2/index.js`).
- `POST /sms/v2/client-metrics`, body `{day, appVersion, counters}`. Closed vocabulary of 11 counters, integers 0 to 10,000, `day` within the last 8 days, unknown fields refused, at least one nonzero counter.
- Order: v2 flag (404 when off), sign-in, attestation admission (`hooks.security.verifyAttestation`, so monitor/enforce mode applies), rate limit, then SQL. The server records `verified` or `unverified` itself from the attestation result; the app sends no claim.
- Rate limit: new key `client-metrics`, 12 per day per profile and per device (`SMS_V2_CLIENT_METRICS_PER_DAY`), halved for unverified callers, `Retry-After` set. `security.js` is not edited (another lane owns it): the route reuses `createPgRateStore` with its own budget. If the security owner later adds the key to `ROUTES`, the limiter can switch to `hooks.security.checkRate(req, 'client-metrics')`.

**Database** (`db/supabase/migrations/20261113100000_sms_v2_client_metrics.sql`, additive).
- `sms_v2_client_metrics_daily(day, app_version, attestation, metric, total)`: the aggregate table. No profile or device column; forced RLS with no policy (only the functions below touch it).
- `sms_v2_client_metric_receipts(profile_id, device_digest, day)`: owner-scoped de-duplication so a re-sent day counts once; pruned after 14 days; never read by admin code.
- `pandapay.sms_v2_record_client_metrics(...)` (security definer, `app_user`): validates everything again, takes the shared consent lock, returns `recorded`, `duplicate` or `no_consent`, and caps distinct version labels at 50 per day.
- `pandapay.sms_v2_client_metrics_report(since)` (private admin role, `learning.read`): totals by counter, by version and attestation, and a report count.
- SQL test `db/tests/20261113100000_sms_v2_client_metrics_test.sql`.
- `api/src/portable_backup/coverage.json`: both tables classified `platform_ops` (a repo test requires every migration table to be listed).

**Metrics route** (`metrics_route.js`).
- `syncErrorRate`: `{available:true, source:'client_metrics', value, attempts, errors, byReason}` when attempts are reported; errors over sync runs.
- `migrationFailureRate`: `{available:true, value, started, completed, failed}`; failed over finished runs (completed plus failed), so a run still in progress or interrupted and resumed is not counted as a success or a failure.
- Both feed `gates` (limits 1% and 0.5%, strictly under to pass) and `missingSignals`. With no report they stay `available:false`; one signal alone keeps `decision:'incomplete'`. New `clientReports` block: report count, bundle download failures, and per version and attestation counts.

## Privacy decisions

- Counts only: 11 fixed counter names, a day, an app version. No message text, sender, amount, merchant, instrument, id or error text. The server rejects anything else.
- Consent is checked three times: when counting, when uploading (withdrawal deletes stored counts), and in SQL under the shared consent lock (a withdrawal that commits first wins).
- The aggregate has no profile or device column (the SQL test asserts it). The raw installation id is hashed by the route before storage; the digest sits only in the receipts table with the profile, for de-duplication, and nothing the admin reads touches it.
- Attestation status is decided by the server. Unverified reports are stored under `unverified`, so a forged client cannot count as verified; they are never mixed into a verified bucket.
- Small cells: a version used by very few people gives a small aggregate row. No minimum cell size is enforced; admins can already see rule stats by app version. Revisit before widening who can read the metrics.

## Decisions and known limits

- **Bias:** only consenting, reporting phones are counted, so the rates describe that group, not everyone. Phones with sync broken before a first successful report still report (upload runs after a failed sync), but a phone that never reaches the network cannot.
- **Sample size:** no minimum is enforced; `attempts` and `finished` counts are in the payload. Read them before acting on a `go` at the start of a rollout.
- **Retries inflate the sync rate** only through real failed runs; the foreground timer runs every 15 minutes, so a user offline all day adds up to about 96 error runs. This matches "sync error rate" as a share of runs. If the owner wants per-user rates, that needs a per-profile counter and a decision on storing it.
- **Reason `server`** is only used for `HttpException`. The upload queues swallow HTTP status failures inside `drain()` (they retry with backoff), so those do not count as sync errors; only a run that throws does. Bundle download HTTP failures are counted separately.
- **Migration coverage:** `measureMigration` wraps the automatic first-run replay in `_sync`. The user-started history update (`historyUpdate`) is not counted.
- The SQL test is not added to the list in `tests/admin_console_security/full_schema.test.js` (shared file); add `20261113100000_sms_v2_client_metrics_test.sql` and `api/test/sms_v2/client_metrics_pg.test.js` there.

## Verification

- `cd api && JWT_ACCESS_SECRET=ci_only_not_a_real_secret npm test`: 1,441 tests, 1,437 pass, 0 fail, 4 skipped.
- New tests: `api/test/sms_v2/client_metrics.test.js` 11 pass; `client_metrics_pg.test.js` 1 pass (scratch DB); `metrics_route.test.js` 9 pass (fake client taught the new query); `metrics_pg.test.js` pass.
- `node scripts/check_sms_v2.js`: 30 files OK.
- SQL test `20261113100000_sms_v2_client_metrics_test.sql` passes on a scratch local PostgreSQL 18 with the full auth and product migrations (dropped afterwards).
- `cd app && flutter test --no-pub --concurrency=1 test/features/sms_v2`: 270 pass, 2 skipped, with the flag off and with `--dart-define=SMS_PIPELINE_V2=true`. New: `telemetry/client_metrics_test.dart` 12 tests, `telemetry/runtime_metrics_test.dart` 2 tests.
- `flutter analyze --no-fatal-infos`: the new and edited files report no issues; existing infos elsewhere are unchanged.
