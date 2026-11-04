# Lane G handoff: old-app compatibility fixes and app identification

Branch `sms-v2/lane-g-compat`, from `sms-v2/claude-lanes`. Local only: nothing pushed, deployed or flagged; the scratch PostgreSQL was dropped afterwards.

## What changed

| Item | Where |
| --- | --- |
| App sends `X-App-Version` on every PandaPay API request, and `X-Sms-Pipeline: v2` only when v2 is on | `app/lib/data/api_request_headers_client.dart` (new), wired in `app/lib/main.dart` (`http.runWithClient`), `authenticatedHttpClientProvider` in `app/lib/app/providers.dart`, `app/lib/features/sms_v2/providers/runtime_provider.dart` |
| D-1: legacy clients never see `refund` | `api/src/legacy_entry_kind.js` (new), registered by one `app.use` in `api/src/index.js` |
| D-2: legacy replay leaves v2-owned and superseded rows alone | early return in the duplicate branch of `insertTransactionAndUpdateState`, `api/src/index.js` |
| Tests | `app/test/data/api_request_headers_client_test.dart`, `api/test/legacy_entry_kind.test.js`, the 6 flipped or new tests in `api/test/sms_v2/old_app_compat_pg.test.js`; `app/test/flutter_test_config.dart` mocks `PackageInfo` for every test |
| Docs | runbook `dark-deploy.md` section 4 and owner item 6 updated |

## App headers

- `ApiRequestHeadersClient` wraps an `http.Client` and touches only requests whose origin equals `Env.apiBaseUrl`. Other origins, bodies, methods, and every other header are unchanged (tests).
- `X-App-Version` is `<version>+<buildNumber>` from `package_info_plus` (already a dependency; no new dependency), falling back to `--dart-define=PANDAPAY_APP_VERSION`, else omitted. Values not matching `[0-9A-Za-z.+_-]{1,40}` are never sent. Decision: the build number is included, so `SMS_V2_FIRST_APP_VERSION` must be given as `x.y.z+build`; a bare `1.4.0` would sit below `1.4.0+57` in the gate's ordering.
- `X-Sms-Pipeline: v2` is added only when the flag is on (`smsPipelineV2EnabledProvider` in the two provider-built clients, `kSmsPipelineV2` in the zone client). A v2 build with the flag off therefore behaves as a v1 client toward the server.
- Coverage: `main()` runs the app inside `http.runWithClient`, so every `http.Client()` (including repository defaults such as catalogue, app status, changelog) gets the wrapper; the shared authenticated client and the SMS v2 runtime client wrap their inner client explicitly so they honour the provider override and the local SMS rig client. Both layers set the same values (idempotent). Not covered: code running in a background isolate that never goes through `main()` and builds its own `http.Client()`; none of those paths calls a gated legacy route.

## Server D-1

Every JSON body to a request without `X-Sms-Pipeline: v2` has `entry_kind` / `entryKind` equal to `refund` replaced by `transfer`. Done as one response filter rather than per-route SQL, so it also covers ignore, restore, duplicate-candidate resolve, bulk category apply, category preview, from-sms answers and sync pull, which all return transaction rows. Stored data and server-side totals are not touched; the test compares spend-by-category, spend-report, home-summary and monthly-reports with and without the header. Header present means v2 (any case, trimmed); `X-App-Version` alone never opts in. Decision: `transfer` (the request's proposal), not `income`. Known limits: the CSV export's "Kind" column still prints `refund`.

## Server D-2

When the stored row has `pipeline_version = 2` or `status = 'superseded'`, the legacy duplicate branch returns `{status: 200, duplicate: true, duplicateKind: 'exact_retry', transaction}` with the same field set as the old path, and does nothing else (no reclassify, observation, card-state or pairing work). Rows with `pipeline_version = 1` are unchanged; a test proves a v1 duplicate returns one active row and still has a stale kind refreshed.

## Verification (scratch PostgreSQL, loopback only)

- `cd api && JWT_ACCESS_SECRET=ci_only_not_a_real_secret npm test`: 1437 pass, 0 fail, 4 skipped.
- `node --test test/sms_v2/old_app_compat_pg.test.js test/legacy_version_gate.test.js test/legacy_entry_kind.test.js` with `SMS_V2_TEST_DATABASE_URL` set: compat 13 pass, 0 fail, 1 skipped (PARITY needs the old-world env); gate 10 pass; entry-kind unit 3 pass. With both fixes removed, the three LANE-D tests fail as expected.
- `node scripts/check_sms_v2.js` (from `api/`): 29 files OK.
- App: new header tests 6 pass; `test/features/sms_v2` and the full `flutter test --no-pub --concurrency=1` (2951 pass, 6 skipped) pass with the flag off, and `test/features/sms_v2` plus the header and authenticated-client tests pass with `--dart-define=SMS_PIPELINE_V2=true`. `flutter analyze --no-fatal-infos`: no new warning or error from these changes.

## For the orchestrator

- Set `SMS_V2_FIRST_APP_VERSION` as `x.y.z+build` matching the first v2 release's `pubspec.yaml` `version`.
- The old-app smoke in the runbook still needs a real phone; this lane proves the server side only.
- `PATCH /transactions/:id/note` on a superseded row still answers 200 (unchanged; lane D left it as is).
