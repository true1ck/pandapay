# Lane O handoff: SMS v2 security audit and HIGH fixes

Branch `sms-v2/lane-o-security`, from `sms-v2/claude-lanes` (1baab86). Local only: nothing pushed, deployed or flagged. No scratch database was needed (no SQL changed). The full report is `../security-audit-2026-11.md`.

## Result

No open HIGH finding. Three HIGH, four MEDIUM fixed with a failing test first; three medium design items and four low findings stay open, and two informational items are accepted, all listed in the report.

| ID | Sev | Fix | Where |
| --- | --- | --- | --- |
| LO-01 | HIGH | `facts:batch` caps instruments, events, ledger at 500 each and charges the daily budget for the largest list | `api/src/sms_v2/facts_route.js` |
| LO-03 | HIGH | Both regex linters refuse an unbounded quantifier after a group whose branches can start with the same text; unsigned private rules are linted on the phone | `api/src/sms_v2/rules_admin_route.js`, `packages/pandapay_domain/lib/src/sms_v2/engine/lint.dart`, `app/lib/features/sms_v2/storage/provisional_store.dart` |
| LO-04 | HIGH | Auto-pause needs `AUTO_PAUSE_MIN_DEVICES = 3` distinct profiles | `api/src/sms_v2/rule_stats.js` |
| LO-02 | MEDIUM | Failed or over-count facts bodies spend one budget unit | `facts_route.js` |
| LO-06 | MEDIUM | Cleartext to loopback moved out of the release network config | `app/android/app/src/main/res/xml/network_security_config.xml`, new `src/debug/res/xml/network_security_config.xml` |
| LO-07 | MEDIUM | Shared corrections keep only `category` and `merchantKey` | `api/src/sms_v2/corrections_route.js` |
| LO-08 | MEDIUM | `rule-stats` bounds on version, rule id, rows, counters | `rule_stats.js` |

Tests added: `api/test/sms_v2/security_audit.test.js` (11 tests), `packages/pandapay_domain/test/sms_v2/engine/lint_alternation_test.dart`, `app/test/app/local_sms_rig_release_gate_test.dart` (release-build proof for the local rig), `app/test/native/android_network_security_test.dart`, plus one test each in `provisional_store_test.dart` and `bundle_verifier_test.dart`.

## For the orchestrator

1. **Rules lane**: the new lint rule also runs in `bundle_lint.dart` (build and publish). A rule such as `(?:\w|\d)+` now fails `sms_rules lint`. Disjoint branches (`(?:x|y)*`, `(?:\s|,)*`) still pass. `lint.dart` is the only file here that overlaps a rules-lane area; the change is confined to group bookkeeping and one new check, so a merge conflict should be mechanical.
2. **Android**: `flutter run --profile` against `http://10.0.2.2` no longer works (only debug builds allow loopback cleartext). Hosted `https` builds are unaffected.
3. **Phone upload limits**: the phone already sends at most 500 of each kind per request, so no client change is needed. A server cap of 500 per list is now an API contract; mention it if a client other than the Flutter app is planned.
4. **Open items that need an owner decision** (details in the report): LO-09 move bundle signing out of the public API process (recommend pre-signing in the hourly admin job); LO-10 limited-use App Check tokens before switching WP-17 to `enforce`; LO-11 exclude `pandapay.sqlite` from iOS backups and decide on SQLCipher (touches native SMS code, so left alone).
5. `owasp-mobile-security-checker` scanners scanned 0 files here; the M1 review used grep. WP-13's "no high findings over `app/lib/features/sms_v2/`" item is met by this audit.

## Verification run

- `cd api && JWT_ACCESS_SECRET=ci_only_not_a_real_secret npm test`: 1441 tests, 1437 pass, 4 skipped, 0 fail.
- `cd api && node --test test/sms_v2/*.test.js`: 174 tests, 124 pass, 50 skipped (Postgres-only suites, no scratch database used), 0 fail.
- `cd api && node scripts/check_sms_v2.js`: 29 files OK.
- `cd packages/pandapay_domain && dart test`: all 1031 tests pass.
- `cd tools/sms_rules_cli && dart test`: 41 tests pass.
- `cd app && flutter test --no-pub --concurrency=1 test/features/sms_v2`: 258 pass, 2 skipped, with the flag off and with `--dart-define=SMS_PIPELINE_V2=true`. The new `test/app` and `test/native` tests pass.
- `npm audit --omit=dev` in `api`: 0 vulnerabilities.
- The PG-backed suites (`*_pg.test.js`) were not run; no SQL changed, and the corrections change does not alter any asserted row in `corrections_pg.test.js`.
