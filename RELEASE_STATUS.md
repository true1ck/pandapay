# PandaPay fresh-start release: status, what is left, what is next

**Last updated:** 8 Nov 2026. Section 0 is current. Sections 1 to 7 are the 6 Nov snapshot, kept for history; rows that have since changed are marked.
**Branch:** `latest-dev` at `4112b13`, pushed to origin.
**Production:** cut over to SMS v2 on 6 Nov 2026.
**Privacy:** this file quotes accuracy numbers from the owner's private sample (totals only, no messages).

Plans: `docs/superpowers/plans/2026-11-05-fresh-start-release.md` (decisions D1 to D9) and `docs/superpowers/plans/2026-11-06-sms-learning-loop.md` (with its `-REPORT.md`). The older log `FRESH_START_PROGRESS.md` has the per-phase details.

## 0. Where things stand on 8 Nov 2026

- **Code:** `latest-dev` on GitHub is at `4112b13` (pushed 8 Nov 2026, 11 commits on top of the merge with 67 commits from other sessions: Splits, the SMS AI drafts worker, performance work). A push to `latest-dev` runs Build and test and then deploys to production on its own.
- **Production:** cut over to SMS v2 only on 6 Nov 2026 (new product database, feature flags set, minimum app version 1.0.17). Signed rule bundles 9 to 12 are live since 8 Nov 2026 (1,140 rules, 125 ignore rules, 154 merchant aliases; cohorts all, 25%, 5%, testers) and renew hourly. They add 41 rules, 26 ignore rules and 16 aliases to bundles 5 to 8.
- **App:** build 1.0.17 (142) is installed on the owner's iPhone. Since 6 Nov it adds: a "Refresh rules and re-sort" button; a fix so records the server refuses for good no longer block the re-sort; earlier "ignored" messages are read again when they arrive again; a checklist after an edit (choose which other transactions to change, nothing ticked for type or payment-method changes); a Save confirmation; "Transfer between my accounts" and "Credit card bill payment" actions; a "Transfer type" choice in Edit; a searchable, grouped category picker.
- **Rule edits not yet live:** the server import adds only new rule ids, so 188 edits to existing rules in the repo (among them four Union Bank rules) are in no bundle yet. Each needs a new version published from the admin console or by a script.

- **Replay of six months of the owner's real bank messages** (8 May to 8 Nov, 2,613 messages read from the Mac's synced Messages, counts only, nothing stored in the repo) through the real phone pipeline with the 1,099 repo rules: 649 transactions. Findings: (1) 11 messages from one half-day window on 3 Nov, 2 of them money, never reached the app (the iPhone Shortcut did not return them; cause unknown); (2) 43 messages the phone had marked "ignored" are counted by today's rules (5 card spends and 38 small cashbacks and refunds), because the old keyword gate called them promotions and an ignored decision was final (fixed in the app in `dfe5d07`); (3) about 11 messages are real rule gaps (foreign-currency card spend, small card spend, income-tax challan payments, Airtel recharges, wallet payments); (4) merchant names split by processor prefixes and cut-offs (Swiggy under 10 names, Amazon under 7, MakeMyTrip under 3), now merged by the new aliases.
- **Not yet checked:** the "Needs review" count on the phone (the app database is encrypted, so it cannot be read from the Mac); why the Shortcut missed the 3 Nov window; whether payments to the owner's own name become transfers automatically (needs the profile name set).

**Release figure:** the cutover row (section 4) is now done, which moves the whole-release estimate from about 68% to about 76% by the same arithmetic (weights unchanged, no other row re-estimated since 6 Nov).

**Next, in order:** (1) publish new versions of the 188 edited rules (the import skips edits); (2) look into why the Shortcut missed a half-day of messages; (3) read the phone's Needs review list and the replay together; (4) set the profile name so own-name transfers are recognised; (5) the older owner items in section 7 (Gemini key, legal and store work, device acceptance, friends run).

## 1. The two numbers

| Measure | Now | Was (6 Nov, 01:00) |
|---|---|---|
| **Build work** (code, tests, docs written and passing) | **about 97%** | about 90% |
| **Whole release** (build plus your checks, store and legal work, cutover, friends run) | **about 68%** | about 65% |

The whole-release figure moves slowly because most of what is left is not code. It is device checks, your legal and store work, the Gemini key, the production cutover and the 7-day friends run.

How the numbers are made: each item below has a weight (its rough size and risk) and a "done" percentage. The overall figure is the weighted average. The weights and the percentages are my estimates, not measurements. The arithmetic is in section 6.

## 2. Build work, item by item

| Item | Done | State | What is left |
|---|---|---|---|
| 0. One codebase (branches, rescue, cleanup) | 100% | Done | Delete the rescue branch and the learning-loop worktree and branch when you agree |
| 1. SMS v2 only in the app | 100% | Done | Nothing |
| 1b. Foreign payments on v2 | 100% | Done | Edge cases listed in `docs/sms-pipeline-v2/foreign-payments-v2.md` |
| 2. Server cleanup and email-import hardening | 100% | Done | Nothing in code. The production migrations are applied at cutover |
| 3. Phone storage security (SQLCipher, receipts, spool, widgets) | 90% | Built, runs on your phone | Locked-phone capture, receipt check, full release build |
| 4. Sessions (sign-out wipe, 90-day tokens, bill and UPI sync) | 95% | Built | Your phone check of sign-out and offline sign-out |
| 5. Consent and privacy (code) | 100% | Merged | Nothing in code. Your wording and details are in the legal row |
| 6. Release hardening (obfuscation, dependency audit) | 90% | Done | No release build has been run on a phone |
| 6b. AI jobs and hourly rule signing | 95% | Merged | Your paid Gemini key and the real dry run (see 4) |
| **Learning loop A1 to C1** | **100%** | **Merged into integration** | Real-world checks are in section 3 |
| Cleanup (D5 escrow, dead queues, legacy console screens) | 100% | Done | The legacy "SMS Rule Approvals" screen and routes are still there |
| Bugs found in testing | 90% | Fixed | November capture is only 50% explained (see 5) |

## 3. The learning loop, task by task

Built by the `learning-loop` session on its own branch, re-checked by me, fast-forwarded into integration today. Every task has its own commit and tests. The second column is what is still unproven in real use.

| Task | Commit | Built and tested | Checked in real use |
|---|---|---|---|
| A1 Opt-in read fix | `5fef637` | 100% | 0% |
| A2 Opt-in v3 (layouts, shop categories, shop names; revoking scrubs fixes) | `8437a8c` | 100% | 0% |
| A3 Offer card in Review (30-day snooze, stops after 3 "Not now") | `580df46` | 100% | 0% |
| A4 Admin settings, per-account limits, pause switch | `48ef12c` | 100% | 0% |
| A5 Learning-signals route (consent, caps, retention) | `e0ba2f7` | 100% | 0% |
| A6 Phone sends category choices, shop names, shops left in Other | `2137fb5` | 100% | 0% |
| A7 Console Learning page (K-anonymous candidates, Create rule, Dismiss) | `028d670` | 100% | 0% |
| A8 Shop-name rules (draft, candidate, publish) | `bb29eb1` | 100% | 0% |
| B1 Prompt version recorded; covered layouts skip the AI | `e766c5a` | 100% | 0% |
| B2 AI sees user reports, past rejections, similar rules; `--eval` | `9b2b9ee` | 100% | 0% |
| B3 Approve or reject AI drafts with a reason | `710df0d` | 100% | 0% |
| B4 AI category suggestions for shops in Other (off by default) | `e8ce028` | 100% | 0% |
| B5 New shared rules re-categorise automatic categories only | `b8df4a3` | 100% | 0% |
| B6 Private AI rule performance on the draft | `3efc0b7` | 100% | 0% |
| B7 Everything visible and controllable in the console (coverage test) | `bfce019` | 100% | 0% |
| B8 End-to-end test on PostgreSQL, plus the phone side | `069b6ee`, `65e936b` | 100% | 0% |
| C1 Abuse, privacy and injection tests; data-flow record | `628dd02` | 100% | 0% |
| Report and contracts fix | `b9ff6c7`, `93e99bb` | 100% | n/a |

Size: 126 files, about 14,500 lines added, 10 new migrations.

## 4. Verification, your work and the cutover

| Item | Done | Owner | State and what is left |
|---|---|---|---|
| 7.1 Automated suites and scanners | 92% | Me | See the results table below. Left: re-run the OWASP scanners on the final tree and the golden and accuracy commands after the merge |
| 7.2 Accuracy on your real messages | 10% | You | Full history import and comparison with bank statements. Last measurement on the private sample (5 Nov, before the foreign rules): 94.4% weighted and 95.9% unweighted, target 95%. Not re-measured |
| 7.3 Device acceptance on release builds | 25% | You, with me | The table has about 23 older rows plus about 8 new learning-loop rows. Only import, Splits and Shortcut capture are confirmed (build 115). Open: the 8 new rows, locked phone, sign-out, offline sign-out, reinstall, new phone, second account, account deletion, email and the AI-sharing rows. The 25% is my estimate |
| Legal and store work (placeholders, grievance officer, store forms, lawyer review) | 30% | You | Drafts exist in `docs/release/store-and-legal-checklist.md` and `docs/release/learning-data-flows.md` |
| Paid Gemini key, budget alert, real dry run and `--eval` | 0% | You, then me | Not started |
| 8. Production cutover | 100% | Done 6 Nov | Done. Production runs SMS v2 only |
| 9. Friends run, 7 days | 0% | You | Not started |

Automated results on `93e99bb` (the ones I re-ran myself):

| Suite | Result |
|---|---|
| App | 2675 passed, 10 skipped, 0 failed. Analyze: 110 infos, no errors or warnings |
| Console | analyze clean, 119 passed |
| API unit | 1349 tests, 1343 passed, 6 skipped, 0 failed |
| Auth | 377 passed |
| Private-admin script (clean schema built from all migrations, PostgreSQL tests, contracts check) | passes end to end |
| API PostgreSQL suites on their own | 257 passed (from the learning-loop report; I did not run these separately) |

## 5. Open points and risks

1. **Nothing is backed up off this Mac.** 22 commits (the learning loop and its report) exist only locally.
2. **Build 125 on your phone and the test rig pre-date the learning loop.** The rig needs a restart on the merged code to apply the 10 new migrations and the new foreign rules. The phone needs a new build before any learning-loop check can happen.
3. **Category and shop-name rules reach everyone at once.** They are part of the signed bundle, so the testers-first cohort staging does not apply to them. Layout rules still stage by cohort. Acceptable for a friends test, to be decided before public launch.
4. **Accuracy is just under target.** 94.4% weighted against 95% on 5 Nov. It was measured before the foreign ATM, EMI and fee rules.
5. **November capture gap.** The rig has nothing for 4 Nov and nothing after 5 Nov, 8:23 pm. We need you to say whether bank messages exist for those times.
6. **Lawyer review open points.** Seven are listed in `docs/release/learning-data-flows.md`, including the Gemini terms and location, whether a shop key counts as personal data, and the 180-day default retention.
7. **Card rewards (D7) is a separate session.** Its 11 branches each carry between 7 and 413 commits that are not in integration (branch activity as late as 6 Nov, 05:55). It ships only if its own gates pass by the release cut, otherwise it goes in the next release. It is not counted in the numbers above.
8. **Smaller leftovers.** The legacy "SMS Rule Approvals" screen and routes; 110 analyzer infos in older files; five legacy SMS-learning admin SQL tests to delete or rewrite; deploy unit tests fail 10 under macOS bash 3.2 (all pass under Linux bash 5.2); the passphrase file export/import code still has no screen.

## 6. How the percentages add up

| Group | Item | Weight | Done | Weight x done |
|---|---|---|---|---|
| Build | 0. One codebase | 5 | 100 | 500 |
| Build | 1. SMS v2 only (app) | 10 | 100 | 1000 |
| Build | 1b. Foreign payments | 8 | 100 | 800 |
| Build | 2. Server cleanup | 8 | 100 | 800 |
| Build | 3. Phone storage | 10 | 90 | 900 |
| Build | 4. Sessions | 6 | 95 | 570 |
| Build | 5. Consent and privacy (code) | 6 | 100 | 600 |
| Build | 6. Release hardening | 3 | 90 | 270 |
| Build | 6b. AI jobs and rule signing | 6 | 95 | 570 |
| Build | Learning loop | 14 | 100 | 1400 |
| Build | Cleanup | 3 | 100 | 300 |
| Build | Bugs found in testing | 4 | 90 | 360 |
| | **Build total** | **83** | | **8070, so 97.2%** |
| Verify | 7.1 Automated | 6 | 92 | 552 |
| Verify | 7.2 Accuracy | 8 | 10 | 80 |
| Verify | 7.3 Device acceptance | 10 | 25 | 250 |
| Verify | Legal and store | 6 | 30 | 180 |
| Verify | Gemini key and dry run | 3 | 0 | 0 |
| Verify | 8. Cutover | 10 | 0 | 0 |
| Verify | 9. Friends run | 8 | 0 | 0 |
| | **Whole release total** | **134** | | **9132, so 68.1%** |

## 7. Next actions, in order

| # | Action | Who | Needs |
|---|---|---|---|
| 1 | Scan the 22 new commits for private data, then push `sms-v2/integration` | Me | Your OK to push |
| 2 | Restart the test rig on the merged code, build and install build 126 on your iPhone | Me | Your OK (this is a checkpoint, not a per-change build) |
| 3 | Run the learning-loop device checks and the older open rows of the acceptance table | You, with me watching | Build 126 |
| 4 | Create the paid Gemini key and a budget alert, then run the dry run and `--eval` yourself in your own terminal (the key stays out of chat and out of the repo) | You, then I read the result files | Google Cloud billing |
| 5 | Import your full history and compare monthly totals with statements. Tell me whether bank messages exist for 4 Nov and after 5 Nov, 8:23 pm | You | Time |
| 6 | Fill every `[OWNER TO FILL]` placeholder, name a grievance officer, confirm disk encryption and backup retention, then the store forms | You | Provider and store answers |
| 7 | Small clean-up pass: remove the legacy "SMS Rule Approvals" screen and routes, fix the five legacy SQL tests, re-run the OWASP scanners and the golden and accuracy commands | Me (a new session) | Your OK |
| 8 | Decide on staging category and shop-name rules by cohort | You | A short discussion |
| 9 | Cutover (Phase 8), one step at a time | You approve, I run | Items 1 to 6 done |
| 10 | Friends run for 7 days. Review the console Templates and Learning tabs at least every 2 days | You, with me | Cutover |
| 11 | Public-launch gate: certificate pinning (LO-12), lawyer review, store declarations, DPDP readiness before 13 May 2027 | You | After the friends run |

Items 1 and 2 are the next steps that unblock everything else.
