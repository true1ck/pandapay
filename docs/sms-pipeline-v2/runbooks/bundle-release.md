# Bundle release runbook

How the first SMS v2 rule bundle goes from `rules/sms/v2` to phones, and how to undo it. One script does the steps in order and stops at the first failure: `api/scripts/release_sms_v2_bundle.js`. It runs on an administration machine, never on a phone and never from CI. It does not push, deploy or change a flag.

Later rule changes do not use this script. They go through the Rules page (draft, golden gate, publish by cohort); see WP-09 and WP-11.

## Before you start

- The release gates in `test-and-release.md` pass and the checklist's "Before release" items are done.
- `SMS_RULES_SIGNING_KEY` (Ed25519 private PEM) and `SMS_RULES_KEY_ID` are in your shell environment from the secret store. Generating and rotating the key is in `signing-keys.md`. The public key must already ship in the app one release ahead.
- `ADMIN_API_DATABASE_URL` is the private `admin_api_runtime` login, and you know an active owner's `admin_users.id` (needs `learning.publish`).
- The v2 migrations are applied, including `20261112215000_sms_v2_release_metrics.sql` (the metrics page needs it).
- `dart` is on the path (the tools CLI is Dart).

## 1. Dry run (the default)

```sh
node api/scripts/release_sms_v2_bundle.js
```

It prints one line per step and writes its files to a fresh temporary folder (or `--work-dir`).

| Step | What it does | Stops when |
| --- | --- | --- |
| build | `sms_rules build` merges `rules/sms/v2` into one canonical bundle and runs every rule example | any example disagrees with the engine, or the merged bundle breaks the contract |
| golden gate | `sms_rules golden` with profile `release`, the committed baseline (`tools/sms_golden/reports/latest.json`) and `--require-stages` | a gate fails, a metric drops below the baseline, or a stage is not available |
| contract check | the server's bundle validator accepts the bundle | it does not |
| signing key | `SMS_RULES_SIGNING_KEY` and `SMS_RULES_KEY_ID` load as an Ed25519 key | dry run only warns; `--apply` refuses |
| import | skipped in a dry run | |

The golden command only loads signed-shape bundles, so the script signs the golden copy with a random throwaway key made for that run and deleted straight after. The production key never reaches the Dart tools. The report is at `<work-dir>/golden/report.json` and `report.md`; attach it to the release record.

Use `--profile m1` only for a rehearsal on a pre-release rule set. A real release uses the default `release`.

## 2. Apply

```sh
node api/scripts/release_sms_v2_bundle.js --apply --admin-id <admin_users.id>
```

`--apply` first checks, before building anything, that the admin id is a UUID, the signing key loads and `ADMIN_API_DATABASE_URL` is set. Then it repeats the dry-run steps, and only if all pass it runs `import_sms_v2_rules.js`, which:

1. stores every rule as version 1 on cohort `all` (rules already there are left alone) and the non-rule parts (senders, ignore, link and category rules, merchant aliases);
2. signs with the key from the environment and mints a bundle for each cohort whose content changed: `all`, `pct25`, `pct5`, `testers` (the first import gives bundles 1 to 4 with the same content). The signed copy is stored with the bundle; the public API serves that copy and never signs;
3. writes an audit row.

The script then checks that all four cohorts were minted, or that nothing was new. Running it again with the same rules is safe and reports "nothing new to mint". The key is never printed, written to a file or put on a command line, and anything a child process echoes back is filtered.

## 3. After the import

- Rules page: one active bundle per cohort, all signed with the expected key id.
- The hourly job `run_sms_v2_rule_jobs.js` is scheduled on the maintenance host (it also re-signs served bundles before their 7-day expiry; see `signing-keys.md`). Run it once by hand now, check its output, and check that `GET /sms/v2/rules` answers 200 for a tester.
- `GET /admin/sms/v2/metrics`: `bundleChecks.active` lists the four bundles; `bundleChecks.checks` starts rising as phones check (about one check per phone every 6 hours).
- On a tester phone, force a bundle check and confirm the version arrives and verifies (the phone ignores a bundle whose signature or key id it does not trust).
- Then follow the release checklist: flag on for testers, then everyone.

## Rollback

| Situation | Action |
| --- | --- |
| The script stopped before the import | Nothing changed on the server. Fix the cause (it names the step) and run it again. |
| One bad rule after release | Pause or roll back that rule on the Rules page. Phones get the previous version within 6 hours or at next app start. |
| The whole bundle is bad | On the Rules page, republish the previous bundle (rollback). Do not delete rows. |
| Import produced the wrong bundle versions | Do not re-import over it. Use the Rules page rollback, then correct `rules/sms/v2` and release again as a rule change. |
| v2 ingestion should stop altogether | Turn `sms_pipeline_v2_enabled` off. Phones keep everything in their outbox. |
| Signing key exposed | "Revoking a leaked rule key" in `signing-keys.md`: switch the maintenance environment to the spare key and run the hourly job once. |
| `/sms/v2/rules` answers 503 `bundle_unavailable` | The served copy is missing or expired. Run `run_sms_v2_rule_jobs.js` on the maintenance host and fix whatever stopped the hourly job. |

## Legacy route cutoff (WP-17)

The legacy SMS routes (`/transactions/from-sms/batch`, `/sms/facts`, `/ai/jobs*`, `/sms/rules/active`) answer `426 Upgrade Required` only after a cutoff date, and only to an `X-App-Version` below the first v2 build. Off by default. To announce and set it, after release:

```
LEGACY_SMS_CUTOFF_DATE=2027-01-15        # YYYY-MM-DD means 00:00 UTC that day
SMS_V2_FIRST_APP_VERSION=<first v2 build, e.g. 1.1.0+120>
```

Both go in the API environment and take effect on restart; the date is compared on every request. Setting the date without the version stops the server at startup. Builds before v2 send no `X-App-Version`, so after the cutoff they count as old; set `LEGACY_SMS_BLOCK_MISSING_VERSION=false` to let header-less callers through. To switch the gate off again, unset `LEGACY_SMS_CUTOFF_DATE`. The AI worker's `/ai/jobs/lease`, `/heartbeat`, `/result`, `/retry` and `/fail` calls are never gated.
