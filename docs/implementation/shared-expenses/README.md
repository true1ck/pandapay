# Shared expenses implementation register

Baseline `sms-v2/integration` @ `bf6bec9b`. Started 4 November 2026. Root owns this register and integration files; every implementing agent owns a packet status/handoff. Update this file and its packet evidence before ending a work increment. Never mark a build, mock, pure helper or generated image as verified end-to-end finance.

## Status vocabulary

`not_started` → `implementing` → `review` → `integrated` → `verified`; `blocked` records an explicit dependency. A verified sub-increment does not complete its whole packet. Each entry includes owned paths, contract version, dependency commit, implemented behavior, exact test results, scenario IDs, unresolved gates and next owner. Evidence and completed behavior are append-only history; correct a superseded claim explicitly.

| Packet | Status | Current sub-increment / next gate |
| --- | --- | --- |
| P00 | implementing | [Foundation contract](../../contracts/shared-expenses-v1/README.md) implemented and tested as a subset; [P00 handoff](P00-status.md) lists independent review and full contract gates. |
| P01 | not_started | Real isolated PG/RLS/migration/role-setup/backup proof needed; no shared migration deployed. |
| P02 | implementing | Exact allocation, one-expense balances, personal cost and checked source adapters delivered/tested in Node and Dart; [P02 handoff](P02-status.md). Foundation subset awaits independent review; accepted journal/corrections/settlement math remain open. |
| P03–P13 | not_started | Follow [work packages](../../design/shared-expenses-agent-work-packages.md); source-linked vertical slice awaits P01/P03/P05 integration. |

## Ownership and handoff

Root currently owns new `api/src/shared_expenses/**`, `api/test/shared_expenses*.test.js`, `packages/pandapay_domain/lib/src/shared_expenses/**`, public export, scoped tests, `scripts/check_shared_expenses_web.py`, `contracts/shared_expenses/v1/**` and packet status files. No other live writer is assigned. Parallel agents were unavailable due to usage limits at this increment; independent review remains a gate, not a claimed pass.

Before the next worker starts, record its packet/path lease, accepted contract version and dependency evidence. Root alone integrates router/providers/API bootstrap/global schema/lockfiles and migration assignments. Do not edit another packet's file concurrently or stage unrelated local artifacts.

## Preserved baseline

Old draft contracts and original samples/plans are retained in stash `30cb0be3f60acb810970147417f063de99e3cc4e`; do not pop/drop/reapply automatically. New contract files are revised for SMS v2. Existing untracked Flutter appdata, logs/device images and AGENTS.md predate this work and remain out of scope.

No production rollout, source cutover, DB mutation or device verification occurred in this increment. Ordinary local feature implementation and verification continue under the user's instruction and AGENTS.md.

## Execution log

- 2026-11-04: branch/source rechecked; no tracked modifications at start. Foundation subset and register created. Red/green tests and completed evidence will be recorded in `P02-status.md` and mirrored here after execution.
- 2026-11-04: foundation red tests failed on missing modules/functions before implementation. Added exact BigInt allocation, paid/share/balance preview, personal-cost overlay, strict source identities, checked source-int/wire/Money adapters and common fixtures. New suites: **36 Node tests and 32 Dart tests passed**, including 500 randomized cases per runtime. These are helper tests, not app integration.
- 2026-11-04: refreshed API dependencies from the existing lockfile (`npm ci --ignore-scripts --no-audit --no-fund`) and refreshed Dart metadata offline from the existing local cache. No manifest or lockfile versions changed. The initial dependency/analytics/cache failures were runner failures, not passes.
- 2026-11-04: full-suite execution exposed existing Windows fixture-loader separator and CRLF-frontmatter assumptions. Fixed four test files only, matching the CLI's existing path normalization; separate local commit **`9e23201d`**. No production SMS rules changed. Detailed red/green counts and remaining skipped DB gates: [P02 evidence](P02-status.md).
- 2026-11-04: final full regression: **1,036 Dart tests passed**, scoped analyzer clean; API **1,445 passed / nine skipped**; separate SMS v2 API **102 passed / 34 skipped**. Dart2JS/Node passed all 23 common vectors plus Money boundary checks. HTML inventory/navigation/font/responsive checks passed. Real DB, app/device, independent review and capacity gates remain pending.
- 2026-11-04: local save points on the selected branch: **`2d6163e1`** backend math/source identities/common fixtures/contract; **`40d5cd5b`** matching Dart domain and JavaScript-target check. Both include their focused tests and depend on the `9e23201d` test-portability prerequisite. No push or deployment.

## Next work, in dependency order

1. Independent review of the foundation contracts/math and source-reference boundaries; root keeps the integration lease until reassigned.
2. Finish P00 authenticated source-admission/version/remap, whole-revision consent, command/event/ACL/recovery contracts and executable fixtures. A syntactically valid ID is not funding authorization.
3. P01 additive isolated PostgreSQL/RLS/role-setup/backup coverage, plus P03/P05 canonical source + immutable local command vertical slice. Real populated-DB and concurrency proof required before accepted shared writes.
4. P04/P06 existing-form integration, then Insights tabs and Payments subscription routing using actual Bamboo fonts/components. No new UI has been wired by this foundation increment.

Each future update must record test failures/skips as well as passes. Keep whole packets open when only a sub-increment is verified. Record the eventual integration commit in the packet handoff before another agent depends on it.
