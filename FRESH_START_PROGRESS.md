# Fresh-start release: what has been done

**Plan:** `docs/superpowers/plans/2026-11-05-fresh-start-release.md` (decisions D1 to D8, owner-confirmed 5 Nov 2026).
**Rule:** Update this file after every phase. As of 8 Nov 2026 the work lives on `latest-dev` (pushed, at `4112b13`) and production has run SMS v2 only since 6 Nov. The sections below are the 6 Nov record.
**Last updated:** 8 Nov 2026 (the "Update" section below). "At a glance" and sections 1 and 2 were checked on 6 Nov 2026, 10:45 IST.

## Update, 8 Nov 2026

The fresh-start release shipped on 6 Nov: production was cut over to SMS v2 only. Since then:

- **Code:** `latest-dev` on GitHub is at `4112b13` (pushed 8 Nov 2026, 11 commits on top of the merge with 67 commits from other sessions: Splits, the SMS AI drafts worker, performance work). A push to `latest-dev` runs Build and test and then deploys to production on its own.
- **Production:** cut over to SMS v2 only on 6 Nov 2026 (new product database, feature flags set, minimum app version 1.0.17). Signed rule bundles 9 to 12 are live since 8 Nov 2026 (1,140 rules, 125 ignore rules, 154 merchant aliases; cohorts all, 25%, 5%, testers) and renew hourly. They add 41 rules, 26 ignore rules and 16 aliases to bundles 5 to 8.
- **App:** build 1.0.17 (142) is installed on the owner's iPhone. Since 6 Nov it adds: a "Refresh rules and re-sort" button; a fix so records the server refuses for good no longer block the re-sort; earlier "ignored" messages are read again when they arrive again; a checklist after an edit (choose which other transactions to change, nothing ticked for type or payment-method changes); a Save confirmation; "Transfer between my accounts" and "Credit card bill payment" actions; a "Transfer type" choice in Edit; a searchable, grouped category picker.
- **Rule edits not yet live:** the server import adds only new rule ids, so 188 edits to existing rules in the repo (among them four Union Bank rules) are in no bundle yet. Each needs a new version published from the admin console or by a script.

- **Replay of six months of the owner's real bank messages** (8 May to 8 Nov, 2,613 messages read from the Mac's synced Messages, counts only, nothing stored in the repo) through the real phone pipeline with the 1,099 repo rules: 649 transactions. Findings: (1) 11 messages from one half-day window on 3 Nov, 2 of them money, never reached the app (the iPhone Shortcut did not return them; cause unknown); (2) 43 messages the phone had marked "ignored" are counted by today's rules (5 card spends and 38 small cashbacks and refunds), because the old keyword gate called them promotions and an ignored decision was final (fixed in the app in `dfe5d07`); (3) about 11 messages are real rule gaps (foreign-currency card spend, small card spend, income-tax challan payments, Airtel recharges, wallet payments); (4) merchant names split by processor prefixes and cut-offs (Swiggy under 10 names, Amazon under 7, MakeMyTrip under 3), now merged by the new aliases.
- **Not yet checked:** the "Needs review" count on the phone (the app database is encrypted, so it cannot be read from the Mac); why the Shortcut missed the 3 Nov window; whether payments to the owner's own name become transfers automatically (needs the profile name set).

## At a glance (verified 6 Nov 2026, 10:45 IST)

| | |
|---|---|
| Branch | `sms-v2/integration` at `e4831e5`, identical to `origin/sms-v2/integration` (nothing unpushed from this session) |
| What changed since my last push (`f803d7b`) | 440 commits from the card-rewards and learning-loop sessions: card rewards Phase 1 merged (`e60599d`), the SMS learning loop A1 to C1 merged (`e4831e5`), owner task list `docs/OWNER_MANUAL_TASKS.md` |
| Build on your iPhone | **Build 125**, built from `f803d7b`. It does **not** include card rewards or the learning loop. Needs a rebuild to test those. |
| Local test backend | Rig `WSmnfN` (192.168.160.140) is running, but it was started before the learning loop and card rewards migrations (182 migrations now). Restart it before the next build. |
| Production | Untouched. No deploy, no migration, no flag change. `master` and the deploy branch have not moved. |
| Code | Every planned task is built and merged. All suites pass on `e4831e5`: rules lint clean; shared engine 2,050; rules tool 262 (0 regex mismatches); server 2,172 pass (31 skipped, Postgres-only); auth 377; console 119, analyzer clean; app 2,940 pass (10 skipped), analyze 110 issues, no errors. |
| Overall | Code about **97%** built. Whole release about **70%**, because nothing is yet **proven** with real users: your checks, legal details, keys, the Gemini dry run and the cutover are still open (`docs/OWNER_MANUAL_TASKS.md` lists every one). |

## 1. Everything in one table (work items and completion)

"Done" means built, tested and merged. Device and real-world checks are called out separately because they are what is left.

| Phase | Work item | Done | State | Evidence |
|---|---|---|---|---|
| **0. One codebase** | 0.1 Save main-checkout work | 100% | Done | Rescue branch `2d8a914` (kept until you say delete) |
| | 0.2 Superseded branches | 100% | Done | Deleted after checks |
| | 0.3 Lane X (Kiwi receipt question) | 100% | Done | `7b2f3f7` |
| | 0.3 Card rewards (D7) | 95% | Merged by its own session | Phase 1 in integration (`e60599d`); `card-rewards/release` still has 1 commit not merged; rollout steps need your approval |
| | 0.4 Prune branches and worktrees | 100% | Done | Local and remote pruned |
| **1. SMS v2 only (app)** | 1.1 to 1.4 | 100% | Done | Flag, legacy pipeline, old-install code and escrow removed; email consent screen |
| **1b. Foreign payments** | Rules, CCR-004/005, app bridge | 100% | Done | ATM, EMI, non-card debits, linked forex fees; engine 2.3.0 |
| **2. Server** | 2.1 to 2.3 | 100% | Done | Legacy routes gone, email import hardened, legacy tables dropped (migrations not applied anywhere) |
| **3. Phone storage** | 3.1 to 3.6 | 90% | Built, running on your phone | SQLCipher, encrypted receipts and spool, wipe. Locked-phone capture not yet checked |
| **4. Sessions** | 4.1 to 4.5 | 95% | Built | Sign-out revokes and wipes (you used it); warning now counts stored messages. Offline sign-out not tested |
| **5. Consent and privacy** | 5.1 to 5.3 | 100% | Done | SMS disclosure per account, Gemini wording, accurate in-app text |
| | 5.4 Policy, terms, 18+ box | 85% | Built | Needs your `[OWNER TO FILL]` details and review |
| | 5.5 Store and legal | 30% | Yours | `docs/release/store-and-legal-checklist.md` |
| **6. Release hardening** | 6.1 to 6.2 | 90% | Done | Obfuscated builds, audit; no release build run on a phone yet |
| **6b. AI template loop and jobs (D9)** | 6b.1 to 6b.5 | 95% | Done | Hourly rule signing, AI worker on the private host, console job health; Gemini dry run needs your key |
| **Learning loop (separate session)** | A1 to A8, B1 to B8, C1 | 100% built, 0% proven | Merged `e4831e5` | Its own status: `docs/superpowers/plans/2026-11-06-sms-learning-loop-STATUS.md`. Not on your phone yet |
| **Follow-ups** | Email consent enforced on the server, poller and webhook | 100% | Done | `c43dbc0`, `09687fc` |
| | Postgres suites in CI | 100% | Done | Job `postgres-suites`; never run on GitHub yet |
| | Crash reports from obfuscated builds | 100% | Done | `778e051`; steps in `docs/release/symbolication.md` |
| | Receipts in portable backup; receipts survive container moves | 100% | Done | `476ab25`, `381e397` |
| **Phone bugs found in testing** | Shortcut import crash | 100% | Fixed | `fc021a9` |
| | Splits not working | 100% | Fixed and confirmed | Backend switches were off |
| | Pages flicker during import | 100% | Fixed and confirmed | `c8f9853` and earlier (owner, build 124) |
| | Import notification (Lock Screen progress) | 90% | Fixed | `398ece5`, `eed32bf`; you saw it work |
| | Detail page "original SMS isn't on this phone" | 90% | Explained and fixed | Messages were gone because of sign-out, by design; page lookup fixed `db0f57d`; sign-out warning `6756c9f` |
| | November not fully captured | 50% | Partly checked | Nov 1 to 3 match your export; Nov 4 and later need your answer |
| **7. Verification** | 7.1 Automated suites and scanners | 97% | Passing | Numbers in "At a glance" |
| | 7.2 Accuracy on your real messages | 10% | Yours | Full import vs statements |
| | 7.3 Device acceptance table | 35% | In progress | About 23 rows open (`docs/OWNER_MANUAL_TASKS.md`) |
| **8. Cutover** | Keys, backups, empty database, session revoke, deploy | 0% | Needs your approval | Nothing started; every step needs your OK |
| **9. Friends run** | 7 days with testers, then public-launch gate | 0% | Not started | |

## 2. Branches (verified 6 Nov 2026, 10:45 IST)

| Question | Answer |
|---|---|
| Branch we are on | `sms-v2/integration` at `e4831e5` (same as the remote) |
| Local branches | 18 (integration, `master`, `codex/ios-shortcuts-prototype`, `codex/foreign-payments-complete`, `claude/learning-loop-c19dfa`, `rescue/main-checkout-2026-11-05`, and 12 `card-rewards/*`) |
| Remote branches besides `origin/sms-v2/integration` | 4: `master`, `main`, `dev`, `codex/ios-shortcuts-prototype` (the deploy trigger) |
| Merged into the current branch (or patch-equivalent) | **15 of 17** local branches: `master`, `codex/ios-shortcuts-prototype`, `codex/foreign-payments-complete`, `claude/learning-loop-c19dfa` and 11 `card-rewards/*` (phase1, wp1 to wp9, wp6a, wp6b) |
| Unmerged into the current branch | **2**: `card-rewards/release` (1 commit; the card-rewards session decides) and `rescue/main-checkout-2026-11-05` (old checkout snapshot, safe to delete when you agree) |
| Merged remote branches | All 4 remote branches are merged |
| Deleted so far | About 105 local branches and 11 remote branches (tips recorded in the notes below) |
| Worktrees | Integration, your main checkout (on the rescue branch), `claude/learning-loop-c19dfa`, `codex/foreign-payments-complete`, one old Codex leftover, plus the card-rewards ones |

---

## Detailed notes

## Status (5 Nov, historical: see section 1 above for the current state)

| Phase | State |
| --- | --- |
| 0. One codebase | Done locally (see below). Card-queue branch and card-rewards still open. |
| 1. SMS v2 only on the phone | DONE and merged into local `sms-v2/integration` (`812c201`). See Phase 1 details and the four owner decisions at the bottom. |
| 2. Server cleanup | DONE and merged into local `sms-v2/integration` (merge commit on top of `d50a81d`, `65f3593`, `800a57f`). Server 1,255 pass, 5 skipped, 0 fail (baseline 1,552; drop = deleted tests of deleted code). Email import kept (D4) and hardened. See "Phase 2 details" below. |
| 3. Encrypted storage | DONE and merged into local `sms-v2/integration` (merge `6870ca9`; sign-out wired to the wipe in `849bcca`). Full app suite 2,515 pass, 10 skipped, 0 fail; analyze 113 (baseline). Real-device checks still open (below). |
| 4. Sign-out and wipe | DONE and fast-forwarded into local `sms-v2/integration` (`4434e6d`). Flutter 2,472 pass; api 1,260 pass; auth 377 pass; analyze at 113 baseline. Wired to the Phase 3 wipe hooks in `849bcca`. |
| 1b. Foreign payments on v2 (owner request, 5 Nov) | DONE and merged into local `sms-v2/integration` (`d54a6c2`). Checks on the combined branch: lint clean; domain 1,204; rules tool 249; server 1,255 (5 skipped); full app suite 2,538 pass, 10 skipped, 0 fail; analyze 113. Details below. |
| 5. Consent and privacy (code) | In progress: agent on `fresh/phase5-consent` (`../pandapay-fresh-consent`): SMS disclosure, Gemini opt-in copy, accurate privacy text, policy and terms drafts, 18+ checkbox. 5.5 is owner work (checklist doc drafted by the agent). |
| 6. Release hardening | DONE and merged (obfuscated builds, auth `follow-redirects` fix, LO-11 marked Fixed, symbolication doc). Not yet run: a release build on a phone. |
| Cleanup of leftovers | DONE and merged (`ce26321`): D5 server escrow removed with a drop migration, dead learning-feedback queues, legacy console screens, stale docs. App 2,511 pass, analyze 111; api 1,248; auth 377; console 75. |
| 7. Gates / 8. Cutover / 9. Friends run | Not started; need you (real-message accuracy, device acceptance, approvals). |

## Phase 0: what was done

**Where the work lives now**
- Local branch `sms-v2/integration`, worktree `../pandapay-integration`. Tip `ae342a9`. Not pushed. `origin/sms-v2/integration` is still `48df9ca`.
- It contains: origin integration `48df9ca` + lane X (Kiwi receipt question, merge `7b2f3f7`) + selected changes from the main checkout (`ae342a9`).

**Main checkout (`codex/ios-shortcuts-prototype`, 114 uncommitted files)**
- Saved on local branch `rescue/main-checkout-2026-11-05` (`2d8a914`). The checkout itself is untouched except that it is now on that branch.
- Left out of that commit and still uncommitted in the checkout: `SMS_V2_STATUS.md`, `SMS_V2_IMPLEMENTATION_PLAN.md`, the fresh-start plan, and the deleted `Package.resolved` (Xcode lockfile).
- Checked each file against integration. 82 were identical. The rest were compared by change history:
  - **Taken** (new or applied cleanly): `auth_feedback.dart`, `live_alert_status.dart`, the login screen rework, `auth_api.dart`, `ios_shortcut_links.dart`, Android fastlane lanes and README, three-way merged iOS import files (`IncomingSmsIntent/Spool.swift`, `SmsImportBackgroundHost.swift`, `ios_sms_background.dart`, `ios_sms_import_screen.dart`, `ios_sms_intake_controller.dart`) and their tests, plus the new tests.
  - **Not taken:** foreign-payments files and `docs/sms-pipeline-v2/*` copies. Integration already has the released, newer versions.
  - When both sides edited the same lines, the rescue side won except for the `SMS_PIPELINE_V2` flag lines, which stay from integration.

**Checks on `sms-v2/integration` at `ae342a9`**
- App: analyze 180 issues before and after (no new ones). Full suite 3,285 pass, 8 skipped, 0 fail.
- Server: 1,552 pass. `test/shared_expenses_routes.test.js` needs `JWT_ACCESS_SECRET` and `DATABASE_URL` set; with placeholders it passes (7/7). Another developer's test.
- Auth: 375 pass.
- Needed one package download: `flutter_contacts` (from the split-bills work).

**Branches and worktrees removed (local only)**
- 34 merged agent worktrees (lanes A to X, WP-00 to WP-09 agents) and 53 merged local branches (`git branch -d`).
- 5 superseded branches deleted with `-D` after checking each. Tips are recorded so they can be restored with `git branch <name> <sha>` (while the commits remain in the object store or reflog):

| Branch | Tip | Why it was safe |
| --- | --- | --- |
| `sms-v2/wp-10-ai-templates` | `ddd5e13` | Integration has the same feature in later form (`20261112140000_sms_v2_templates.sql`, `template_worker.js`). Old copy used a retired migration number. |
| `sms-v2/wp-12-corrections` | `58d00ed` | Integration has the corrections store, route and sync (`20261112150000_sms_v2_corrections.sql`). Cherry-pick conflicted in 10 files that integration rewrote. |
| `sms-v2/main-claude-backup` | `01bd0a8` | Backup of the two above plus the oracle fix. |
| `sms-v2/wp-03a-banks` | `02b2d0f` | Bank rule files were regenerated by later lanes; scenarios with `chaipoint` pass the golden gate (239 cases, 30 scenarios). |
| `sms-v2/wp-03b-wallets` | `c5d44f9` | Cherry-picked it: lint reports its rule is shadowed by existing `UPI-GPAY-PAID-01`. Redundant, dropped. |
| (commit `9bd7088`, oracle fix) | n/a | I fixed the same test oracle differently earlier; integration has that version. |

**Not removed**
- 11 merged branches that Codex worktrees have checked out: `codex/foreign-payments-complete`, `codex/sms-v2-history-recheck`, `-personal-rule`, `-real-accuracy`, `-standalone-ios-rig`, `-wp12`, `-wp13`, `-wp14`, plus `sms-v2/claude-lanes`, `sms-v2/main`, `sms-v2/publish`. All are merged into integration; removing them means removing those worktrees (ask first).
- 10 `card-rewards/*` branches: another session's work (D7).
- `origin/feature/card-queue-geofence` (`3ef60d6`) and the local copy: see open items.

## Open items from Phase 0

1. **Card queue and geofence: DELETED on the owner's approval (5 Nov 2026).** `origin/feature/card-queue-geofence` was deleted from the remote. Tip was `3ef60d6` (24 Aug 2026, sujaykurtikar): 51 files, 7,331 lines (queue-driven card crawler, structured card import, place recommendation, geofence tweaks, catalogue screen). It was not merged because it conflicted in 10 files and its migrations `0036` to `0039` clash with existing numbers. To restore while GitHub still holds the commit: `git push origin 3ef60d6:refs/heads/feature/card-queue-geofence`.
2. **Card rewards (D7):** another session consolidates `card-rewards/*` into `card-rewards/release`. Not merged here.
3. **Push:** nothing pushed. Pushing `sms-v2/integration` needs a private-data scan first.
4. **Decisions D4 and D5:** D4 changed to "keep email import". D5 (remove server-escrowed account recovery) stands; the owner has not been shown the deletion list yet.

## Phase 2 details (server)

**Deleted:** routes `/transactions/from-sms`, `/from-sms/batch`, `/reconcile-sms`, `/transactions/sms-import-state`, `/sms/facts`; the per-message AI queue, Gemini worker and quota routes; SMS learning workers; the legacy client version gate; the `gemini-worker` and `sms-learning-worker` services in all three compose files; two Gemini pilot workflows; about 25 test files of deleted code. A guard test (`api/test/release_guards.test.js`) fails if a raw-SMS route comes back.

**Kept on purpose:** the email path (`sms_parser.js`, `importParsedMessage`, `imap_poller.js`, inbound-email routes, `parser_failures` and `needs_review_items` writes); `sms_rule_bundle.js` and the learning tables its SQL functions still read; `subscription_parser.js` (unused, not on the delete list).

**Email import hardening:** mailbox passwords sealed with AES-256-GCM in the API (key id and AAD bound to profile and connection); a bank-sender filter is required; parsed email text is nulled when the transaction is created; new `DELETE /imap-connections/:id` removes the sealed password; `email_import` added to consent purposes; new `GET /imap-connections/bank-senders` (app not wired yet).

**New migrations (not applied anywhere):** `20261115000000_fresh_start_drop_legacy.sql` (drops AI queue tables and unused functions, no CASCADE); `20261115020000_imap_credentials_app_encryption.sql` (truncates `imap_connections`, so every user reconnects their mailbox).

**Owner must handle at cutover**
1. New `IMAP_ENCRYPTION_KEY` (`openssl rand -base64 32`). The old format makes the API refuse to start in every environment. Optional `IMAP_ENCRYPTION_KEY_ID` (default `k1`).
2. Stop and remove the `gemini-worker` and `sms-learning-worker` containers on the host (`deploy.sh` refuses to deploy while an unlisted service runs).
3. Apply the two migrations.
4. Old env vars (`AI_WORKER_TOKEN`, `SMS_LEARNING_*`, `GEMINI_*` worker limits) are unused and can be removed.

**Follow-ups found**
- Admin console screens for legacy SMS AI and learning (`sms_ai_operations_screen.dart`, `sms_correction_cases_screen.dart`) will 404. Remove or hide them (console work, not yet assigned).
- `api/test/sms_category_taxonomy_contract.test.js` reads the legacy `sms_rule_bundle.dart`; the app agent was asked to handle it when it deletes that file.
- `email_import` consent is not enforced server-side on `POST /imap-connections` (the app screen gates it).
- Postgres-backed tests (`email_import_pg`, `sms_v2/*_pg`) are skipped by default and have no CI step; the agent ran them on a scratch Postgres and they passed.
- 10 `deploy/tests` fail on macOS bash 3.2; same failures on the base commit.

## Phase 1 details (app)

Merged into local `sms-v2/integration` as `812c201` (commits `0208e52`, `64c8041`, `0364192`, `f32f685`, plus Task 1.3 `fffd355`). Checks after merge: app analyze 113 issues, 0 errors, 0 warnings (baseline 180); full app suite 2,441 pass, 7 skipped, 0 fail (baseline 3,285; drop = about 45 legacy-only test files and parser tests deleted); server 1,255 pass. The merge conflicted on one server test; I kept the server agent's version and removed only the one test that read the deleted `sms_rule_bundle.dart`.

**Done**
- `SMS_PIPELINE_V2` flag gone; `X-Sms-Pipeline: v2` always sent; CI "SMS v2 enabled" step and rig script defines removed. Release guard tests added (v2 unconditional; no client code can upload raw SMS).
- About 91 files deleted: legacy parser (`local_sms_parser`, `sms_fact_scoring`), needs-review repository and screen, legacy rule bundle and outbox, auto-resolution, SMS backup file import, iOS parser prototype entry point, old-install DB migration, SharedPreferences token migration, D5 escrowed account recovery (coordinator, crypto, repository, scheduler, recovery screens, `Env.accountDataRecoveryEnabled`).
- `SmsSecurityPolicy` replaces `LocalSmsParser.sensitive` everywhere.

**Kept despite the plan**
- `indian_narration_sanitizer.dart`, `flashtext_merchant_extractor.dart` (statement reconciler and recurrence use them); `sms_learning_feedback.dart` (v2 corrections use it); `account_recovery_operation_gate.dart` (about 20 users, including reset-data and delete-account); new `sms_capture_signals.dart` holds regex helpers copied from the parser so the v2 intake gate behaves the same.
- Passphrase file export/import code kept, but no screen reaches it today.

**Behaviour changes**
- A message with no sender becomes a `financial_review / sender_unavailable` intake decision instead of a legacy needs-review row.
- The Android background SMS handler no longer falls back to the deferred-SMS spool; the inbox scan re-reads later.
- Subscription detail no longer fills mandate details from SMS bodies.

## Decisions needed from the owner (found in Phase 1)

1. **Foreign payments:** the feature (model, repository, screens, server) stays, but its only SMS extractor was deleted, so nothing on the phone creates foreign payments any more. Keep the screens, or remove the feature, or port the extractor to a v2 rule?
2. **Shared-learning feedback route:** `sms_learning_capture.dart` and `SmsFeedbackOutbox` still queue corrections to a server route that Phase 2 deleted, so those posts will fail. Remove them (v2 corrections have their own route) or keep the route?
3. **D5 notice:** server-escrowed account recovery has now been deleted on the app side (as planned). Server routes and tables for it, and the `PANDAPAY_ACCOUNT_RECOVERY_ENABLED` entries in compose and env examples, are still to remove.
4. **File export/import:** the passphrase export and import code has no screen. Add a Data transfer entry or delete it?

## Phase 4 details (sessions)

Commits: `01f8b68` DELETE /notification-devices; `9fb70ae` sign-out revokes session, unregisters push, wipes the phone; `c7ff880` 90-day refresh tokens; `0bbfa10` sync hand-entered bills; `4434e6d` UPI payment type on the server.

**Wire at integration (after Phase 3 merges):** `app/lib/features/auth/account_sign_out_provider.dart`, `phoneWipeHooksProvider` returns `NoPhoneWipeHooks` today. Implement `PhoneWipeHooks`: `destroyKeys()` = `InstallGuard.clearAllSecureStorage()` + database key `destroy()` (after `TokenStore.clear()`); `wipeStorageRoot()` = `StoragePaths.wipe()`; `clearHomeWidgets()` = `HomeWidgetService.clearAll()`; `preservedPreferenceKeys` = `{InstallGuard.markerKey}`. Also: the iOS spool key destroy (if Phase 3 adds one) goes in `destroyKeys()`; closing the database must work with the encrypted open.

**Cutover:** new migrations in order `20261115010000_user_commitments.sql` (new `user_commitments` table and sync function) and `20261115030000_transaction_payment_method.sql` (adds `transactions.payment_method`). If `JWT_REFRESH_TTL` is set explicitly on the server, change it to `90d`. Old 180-day tokens stay valid until D6 revokes every session.

**Users will notice:** sign-out tries to upload queued work for up to 20 seconds ("Saving your changes..."), warns with counts if anything would be lost ("Sign out of PandaPay?"), then deletes phone data; sessions last 90 days; hand-entered bills and the UPI label follow to a new phone.

**Not verified:** nothing run on a device; sign-out and bill sync are covered by unit, widget and SQL tests only; the new Postgres tests are not in `npm test` or CI; the sign-out flush does not call the private SMS-learning queue flush.

## Phase 3 details (storage)

Commits: `984f9e4` one backup-excluded storage root (Application Support/PandaPay, Android data_extraction_rules); `d4c9e42` SQLCipher database with the install key; `c7da3a0` clear Keychain leftovers after a reinstall; `a451693` encrypted receipt files (per-account key, `.pprc`); `ab0753e` encrypted SMS text in the iOS spool (CryptoKit, `SpoolCipher.swift`); `8d2313f` clear home widget data; `557eed5` `LocalAccountWipe`. Integration wiring: `849bcca` (`StoragePhoneWipeHooks`: destroy owned keys, clear secure storage, wipe the storage root, clear widgets; keeps only the install marker pref).

**Package change:** `sqlite3_flutter_libs` replaced by `sqlcipher_flutter_libs ^0.6.8`; iOS pods now use SQLCipher 4.10.0.

**Needs a real device (not testable on this Mac):** full iOS build (new Swift files `StorageBackupBridge.swift`, `SpoolCipher.swift` added to the Xcode project by hand); possible duplicate sqlite3 symbols between the spool's `import SQLite3` and static SQLCipher; Shortcut capture on a locked phone; reinstall leaves no Keychain leftovers; receipt attach, view and share; Android 12+ manifest merge; SQLCipher in the Android worker isolate.

**Caveats:** the portable backup export still copies attachment files raw (ciphertext if ever wired to a screen); `appDatabaseProvider` can throw `DatabaseKeyUnavailable` while the key store is locked.

## Foreign payments on v2 (details)

Commits: `19f0f64` engine support (CCR-004: `unitFrom` and `original` on a rule's emit amount; engine 2.2.0); `e09600f` foreign-only amount never treated as paise in the linker; `8764dbc` 48 foreign-currency rules plus 15 golden cases and 3 scenarios; `323be23` v2 foreign amounts become Foreign payments records (`foreign_payment_bridge.dart`); `bd667c6` docs (`docs/sms-pipeline-v2/foreign-payments-v2.md`, CCR-004); `e0fcec8` a foreign-only refund no longer joins an INR purchase.

**Behaviour:** a message with a foreign amount and a billed INR amount is a normal INR purchase carrying the original amount; a foreign-only message creates a Foreign payments row (`awaiting_rate`, server turns it into `estimated`) and never counts as INR spend or touches card or reward state. A bare `$` or `¥` shows as "Currency needed". A later INR-billed alert settles the earlier foreign-only row on an exact match (same direction, currency, amount and card, within 7 days, one candidate each way); weak or ambiguous matches stay pending. Idempotent by source key; no SMS text stored or sent.

**Not handled yet:** foreign ATM and cash, EMI conversions, non-card foreign debits; a separately posted forex markup alert stays an ordinary INR fee; a billed alert without a foreign amount cannot settle a foreign-only row by itself; a settled row shows as "Dismissed".

**Rules gates:** lint clean; regex parity 0 mismatches over 156,366 comparisons; golden gate ok.

## iPhone build 111 (5 Nov, evening)

First real iOS build with SQLCipher. It failed once: the system `SQLite3` module cannot build when SQLCipher's `sqlite3.h` is on the search path (21 errors, "unknown type name 'sqlite3_context'"). Fix (`IncomingSmsSpool.swift`): on iOS the spool imports `SQLCipher` (it opens the plain spool database like ordinary SQLite); the Mac test harness still uses `SQLite3`. Rebuilt, signed, installed and launched on the connected iPhone as **PandaPay SMS v2 Test** against the local rig (`/tmp/pandapay-sms-rig.gxWElK`, scratch data, test login `test@example.com`, phone `9999999999`, code `1234`). Mac Swift spool test still passes. Also renamed migration `20261112210000_sms_v2_release_metrics` to `20261112215000` (prefix collision with shared expenses).

**5 Nov, late:** owner confirmed build 111 works on the iPhone (opens, signs in). Phases 5, 6 and the cleanup are being built in parallel worktrees.

## Build 113 (5 Nov, night): crash on Shortcut import fixed

**Symptom (owner screenshot):** the Shortcut action "Capture PandaPay History SMS" failed with "the app quit unexpectedly"; then "The data is not in the correct format"; Retry processing did nothing.
**Cause (device crash report, SIGABRT):** `SmsImportBackgroundHost.startHeadless()` registered plugins on the headless Flutter engine before starting it (camera plugin assertion). The owner's earlier fix `d8e6edd` ("Start the background SMS engine before registering handlers") was reverted by my three-way merge of the uncommitted main-checkout work (I took the older side on conflicted hunks). **My regression.**
**Fix:** `fc021a9` restores engine-first order and the simulator registrant conditional. Other lines removed from the iOS import files versus origin were reviewed: they are newer main-checkout behaviour or the deleted legacy parser call.
**Build 113 also:** turns on `PANDAPAY_SHARED_EXPENSES_ENABLED=true` (Splits is a compile-time flag, default false; it was never merged-out). `PANDAPAY_STATEMENT_IMPORT_CONTINUATION_ENABLED` and `PANDAPAY_OTP_V2_ENABLED` stay off. A temporary flicker probe is in the local working tree only (uncommitted).
**Branch audit:** `git cherry` shows no commit on any remote branch or on the 5 local Codex branches that is not already in integration. Not merged by design: 10 `card-rewards/*` branches (other session, behind its flag).

## Branch cleanup (6 Nov, early morning)

**Audit:** `git cherry` against `sms-v2/integration` shows no unique commit on any remote branch or any local branch except: the 10 `card-rewards/*` branches (other session, kept), `fresh/phase5-consent` (agent still working, will be merged), and `rescue/main-checkout-2026-11-05` (one snapshot commit of the old checkout; kept for safety, delete once you agree nothing is missing).
**Removed locally:** 12 finished Codex/agent worktrees and their branches (`codex/sms-v2-wp12`, `-wp13`, `-wp14`, `-history-recheck`, `-real-accuracy`, `-standalone-ios-rig`, `-personal-rule`, `-personal-formats`, `-replay-restore`, `-template-privacy`, `-repeated-corrections`), plus `sms-v2/main`, `sms-v2/claude-lanes`, `sms-v2/publish`.
**Kept on purpose:** `codex/ios-shortcuts-prototype` (the branch whose push triggers the deploy workflow), `codex/foreign-payments-complete` (its worktree has one uncommitted doc edit), `master`, the old Codex worktree under `~/.codex/worktrees/0d9c` (51 uncommitted files, detached at 27 Oct).
**Remote branches:** NOT deleted. Several commits exist only on this Mac until `sms-v2/integration` is pushed; delete remote branches after the push.
**Rig:** Splits backend switches (`shared_expenses.settings` reads and proposals) were all off in the scratch database; turned on locally and set on every rig start (`63e1a4a`). **Flicker:** `012175b` merges per-batch refresh storms (3 s window).

## Pre-push scan (6 Nov, 04:30)

Scanned every added line of the 54 unpushed commits (31,397 lines, 528 files) for 10-digit mobile numbers, 12-digit references, secrets and keys, private data paths and non-example email addresses. Only synthetic values and generic bank sender addresses were found; no `/tmp/pandapay-real-sms` paths, no private keys, no real passwords. Clean.

## Remote branches deleted on 6 Nov 2026 (owner approved)

Each had no commit missing from `origin/sms-v2/integration` (`git cherry` showed 0). To restore one while GitHub still holds the commit: `git push origin <tip>:refs/heads/<name>`.

| Branch | Tip |
|---|---|
| `claude/home-bamboo-ink-restyle` | `2d87b46` |
| `claude/panda-pay-card-data-offers-1zoiu5` | `4b3f60e` |
| `codex/admin-console-fixes` | `8f9e6f1` |
| `codex/android-notification-icon` | `acbb591` |
| `codex/backend-stability` | `7f0b3c0` |
| `codex/card-scan-preview-tata-ocr` | `d1d34ff` |
| `codex/full-app-dynamic-audit` | `2ac9220` |
| `codex/payments-statement-navigation` | `87d838e` |
| `codex/sms-v2-integration/feature/split` | `92ee136` (other developer's split branch) |
| `feature/intelligent-pipeline-alignment` | `bf15e59` |

## 6 Nov, ~01:30: fresh-start test and remaining follow-ups

- Owner asked to stop fixing old-data bugs: everyone starts fresh. Test backend restarted empty (`/tmp/pandapay-sms-rig.WSmnfN`), test app uninstalled, clean build 122 then 123 installed. Temporary diagnostics removed.
- `6756c9f`: sign-out warning now counts stored original messages and says the history can be imported again (it used to sign out silently).
- `398ece5`: Lock Screen import progress is recreated after being swiped away, when the app becomes active or is about to leave, and during processing and paused states.
- Agents started for the remaining code items: server (enforce `email_import` consent on the server, remove unused env vars, Postgres tests in CI), more foreign rules (ATM, EMI conversion, non-card, separate markup fee), app (crash reports from obfuscated builds, encrypted receipts in the portable backup).
- Local commits not pushed yet: `db0f57d`, `6756c9f`, `398ece5`.

## 6 Nov, ~02:30: follow-ups merged into local `sms-v2/integration` (`e49c33c`)

- `778e051` crash reports from obfuscated release builds carry the build id and frame offsets; `docs/release/symbolication.md` has the steps (checked with a real obfuscated binary).
- `476ab25` portable backup decrypts receipts on export and re-encrypts them on restore (fixes the old "copies attachment files raw" caveat).
- `381e397` receipts keep working if iOS moves the app's data container (paths now stored relative to the receipts folder; older absolute paths re-rooted). Found by the app agent; fixed with a failing test first.
- `c43dbc0` server refuses mailbox connect and forwarding address without a current `email_import` consent (403 `email_import_consent_required`).
- `0a730a5` new CI job `postgres-suites` runs all PostgreSQL-backed suites against a throwaway service database (checked locally on Postgres 18; never run on GitHub yet). `5572524` fixes `rules_pg`, which had been failing on any real database.
- `78f662b` guard against the removed legacy SMS cutoff settings (they were already gone); dark-deploy runbook corrected.
- Checks after merge: app 2,600 pass, 10 skipped; analyze 111, no warnings; api 1,267 pass, 6 skipped; auth 377.
- Email consent gaps closed in `09687fc`: the poller skips owners without current consent, forwarded email for them keeps no text and makes no transaction, and `GET /forwarding-addresses/me` needs consent (api 1,273 pass). Still open: five legacy SMS-learning admin SQL tests should be deleted or rewritten (with Phase 6b).
- Still running: foreign rules (ATM, EMI, non-card, markup fee) and Phase 6b.

## Phase 6b merged (6 Nov)

`41a934d` job entry points in the image (rule job `--loop` hourly at :07); `2c65570` two services in `deploy/admin/compose.private.yml` + signing key for admin-api; `b2b662e` old AI worker settings removed with a guard; `6b5beaf` system status for both jobs + console held/failed reasons; `39a1de4` India rules + placeholder legend in the prompt, dry-run script (`docs/sms-pipeline-v2/handoff/WP-10.md`). Checks after merge: api 1,284 pass; auth 377; console 77, analyze clean.

**Cutover config (private admin host):** `SMS_RULES_SIGNING_KEY`, `SMS_RULES_KEY_ID` (admin-api refuses to start without), `SMS_V2_JOB_ADMIN_ID`, `GEMINI_API_KEY` (billed project), `SMS_V2_AI_MODEL`, `SMS_V2_AI_TPM`, `SMS_V2_AI_INPUT_USD_PER_MILLION`, `SMS_V2_AI_OUTPUT_USD_PER_MILLION`; outbound HTTPS to generativelanguage.googleapis.com; Google Cloud budget alert. After merge remove GitHub secrets `GEMINI_API_KEY`, `GEMINI_FALLBACK_API_KEY`, `GEMINI_MODEL`, `GEMINI_FALLBACK_MODEL`, `AI_WORKER_TOKEN`.

## Final local state before push (6 Nov)

`sms-v2/integration` at `f803d7b` (includes foreign-more: `64a7f73`, `560eac3`, `f777751`, `d9fc541`, `7e18604`). Gates on the combined code: rules lint clean; domain 1,260; rules tool 262 (regex parity 0 mismatches); api 1,284 pass, 6 skipped; auth 377; console 77, analyze clean; app 2,636 pass, 10 skipped, analyze 111, no warnings. Pre-push scan of all unpushed lines: clean (one test placeholder string). Build 125 installed over existing data on the rig `WSmnfN`; the rig still serves the rules it signed at start, so the new foreign rules reach the phone after the next rig restart or at cutover.

**Pushed** `sms-v2/integration` `eed32bf..f803d7b` (27 commits) on 6 Nov with owner approval. No workflow runs on this branch.

## Learning loop (separate session, 6 Nov)

A different session ("Build the SMS learning loop (all parts)", branch cut from `sms-v2/integration` `f803d7b`) is building the whole SMS learning-loop plan (`docs/superpowers/plans/2026-11-06-sms-learning-loop.md`, A1 to C1). This session does not build it. When that branch reports done, the owner decides when it merges and this session does the merge. Until then, avoid editing the files that branch changes: `api/src/sms_v2/template_worker.js`, `ai_templates.js`, `corrections_route.js`, `security.js`, `rule_stats.js`, `api/src/sms_v2/jobs/*`, `review_controller.dart`, `corrections_service.dart`, `app/lib/features/sms_v2/sync/*`, `console/lib/features/sms_rules/*`, `console/lib/data/sms_v2_admin_api.dart`, `overview_screen.dart`, `api/src/admin/route_manifest.js` and its two JSON mirrors.

## 6 Nov, 08:20: learning loop merged into local `sms-v2/integration` (`93e99bb`)

The `learning-loop` session finished all 18 tasks (A1 to C1) plus its report on `claude/learning-loop-c19dfa`. The owner approved the merge and it was fast-forwarded into the local `sms-v2/integration` (no merge commit, no conflicts). Not pushed: integration is 22 commits ahead of `origin`. Re-run on the final tree: app 2,675 pass (10 skipped, analyze 110 infos); console 119; api 1,343 pass (6 skipped); auth 377; the private-admin script passes end to end. A contracts mismatch that already existed on integration (18 removed `/admin/sms-ai/*` and `/admin/sms-learning/*` routes still listed in the two route mirrors) was fixed in `93e99bb`. The edit-freeze list in the "Learning loop (separate session)" section above no longer applies. Current status, percentages and next actions: `RELEASE_STATUS.md`.
