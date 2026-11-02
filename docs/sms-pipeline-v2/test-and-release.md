# Test and release

Nothing reaches users until every gate on this tab passes. Each work package's done criteria feed these gates.

## Test layers and commands

| Layer | Proves | Command | Runs |
| --- | --- | --- | --- |
| Contracts | Dart and Node validators agree on every fixture | `cd packages/pandapay_domain && dart test test/sms_v2/contract_fixtures_test.dart`; `cd api && node --test test/sms_v2/contracts.test.js` | CI, every push (step added by WP-01) |
| Domain logic | Engine, instruments, linker, ledger, categories | `cd packages/pandapay_domain && dart test` | CI, every push |
| Regex parity | Every rule pattern behaves the same in Dart and JavaScript | `node tools/sms_rules_cli/test/regex_parity.mjs` | CI (added by WP-02) |
| Golden set | Accuracy gates, with no metric dropping | `cd tools/sms_rules_cli && dart run bin/sms_rules.dart golden --bundle ../../app/assets/sms_rules/baseline_bundle.json --baseline ../sms_golden/reports/latest.json` | CI (added by the orchestrator after WP-03), plus nightly |
| App, flag off | Nothing changed for today's pipeline | `cd app && flutter test --concurrency=1` | CI |
| App, flag on | v2 wiring, screens, migration | `cd app && flutter test --concurrency=1 --dart-define=SMS_PIPELINE_V2=true` | CI (orchestrator adds the step at M2) |
| Visual | Key screens in light and dark | Alchemist golden tests under `app/test/features/sms_v2/` | CI, using the CI variant |
| Server | Routes, storage, security, jobs | `cd api && npm test` | CI |
| Database | Migrations, row-level security, report queries excluding superseded rows | `db/tests/2026111*_sms_v2_*_test.sql` in the smoke job | CI |
| End to end, Android | Capture through to totals on screen | `android-emulator` skill, or the Maestro flow `maestro/sms_v2_import.yaml` | Each milestone gate and the release |
| End to end, iOS | Shortcut intake through to totals | iOS simulator smoke test | Each milestone gate and the release |
| Migration | The legacy fixture becomes the expected v2 state | `cd app && flutter test test/features/sms_v2/migration/` | CI |
| Performance | The budgets below | Tagged benchmarks (`--tags benchmark`) | Nightly, plus each gate |
| Security | No high findings; attestation and limits work | `owasp-mobile-security-checker` skill, plus `api/test/sms_v2/security.test.js` | M2 gate and the release |

## Golden set and metric gates

The case and scenario formats are defined in WP-00. Each case is weighted by its template's real message volume. Kind, amount and instrument are also reported weighted by rupee amount, so a wrong ₹25,000 counts more than a wrong ₹20.

| Metric | Definition | M1 gate | Release gate |
| --- | --- | --- | --- |
| Capture recall | Financial messages that are not ignored | ≥ 99% | ≥ 99.5% |
| Ignore precision | Ignored messages that really are non-financial | ≥ 99.5% | ≥ 99.9% |
| Event kind | Correct event type | ≥ 97% | ≥ 99% |
| Amount and role | Correct amount in the correct role | ≥ 99% | ≥ 99.5% |
| Instrument | Correct account, card or wallet | ≥ 98% | ≥ 99% |
| Double counts | Scenarios where one real event counts twice | 0 | 0 |
| Pairs linked | Expected multi-message events joined | ≥ 95% | ≥ 98% |
| Category | Correct spend category | ≥ 90% | ≥ 95% |
| Ask rate | Unknown plus review items, over financial messages | ≤ 5% | ≤ 2% |
| Scenario totals | Spend, income, investment, count and by-category exactly right | 100% | 100% |

The gates live in `tools/sms_golden/gates.json` as `m1` and `release` profiles. No metric may fall below the last committed report. When new cases are added, the orchestrator recommits the baseline in the same pull request. The release gates must pass on both the synthetic cases and the redacted real templates from the owner's export: 5,210 messages from 274 senders, November 2025 to November 2026.

## Migration and compatibility tests

- **Legacy fixture database:** WP-16's fixture migrates to the exact expected state, twice in a row, and also after an interrupted run.
- **Old app against the new server:** all legacy API tests pass on a server with every v2 migration applied. A recorded set of today's app requests replays with identical responses.
- **New app when v2 routes fail:** on `404` or `5xx`, the phone keeps everything in its outbox, shows a sync status, and loses nothing. That is why the server ships before the app.
- **Bundle compatibility:** an engine refuses a bundle needing a newer engine and keeps its last good bundle. An unknown optional field in a server response is ignored.
- **Two devices on one account:** facts from both merge through sync into the same events, and instrument key conflicts settle on the server's id.
- **Account switch:** every v2 table stays namespace-isolated, including the outbox and the migration state.
- **Real upgrade path:** install today's production build, import synthetic data, upgrade to the candidate, and check the migration report and totals. Do this on an Android emulator and an iOS simulator.

## Performance and cost budgets

| Budget | Target |
| --- | --- |
| Engine | 10,000 messages against 1,000 rules in under 2 s on a CI desktop; bundle compile under 300 ms |
| Linker | 20,000 facts in under 5 s on a CI desktop |
| History import on the phone | 20,000 messages in under 2 minutes on a mid-range Android phone, with peak memory under 300 MB |
| A live message | Visible in totals within 1 second of capture |
| Network | One upload per 500 items; at most 4 sync calls an hour in the foreground; one bundle check every 6 hours when nothing has changed |
| Server batch | 500 items in under 1 s p95, with a fixed number of SQL statements per batch (no more than 15) |
| AI | At most one call per new template. Monthly AI cost per 1,000 active users is reported on the metrics page; the target is set after the first month's measurement. |
| Battery | No new periodic background work beyond today's capture |
| App size | No larger than the current release |

## Release checklist and staged rollout

The server ships first, the app second, and rule changes roll out on their own track afterwards.

**Before release:**

- [ ] Every work package is Done, and the release gates pass on both the synthetic cases and the owner's redacted real templates.
- [ ] The owner has reviewed the migration dry-run report on their own phone.
- [ ] Testers have used the candidate for at least 7 days. The correction rate is under 1% of new events, and no P0 gap is open.
- [ ] Security: the OWASP checker shows no high findings, the attestation monitor data is reviewed, the signing key is in the secret store, and the public key ships in the app.

**Server, first:**

- [ ] Migrations are applied to staging, then production.
- [ ] Bundle 1 is imported and active.
- [ ] The rule-stats and auto-pause jobs are scheduled.
- [ ] `sms_pipeline_v2_enabled` is on for testers, then for everyone.
- [ ] Today's production app is checked against production using the legacy routes.

**App:**

- [ ] Version bump, release notes ("We re-checked your history…") and the Codemagic builds.
- [ ] **Android staged rollout** at 5%, then 20%, 50% and 100%, over about 7 days. Each step is a go/no-go on:
  - crash-free sessions of at least 99.5%
  - correction rate under 1%
  - sync error rate under 1%
  - migration failure rate under 0.5%
- [ ] **iOS:** phased release.

**After release:**

- [ ] Rule changes go testers → pct5 → pct25 → all, independently of app releases.
- [ ] The correction queue is triaged daily for 2 weeks.
- [ ] The legacy-route cutoff date is announced and set in `config.js`.
- [ ] The tag `sms-v2-rc-flagged` (the last candidate built before WP-17 removed the flag) is kept until the cutoff date.

## Rollback and kill switches

Every switch below works without an app release, except the last one.

| Problem | Switch | Effect | Who |
| --- | --- | --- | --- |
| One bad rule | Pause or roll back on the Rules page (or auto-pause) | Phones get the previous version on their next bundle check: within 6 hours, or at next app start | Admin |
| A bad bundle overall | Republish the previous bundle | Same as above | Admin |
| v2 ingestion failing on the server | Turn `sms_pipeline_v2_enabled` off | v2 routes return `404`. Phones keep everything in their outbox and upload when it is back on; nothing is lost. | On-call |
| AI drafting misbehaving or too costly | `SMS_V2_AI_RPM=0` | Templates queue; no AI calls | On-call |
| Attestation wrongly rejecting real devices | `SMS_V2_ATTESTATION_MODE=monitor` | Requests accepted, with lower limits | On-call |
| Migration wrong for one user | `sms_v2_unsupersede(profile_id)` | That user's legacy rows are visible again | Admin or support |
| Signing key exposed | Key rotation runbook (WP-13) | New key signs, old key removed in the next release | Owner |
| Critical app bug after release | Halt the staged rollout, then ship a hotfix. In an emergency before the cutoff date, rebuild from `sms-v2-rc-flagged` with the flag off; the legacy routes still work until then. |  | Owner |
