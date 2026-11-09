# Deployment plan: account lock, recovery, device check, reward gate

Written 10 Nov 2026. Nothing in this plan has been run against production. Every step that
changes production says **needs your OK**; nothing below is done for you.

Background: `ACCOUNT_LOCK_AND_RECOVERY_ROLLOUT_2026-11-09.md` (what each switch does),
`EMAIL_PHONE_LOCK_PLAN_2026-11-09.md`, `RECOVERY_FLOW_DESIGN_2026-11-09.md`.

## 1. Where things stand

| Thing | State |
|---|---|
| Production (`origin/prod`) | `666a943`, deployed by Sujay on 10 Nov. It is **16 commits ahead of `origin/master`** and has none of the lock, recovery or gate work. |
| Last prod deploy runs | The four most recent "Deploy to production" runs (including `666a943`) are **red**, all at the same last step: "Smoke test authenticated nearby discovery API" ends in a `TimeoutError`. The deploy and the health check before it passed, and all test jobs were green. The last fully green deploy was `2dc55be` (9 Nov, 17:23 UTC). Treat this as an existing nearby-places timeout, not as a failed deploy, and expect the same red end on the next one. |
| `origin/dev` (Sujay) | `17fa49b`, four commits ahead of prod. |
| My work | Local `dev`: 19 commits that `origin/dev` lacks, none pushed. The reward gate is one more commit on `claude/goofy-burnell-b2b60e`. |
| **Release candidate** | Local branch `integrate-2026-11-10`: my work + all of `origin/dev` + `origin/prod` + the reward gate, with the gate's migration renumbered. Merges were clean. Not pushed. |

**Why the candidate exists.** Pushing my `dev` straight to `prod` would have been refused
(prod is not an ancestor of it) and a forced push would have thrown away Sujay's 16
production commits. The candidate contains everything production has, so `prod` can be
fast-forwarded to it.

## 2. What planning found, and what was fixed

Each of these would have broken a deploy or a feature. All are fixed and committed.

| # | Problem | Fix |
|---|---|---|
| 1 | Production had moved on (see above). | Candidate branch merges it in. |
| 2 | **Migration 0016** (one account per mailbox) stops mid-deploy if two live accounts already share a mailbox (for example `a.b@gmail.com` and `ab@gmail.com`). That is inside the maintenance window, with the writers stopped. | The deploy's read-only gate (`auditContactUniqueness.js --require-unique`, which runs before any downtime) now counts these. Rehearsed: it reports them and exits 2. Also `auth/scripts/preflight_email_canonical.sql` lists them by domain and id for use by hand. |
| 3 | The `db-migrate` image copies only a few `auth/src` files. The audit now imports `emailIdentity`, so in that image it would crash and **block every deploy**; the support tools could not load either. | Seven files added to `db/migrate/Dockerfile` and its allow-list. The image was built with Docker and the scripts loaded from it. A test fails on the old Dockerfile. |
| 4 | New table `recovery_attempts` had no grant for a separate `AUTH_RUNTIME_ROLE`, so every recovery call would be refused. My real-database tests ran as the owner login and hid it. | `runtimePermissions.js` grants select, insert, update (not delete) when 0018 is applied. Tested. |
| 5 | `account_recovery_unit.test.js` would **fail in CI**: it loaded the real config at import and passed locally only because of a developer `.env`. | Config is now read lazily. The whole auth suite passes with the `.env` set aside, as CI runs it. |
| 6 | The reward gate migration was numbered `20261117030000`, before `20261118010000` which production already applied. | Renumbered `20261118020000` (file, SQL test, CI step, docs). |
| 7 | The app compares **version names**, not build numbers, when forcing an upgrade. Every build so far is `1.0.17`, so the new build cannot be told apart from old ones. | The new build must be `1.0.18` (step 6). |

## 3. What has been proven, and how

| Check | Result |
|---|---|
| Auth tests, candidate, no `.env` (as CI) | 475 pass, 0 fail |
| API tests, candidate, clean `npm ci`, no env | 2306 pass, 32 skipped (need a database), 0 fail |
| CI "PostgreSQL-backed suites" run locally on the candidate (product migrations incl. Sujay's and the gate, 50+ SQL assertion scripts incl. the renumbered gate test, fixtures) | see section 8 |
| Five lock/recovery database fixtures on a throwaway no-locale cluster (`scripts/test_auth_lock_recovery_postgres.sh`) | all pass |
| **Upgrade rehearsal**: real migration runner, database at the pre-recovery state with users, then 0015 to 0018 with a separate runtime login | 5 of 5 users kept, canonical emails filled, runtime login can insert but not delete on the new table |
| **Duplicate rehearsal**: two accounts on one Gmail mailbox | stops at 0016 (0015 applied); after closing one, a rerun finishes 0016 to 0018 |
| Deploy audit against those databases | duplicates found: exit 2; clean: exit 0 |
| `db-migrate` image built and scripts loaded in it | yes |
| App tests, candidate | 3357 pass, 11 skipped, 1 fail (not mine, section 8) |

**Not proven, and cannot be from here:** real email delivery, the stop link through nginx,
the migration runner with the production TLS certificate on the Supabase pooler, anything on
the iPhone or Play, and behaviour on production data. Each has a check below.

## 4. Decisions you need to make first

1. **Include the reward gate in this release?** It adds a product-database migration that
   replaces one reward function. With the setting at 0 (its default) the function answers
   exactly as before (checked against the old one on a 19-answer scenario, and its 36 SQL
   tests pass). Recommended: yes. Alternative: leave the branch out of the candidate and ship later.
2. **Who pushes, and when.** Sujay pushes to `dev` and `prod`, and a push to `prod` deploys.
   Tell him you are about to push `prod`, and do not both push. The deploy workflow queues
   rather than interleaves and refuses a deploy if the tested commit is no longer the tip.
3. **Version name for the app: `1.0.18`.** Needed to force the upgrade.

## 5. Plan, in order

Rollback for each phase is in section 7.

### Phase A. Re-integrate and re-test (about 1 hour; local)

Sujay may have pushed since. Right before pushing:

```bash
git fetch origin
git checkout integrate-2026-11-10
git merge origin/dev origin/prod          # resolve anything new; stop and ask if it conflicts
cd auth && NODE_ENV=test npm test          # expect all pass, with no .env present
cd ../api && NODE_ENV=test npm test
cd .. && bash scripts/test_auth_lock_recovery_postgres.sh
cd app && flutter analyze && flutter test
```

Pass means: no failures. The api package `libphonenumber-js` must be installed
(`npm ci`), otherwise five shared-expense files fail for that reason alone.

### Phase B. Read-only checks on the server (about 10 minutes; needs your OK to connect)

```bash
srv() { ssh -i "PEM_PandaPay/ssh-key-2026-08-01 (3).key" -o IdentitiesOnly=yes ubuntu@140.245.223.86 "$@"; }

# 1. Duplicate mailboxes. Expect zero rows. Prints domains and ids, never an address.
srv "docker exec -i pandapay-prod-backup-1 sh -c 'psql \"\$AUTH_DATABASE_URL\"'" < auth/scripts/preflight_email_canonical.sql

# 2. Which settings exist in the server .env. Prints 1 or 0, never a value.
srv 'cd /home/ubuntu/apps/pandapay && for k in AUTH_PUBLIC_BASE_URL AUTH_RUNTIME_ROLE REQUIRE_PHONE_AT_SIGNUP DEVICE_ACCOUNT_LIMIT; do printf "%s: " $k; grep -c "^$k=." .env; done; printf "secret 32+ chars: "; grep -c "^AUTH_INTERNAL_SERVICE_SECRET=.\{32,\}" .env'
```

- Duplicates found: close or merge all but one account in each group (support decision), rerun.
- `AUTH_PUBLIC_BASE_URL` is 0: add `AUTH_PUBLIC_BASE_URL=https://auth.pandapath.site` to the
  server `.env` (no trailing slash). Without it recovery works but the emails have no "stop
  this" link. **Needs your OK** (it edits the server).
- `AUTH_RUNTIME_ROLE` is 1: the grant fix from section 2 matters; otherwise it does not.
- The secret check must print 1.

### Phase C. Push to `master` (CI only; needs your OK)

```bash
git checkout master && git merge --ff-only integrate-2026-11-10   # or merge it, if master has moved
git push origin master
```

A push to `master` runs "Build and test" and publishes images; it deploys nothing. Wait for
all jobs green: security migrations, API and auth, PostgreSQL-backed suites, App shards 1 to 8,
Prod bundle, Container images, End-to-end smoke. Do not go on if any is red.

### Phase D. Deploy the backend (needs your OK; the step with downtime)

```bash
git push origin master:prod        # fast-forward; deploys production
```

The workflow runs the tests again, then `deploy/deploy.sh`, which: builds images; runs the
read-only migration and contact audits **before any downtime** (this is where a duplicate
mailbox now stops it safely); stops auth, api and the workers; takes a paired encrypted
backup; applies migrations (auth 0015 to 0018, product `20261118020000` and Sujay's);
restarts and waits for `/ready` on both services. Expect a few minutes of downtime and
up to the 30-minute window as the limit.

State afterwards: **every switch off.** Today's app builds keep working unchanged. New
behaviour on the server only: email aliases collapse to one account, throwaway domains
are refused at sign-up, the recovery endpoints exist, the device check logs.

**Expect the workflow to end red** at "Smoke test authenticated nearby discovery API" (see
section 1; it has timed out on every recent deploy). What matters is that "Deploy" and
"Verify production is healthy" before it are green. If either of those is red, stop and use
section 7.

Verify (no secrets, one harmless row):

```bash
curl -fsS https://api.pandapath.site/ready && curl -fsS https://auth.pandapath.site/ready
# Recovery answers the same for a made-up account: expect ok:true, a code_length of 6.
curl -s -X POST https://auth.pandapath.site/auth/recovery/start -H 'content-type: application/json' \
  -d '{"lost_email":"nobody@example.com","phone":"+919999999999","fact":"4821","device_id":"plan-check-0001"}'
# The card question must refuse a caller without the secret: expect 401, or 404 if nginx hides it. Never 200.
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://api.pandapath.site/internal/recovery/card-fact
```

Then confirm a normal sign-in still works with the current iPhone build (143).

### Phase E. Build and test the apps (about half a day; needs your OK to publish)

1. Set the version in `app/pubspec.yaml` to `1.0.18+144` and commit it on `master`
   (docs-only pushes need `[skip ci]`; this is not docs-only).
2. iPhone: the three-step recipe in memory `ios-device-build-and-install-recipe` with
   `--build-name=1.0.18 --build-number=144`; install over the old app, never delete it.
3. Android: `scripts/fastlane.sh exec fastlane android internal build_number:144`.
4. Test on the iPhone, with the server still on the old switches:
   - Sign up with a new email: phone box shown, number saved, not asked again.
   - Settings, Email & phone: add a recovery email (two codes), remove it, add it again.
   - Sign out. "Need help signing in?" then both paths: with a recovery email (code, new
     email and code, signed in, other device signed out) and "I don't have a recovery
     email" (24-hour notice, come back, finish).
   - A wrong phone or wrong card digits gives the same message as a wrong code.
   - While a recovery is waiting, Settings on a second signed-in device shows the red card
     and its button cancels; the email link shows a button, and pressing it cancels.
   - Check the emails really arrive and the stop link opens (this proves nginx and SMTP).

Do not go on until all of that works.

### Phase F. Make the new build the minimum, then lock (days later; each needs your OK)

Wait until almost every active install has the new build (watch builds in use).

1. Raise the minimum version. Save as `min_version.sql`: 
   `UPDATE app_status SET min_supported_version = '1.0.18' WHERE id = true;`
   ```bash
   srv "docker exec -i pandapay-prod-backup-1 sh -c 'psql \"\$PRODUCT_DATABASE_URL\"'" < min_version.sql
   ```
   Old builds then show the "update required" screen. Check on an old install if you have one.
2. Set `REQUIRE_PHONE_AT_SIGNUP=true` in the server `.env`, then redeploy the current
   commit: `gh workflow run deploy-prod.yml --ref prod`. Existing accounts are asked for a
   phone at next open. Watch for 403 `phone_required` that does not clear, and for support
   contacts about "number already used" (release with `recovery_support.js release-phone`).
3. Set `RECOVERY_REMINDER_EMAILS_ENABLED=true` and redeploy. Every account older than 7
   days with no recovery email is due at once; it sends 25 at a time.

### Phase G. Device check, then the reward gate (a week later; decisions)

1. Read what the log-only check recorded:
   `node auth/scripts/account_clusters.js flags` and `devices` (run them inside the
   `db-migrate` image with the compose `run --rm` form, so the encryption settings are present).
   If the flagged numbers look like real abuse and not families sharing a phone, set
   `DEVICE_ACCOUNT_LIMIT_ENFORCE=true` and redeploy.
2. The reward gate stays at 0. Turning it on is its own decision: see the section the gate's
   session added to the rollout guide (how to switch on, who would be held, what to watch).

## 6. Who does what and where your OK is needed

| Step | You | Me |
|---|---|---|
| A. re-integrate and test | say go | do |
| B. server checks | OK to connect | run the three read-only commands |
| C. push `master` | OK | push |
| D. push `prod` | OK, tell Sujay | push, watch, run the checks |
| E. builds | OK to publish to Play | build, install, you test the phone |
| F. minimum version, flags | OK each | edit and redeploy |
| G. enforce, gate | decide | edit |

## 7. If something goes wrong

All schema changes are additive, so old code still runs on the new schema.

| Where | What happens | What to do |
|---|---|---|
| B finds duplicate mailboxes | nothing yet | close or merge them; rerun |
| D: audit stops the deploy | nothing changed, no downtime | fix the accounts it names by count; rerun |
| D: migration fails inside the window | the deploy script restores the writers it stopped and reports; the paired backup exists | read the failing step; do not edit applied SQL; fix forward |
| D: unhealthy after deploy | `/ready` fails | point `prod` back to `666a943` (a forced push, **your decision**) and let it redeploy; the data stays |
| E: app problem | only testers have it | do not raise the minimum; fix and rebuild |
| F1 locks out old builds by mistake | people see "update required" | set `min_supported_version` back to `1.0.17` |
| F2 phone lock causes trouble | people stuck on the phone screen | set `REQUIRE_PHONE_AT_SIGNUP=false` and redeploy; no data is lost |
| G enforcement refuses real people | 403 `DEVICE_ACCOUNT_LIMIT` | set `DEVICE_ACCOUNT_LIMIT_ENFORCE=false` and redeploy |

## 8. Still open

- One app test fails on my Mac: `quick_add_shared_test.dart`, "sharing fits 320dp and 2x
  text without obscuring the amount" (a row overflows by 2.8 pixels). It fails the same way
  on `origin/dev` alone, so it is not from this work. CI is not affected: all eight app test
  shards passed on Sujay's `prod` push, so it looks font-dependent on macOS. If CI on
  `master` shows it red, that is Sujay's test to fix, not a reason to hold the release.
- The analyzer reports 116 informational notes and no errors or warnings, the same count
  as before the merge.
- Not yet run by anyone: Phase B on the real server, and everything in Phases C to G.

## 9. What stays unbuilt

Play Integrity and App Attest (need your credentials), the 14-day expiry of an unused phone
claim (needs an "activated" signal from the product database), background reminder
notifications, and enforcement of the device limit (wait for the numbers).
