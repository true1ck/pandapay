# Lane R handoff: release plumbing

Branch `sms-v2/lane-r-plumbing`, from `sms-v2/claude-lanes` (a8a9560). Local only; nothing pushed, no flag changed, no Gmail or production code touched.

## 1. Engine version and `minEngineVersion`

- `smsEngineVersion` is now `2.1.0` (`engine/compiled_bundle.dart`, comment says why: `info` facts may carry `amountMinor`, CCR-002).
- New `rules/sms/v2/meta.json`: `{"minEngineVersion": "2.1.0"}`. `readRulesFolder` already reads `minEngineVersion` from `meta.json`; the domain and app test loaders already skip the file. No `bundleVersion` or dates are pinned there (the release script and CLI flags set those).
- Honoured end to end: `CompiledBundle.compile` refuses a bundle needing a newer engine (`engine_too_old`); `build` and `lint` surface it as `bundle_refused` and fail; the phone `BundleStore` compiles before installing and keeps the last copy (existing app test with `99.0.0`).
- Tests: domain `engine_test.dart` (shipped engine reads 2.1.0, a 2.0.0 engine refuses it and returns `bundle_refused`); CLI `rules_commands_test.dart` (build takes meta, refuses 99.0.0 and writes nothing; the real `rules/sms/v2` builds to a bundle that 2.1.0 compiles and 2.0.0 refuses).
- Release note: a phone on engine 2.0.x will keep its last bundle instead of loading a bundle that needs 2.1.0, so the app that ships `smsEngineVersion` 2.1.0 must be out before the first bundle built from these rules is published.

## 2. Lint rejects aliases in `senders`

- New error `lint.sender.alias` in `engine/bundle_lint.dart` for rules and ignore rules: a `senders` entry that is an alias (not a canonical brand) is reported with the brand to use. Unknown senders still report `lint.sender.unknown`.
- Tests: domain `engine_test.dart`; CLI `rules_commands_test.dart` (ignore rule scoped to an alias fails, canonical passes).
- Real rules flagged and fixed (sender changed to the canonical brand; where the canonical brand was already in the list the alias entry was removed):
  - `rules/sms/v2/brokers/payouts.json`: `BRK-PAYOUT-BANK-CREDITED-01` listed `KOTAKS` (alias of `KOTAKN`, which was already listed); entry removed.
  - `rules/sms/v2/banks_lane_b/lane_b_cards_upi.json`: five `FED-SCAPIA-CARD-*` rules listed `FEDSCP` (alias of `FEDSMS`, already listed); entry removed in each.
  No ignore rule was flagged. These rules were not firing for `FEDSCP`/`KOTAKS` handles before; they now fire for the canonical brand only (the engine resolves the aliases first), so real messages from those handles now reach them. The golden gate, the 217 cases and 18 scenarios, still passes.

## 3. Metrics minimum sample size

`api/src/sms_v2/metrics_route.js`: `MIN_SAMPLE = {devices: 20, syncRuns: 200}`. `go` needs every gate to pass AND both floors met; otherwise `incomplete`. A failing gate is still `no-go` whatever the sample. Payload gains `sample` (`reportingDevices`, `devicesBasis`, `minDevices`, `syncRuns`, `minSyncRuns`, `sufficient`). Configurable per call (`collectMetrics(..., {minSample})`) and in the handler through `SMS_V2_METRICS_MIN_DEVICES` and `SMS_V2_METRICS_MIN_SYNC_RUNS`.

Device count: `sms_v2_client_metrics_report` returns `reports` (device-days, one receipt per device per day) and no distinct-device count. Until it does, `reportingDevices = ceil(reports / days)`, a lower bound on distinct devices (basis `lower_bound_from_receipts`); a `devices` field in the report is used as-is (basis `distinct`). The bound only understates, so it can only delay a `go`. Request to the SQL owner: add `'devices', count(DISTINCT device_digest)` to the report function. Receipts are kept 14 days, so windows over 14 days undercount devices.

Tests in `metrics_route.test.js` (7 new); `client_metrics.test.js` go-test fixture now reports 140 receipts so it still reaches `go`.

## 4. Test lists

`tests/admin_console_security/full_schema.test.js` now also runs `20261112210000_sms_v2_release_metrics_test.sql`, `20261113100000_sms_v2_client_metrics_test.sql`, `metrics_pg.test.js` and `client_metrics_pg.test.js`. Ran it against a scratch socket-only Postgres 18 (`/tmp/pandapay-admin-pg.laneR1`, dropped afterwards): pass. The cluster needed `LC_ALL=en_US.UTF-8` to start on this Mac.

## 5. Derived copies

- `console/assets/sms_golden/bundle.json`: regenerated with `cd console && dart tool/copy_golden.dart` (the generator CI runs; `dart run` needs the Flutter deps). It is a one-line JSON of cases, scenarios, senders, gates and `reports/latest.json`; 235 items.
- `app/assets/sms_rules/baseline_bundle.json`: NOT touched. It is the version-0 empty placeholder (`rules: []`, `signature: null`, `minEngineVersion` 2.0.0) that `BundleStore.load` and its test rely on. It must stay empty and loadable by every engine until a signed build is released; replacing it with an unsigned rules bundle would ship unverifiable rules. `api/sms_v2_assets` (contracts, gates) was unchanged: `check_sms_v2.js` passes.

## Tests

| Command | Result |
|---|---|
| `packages/pandapay_domain` `dart test` | 1049 pass |
| `tools/sms_rules_cli` `dart test` | 230 pass; `lint --rules ../../rules/sms/v2` clean; `check_pipeline` golden ok (217 cases, 18 scenarios, engine 2.1.0) |
| `node test/regex_parity.mjs` (from the CLI dir) | 140,722 comparisons, 0 mismatches |
| `api` `npm test` | 1441 tests, 1437 pass, 4 skipped (database tests needing a URL), 0 fail; `check_sms_v2.js` 30 files OK |
| `app` `flutter test --no-pub --concurrency=1 test/features/sms_v2` (flag off, and with `SMS_PIPELINE_V2=true`) | 296 pass, 3 skipped, 1 FAIL in both |
| full_schema against scratch DB | pass |

The one app failure is not from this lane: `pipeline/idempotency_test.dart` "one batch and one-at-a-time agree on every non-IPO event" has hard-coded per-event-type counts (for example refund 13, purchase 32) that no longer match the merged rules (refund 10, purchase 33). It fails identically with this lane's rule edits and engine bump reverted. Whoever owns the pipeline tests should refresh the expected counts (or assert batch equals single, which is the test's purpose).
