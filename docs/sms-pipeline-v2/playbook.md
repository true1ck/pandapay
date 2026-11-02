# Agent playbook

Every agent, whatever its model, follows these rules. They keep parallel work from breaking the app, and keep `sms-v2/main` releasable at every merge. `sms-v2/main` is the integration branch: it starts from the production line (`codex/ios-shortcuts-prototype`) and merges back only at release. A repo copy of every tab lives in `docs/sms-pipeline-v2/`, with one file per work package in `work-packages/`.

## Rules every agent follows

### Read first, in this order

1. **Overview:** the Summary and Target architecture sections.
2. **Contracts:** the whole tab.
3. **Your work package**, in the Work packages tab or `docs/sms-pipeline-v2/work-packages/WP-XX.md`.
4. **This playbook.**

### Set up

- Work in your own worktree, branched from `sms-v2/main`. For example: `git worktree add ../pandapay-wp05 -b sms-v2/wp-05-event-linker sms-v2/main`.
- **Never push.** The orchestrator merges and pushes. Pushing `master` or `codex/ios-shortcuts-prototype` deploys to production.
- Install dependencies:
  - `cd packages/pandapay_domain && dart pub get`
  - `cd app && flutter pub get`
  - `cd api && npm ci`
- The stack is Riverpod 2.6.1 with codegen and go\_router 14. Do not upgrade any package. Examples written for Riverpod 3 do not apply.

### Stay inside your lane

- Edit only the paths your work package owns, plus new files under them.
- Your work package lists **touch points**: the only edits allowed in shared files. Make them exactly as described.
- Need something outside your lane? Stop, write a request at `docs/sms-pipeline-v2/requests/WP-XX-<slug>.md` (what, why, which files) and report to the orchestrator. Do not work around it, and do not stub a contract.

### The build flag

- **App:** `const bool kSmsPipelineV2 = bool.fromEnvironment('SMS_PIPELINE_V2');` in `app/lib/features/sms_v2/flag.dart` (created by WP-01).
  - Every new behaviour on an app code path runs only when it is true.
  - With the flag off, the app behaves exactly as today and every existing test passes unchanged.
- **Server:** new routes are always registered, but return `404` unless the `sms_pipeline_v2_enabled` row in `feature_flags` is on. The guard `requireSmsV2` is built by WP-08.
- **Domain package and console** need no flag: new code there is unused until it is wired in.
- **Run with the flag:** `flutter run --dart-define=SMS_PIPELINE_V2=true` and `flutter test --dart-define=SMS_PIPELINE_V2=true`.

### Tests and commands

- **Write the failing tests for your done criteria before the code.**
- **Synthetic messages only.** Never commit a real person's SMS text, name, phone number or account digits. Golden cases built from real data pass through WP-00's redaction tool before commit.
- Run the full suites at checkpoints, not after every edit:

| Suite | Command |
| --- | --- |
| Domain | `cd packages/pandapay_domain && dart test` |
| App, flag off | `cd app && flutter analyze --no-fatal-infos && flutter test --concurrency=1` |
| App, flag on | `cd app && flutter test --concurrency=1 --dart-define=SMS_PIPELINE_V2=true` |
| Codegen (when providers change) | `cd app && dart run build_runner build --delete-conflicting-outputs` |
| Server | `cd api && npm test` |
| Contracts | `cd packages/pandapay_domain && dart test test/sms_v2/contract_fixtures_test.dart` and `cd api && node --test test/sms_v2/contracts.test.js` |
| Golden set | `cd tools/sms_rules_cli && dart run bin/sms_rules.dart golden --bundle ../../app/assets/sms_rules/baseline_bundle.json` |
| Database | Apply migrations to the local Docker Postgres, then run `db/tests/*sms_v2*_test.sql` (see Test and release) |

Server files under `api/src/sms_v2/` are syntax-checked by `scripts/check_sms_v2.js`, which WP-08 adds to `npm run check`. No other agent edits `api/package.json`.

### Do not touch

- **Gmail and email:**
  - `app/lib/features/import/gmail_*`, `email_forwarding_screen.dart`, `imap_connection_screen.dart`
  - `api/src/email_ingest.js`, `api/src/imap_*.js`
  - both card discovery engines: `app/lib/data/card_discovery_engine.dart` and `api/src/card_discovery.js`
- **The old pipeline until WP-17:** for example `local_sms_parser.dart`, `sms_import_store.dart`, `api/src/sms_parser.js`, `api/src/gemini_*.js`, `api/src/ai_*.js`. Edit only through listed touch points; fixing bugs there is out of scope, because they are being replaced.
- **Applied migrations:** never edit them; add new files.
- **Generated `*.g.dart` files:** regenerate, never hand-edit.
- **Dependencies:** no `pubspec.yaml` or `package.json` dependency changes beyond those your work package lists.
- **Unrelated features.**

### Definition of done (every work package)

- [ ] Every done criterion in the work package is met, with tests.
- [ ] With the flag off, the full app suite passes unchanged.
- [ ] With the flag on, the app suite passes.
- [ ] The domain, server, contract and golden suites pass, and no golden metric dropped.
- [ ] `flutter analyze` adds no new warnings.
- [ ] No real SMS data, secrets or keys are committed.
- [ ] The status in the Work packages index is updated, and a handoff note exists at `docs/sms-pipeline-v2/handoff/WP-XX.md`: what was built, any deviation, any follow-up.
- [ ] The pull request lists each done criterion with its evidence (test names, command output).

## Orchestration

One orchestrator session (Opus) assigns work packages, merges, runs the full suites after each merge, and decides contract change requests. Work-package agents never merge.

### Assigning

- Assign in the order of the Work packages index. Run packages in parallel only when the index says they can.
- **Model choice:**
  - Opus for WP-01 (contracts), WP-05 (linker), WP-16 (migration) and WP-17 (cutover), where mistakes are expensive.
  - Sonnet for the rest.
  - WP-03 is split into four sub-packages, so four Sonnet agents can work at once.
- Brief each agent with this text, filling in the number and slug:

```
You are implementing WP-XX (<title>) of the PandaPay SMS pipeline v2.
Read, in order: docs/sms-pipeline-v2/overview.md, contracts.md, playbook.md, work-packages/WP-XX.md.
Work only in worktree ../pandapay-wpXX on branch sms-v2/wp-XX-<slug>, created from sms-v2/main. Never push.
Follow the playbook exactly: owned paths only, the build flag, tests first, no real SMS data.
When done, report: files changed, commands run with their results, evidence for each done criterion, and any deviation or request you filed.
```

### Merging

- Merge in index order within a milestone. After each merge:
  1. Run every suite in the playbook with the flag both off and on.
  2. Rebase the next branch onto `sms-v2/main`.
- A milestone gate passes only when every package in it is Done and the gate check in Test and release passes.
- A red suite after a merge is fixed or reverted before anything else merges.

### Hotspot files (one owner each)

| File | Owner | What others do |
| --- | --- | --- |
| `app/lib/app/providers.dart` | WP-14 | Put providers in `app/lib/features/sms_v2/providers/` |
| `app/lib/app/router.dart` | WP-15 | Ask WP-15 for a route |
| `api/src/index.js` | WP-08 (one line: `registerSmsV2(app, deps)`) | Add one registration line in `api/src/sms_v2/index.js` |
| `api/package.json` | WP-08 | Nothing; `check_sms_v2.js` globs new files |
| `app/pubspec.yaml` | WP-01 (assets), WP-13 (attestation plugin) | File a request |
| `console/lib/main.dart` and console routes | WP-11 | File a request |
| Activity, Home and Insights totals (`activity_projection.dart` and similar) | WP-06 | File a request |
| `contracts/sms/v2/` | WP-01, then change requests | File a contract change request |

### Contract change requests

1. The agent writes `docs/sms-pipeline-v2/requests/CCR-<n>.md`: the change, why, and which work packages it affects. Then it stops.
2. The orchestrator approves or rejects it. An approved change is made on a short `sms-v2/ccr-<n>` branch, following WP-01's rules, and merged first.
3. Every affected branch rebases and re-runs the contract suite.

### Status

- Each package's status lives in the Work packages index: Not started, In progress, In review, Done or Blocked.
- A blocked agent reports the blocker and stops. It does not guess.
- The orchestrator mirrors the doc into `docs/sms-pipeline-v2/` whenever a tab changes, so agents without doc access read the same text.
