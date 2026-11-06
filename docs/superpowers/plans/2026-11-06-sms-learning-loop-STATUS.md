# SMS learning loop: status, what is left, what next

As of 2026-11-06, branch `claude/learning-loop-c19dfa`, last commit `93e99bb`. Plan: `2026-11-06-sms-learning-loop.md`. Run report: `2026-11-06-sms-learning-loop-REPORT.md`.

## How to read the percentages

- **Built** means the code, its tests and its documents exist on the branch, committed, and every suite passes. I measured this.
- **Proven** means someone ran it for real: a real phone, the real Gemini API, the real store forms, production. Nobody has done that yet, so these are 0% everywhere. I do not guess a partial number for work that has not started.
- **Overall** is counted by deliverable: 25 deliverables (19 plan tasks, the report, and the 5 owner steps). A deliverable counts only when it needs nothing more from anyone. Weights would be made up, so there are none.

## Overall

| Measure | Result |
|---|---|
| Plan tasks built and tested (A1 to A8, B1 to B8, C1) | **19 of 19, 100%** |
| Hand-off report | **1 of 1, 100%** |
| Owner steps that need a person (key, devices, stores, lawyer, production) | **0 of 5, 0%** (all 5 are prepared in code or documents) |
| **Overall deliverables finished** | **20 of 25, 80%** |
| Overall proven in the real world | **0%**: nothing has run on a real phone, against real Gemini, or in production |

Size: 22 commits, 126 files changed, about 14,500 lines added, 10 new migrations, 47 test files added or changed.

## Plan tasks

| Task | What it is | Built |
|---|---|---|
| A1 | Review and fix screens read the sharing opt-in | 100% |
| A2 | One opt-in (v3) covers layouts, shop categories and names; revoking deletes | 100% |
| A3 | Review offer card with 30-day snooze | 100% |
| A4 | Admin-adjustable settings, per-account limits, pause switch | 100% |
| A5 | Server receives anonymised learning signals | 100% |
| A6 | Phone sends category choices, shop names, shops left in Other | 100% |
| A7 | Console Learning page with K-anonymous candidates | 100% |
| A8 | Publish learned shop names | 100% |
| B1 | AI skips covered layouts, records prompt versions | 100% |
| B2 | Better AI input, `--eval` in the dry-run script | 100% |
| B3 | Approve or reject AI drafts with a reason | 100% |
| B4 | AI category suggestions for shops left in Other | 100% |
| B5 | New category rules re-categorise automatic choices | 100% |
| B6 | Private AI rule performance shown on the draft | 100% |
| B7 | Everything visible and controllable in the console | 100% |
| B8 | End-to-end tests (PostgreSQL and phone) | 100% |
| C1 | Privacy, abuse and injection tests; data-flow record; store label drafts | 100% |
| Handoff | Report with SHAs, counts, deviations, checklist | 100% |

Suites on the final tree: app 2675 passed (10 skipped), console 119, API 1343 passed (6 skipped), API PostgreSQL 257, auth 377, admin security 18, deploy 48 (in a Linux container). `scripts/test_private_admin.sh` passes end to end, including the route contracts check, which commit `93e99bb` fixed.

## What is left

Everything below needs a person, a key or a decision. None of it can be finished by more code.

| # | Item | Prepared (code or document) | Done | What is missing |
|---|---|---|---|---|
| 1 | Paid Gemini key, Google Cloud budget alert, real dry run | 100% (script, `--eval`, worker, budget cap) | 0% | Create the key and alert; run `node api/scripts/dry_run_sms_v2_templates.js --limit 50 --out <file outside repo>` and `--eval`. Draft quality is unmeasured until this runs. |
| 2 | Device acceptance table on a release build | 100% (automated equivalents pass) | 0% | Run the 9 checks on three phones or accounts; see the report. The app was never run on a device or simulator in this work. |
| 3 | Play Data safety, App Store labels, Apple organization account | 100% for the answers (drafted in `docs/release/store-and-legal-checklist.md`); the Apple account is owner-only | 0% | Enter them in the consoles; confirm the Apple organization account. |
| 4 | Lawyer review | 100% (`docs/release/learning-data-flows.md`, 7 open points) | 0% | A lawyer reads the policy section 5, the opt-in wording and the record; answers the 7 points. Needed before public launch, not for the friends run. |
| 5 | Production deploy (Phase 8) | 100% (10 migrations, 2 private jobs) | 0% | Apply migrations; deploy `sms-v2-template-worker` and `sms-v2-rule-jobs`; set production values in the console Settings tab. |

## Follow-ups outside the plan

| Item | State |
|---|---|
| Remove the legacy "SMS Rule Approvals" screen and routes | 0%, left in place on purpose |
| Stage category and shop-name rules by cohort (today one publish reaches everyone) | 0%, a design decision |
| Clear the 110 analyzer infos in older files (111 at the base; none on lines this work added) | 0% |
| Decide whether audit entries for per-account limits keep the account id after deletion | 0%, lawyer open point 4 |

## Not covered by this run

- **The rest of the fresh-start release plan** (`2026-11-05-fresh-start-release.md`, Phases 0 to 9). Its 164 checkboxes are all unticked in the repository, so the file cannot tell me its progress, and I have not audited it against the code. I give no percentage for it. The learning-loop work depends on its Phase 6b, which is already on the base branch.
- **Merging.** This branch is not merged into `sms-v2/integration`. That branch belongs to the "SMS classification pipeline review" session.
- **Things only tests have seen:** the console screens (a fake admin, not the real API in a browser), the phone behaviour (Flutter tests), and the AI path (a fake provider).

## Next actions, in order

1. **Review and merge the branch** into `sms-v2/integration` through the session that owns it. A `/code-review` pass first is worth the time: 126 files changed.
2. **Get the paid Gemini key and budget alert** (action 1 above), then run the dry run and `--eval`. This decides whether the AI drafts are good enough to switch on.
3. **Apply the 10 migrations to the rig database and run the friends test**: three phones or accounts, sharing on, the device acceptance table.
4. **Pick the production settings** you want at launch: K (default 3), signal retention (default 180 days), daily caps, AI budget (default $10 a month), and whether to switch on `ai_merchant_suggestions_enabled` (off by default).
5. **Fill the store forms and send the data-flow record to the lawyer.**
6. **Phase 8 deploy** of the two private jobs once 1 to 3 look good.
7. **Decide on the follow-ups**, starting with the legacy approvals screen.
