# PandaPay — everything only you can do

**Written:** 6 Nov 2026. **For:** the owner. **How to read it:** the top part is the short version, in bullets. The bottom part has the detail for each item (what, why, where, how). Every item names the document it came from so you can check it.

This list was put together from the existing plans and status files: the fresh-start release plan, the SMS v2 status file, the store and legal checklist, the dark-deploy and signing-key runbooks, the old `TODO_OWNER.md`, and the card-rewards rollout (plan section 9). Some older items may already be done or overtaken. Where I could not tell, the item says "check".

Tags used below:

- **[iPhone test]** — needed before a test build runs on your iPhone against the local test backend.
- **[Cutover]** — needed before the production cutover (real servers, real users).
- **[Launch]** — needed before a public launch. Not needed for the friends test.
- **[Anytime]** — ongoing, or no deadline.

---

# Part 1 — The short version

## What stops us today

- **Installing a test build on your iPhone (local test backend):** nothing on your list stops it. You only need the iPhone plugged in, unlocked, trusted by the Mac, with Developer Mode on, and the Mac and iPhone on the same Wi-Fi. One thing is on my side, not yours: the card-rewards work is on its own branch and has to be merged into the SMS v2 integration branch (the one your iPhone builds come from) before a build can include it.
- **Production deploy (real servers):** several of your items stop it. The main ones are below. None can be done by me.
  - Legal pages: placeholders filled on 6 Nov 2026; the new pages still have to be copied to the server (`/var/www/pandapay-legal/`).
  - The SMS rule-signing key has not been created, and its public half is not in the app yet (the shipped map is empty).
  - Firebase App Check is not registered for the two app identities.
  - The paid Gemini key and its settings are not set on the private admin host.
  - A new `IMAP_ENCRYPTION_KEY` has to be made, and `PRODUCT_TERMS_VERSION` set.
  - You have to approve each cutover step, and every push or merge that triggers a deploy.
  - Backups, maintenance window and tester list need your decisions.
  - The device acceptance checks (about 23 rows) and the accuracy check on your real messages are still open.

## A. Before a test build on your iPhone [iPhone test]

- Plug in the iPhone, unlock it, tap Trust, turn on Developer Mode.
- Keep the Mac awake on the same Wi-Fi as the iPhone; allow Local Network access when the app asks.
- Remove any old "PandaPay SMS v2 local test CA" profile from the iPhone.
- Delete the old app before installing the fresh build (fresh start; nothing carries over).

## B. Production cutover — config and keys you must create [Cutover]

- Create the SMS rule-signing key (Ed25519), store the private half as `SMS_RULES_SIGNING_KEY` and its id as `SMS_RULES_KEY_ID` on the private admin host only. Put the public half in the app (`rule_keys.dart`) and ship that app release first.
- Register both app identities in Firebase App Check (App Attest on iOS, Play Integrity on Android). Start in `monitor` mode.
- Make a new `IMAP_ENCRYPTION_KEY` (`openssl rand -base64 32`) and a key id. Confirm `INBOUND_EMAIL_WEBHOOK_SECRET` is set.
- Set `PRODUCT_TERMS_VERSION=2026-11-15` (or remove it) and confirm `ACCOUNT_LIFECYCLE_ENABLED` is on.
- Create a Gemini key on a billed Google Cloud project; set the AI model, token limit and the two prices on the private admin host only.
- Fill the legal placeholders, publish the legal pages, and use their links in both stores.

## C. Production cutover — approvals and actions [Cutover]

- Approve (or refuse) each step of the cutover, one at a time. Nothing has been pushed to `master` or deployed. A push to `master`, or a `[deploy-prod]` commit on `codex/ios-shortcuts-prototype`, deploys to production.
- Pick the date and time of the maintenance window and tell the people who need to know.
- Approve the pre-cutover encrypted backups, write down the destroy date (cutover + 30 days), and delete them on that date.
- Approve starting the product database empty, revoking every session, and blocking old app builds.
- Stop and remove the old `gemini-worker` and `sms-learning-worker` containers on the host.
- Start the private admin services and confirm the rule job is healthy.
- Approve the card-rewards rollout steps (section 9 of the card-rewards plan): seed the directory, forced import, publish, recompute, audit.

## D. Stores and legal [Cutover for the test channels, Launch for public]

- Confirm the Apple developer account is an Organization account; same for Google Play where required.
- Play Console: SMS permission declaration with a 30 to 60 second video; Data safety form; financial features declaration; account-deletion web link; background-location declaration or remove the permission; target audience 18+.
- App Store Connect: privacy labels, review notes, age rating, and the Sign in with Apple check.
- Name a grievance officer; confirm the general contact address.
- Confirm in writing that the host's disks are encrypted at rest, and that backups really expire within 30 days.
- Before public launch: an Indian fintech privacy lawyer reviews the policy, terms, consent screens and the learning-data open points.

## E. Checks only you can do on real phones [Cutover]

- Accuracy: import your full history on Android and through the iPhone Shortcut, then compare monthly totals and categories with your bank and card statements.
- Device acceptance table (iPhone and Android, release builds): consent first, locked-phone capture, encrypted database/receipts/spool, backup exclusion, sign-out, offline sign-out, reinstall, new phone, second account, account deletion, email consent, mailbox password, bank-senders-only, email text deleted, disconnect, AI sharing off by default, layouts reach the AI, private draft, approved rule reaches everyone, turning sharing off, rule sets stay fresh.
- Card rewards on the phone: open My Cards, a card's detail page and the caps screen, and look at the limit bars, the 80% and 100% alerts, and the Partial/Basic label. This has not been run on a device by anyone.
- Older device checks that may still be open (check): camera/QR scan, SMS import on a real Android phone, geofencing and the home-screen widget, and adding the iOS widget extension in Xcode.

## F. Decisions that are waiting for you

- Card rewards: ship it switched on, or behind a flag? (The fresh-start plan says it ships only if its own gates pass, behind its flag.) Say yes to merging `card-rewards/phase1` into the SMS v2 integration branch.
- Accept or reject the known limits of card rewards: Flipkart Axis loses its quarterly Flipkart limit for installed apps; LIC Classic's 3X rate rests on the research record, not the LIC page; Fabindia SBI's other-spends rate was set to unknown.
- Foreign payments, the shared-learning feedback route, the D5 deletion notice and the file export/import screen (check which of these are still open).
- Tester list, who reviews corrections, and whether testers get TestFlight and Play internal testing.
- Consent wording and store disclosures (your text), if you want it different from the drafts.
- Whether to delete the rescue branch and the old Codex worktree, and when to delete remote branches after the push.

## G. During the friends run (7 days) [Anytime]

- Ask testers to turn on "Help PandaPay read new bank messages".
- Review the console Templates tab at least every 2 days and publish approved drafts to the testers cohort.
- Watch correction rate (target under 1%), crashes, sync errors, layouts held, drafts failed, and the AI cost per day.
- Stop the local test rig when you are not testing (its login code is fixed).

## H. Before public launch [Launch]

- Certificate pinning (LO-12), with a backup pin.
- Lawyer review and store declarations approved.
- DPDP readiness before 13 May 2027: a breach runbook that notifies the Data Protection Board and every affected user, a retention schedule, and processing logs kept for one year.
- Older owner items (check): clearing real scrape sources (read each bank's terms before enabling a source) and adding an Anthropic key for LLM extraction.

---

# Part 2 — The detail

## 1. Installing a test build on your iPhone [iPhone test]

Source: `docs/sms-pipeline-v2/runbooks/local-iphone-rig.md`, `FRESH_START_PROGRESS.md`.

- **What you do:** plug in the iPhone and unlock it; tap Trust; turn on Developer Mode (Settings, Privacy and Security); keep the Mac on and awake; keep both on the same private Wi-Fi.
- **What the build is:** a standalone Profile build called "PandaPay SMS v2 Test" with its own app identity, installed by `scripts/build_sms_v2_local_ios.py` from the Mac. A normal debug build can show a white screen when opened from the Home Screen, so the Profile build is used.
- **Signing in on the rig:** the test account is `test@example.com`, phone `9999999999`, code `1234`. This code is fixed, so run the rig only on a network you trust and stop it when you are done.
- **Fresh start:** delete the old app first. Sign-out wipes the phone's data on purpose, so anything you want from the old build must be imported again.
- **Remove old test certificates:** Settings, General, VPN and Device Management, remove "PandaPay SMS v2 local test CA" if it is still there.
- **Known caution:** a build made while the rig is stopped cannot sign in. Start the rig first.

## 2. Keys and settings you must create [Cutover]

Sources: `docs/sms-pipeline-v2/runbooks/signing-keys.md`, fresh-start plan Phases 6b and 8.

- **SMS rule-signing key.**
  - Generate on a trusted machine: `openssl genpkey -algorithm Ed25519 -out sms-v2-private.pem`, then `openssl pkey -in sms-v2-private.pem -pubout -out sms-v2-public.pem`.
  - Private key: secret store as `SMS_RULES_SIGNING_KEY`, with `SMS_RULES_KEY_ID`. Only the private admin host (`admin-api`, `sms-v2-rule-jobs`) holds it. The public API must never have it.
  - Public key: add its base64 32 bytes to `smsV2RuleKeys` in `rule_keys.dart`. Ship that app release one release before you switch the server to the key. The shipped map is empty today, so a production build cannot trust any rule bundle yet.
  - Also create a spare key and ship its public half now. Without a spare, a leaked key can only be replaced by a new app release.
  - Rules expire after 7 days. The hourly rule job keeps them fresh; check System status shows "SMS rule set signing" ok.
- **Firebase App Check.** Register both app identifiers (App Attest on iOS, Play Integrity on Android, with the release Android signing certificate). Keep `SMS_V2_ATTESTATION_MODE=monitor` for the first rollout, and decide on `enforce` after you review the monitor.
- **Email import keys.** New `IMAP_ENCRYPTION_KEY` (`openssl rand -base64 32`) and an optional `IMAP_ENCRYPTION_KEY_ID` (default `k1`). The old key format makes the API refuse to start. Confirm `INBOUND_EMAIL_WEBHOOK_SECRET` is set. Every user reconnects their mailbox after cutover (the migration clears the stored connections).
- **Terms version.** Set `PRODUCT_TERMS_VERSION=2026-11-15` or remove the variable. A server still on `2026-08-07` rejects sign-up with `product_terms_changed`. If you change the policy text later, change `consentPolicyVersion` in the app and this variable together.
- **Account deletion.** Confirm `ACCOUNT_LIFECYCLE_ENABLED` is on in production.
- **Refresh tokens.** If `JWT_REFRESH_TTL` is set explicitly on the server, change it to `90d`.
- **Gemini (AI template loop).**
  - Create the key in a Google Cloud project with billing on, and confirm in AI Studio that the project is on a paid tier.
  - On the private admin host only, set `GEMINI_API_KEY`, `SMS_V2_AI_MODEL`, `SMS_V2_AI_TPM`, `SMS_V2_AI_INPUT_USD_PER_MILLION`, `SMS_V2_AI_OUTPUT_USD_PER_MILLION` and `SMS_V2_JOB_ADMIN_ID`. Allow its outbound HTTPS to generativelanguage.googleapis.com.
  - Keep the "Shared: No, service provider" answer in the store forms only after the paid-key terms are confirmed.
- **Old settings you can delete:** `AI_WORKER_TOKEN`, `SMS_LEARNING_*`, the old `GEMINI_*` worker limits.

## 3. The production cutover, in order [Cutover]

Source: fresh-start plan Phase 8. You approve each step. I will not run any of these without your yes.

1. Fast-forward `master` to the release commit on `sms-v2/integration` and tag `release/fresh-start-1`. **Pushing to `master` deploys to production.** The other trigger is a `[deploy-prod]` commit on `codex/ios-shortcuts-prototype`. Nothing else should push.
2. Take paired encrypted backups of the product and auth databases (`db/backup/README.md`). Write down the destroy date (cutover + 30 days). Decide the backup mode (off-host, or local with its disk-loss caveat).
3. Turn on maintenance mode: `update app_status set maintenance_mode = true`.
4. Start the product database empty from the migrations and point the API at it. Keep the auth database. (Login accounts stay; all product data is wiped.)
5. Revoke every session in the auth database (same statement as logout-all-devices, without the user filter).
6. Block old builds: `update app_status set min_supported_version = '<new build version>'`.
7. Deploy `api` and `auth` from the tag. Remove the legacy worker containers (`gemini-worker`, `sms-learning-worker`); the deploy script refuses to run while an unlisted service is up. Set the new `IMAP_ENCRYPTION_KEY`.
8. Set up SMS v2 trust: rule-signing keys and App Check. Load the rules on the new database with `node api/scripts/release_sms_v2_bundle.js --apply --admin-id <id>`.
9. Start the private admin profile with the two job services. Confirm the rule job logs `"status":"ok"`, `GET /sms/v2/rules` answers 200 with an `expiresAt` about 7 days ahead, and System status shows rule signing ok.
10. Set the Gemini key and settings (section 2).
11. Turn maintenance mode off. Testers delete the old app, install the new build (TestFlight or Play internal testing), sign in, accept consent, import history.
12. On the destroy date, delete the pre-cutover backups.

Also needed for the migrations: `20261115050000_user_consents_email_sms_purposes.sql` must be applied before the release goes live, or consent rows for `email_import` and `sms_reading` are rejected. Server migrations are one-way (there is no down migration); a bad migration is fixed forward with a new file.

## 4. Card-rewards rollout [Cutover]

Source: `docs/card-rewards-phase1-implementation-plan.md` section 9, `docs/card-rewards-status.md`.

- **Before anything:** say yes to merging `card-rewards/phase1` into `sms-v2/integration` (it is a separate branch today and the iPhone builds do not include it). A trial merge shows 9 files with conflicts (workflow file, `api/package.json`, a test config, console files, one doc). I would do the merge on a new branch, re-run the tests, and only then touch integration.
- **Decide:** ship switched on or behind a flag. Card rewards currently has no on/off switch of its own beyond the v1/v2 feed split.
- **Steps (you run or approve):**
  1. Fresh database backup, then deploy (migrations apply automatically; the two card-rewards migrations are `20261105120000` and `20261106120000`).
  2. `node api/scripts/seed_merchant_directory.js --dry-run`, then `--apply`. The API caches the directory for 5 minutes; restart the API to skip the wait.
  3. `api/scripts/sync_card_catalogue.sh --dry-run`, read `.staging/coverage-report.md`, then the real import. On a catalogue that already has published cards, it must be run with `--force` (otherwise published cards are skipped and never get Phase 1 rules). Each forced refresh writes an audit row and the card stays published.
  4. `publish_card_pipeline.js --dry-run`, then publish (already-published cards are a no-op).
  5. `node api/scripts/recompute_card_state.js --dry-run`, then `--apply`, straight after the forced import (the import removes users' cap, milestone and fee-waiver progress until this runs). Run it again after any `card_state_v2 deferred` warning in the API logs.
  6. `node api/scripts/audit_catalogue.js https://api.pandapath.site/catalogue?schema=2` and record the numbers in the status doc.
  7. Release the app build that has card rewards.
- **Known limits you are accepting:**
  - Flipkart Axis: installed apps lose its quarterly Flipkart limit until they update (a small over-statement above ₹80,000 a quarter, an under-statement below).
  - LIC Classic's 3X on other spends rests on the research record; the LIC page could not be read. If you prefer strict, I can turn the rule into information-only with one line.
  - Fabindia SBI's other-spends rate is unknown, so it is shown at the card's own lower base rate.
  - About 330 cards that were not hand-checked may be missing their EMI-exclusion wording (Phase 2 list).
  - 12 statement-cycle fee-waiver rules are not rebuilt.
  - If any staging or dev database already applied the earlier version of the index-function migration, it needs a manual drop of the old overload. Production has not run it.
- **Not done by anyone:** an emulator or device pass of the new screens (see section 6).

## 5. Stores and legal [Cutover / Launch]

Source: `docs/release/store-and-legal-checklist.md` (the full draft answers for the forms are there).

- **Placeholders: done (6 Nov 2026).** Operator and grievance officer: Chandresh Kerkar (individual, Goa), panda.paths123@gmail.com. Hosting: Oracle Cloud Hyderabad and Supabase on AWS Mumbai. Error reports: none collected today. Governing law: India, no courts named. No postal address yet, by choice. To change any of it, edit both `deploy/legal/*.html` and `app/lib/features/settings/legal_text.dart` (a test fails if they differ).
- **Grievance officer.** The DPDP Act expects one with contact details and a reply time; the policy promises a reply within 30 days.
- **Contact address.** The pages use `panda.paths123@gmail.com`. Replace it if you want a company address on a public policy.
- **Hosting facts.** Get written confirmation that the server's disks are encrypted at rest, then add a sentence to privacy section 7. Check the real backup schedule matches "backups expire within 30 days after account data is deleted", or change section 8.
- **Publish the legal pages:** copy `deploy/legal/*.html` to `/var/www/pandapay-legal/` (`deploy/DEPLOY.md`); the app links to them through `PANDAPAY_LEGAL_BASE_URL`; use the same URLs as the privacy policy URL in both stores.
- **Apple:** the developer account must be an Organization (guidelines 5.1.1(ix), 3.2.1(viii)); fill the App Privacy labels; paste the review notes; set age rating 18+; check guideline 4.8 for Sign in with Apple against your final login options.
- **Google Play:** Organization account where required; target audience 18+; SMS permission declaration (SMS-based money management) with a short video of the disclosure followed by the permission prompt; Data safety form; financial features declaration; account deletion (in-app path exists; add a web link or an email request page); background location (declare it with an in-app disclosure, or remove `ACCESS_BACKGROUND_LOCATION` if location alerts are not in this release).
- **Shared-learning wording.** Use the same wording in the store answers, the in-app opt-in sheet and privacy section 5. If the policy text changes, bump `consentPolicyVersion` and the opt-in version (`sms-shared-learning-v3`) together.
- **Lawyer (Launch).** An Indian fintech privacy lawyer reviews the policy, terms, consent screens and `docs/release/learning-data-flows.md` section 8 (open points, including the paid-Gemini terms). Not needed for the friends test.
- **After the stores accept:** keep the screen recording and the exact disclosure text with the release record.

## 6. Checks only you can do [Cutover]

Source: fresh-start plan Tasks 7.2 and 7.3.

- **Accuracy on your real messages.** Import your full history on Android and through the iPhone Shortcut on a fresh install. Compare monthly totals and categories with bank and card statements. Record results in `docs/sms-pipeline-v2/handoff/WP-17.md`. Target: correction rate under 1%.
- **Device acceptance (release builds, iPhone and Android).** Check each row and write what you saw:
  - Consent comes first (disclosure before any permission prompt or Shortcut; "Not now" keeps the app usable).
  - Locked-phone capture (transaction appears after unlock; no crash).
  - Database, receipts and Shortcut spool are encrypted; the storage folder is excluded from backups.
  - Sign-out wipes the folder and the widget and the old token gets 401; same when offline.
  - Reinstall opens on login, not on the old account.
  - New phone shows the same totals, hand-entered bills and UPI label.
  - Second account sees the SMS disclosure before any import.
  - Account deletion removes product and auth rows, including mailbox connections and inbound emails.
  - Email: consent first; mailbox password stored as ciphertext only; only bank senders are fetched; parsed email text is deleted; disconnect removes the connection row.
  - AI sharing is off by default; turning it on sends layouts; a private draft fixes your own phone; an approved rule reaches everyone's phone after the next rule check; turning sharing off empties the queue.
  - Rule sets stay fresh 8 days after cutover.
- **Card rewards on the phone** (new, not done by anyone): My Cards tile shows the fullest limit; card detail shows every limit with the reset date; the caps screen shows limits; crossing 80% and 100% raises one alert naming a better owned card; a Partial or Basic card shows its label; a Verified card shows none. Compare a few cards against your own statements.
- **Older checks that may still be open (check):** camera and QR card scan on a real device; SMS import on a real Android phone; nearby-merchants and the home-screen widget on a real device; the iOS widget extension still has to be added in Xcode by someone with a real Xcode session.
- **Real-device speed and history dry-run.** Run 20,000 messages on a phone (desktop took 43 seconds) and review the dry-run of your own history.

## 7. Decisions waiting for you [Anytime]

- **Card rewards:** merge and flag decision (section 4); accept the known limits.
- **Foreign payments:** the screens stay, and the v2 rules now create records for foreign-only amounts. Confirm that is what you want, and what to do about foreign ATM and cash cases not yet handled.
- **Shared-learning feedback route:** old queued corrections post to a route that no longer exists; confirm they should be removed (v2 corrections have their own route).
- **D5 notice:** server-escrowed account recovery has been removed; you have not been shown the deletion list yet.
- **File export/import:** the passphrase export code has no screen. Add a Data transfer entry or delete the code.
- **Tester list and correction reviewer;** whether to use TestFlight and Play internal testing.
- **Consent wording and store disclosures** if you want to change the drafts.
- **Measurement labels (A1)** are drafts and need your review; hold labels for the IPO family need a product decision.
- **Housekeeping:** delete the rescue branch `rescue/main-checkout-2026-11-05` when you agree; remove the old Codex worktree (`~/.codex/worktrees/0d9c`, 51 uncommitted files) when you agree; delete remote branches only after the push.
- **Pushing:** nothing from the fresh-start or card-rewards work is pushed to `master`. Every push needs your approval.

## 8. During and after the friends run [Anytime / Launch]

- **Friends run (7 days).** Track correction rate, crashes, sync errors. Ask testers to turn on "Help PandaPay read new bank messages". Review the console Templates tab at least every 2 days and publish approved drafts to the testers cohort. Track layouts held (App Check problems), drafts ready versus failed, and AI cost per day.
- **Public-launch gate.** Certificate pinning with a backup pin (LO-12, separate plan); lawyer review; store declarations approved; DPDP readiness before 13 May 2027 (breach runbook that notifies the Data Protection Board and every affected user, retention schedule, processing logs kept for one year).
- **Scraper (older, check):** the 12 candidate bank card pages in `scraper/CANDIDATE_SOURCES.md` stay disabled until you read each bank's terms yourself and run `UPDATE sources SET tos_reviewed = true, is_enabled = true WHERE name = '<issuer name>'`. robots.txt is not legal clearance.
- **LLM extraction (older, check):** add `ANTHROPIC_API_KEY` to `scraper/.env` (never commit it) to switch it on.

## 9. Not on your list (so you can ignore it)

- Merging card rewards into the integration branch, re-running the tests, building the rig with card rewards and building the iPhone app: I do these once you say yes.
- The Phase 2 to 4 card-rewards work (ledger, statements, "which card now", reports): later phases, nothing for you yet.
- The research-data gaps for Swiggy HDFC and Flipkart Axis worked examples: data fixes on my side.
