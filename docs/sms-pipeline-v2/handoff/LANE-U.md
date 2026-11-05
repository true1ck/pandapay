# Lane U handoff: security follow-ups (LO-09, LO-10, LO-13, LO-15)

Branch `sms-v2/lane-u-security-2`, from `sms-v2/claude-lanes` (a8a9560). Local only: nothing pushed, deployed or flagged. A scratch PostgreSQL 18 (stub schema plus the rules, security and two new migrations) was used to check the SQL and the Postgres store, then dropped. Details are in `../security-audit-2026-11.md`.

## Result

| ID | Status | What changed |
| --- | --- | --- |
| LO-09 | Fixed | The public API serves pre-signed bundles and holds no key. Minting stores the signed copy (`sms_v2_bundles.served_body`); the hourly job `run_sms_v2_rule_jobs.js` re-signs before expiry (under 72 h left, tunable with `SMS_V2_BUNDLE_REFRESH_BEFORE_HOURS`) and on a key id change. The route answers `503 bundle_unavailable` when the stored copy is missing, unsigned, the wrong version or expired. Production start-up logs an error if the key is in the public environment. |
| LO-10 | Binding fixed; replay built, off | A token is bound to the first profile and hashed installation id (`sms_v2_attestation_bindings`, `pandapay.sms_v2_bind_attestation`). Another account or installation is unattested (monitor: half limits, no shared learning; enforce: 403). Limited-use token consumption through Firebase is behind `SMS_V2_APPCHECK_REPLAY_PROTECTION=on` (default off, refuses to start without credentials). `DeviceAttestation.limitedUseHeaders()` added to the app. Monitor behaviour without a token is unchanged. |
| LO-13 | Mitigated | Release-free revocation runbook in `runbooks/signing-keys.md` (spare key shipped ahead, switch key id, run the job). Removing the key from the app still needs a release. |
| LO-15 | Fixed best effort | Production rejects debug-provider tokens (provider-style claim, or app ids in `SMS_V2_DEBUG_APP_IDS`) unless `SMS_V2_ALLOW_DEBUG_APP_CHECK=true`. |
| LO-12, LO-14 | Not in scope | Unchanged. |

Files: `api/src/sms_v2/{bundle_builder,rules_store,rules_route,rule_stats,security,index}.js`, `api/scripts/run_sms_v2_rule_jobs.js`, `api/src/portable_backup/coverage.json`, migrations `20261114100000_sms_v2_presigned_bundles.sql` and `20261114110000_sms_v2_attestation_binding.sql`, `app/lib/features/sms_v2/sync/attestation.dart`, runbooks `signing-keys.md` and `bundle-release.md`.

New tests: `api/test/sms_v2/lane_u_signing.test.js` (9), `api/test/sms_v2/lane_u_attestation.test.js` (14), two in `app/test/features/sms_v2/sync/attestation_test.dart`.

## For the orchestrator

1. **Deploy order**: apply both migrations, run `run_sms_v2_rule_jobs.js` once on the maintenance host (fills `served_body` for existing bundles), then deploy the API and remove `SMS_RULES_SIGNING_KEY` from its environment. Before the job has run the new API answers 503 for old rows. The private admin API still signs at publish time and keeps the key.
2. **Alerting**: the hourly job must run and be alerted on (non-zero exit); an unrefreshed bundle expires after 7 days and the API then fails closed.
3. **Binding in production** defaults to the durable `db` mode and needs the second migration first. Elsewhere it is per process. `SMS_V2_ATTESTATION_BINDING=off` disables it.
4. **Not wired**: the sync client still sends the cached standard token on every route. Wire `limitedUseHeaders()` to `unknown-templates`, `corrections` and `rule-stats` before ever setting replay protection on (`google-auth-library` is also needed). The route-agnostic `headers` callback in `runtime_provider.dart` was left alone (other lane's area).
5. Overlap risk: `rules_store.js` and `rules_route.js` (rules lane) have small edits: `servedBody` on bundle rows, `setServedBundle`, `phoneBundle` returns the served copy, the signer is gone from `registerRules`. `registerRules` ignores a `signer` dependency now.
6. The client-metrics receipt table was not changed; binding lives in the new bindings table and the existing profile plus installation keyed rate counters.
7. Follow-up for LO-13: a phone-side key-rank ratchet (needs bundle store state and a release).

## Verification run

- `cd api && JWT_ACCESS_SECRET=ci_only_not_a_real_secret npm test`: 1441 tests, 1437 pass, 4 skipped, 0 fail.
- `cd api && node --test test/sms_v2/*.test.js`: 213 tests, 162 pass, 51 skipped (Postgres-only suites), 0 fail.
- `cd api && node scripts/check_sms_v2.js`: 30 files OK.
- `cd packages/pandapay_domain && dart test`: all 1047 tests pass.
- `cd app && flutter test --no-pub --concurrency=1 test/features/sms_v2`, flag off and `--dart-define=SMS_PIPELINE_V2=true`: all pass except `pipeline/idempotency_test.dart` "one batch and one-at-a-time agree on every non-IPO event" (extra `refund/ambiguous` key). It fails identically on the untouched base tip a8a9560, so it is not from this lane and belongs to the pipeline or refund work.
- The Postgres-backed `*_pg.test.js` suites were not run (they need the full schema and admin roles); the new SQL and store paths were exercised on the scratch database with an ad hoc script (mint with served copy, refresh, null served body, binding owner/other/cleanup, app_user cannot read the bindings table).
