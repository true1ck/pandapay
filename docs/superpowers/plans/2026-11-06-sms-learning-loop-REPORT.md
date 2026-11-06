# SMS learning loop: run report

Plan: `docs/superpowers/plans/2026-11-06-sms-learning-loop.md`. Run on 2026-11-06.

**Outcome: done.** Every task (A1 to A8, B1 to B8, C1) is built with its tests and its own commit, and every suite passes. What is left is the owner's list at the end: a paid Gemini key and the real-Gemini dry run, device checks, store forms, lawyer review and the production deploy. No code can do those.

- **Branch:** `claude/learning-loop-c19dfa` (a worktree branch, cut from `sms-v2/integration` at `f803d7b62`). The plan's name `fresh/learning-loop` was not used; the run stayed on its own worktree branch, as instructed.
- **Final commit:** the commit that adds this file (`docs: learning loop report`); its SHA is in the run's last message and in `git log -1`.
- **Not done on purpose:** no `git push`, no merge into `sms-v2/integration`, no deploy, no production setting or key change, no data deletion, no call to the real Gemini API. Tests use a fake provider and a fake App Check hook.
- **Size:** 126 files changed, about 14,500 lines added, 21 commits including the plan copy and this report.

## Tasks and commits

| Task | Commit | What it delivers |
|---|---|---|
| Setup | `e62f2c0` | Both plans copied into the worktree |
| A1 | `5fef637` | Review and fix screens read the sharing opt-in; a fix from an opted-in user carries its layout |
| A2 | `8437a8c` | Opt-in v3 (`sms-shared-learning-v3`) covers layouts, shop categories and names; revoking scrubs fixes; new copy, policy section 5, store checklist |
| A3 | `580df46` | Review offer card: 30-day snooze, stops after the third "Not now"; sharing status line on the fix form |
| A4 | `48ef12c` | Admin-adjustable settings with ceilings, per-account limits, `learning_paused` switch, console Settings tab with reasons and audit |
| A5 | `e0ba2f7` | `POST /sms/v2/learning-signals`: contract, consent, caps, one row per account, shop and value, retention pruning |
| A6 | `2137fb5` | Phone sends category choices, shop names and shops left in Other; queue only with consent, emptied on withdrawal |
| (A6 fix) | `9029e5e` | Removes an unused variable in the A6 test |
| A7 | `028d670` | Console Learning page: K-anonymous candidates, Create rule, Dismiss with a reason |
| A8 | `bb29eb1` | Shop-name (merchant alias) drafts, candidates and publish |
| B1 | `e766c5a` | AI worker records the prompt version; layouts an active rule already reads end as `covered` with no AI call |
| B2 | `9b2b9ee` | Prompt carries user reports, past rejections and similar rules; draft refused if it reads a sibling layout; `--eval` in the dry-run script |
| B3 | `710df0d` | Approve or reject AI drafts with a reason; status chips and badge in the Templates tab; shared test harness |
| B4 | `e8ce028` | AI category suggestions for shops left in Other (off by default, one per shop key, shared budget) |
| B5 | `b8df4a3` | New shared category rules re-categorise what the rules chose, never what the person set or confirmed |
| B6 | `3efc0b7` | Private AI rule performance reported and shown on the draft (30-day hits, fixes, phones) |
| B7 | `bfce019` | Requeue, Block, Ask again, Reporters with a temporary limit, Recent changes, Overview tiles; coverage test fails on any route, setting or status without a console surface |
| B8 (server) | `069b6ee` | 13-step end-to-end scenario on PostgreSQL with a fake provider; `templates_pg` moved onto the harness |
| B8 (phone) | `65e936b` | Phone-side loop test |
| C1 | `628dd02` | Poisoning, authorisation, deletion and injection tests; `docs/release/learning-data-flows.md`; Play and App Store label drafts |
| Handoff | this file | `docs: learning loop report` |

New migrations, in order: `20261116000000_sms_shared_learning_v3`, `…000500_sms_v2_settings`, `…010000_sms_v2_learning_signals`, `…020000_sms_v2_learning_decisions`, `…030000_sms_v2_alias_drafts`, `…040000_sms_v2_ai_learning`, `…045000_sms_v2_template_decisions`, `…050000_sms_v2_merchant_suggestions`, `…060000_sms_v2_admin_controls`, `…070000_sms_v2_results_attested_only`. All new tables have row-level security and every table that holds an account id cascades from `profiles`.

## Suites on the final tree

Run after C1 (the report commit changes only this file). Real counts:

| Suite | Command | Result |
|---|---|---|
| App | `cd app && flutter test` | **2675 passed, 10 skipped, 0 failed** |
| App analyze | `cd app && flutter analyze` | 0 errors, 0 warnings, **110 infos** (see note 1) |
| Console | `cd console && flutter analyze && flutter test` | analyze: no issues; **119 passed** |
| API unit | `cd api && npm test` | **1349 tests: 1343 passed, 6 skipped, 0 failed** |
| API PostgreSQL | `cd api && node --test --test-concurrency=1 test/sms_v2/*.test.js` | **257 passed, 0 failed, 0 skipped** |
| Auth | `cd auth && npm test` | **377 passed** |
| Admin console security | `node --test --test-concurrency=1 tests/admin_console_security/*.test.js` | **18 passed, 0 skipped** (includes the clean-schema gate, which now runs 18 PostgreSQL test files) |
| Deploy | `python3 -m unittest discover deploy/tests` | **48 passed** in a `python:3.12-slim` container (see note 6) |

PostgreSQL tests ran against a throwaway Docker database (`learning-loop-pg`, port 5593) with `SMS_V2_TEST_DATABASE_URL` and `SMS_V2_TEST_ADMIN_DATABASE_URL` set, plus `JWT_ACCESS_SECRET` and `API_DATABASE_URL` for `npm test`. The end-to-end test was run twice in a row to prove its cleanup.

## Where the result differs from the plan, and why

1. **`flutter analyze` is not at zero.** It reports 110 infos (111 at the base). None is on a line this work added and none is a warning or an error; they sit in 37 untouched or older files. Fixing them is unrelated cleanup, so it was left alone. Like the base, `flutter analyze` still exits non-zero because of them.
2. **Category rules and shop names publish to everyone at once.** They are parts of the signed bundle, not per-rule versions, so the four-cohort golden check runs but one publish reaches every cohort. The end-to-end step 6 asserts that every cohort carries the rule, instead of "testers first, others later". Staging them would need versioned parts.
3. **K counts the people who reported a shop, not only those who agree.** A shop with 2 votes for Dining and 1 for Groceries is shown (3 people) with its split and agreement, which is what the edge-case table asks for. End-to-end step 12 is adapted: after the first withdrawal the row stays with `users = 2, keyUsers = 3`; it disappears when the second person withdraws and fewer than K remain.
4. **The AI verdict is `rejected`, not `failed`.** The sync contract already allows `pending`, `ready` and `rejected`; the phone drops the private rule on `rejected`. The phone test covers it (an extra test beyond the plan).
5. **The harness was created in B3, not B8.** B3's PostgreSQL tests needed it. B8 moved `templates_pg` onto it; C1 added a per-token `sessions` option for the authorisation tests.
6. **Deploy tests need Linux bash.** On macOS (bash 3.2) some of the 48 deploy tests fail on bash features; all 48 pass under bash 5.2 in the container. Nothing in this work touches the deploy scripts.
7. **A result function now serves attested submitters only** (`20261116070000_sms_v2_results_attested_only`). End-to-end step 3 requires that a phone that failed App Check gets no private rule, so the function that returns a layout's result now serves attested submitters only.
8. **Test infrastructure fixes.** `tests/admin_console_security/full_schema.test.js` named a test file wrongly (A4). Under `node --test` its nested PostgreSQL run silently executed nothing, because the parent's `NODE_TEST_CONTEXT` leaked into the child; it is now cleared and the gate runs the old files plus nine learning files (1.7 s before, 8.6 s after, 18 files). PostgreSQL tests share one database, so run them with `--test-concurrency=1`.
9. **Smaller choices.** The history re-check of B5 works in batches of 50 events; the Overview tile "Learning candidates" opens "SMS Pipeline Rules"; a category draft opened from the Learning page uses a stable UUID per shop, so reopening it continues the same draft.
10. **The legacy "SMS Rule Approvals" screen and its routes were left in place.** Removing them is a separate change.
11. **The plan text was not edited.** Items 2 to 4 are the places where its text no longer matches what shipped.

## Owner checklist (nothing here can be done by code)

- [ ] **1. Paid Gemini key and budget alert** (fresh-start step 8.8b). Create the key in a Google Cloud project with billing on, set a budget alert, and confirm in AI Studio that the project is on the paid tier. Then the real-Gemini dry run, from a scratch folder outside the repository:
  ```
  ADMIN_API_DATABASE_URL=<rig admin_api_runtime URL> SMS_V2_JOB_ADMIN_ID=<owner admin_users.id> \
  GEMINI_API_KEY=… SMS_V2_AI_MODEL=… SMS_V2_AI_TPM=… \
  node api/scripts/dry_run_sms_v2_templates.js --limit 50 --out <scratch>/ai-dry-run.json
  … same environment … node api/scripts/dry_run_sms_v2_templates.js --eval --out <scratch>/ai-eval.json
  ```
  `--eval` prints "N of M approved drafts reproduced"; run it before any prompt or model change.
- [ ] **2. Device acceptance table, on a release build** (plan, "Acceptance"): opted-in fix from the detail screen carries a layout; not opted in sends nothing; Review offer snoozes 30 days and stops after the third "Not now"; a category change on three phones shows in the Learning tab, "Create rule", publish, and a fourth phone's Swiggy spends in Other become Dining while a Groceries choice stays; three people renaming "PAYU SWIGGY" then "Create name"; Blinkit in Other on three phones with the AI suggestion (B4) visible; a rejected AI draft sends the sender's message back to Review; changing the layout cap to 20 makes the 21st layout return 429 and switching AI off pauses the worker within a minute, both in the audit log; turning sharing off removes that user's signals and the Learning counts drop.
- [ ] **3. Store forms.** Play Data safety: add "App activity: other user-generated content (shop categories and names you choose), optional" next to "Messages: SMS (redacted layouts only), optional"; App Store privacy labels likewise; Apple organization account. Drafts are in `docs/release/store-and-legal-checklist.md` (sections 3.2, 3.3 and 4.1).
- [ ] **4. Lawyer review** before public launch: the privacy policy section 5, the opt-in wording (`TemplateSharingCopy`) and `docs/release/learning-data-flows.md`, including its seven open points (Gemini terms and location, whether a shop key is personal data, the 180-day default, audit entries that keep an account id after deletion, the Reporters list, age, withdrawal path).
- [ ] **5. Phase 8 deploy:** apply the ten new migrations, deploy the two private jobs (`sms-v2-template-worker` and `sms-v2-rule-jobs` in `deploy/admin/compose.private.yml`), and set the production values for the settings in the console's Settings tab (K, retention, caps, AI budget, `ai_merchant_suggestions_enabled`, which is off by default).

## Follow-ups (not part of this plan)

- Remove the legacy "SMS Rule Approvals" screen and routes.
- Decide whether category and shop-name rules should be staged by cohort (note 2).
- Clear the 110 analyzer infos in older files.
- Decide whether per-account limit entries in the audit log should be scrubbed when an account is deleted.
