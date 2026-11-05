# Runbook: dark deploy of the SMS v2 server (flag OFF)

**Status:** plan only. Nothing in this document has been run against production, and no agent may run it. Every step marked **OWNER** needs the owner's explicit go-ahead.

**Superseded by the fresh-start release:** this plan describes the earlier dark deploy next to live legacy apps. The fresh-start release has no old apps, no legacy SMS routes, no `426` gate, no client build flag, and no `gemini-worker` or `sms-learning-worker` containers. Only the server flag `sms_pipeline_v2_enabled` and the migration list below still apply.

**Goal:** put the v2 server code and the 11 `*sms_v2*` migrations on the shared production host with `sms_pipeline_v2_enabled` OFF, so live Android users and the remote developer see no change, and nothing can write v2 data. The app and the flag come later (see Test and release).

**Warning, read first.** The deploy workflows replace the **one** production host and database. `deploy-pushed-branch.yml` says so in its own header ("production replacement, not an isolated staging deployment"). There is no staging path. Everything below follows from that.

## 1. What changes on the host

Diff between the last production deploy and `sms-v2/main` (production line tip `6c17d46`, `[deploy-prod]`), outside `docs/`, `app/`, `packages/`, `tools/`:

| Area | Change |
| --- | --- |
| Migrations | 11 new files, 871 lines, **additions only**. No existing migration is edited. |
| API image | New code under `api/src/sms_v2/`, vendored `api/sms_v2_assets/` (contracts, gates), 2 new dependencies (`ajv`, `ajv-formats`), `SMS_V2_CONTRACTS_DIR` / `SMS_V2_GATES_PATH` env set in the Dockerfile. |
| Legacy routes | `api/src/index.js` (about 22 changed lines): the `registerSmsV2(...)` line, `status` guards on several existing queries, plus `event_id, pipeline_version` added to the transaction list/detail SELECT. Also `self_transfer.js` and `transaction_splits.js` (+2/-2 and +4/-2, the same status guard). |
| Admin routes | `api/src/admin/routes.js` and `route_manifest.js` register `/admin/sms/v2/*` on the private admin app (all behind the flag guard too). |
| Compose, deploy scripts, workflows | **No change** to `docker-compose.prod.yml` or `deploy/*`. No new container, worker or cron. The v2 job scripts (`run_sms_v2_rule_jobs.js`, `run_sms_v2_templates.js`) are not scheduled. |
| Env | **No new required variable.** A missing rule-signing key only makes rule routes answer 503 (they answer 404 first while the flag is off). `GEMINI_API_KEY` is read only by the template worker, which is not started. |

Startup risk: `registerSmsV2` throws if the contracts are missing. They are copied into the image (`COPY sms_v2_assets`), and `scripts/sync_sms_v2_assets.js` plus `npm run check` keep them in step. Verify in pre-checks (section 5).

## 2. The new migrations

Read from the SQL. "Old apps" means the shipped Android build (no `X-App-Version`, legacy routes only).

| # | File | What it does | Can it affect old apps? |
| --- | --- | --- | --- |
| 1 | `20261110120000_sms_v2_rules` | 7 new tables (`sms_v2_rules`, `_rule_cohorts`, `_bundles`, `_bundle_parts`, `_testers`, `_rule_stats_daily`, `_rule_stats_profile_daily`), forced RLS admin-only, 4 `pandapay.sms_v2_*` functions (security definer, `REVOKE ... FROM PUBLIC`), grants to `app_user` / `pandapay_admin_api` when those roles exist. | No. New objects only. |
| 2 | `20261111120000_sms_v2_core` | 4 new tables (`sms_v2_instruments`, `_facts`, `_events`, `_ledger_entries`) with forced owner RLS. **On `transactions`:** `ADD COLUMN event_id text`, `ADD COLUMN pipeline_version smallint NOT NULL DEFAULT 1`, partial unique index `uq_transactions_profile_event (profile_id, event_id) WHERE event_id IS NOT NULL`. **`ALTER TYPE txn_entry_kind ADD VALUE 'refund'`.** | Columns: additive, default `1` / `NULL` for every existing row (verified, section 4). **Enum value `refund`: harmless until a row uses it; v2 projection is the only writer and is flag-gated.** Once a profile has a `refund` row, a v1 app would read it as spending; Lane G makes the server answer `transfer` to any client that does not send `X-Sms-Pipeline: v2` (finding LANE-D-1, section 4). The legacy create route still rejects `entryKind=refund` (`TXN_ENTRY_KINDS`). There is no `unknown` entry kind in the enum; an `unknown` v2 event never produces a `transactions` row. |
| 3 | `20261112120000_sms_v2_private_admin` | Restrictive RLS policies and grants on the rule tables for `pandapay_admin_api`; replaces `sms_v2_rollup_rule_stats`. Needs role `pandapay_admin_api` (created by `20261030100000_private_admin_authority`). | No. |
| 4 | `20261112130000_sms_v2_security` | `sms_v2_rate_counters` table, `pandapay.sms_v2_consume_rate` function. | No. |
| 5 | `20261112140000_sms_v2_templates` | 5 template tables and a sequence, 5 functions, **`AFTER INSERT` trigger `sms_v2_revoke_template_consent` on `user_consents`** (fires only for `purpose = 'sms_shared_learning'`, and only acts on a withdrawal), delete trigger on its own table. | The `user_consents` trigger runs inside the old app's `POST /consents` for that purpose. It is `SECURITY DEFINER`; verified that grant and revoke through the legacy route behave identically (section 4). |
| 6 | `20261112150000_sms_v2_corrections` | `sms_v2_correction_cases` table (RLS for `app_user` and the admin role), sequence. | No. |
| 7 | `20261112160000_sms_v2_correction_consent` | Function plus **`AFTER INSERT OR UPDATE OF granted, granted_at` trigger on `user_consents`** (same purpose filter) that erases contributed correction evidence on withdrawal. | Same as row 5. |
| 8 | `20261112170000_sms_v2_supersede` | **`ALTER TYPE txn_status ADD VALUE 'superseded'`**, `ADD COLUMN transactions.superseded_by_event_id text REFERENCES sms_v2_events`, a partial index, trigger `sms_v2_protect_superseded_transaction` (`BEFORE UPDATE OF status, superseded_by_event_id`, acts only when `OLD.status = 'superseded'`), and `pandapay.sms_v2_unsupersede(profile)`. | Nothing is superseded until WP-16's history rollout runs under the flag. Legacy list/detail/report queries already exclude `superseded`; PATCH, ignore and restore on a superseded row return 409/404 and never 5xx (tests, section 4). |
| 9 | `20261112180000_sms_v2_category_drafts` | New admin-only table. | No. |
| 10 | `20261112190000_sms_v2_consent_lock_alignment` | Replaces two functions; **drops and recreates** the `user_consents` trigger from row 5. | As row 5; the drop and create are in one transaction. |
| 11 | `20261112200000_sms_v2_correction_update_guard` | `BEFORE UPDATE` trigger on `sms_v2_correction_cases` (only `app_user`). | No. |

Locks and size (for the maintenance window): `ADD COLUMN ... DEFAULT 1` is a metadata change on PostgreSQL 11 and later. The two `CREATE INDEX` statements on `transactions` and the foreign key on the new column scan the table once under a lock that blocks writes; the writers are fenced during migration, so it costs time, not correctness. A 50,000-row in-place upgrade took seconds on a laptop; measure on the restored production copy to size it (section 5).

Nothing in the 11 files inserts the feature flag. **`feature_flags` has no `sms_pipeline_v2_enabled` row, and a missing row is OFF** (`guard.js`). Never insert it during this deploy.

`ALTER TYPE ... ADD VALUE` cannot be undone in PostgreSQL. The two new enum values stay forever, so "rollback" never means "remove the schema" (section 9).

## 3. Ordering against DEPLOY.md

`deploy/deploy.sh` already encodes the safe order; do not hand-run anything in a different order. In sequence (from the script):

1. Fetch the commit; require it equals the **current tip of the source ref** and **descends from the server's `HEAD`** (a rollback or divergent history is refused before downtime).
2. Build target images (`api`, `auth`, workers, `backup`, `db-migrate`) **before** downtime.
3. Read-only product migration and auth contact preflight (`product_migrate.js --check`: applied / legacy / pending counts, checksum check, baseline).
4. Inventory the `pandapay-prod` Compose project; unknown or unlabeled containers abort before downtime.
5. **Writer fence:** stop `auth`, `api`, `rewards-worker` (30 s graceful stop). The window is bounded (default 30 min, `DEPLOY_MAINTENANCE_WINDOW_SECONDS` 300 to 7200).
6. **Paired encrypted product/auth backup**, verified (offhost needs both destinations, or `BACKUP_MODE=local`). The script continues only after the backup confirms.
7. Replace the working source (`git reset --hard`).
8. **Migrate** (`db-migrate`): the 11 SMS v2 files plus any other pending files, in the product ledger, transactionally.
9. Start the prebuilt images with readiness checks, then final `/ready` on `127.0.0.1:4000` and `127.0.0.1:3210`.

Failure handling: before source replacement the script resumes the old writers by container ID; after it, the writers **stay stopped** ("recover forward, do not start the old images"), so a failed migration is an outage until a forward fix is deployed. That is why the rehearsal in section 5 is mandatory.

The SMS v2 migrations need no special position: they only add. They must still run **before** the new API starts (the new `GET /transactions` selects `event_id, pipeline_version`, and the new status guards compare against `superseded`); `deploy.sh` guarantees that.

## 4. Old-app compatibility, proved on a scratch database

`api/test/sms_v2/old_app_compat_pg.test.js` boots the real `api/src/index.js` on a scratch PostgreSQL (all migrations applied) with a stub auth service, and replays a request script of about 30 calls modelled on the shipped app (`api/test/sms_v2/compat/scenarios.js`: transactions create and list, from-sms batch and replay, sms facts, rules active, cards, spend reports, home summary, monthly reports, budgets, consents).

Evidence (details in the Lane D handoff):

- **Parity with production:** the same script against the production line (`git archive 6c17d46 api`, schema migrated without the 11 files) and against this branch (full schema) gives identical status codes and bodies, after dropping only the two additive keys `event_id` and `pipeline_version`.
- **Rollback direction:** the old code (`6c17d46`) run against the **upgraded** schema (a 50,000-row table upgraded in place) also gives identical answers. So reverting the code leaves a working system.
- **Idempotent upgrade:** a second migration run changes nothing (`applied=149 pending=0`); the 50,000-row table hashes identical before and after, and every row reads `pipeline_version=1, event_id=NULL`.
- **Profiles with v2 rows:** active list, deleted list, detail, spend-by-category, spend-report (month and year), home summary and monthly reports are identical to a twin profile without the `refund` and `superseded` rows. Legacy writes never return 5xx on those rows.

**Two findings**, both **fixed by Lane G** (`docs/sms-pipeline-v2/handoff/LANE-G.md`). They only mattered once a profile has v2 rows (flag on for that user), never in the dark deploy itself. The former `todo` tests are now ordinary passing tests in `old_app_compat_pg.test.js`:

1. **LANE-D-1 (fixed).** A v1 app maps an unknown `entry_kind` to **spend**, so a v2 `refund` row would show as spending. The server now answers `transfer` in place of `refund` in every JSON body (list, detail, patch, ignore, restore, duplicate and bulk-category answers, sync pull) unless the request carries `X-Sms-Pipeline: v2`. The v2 app sends that header only when its pipeline is enabled, so a v2 build with the flag off is served like an old app. Output only: stored rows, `spend-by-category`, `spend-report`, `home-summary` and `monthly-reports` are identical with or without the header. The CSV export still prints the stored kind (`refund`) in its "Kind" column; no app parses it.
2. **LANE-D-2 (fixed).** The duplicate branch of `insertTransactionAndUpdateState` now returns the stored row untouched (same fields as before, no observation recorded, no card state moved) when `pipeline_version = 2` or `status = 'superseded'`. Rows with `pipeline_version = 1` follow the old path unchanged (tested).
3. **App identifies itself (new).** Every request the v2 app makes to the PandaPay API origin carries `X-App-Version: <version>+<build>` (package_info_plus, fallback `--dart-define=PANDAPAY_APP_VERSION`, else the header is omitted), plus `X-Sms-Pipeline: v2` only when `SMS_PIPELINE_V2` is on. (Fresh-start update: the app now always sends `X-Sms-Pipeline: v2`, and the legacy version gate and its 426 answer were deleted. `SMS_V2_FIRST_APP_VERSION`, `LEGACY_SMS_CUTOFF_DATE` and `LEGACY_SMS_BLOCK_MISSING_VERSION` are no longer read; do not set them. See `bundle-release.md`, "Legacy routes".)

**Gate (now met in code):** LANE-D-1 and LANE-D-2 are fixed, so the flag no longer needs to be withheld on their account. Keep the owner decision on the mapping (`transfer` was chosen over `income`; see Lane G handoff) and re-run the old-app smoke below before the first flagged user.

## 5. Pre-checks (before any push)

All read-only. Run from a clean checkout of the candidate commit.

1. **Candidate is a descendant of what the host runs.** On the host (or via the `[inspect-backups]` job, which prints `HEAD`): `git -C /home/ubuntu/apps/pandapay rev-parse HEAD`. Then, locally: `git merge-base --is-ancestor <host HEAD> <candidate>` must succeed. The local `codex/ios-shortcuts-prototype` ref in some checkouts is stale (it was at `234ef00`, before the last deploy); always compare with the remote, not the local ref.
2. **The candidate is exactly the tip you will push** (the host requires target = current tip of the source ref).
3. **Migration rehearsal on restored production data** (DEPLOY.md already requires an actual-data PostgreSQL restore for this security batch). Restore the latest paired backup to the independent recovery host, then with the same migration role as production:
   - `node db/scripts/product_migrate.js --check` (expect `pending=` the 11 files plus anything else new);
   - run the migrations; run `db/tests/2026111*_sms_v2_*_test.sql`; run it a second time (no-op);
   - record how long the `transactions` index builds and foreign key took, and size `DEPLOY_MAINTENANCE_WINDOW_SECONDS` from it;
   - confirm the migration login can `GRANT ... TO pandapay_admin_api` (managed database roles caused trouble in `4832559`).
4. **Prerequisites present in production:** role `pandapay_admin_api` exists and `pandapay.admin_has_permission(text)` exists; `app_user` exists; `txn_entry_kind` has exactly spend, income, investment, transfer and `txn_status` has no `superseded`; `feature_flags` has no `sms_pipeline_v2_enabled` row.
5. **Image sanity:** the api image has `/app/sms_v2_assets/contracts/sms/v2/fact.schema.json`, `event.schema.json`, `api/facts_batch.request.schema.json`; `node scripts/sync_sms_v2_assets.js --check` (or the `npm run check` step) passes.
6. **CI is green** on the candidate, including `node --test --test-concurrency=1 test/sms_v2/*.test.js` and the `20261111120000_sms_v2_core_test.sql` smoke step.
7. **Backups:** `BACKUP_AGE_RECIPIENTS_FILE` readable, both offhost destinations (or `BACKUP_MODE=local`, accepting that it does not survive losing the disk), and the private recovery identity can decrypt a recent backup. DEPLOY.md: the script refuses to fence writers if the backup cannot be made.
8. **People:** tell the remote developer and any active testers the maintenance window (writers are stopped for the duration; API and auth are unavailable). Pick a low-traffic hour.
9. **Commit-message hygiene** (section 6): the tip commit message of the push must contain `[deploy-prod]` and none of the other markers.

## 6. What triggers a deploy (read before pushing anything)

| Push | Effect |
| --- | --- |
| Any `sms-v2/*` branch (including `sms-v2/main`) | **No deploy.** `deploy-pushed-branch.yml` listens only on `codex/ios-shortcuts-prototype`; `build-and-test.yml` runs on `main` and `master` pushes and on pull requests. |
| `codex/ios-shortcuts-prototype`, tip message **without** `[deploy-prod]` | No deploy. |
| `codex/ios-shortcuts-prototype`, **tip** commit message contains `[deploy-prod]` | Runs the full Build and test gate, then **replaces production** with that exact commit (deploys the pushed commit; only `github.event.head_commit.message`, the tip, is inspected). Needs the `production` environment and its secrets. |
| `codex/ios-shortcuts-prototype`, tip contains `[baseline-approved]` | Also adopts the reviewed migration baseline (`MIGRATION_ADOPT_LEGACY_CHECKSUMS=true`). Do not add this unless the owner asks for baseline adoption. |
| Same branch, tip contains `[prepare-local-backup]`, `[inspect-backups]` or `[inspect-baseline]` | Runs those one-off host jobs (they touch the host over SSH). Avoid unless intended. |
| **`master`** (any push or merge) | `Build and test` runs, then `deploy-prod.yml` (`workflow_run`, no marker needed) **deploys the master tip to production automatically** after tests pass. Merging `sms-v2/main` into `master` is therefore itself a production deploy. |
| Manual `workflow_dispatch` of `deploy-prod.yml` | Master only; needs a successful Build and test for the exact commit. |

Both paths end in the same `deploy/deploy.sh`, so the safety sequence in section 3 applies either way. Recommended path: a **dedicated merge commit on `codex/ios-shortcuts-prototype`**, whose message ends with `[deploy-prod]`, pushed once the owner approves. Do not merge to `master` for this step. Never push a branch whose tip message contains a marker by accident (for example a squash that copies `[deploy-prod]` from an old commit message).

## 7. Procedure (OWNER)

1. **OWNER approves** the items in section 10.
2. Merge the candidate into the production line locally (not pushed): `git checkout codex/ios-shortcuts-prototype` (after fetching the remote and fast-forwarding), `git merge --no-ff sms-v2/main` with a message that does **not** contain `[deploy-prod]` yet. Re-run section 5 checks 1, 2 and 6 on that merge commit. Then amend the message to end with `[deploy-prod]` only at the moment of pushing.
3. **OWNER pushes** that one commit to `codex/ios-shortcuts-prototype`. Watch the Actions run (Build and test, then "Replace production with pushed branch"). Do not start a second run (`concurrency: deploy-prod` queues, it does not cancel).
4. If the run fails: read the failure phase. Before source replacement the old writers are resumed automatically; after it they stay stopped, and you recover forward (section 9). Do not start the old images by hand.
5. Run the post-deploy checks.

## 8. Post-deploy checks (all read-only)

Immediately:

- The workflow's own step: `curl -fsS http://127.0.0.1:4000/ready` and `http://127.0.0.1:3210/ready` on the host.
- Unauthenticated, from outside, expect **404** (the flag guard answers before authentication): `curl -s -o /dev/null -w '%{http_code}\n' https://<api-host>/sms/v2/sync` (and `POST .../sms/v2/facts:batch`, `.../sms/v2/rules`). A `401` or `200` means the flag is on: stop and investigate.
- Database: `SELECT count(*) FROM schema_migrations WHERE filename LIKE '%sms_v2%'` returns 11; `SELECT * FROM feature_flags WHERE key='sms_pipeline_v2_enabled'` returns **0 rows**; `SELECT count(*) FROM sms_v2_events` and `sms_v2_facts` return 0; `SELECT count(*) FROM transactions WHERE pipeline_version <> 1 OR event_id IS NOT NULL OR status::text = 'superseded'` returns 0.
- Next 30 minutes: container logs show no `sms_v2` errors; error rate and latency on the legacy routes match the previous hour.

Old-app smoke (the rollout gate in Test and release: "Today's production app is checked against production using the legacy routes"): on a real Android phone with the **currently published** build and a test account, open Home, Activity, a card, Insights; import or receive one SMS and confirm it appears once; edit a note; ignore and restore a transaction; check the monthly report. The remote developer repeats the flows they use.

The next daily encrypted backup completes and verifies.

## 9. Rollback

The flag is already off, so there is **nothing to switch off**; the new code is inert for every user. Decide in this order:

| Situation | Action |
| --- | --- |
| The deploy script fails before source replacement | The old writers are resumed by the script. Confirm `/ready`; fix the cause; redeploy. |
| It fails after source replacement (migration error) | Writers stay stopped on purpose. Fix forward: correct the migration in a **new** migration file (never edit an applied one), redeploy the new tip through the same workflow. Restore from the paired backup only as a last resort, on the recovery procedure in `db/backup/README.md`. |
| Deployed, but a legacy route misbehaves | Ship a **forward revert commit** of the offending change (`git revert`) through the same workflow. `deploy.sh` refuses a target that is not a descendant of the server `HEAD`, so "deploy the old SHA" is blocked by design. |
| Code is reverted but the schema stays | Supported and tested: the production-line code (`6c17d46`) answers the legacy script identically on the upgraded schema. Leave the tables, columns and the two enum values; they are inert. There is **no down migration**, because enum values cannot be dropped. |
| Someone turned the flag on and v2 rows exist | Turn `sms_pipeline_v2_enabled` off (v2 routes return 404; phones keep their outbox). Rows stay; `pandapay.sms_v2_unsupersede(profile_id)` restores superseded legacy rows (`learning.publish` runtime only). See Test and release, Rollback and kill switches. |

## 10. What the owner must approve

1. The window: date, time, and who is told (live Android users and the remote developer; API and auth are down while writers are fenced).
2. Pushing a commit with `[deploy-prod]` to `codex/ios-shortcuts-prototype` (a production replacement), or the alternative of merging to `master`, which deploys automatically. And that neither happens as a side effect of any other push.
3. That the dark deploy ships migrations that add a value to `txn_entry_kind` and `txn_status`, which cannot be undone.
4. The restored-data rehearsal result and the sized maintenance window.
5. The backup mode used for this deploy (offhost, or `BACKUP_MODE=local` with its disk-loss caveat).
6. That the Lane G fixes for LANE-D-1 and LANE-D-2 are accepted, including the mapping for old apps (refund shown as `transfer`; `income` was the alternative).
7. That the flag stays off after this deploy; enabling it for testers is a separate approval.

## 11. Rehearsing locally (no production access)

Used to produce the evidence above; safe to repeat. Scratch PostgreSQL on loopback only, dropped afterwards.

```
export LC_ALL=en_US.UTF-8
initdb -D "$TMPDIR/pgscratch" -U postgres --auth=trust -E UTF8
pg_ctl -D "$TMPDIR/pgscratch" -o "-p 55432 -k /tmp -c listen_addresses=127.0.0.1" -l "$TMPDIR/pg.log" start
psql -h 127.0.0.1 -p 55432 -U postgres -c 'create database pandapay' -c 'create database pandapay_old'
# full schema
NODE_ENV=development DB_SSL=false ADMIN_DATABASE_URL=postgresql://postgres:postgres@127.0.0.1:55432/pandapay \
  APP_USER_PASSWORD=app_user_dev_pw REWARD_WORKER_DB_PASSWORD=reward_worker_dev_pw \
  SMS_LEARNING_WORKER_DB_PASSWORD=sms_learning_worker_dev_pw node db/scripts/product_migrate.js
# production-line schema and code: git archive 6c17d46 db api into a scratch dir (link node_modules), migrate pandapay_old from it
cd api && SMS_V2_TEST_DATABASE_URL=postgres://postgres@127.0.0.1:55432/pandapay \
  SMS_V2_COMPAT_OLD_DATABASE_URL=postgres://postgres@127.0.0.1:55432/pandapay_old \
  SMS_V2_COMPAT_OLD_API_DIR=<scratch>/old/api JWT_ACCESS_SECRET=ci_only_not_a_real_secret \
  node --test test/sms_v2/old_app_compat_pg.test.js
pg_ctl -D "$TMPDIR/pgscratch" stop && rm -rf "$TMPDIR/pgscratch"
```

The `app_user` passwords are the docker-compose development literals; never reuse them anywhere real.
