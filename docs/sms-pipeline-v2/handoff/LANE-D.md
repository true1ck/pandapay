# Lane D handoff: release safety

Branch `sms-v2/lane-d-release-safety`, from `sms-v2/main` (dc76789). New files only; no existing file was edited. Local only: nothing pushed, deployed or flagged; the scratch PostgreSQL was dropped afterwards.

## Delivered

| Item | Path |
| --- | --- |
| Dark-deploy runbook | `docs/sms-pipeline-v2/runbooks/dark-deploy.md` |
| Old-app compatibility test | `api/test/sms_v2/old_app_compat_pg.test.js`, helpers `api/test/sms_v2/compat/harness.js`, `scenarios.js` |
| Findings and fix proposals | `docs/sms-pipeline-v2/requests/LANE-D-old-app-compat.md` |
| Hard-coded logic guard | `packages/pandapay_domain/test/sms_v2/hardcoded_logic_guard_test.dart` |
| WP-17 deletion checker (read-only) | `scripts/check_wp17_deletions.py` |

## Findings that could break old apps

1. **Dark deploy itself is safe for old apps.** With every `*sms_v2*` migration applied, the production-line server (`6c17d46`) and this branch's server give identical answers to a ~30-call legacy script (parity test), including the old code on the upgraded schema (rollback direction). A 50,000-row `transactions` table upgraded in place was unchanged (`pipeline_version=1`, `event_id` NULL); a second run is a no-op.
2. **LANE-D-1 (needs owner decision before any user gets the flag).** `GET /transactions` returns `entry_kind: "refund"` for v2 refund rows; the shipped app's `TxnEntryKind.fromJson` falls back to `spend`, so a refund is shown and totalled as spending in an old app. Old apps send no `X-App-Version`, so the header cannot identify them; WP-17's `426` middleware must treat "absent" as legacy and the v2 app must send it. Proposed fix: map `refund` to `transfer` for legacy clients in list, detail and PATCH answers.
3. **LANE-D-2.** A legacy `POST /transactions/from-sms/batch` replay of an SMS already projected by v2 rewrites that row's `entry_kind` (refund becomes transfer in the test) because the duplicate branch of `insertTransactionAndUpdateState` ignores `pipeline_version`/`status`. Proposed fix: return the stored row untouched when `pipeline_version = 2` or `status = 'superseded'`.
4. Both have `todo` tests (they run and print the failure, and do not fail the suite).
5. **Deploy trigger hazards** (documented in the runbook): a push to **`master`** deploys to production automatically after Build and test, with no marker. On `codex/ios-shortcuts-prototype`, only the **tip** commit message is inspected for `[deploy-prod]` (also `[baseline-approved]`, `[prepare-local-backup]`, `[inspect-backups]`, `[inspect-baseline]`). Pushes to `sms-v2/*` deploy nothing. `deploy.sh` refuses any target that does not descend from the server's `HEAD`, so a code rollback is a forward revert commit. The local `codex/ios-shortcuts-prototype` ref in the checkout was stale (`234ef00`, before the last deploy `6c17d46`); compare against the remote before the descendant check.
6. Two enum additions (`txn_entry_kind: refund`, `txn_status: superseded`) are irreversible; "rollback" never removes schema.
7. The flag cannot be switched on by a migration: no `feature_flags` row is inserted (test asserts it), and a missing row is off.

## How the old-app test works

Boots the real `api/src/index.js` as a child process against a scratch Postgres (migrated with `db/scripts/product_migrate.js`) and an in-process stub of the auth service, with `app_user` connections so row-level security applies. Skipped unless `SMS_V2_TEST_DATABASE_URL` is set (so CI is unchanged). With `SMS_V2_COMPAT_OLD_DATABASE_URL` and `SMS_V2_COMPAT_OLD_API_DIR` (a `git archive 6c17d46 api` with `node_modules` linked, and a database migrated from `git archive 6c17d46 db`) it also runs the PARITY test. The app role password defaults to the docker-compose development literal; override with `SMS_V2_COMPAT_APP_USER_PASSWORD`. Loopback hosts only.

Tests (10): enum labels (no `unknown` kind), new columns default to v1 values, flag off and v2 routes 404, legacy script has no 5xx and creates no v2 rows, PARITY, active/deleted/detail/report equality against a twin profile, legacy writes on superseded and v2 rows never 5xx, replay over a superseded row stays hidden, plus the two `todo` findings.

## Hard-coded logic guard

Fails on a brand, bank or merchant name in a string literal or identifier (comments ignored, camelCase split) in non-test Dart under `packages/pandapay_domain/lib/src/sms_v2` and `app/lib/features/sms_v2`. About 1 second. Allow-list lives in the test, each entry with a reason:

- permanent: `template/vocabulary.dart` (redaction vocabulary, never classifies), `evaluation/family.dart` (golden metric slicing only);
- **debt that exists today** (reported on every run, restricted to the listed names so new ones still fail): `engine/transforms.dart` (payment-gateway and QR prefixes, a port of the old sanitizer), `category/merchant_key.dart` (gateway words), `instruments/instrument_resolver.dart` (`defaultUpiAppSenderBrands`: SBIUPI, PHONPE, GPAY, GOOGPAY, BHIM), and `app/lib/features/sms_v2/instruments/issuer_slugs.dart` (bank name to slug table). These are real hard-coded names in code; Codex owns those areas, so they were not touched. They should move to rules or the bundle.

## WP-17 deletion check

`python3 -I scripts/check_wp17_deletions.py [-v] [--json] [--strict]`. Current result: all 10 candidate files still have live importers (mainly `providers.dart`, `financial_store.dart`, `sms_import_store.dart`, the iOS import files and `router.dart`); **no Gmail, email, IMAP or card-discovery file imports any of them, directly or through an import chain** (chains through the `providers.dart` and `router.dart` hubs are ignored, since WP-17 trims those). Prints the legacy routes (`/transactions/from-sms/batch`, `/sms/facts`, `/ai/jobs*`, `/sms/rules/active`) with their server definitions and app, script and tool references, and the importers of `gemini_worker.js`, `sms_parser.js`, `merchant_category.js` (`index.js`, `import_resolvers.js`, `subscription_parser.js`, and scripts; none of the email/IMAP modules import them). `--strict` exits 1 if a frozen importer appears.

## Test results

- New: `old_app_compat_pg.test.js` 10 tests with the scratch DB (8 pass, 2 `todo` findings, PARITY included when the old world is configured); 10 tests skipped as one file when the env is absent. Guard test 3 pass.
- `cd packages/pandapay_domain && dart test`: 1007 pass.
- `cd api && JWT_ACCESS_SECRET=ci_only_not_a_real_secret npm test`: 1418 tests, 1414 pass, 4 skipped, 0 fail.
- `node --test --test-concurrency=1 test/sms_v2/*.test.js` (the CI step) without a database: 149 tests, 104 pass, 45 skipped (needs DB), 0 fail.

## Follow-ups for the orchestrator

- Decide LANE-D-1 and LANE-D-2 (fix before the flag, or limit testers to the new app).
- Make the v2 app send `X-App-Version`, and have the WP-17 middleware treat absent as legacy.
- Dark deploy rehearsal on restored production data is still required (runbook section 5); this lane only used synthetic data.
- Move the four debt entries of the guard into rules or the bundle, then delete their allow-list rows.
