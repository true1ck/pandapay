# Deployment plan and status: account lock, recovery, device check, reward gate

First written 10 Nov 2026; rewritten the same night (about 02:30 IST) to match what has
actually happened. Each step that changes production says **needs your OK**.

Background: `ACCOUNT_LOCK_AND_RECOVERY_ROLLOUT_2026-11-09.md` (what each switch does),
`EMAIL_PHONE_LOCK_PLAN_2026-11-09.md`, `RECOVERY_FLOW_DESIGN_2026-11-09.md`.

## 1. Status board

| Phase | What | State |
|---|---|---|
| A | Re-integrate and re-test | **Done, in a different way than planned.** Sujay's merges carried my work into `origin/dev` and `origin/prod`; the tests were re-run on the result (section 4). |
| B | Read-only server checks | **Done** 10 Nov. No duplicate mailboxes; `AUTH_PUBLIC_BASE_URL` was added to the server `.env`. |
| C | Push to `master` (CI only) | **Not done.** `origin/master` is at `37723c9`, far behind `dev`. Optional; see section 7. |
| D | Deploy the backend | **Done.** Sujay's push of `8577492` deployed successfully at 01:40 IST. Auth migrations 0015 to 0018 are applied; all new switches are off. A second run for `d267fdb` (app-only changes, same server code) was pushed at 02:17 IST at your request. |
| E | Build and ship the apps | **In progress.** Build `1.0.18+144` (commit `772240c`, local): iPhone compile running; Play internal not yet published. |
| F | Raise minimum version, switch the lock on | Not started. Needs the build on every phone first. |
| G | Device-limit enforcement, reward gate | Not started. Decisions. |

**Production now:** server checkout at `8577492` (before the second run finishes), api and
auth healthy, auth ledger at `0018_account_recovery`, 14 live accounts,
`app_status.min_supported_version = 1.0.17`.

## 2. How it got here (10 Nov, IST)

| Time | Event |
|---|---|
| 00:48 | A merge of `origin/dev` into local `dev` is made under your name (not by me). My unpushed commits reach `origin/dev` and then `origin/prod` through Sujay's merges. |
| 01:28 | Push of `2f4d704` to `prod` starts a deploy run. Its "Security migrations" test job fails (a test schema lacked migration 0016's column, caused by my Google identity change). |
| 01:31 | You asked me to cancel it. Cancelled during the tests, **before the deploy job ran**. Production was checked read-only and untouched. |
| about 01:40 | Sujay pushes `8577492` (the test fixed there too). Deploy **succeeds**; migrations 0015 to 0018 apply on production data. |
| 02:17 | At your request I fast-forwarded `prod` to `d267fdb` (voice and Sujay's later commits; app and docs only). That run re-deploys the same server code. |

## 3. Problems found while planning (all fixed)

| # | Problem | Fix |
|---|---|---|
| 1 | Production had moved on from `master` (Sujay's commits). | Everything now flows through `dev` and `prod`; `master` lags. |
| 2 | Migration 0016 (one account per mailbox) stops mid-deploy if two live accounts share a mailbox. | The deploy's read-only gate (`auditContactUniqueness.js`, before any downtime) now counts them; `auth/scripts/preflight_email_canonical.sql` lists them by hand. Production had none. |
| 3 | The `db-migrate` image lacked files the new audit and support tools import; it would have blocked every deploy. | Seven files added to `db/migrate/Dockerfile` and its allow-list; a test builds the image's file set. Image built with Docker and checked. |
| 4 | `recovery_attempts` had no grant for a separate `AUTH_RUNTIME_ROLE`. | `runtimePermissions.js` grants it. (Production has no such role set, so it is harmless there.) |
| 5 | An auth unit test passed only with a developer `.env`; CI has none. | Config is read lazily; the suite passes with the `.env` set aside. |
| 6 | The reward-gate migration was numbered before one already applied. | Renumbered `20261118020000` on its branch. |
| 7 | The app compares version **names**, not build numbers, to force an upgrade. | The new build is `1.0.18`. |
| 8 | The Google identity test schema lacked migration 0016's `email_canonical` column; it failed the security job that gates every deploy. | Fixed by me (`d818d10`) and by Sujay (`8577492`). The security script passes in full. |

## 4. What has been proven, and how

| Check | Result |
|---|---|
| Auth tests, no `.env` (as CI) | 478 pass |
| API tests, clean `npm ci`, no env | 2306 pass, 32 skipped, 0 fail |
| CI database job (product migrations, 50+ SQL scripts, fixtures), local, fresh cluster | all 53 steps pass |
| Five lock/recovery database fixtures (`scripts/test_auth_lock_recovery_postgres.sh`) | all pass |
| Upgrade and duplicate rehearsals with the real migration runner | pass; duplicates stop at 0016 and a rerun finishes |
| `db-migrate` image built; audit and support scripts load in it | yes |
| **The real deploy of `8577492`** | succeeded; ledger shows 0017 and 0018 |
| App tests on latest `dev` (voice included), local | 3716 pass, 11 skipped, 1 fail: `quick_add_shared_test.dart` overflows by 2.8 px on a Mac; passes on CI |
| CI on `d267fdb`: API and auth, database suites, security migrations, end-to-end smoke, anonymization audit, Flutter and console | green when last read (02:25 IST); the 8 app shards and the prod bundle were still running |

**Not proven:** real email delivery, the stop link through nginx, the phone and Play
builds, and the recovery and phone flows on a real device.

## 5. SQL and settings needed separately

**No SQL is pending.** The deploy applies migrations by itself, and I compared every
migration file in the repo with the production ledgers (read-only):

- Auth: 19 files, 19 applied.
- Product: 194 files, 193 applied. The one not applied, `0013_cron_jobs.sql`, is skipped on
  purpose by the migrator (it needs the `pg_cron` extension); it has been that way since August.
- The reward-gate migration is **not** in the repo's deployed branch; it lives on
  `claude/goofy-burnell-b2b60e`, off by default (decision, section 8).
- Voice needs no server setting and no SQL: it runs on the phone, with the phone's own
  speech and voices. It does need the microphone and speech permissions, which both apps
  already declare.

**Manual SQL, later, and not now:**

```sql
UPDATE app_status SET min_supported_version = '1.0.18' WHERE id = true;   -- Phase F1
```

Do not run it until the iPhone and every tester have `1.0.18`; until then it would lock them
out with an "update required" screen. Run it with:

```bash
srv() { ssh -i "PEM_PandaPay/ssh-key-2026-08-01 (3).key" -o IdentitiesOnly=yes ubuntu@140.245.223.86 "$@"; }
srv "docker exec -i pandapay-prod-backup-1 sh -c 'psql \"\$PRODUCT_DATABASE_URL\"'" < min_version.sql
```

**Server `.env` settings (not SQL):** `AUTH_PUBLIC_BASE_URL` is set (10 Nov, backed up
first). `REQUIRE_PHONE_AT_SIGNUP`, `RECOVERY_REMINDER_EMAILS_ENABLED` and
`DEVICE_ACCOUNT_LIMIT_ENFORCE` are unset, so they default to off. Changing one means
editing `.env` and redeploying with `gh workflow run deploy-prod.yml --ref prod`.

## 6. Remaining plan

### Phase E. Apps (in progress)

Build `1.0.18+144` from commit `772240c`, made on top of `d267fdb` and not pushed.

1. iPhone: the three-step recipe in memory `ios-device-build-and-install-recipe`
   (config, `xcodebuild`, `devicectl install` over the old app; never delete the app).
2. Android testers: `scripts/fastlane.sh exec fastlane android internal build_number:144`
   (the Play internal track was at 143). **Publishing needs your OK**, which you gave on 10 Nov.
3. Test on the iPhone, with the lock switches still off:
   - Sign up with a new email: phone box shown, number saved, not asked again.
   - Settings, Email & phone: add a recovery email (two codes), remove it, add it again.
   - Sign out. "Need help signing in?" with both paths: with a recovery email (code, new
     email and code, signed in, other device signed out) and "I don't have a recovery
     email" (24-hour notice, come back, finish).
   - A wrong phone or card digits gives the same message as a wrong code.
   - While a recovery is waiting, Settings on a second signed-in device shows the red card
     and its button cancels; the email link shows a button, and pressing it cancels.
   - Check the emails really arrive and the stop link opens (this proves nginx and SMTP).
   - Try voice: speak or type a spend, ask a question, hear the answer.

Do not go on until that works.

### Phase F. Minimum version, then the lock (days later; each needs your OK)

1. Raise the minimum version (section 5).
2. `REQUIRE_PHONE_AT_SIGNUP=true` and redeploy. The 14 live accounts are asked for a phone at
   next open. Watch for 403 `phone_required` that does not clear, and for "number already
   used" (release with `recovery_support.js release-phone`).
3. `RECOVERY_REMINDER_EMAILS_ENABLED=true` and redeploy (sends 25 at a time).

### Phase G. Later decisions

1. Read what the log-only device check recorded (`account_clusters.js flags`, `devices`);
   if it shows real abuse, set `DEVICE_ACCOUNT_LIMIT_ENFORCE=true`.
2. The reward gate stays off until you decide.

## 7. Branches

- `origin/dev` = `origin/prod` = `d267fdb` (after the 02:17 push). Build commit `772240c`
  (version bump) is local on `dev`, not pushed. Pushing it to `prod` would redeploy the
  server for a one-line app change; push it to `dev` only, or fold it into the next real push.
- `origin/master` is `37723c9`. Memory says builds come from `master`; it is far behind.
  Pushing `dev` to `master` runs the full CI without deploying anything and brings it level.
  Needs your OK.

## 8. Decisions open

1. **Reward gate** (`claude/goofy-burnell-b2b60e`, off by default): include in a later deploy?
2. **Push `dev` to `master`** so the build rule is satisfied again.
3. **Who pushes `prod`.** Sujay pushes there too; a push deploys. Say so before pushing.

## 9. If something goes wrong

All schema changes are additive, so old code still runs on the new schema. The last
verified-good production commit before tonight's work was `a575b29`; since 01:40 it is
`8577492`.

| Where | What happens | What to do |
|---|---|---|
| Deploy audit stops a deploy | nothing changed, no downtime | fix the accounts it counts; rerun |
| Migration fails inside the window | the deploy script restores the writers it stopped; a paired backup exists | read the failing step; do not edit applied SQL; fix forward |
| Unhealthy after a deploy | `/ready` fails | point `prod` back to `8577492` (a forced push, **your decision**) and let it redeploy; data stays |
| App problem | only you and testers have it | do not raise the minimum; fix and rebuild |
| F1 locks out old builds | "update required" | set `min_supported_version` back to `1.0.17` |
| F2 phone lock causes trouble | stuck on the phone screen | `REQUIRE_PHONE_AT_SIGNUP=false` and redeploy |
| G enforcement refuses real people | 403 `DEVICE_ACCOUNT_LIMIT` | `DEVICE_ACCOUNT_LIMIT_ENFORCE=false` and redeploy |

A deploy run usually ends red at "Smoke test authenticated nearby discovery API" (a timeout
that has hit several recent runs). Only "Deploy" and "Verify production is healthy" before
it matter. The run for `8577492` ended green.

## 10. What stays unbuilt

Play Integrity and App Attest (need your credentials), the 14-day expiry of an unused phone
claim (needs an "activated" signal from the product database), background reminder
notifications, and device-limit enforcement (wait for the numbers).
