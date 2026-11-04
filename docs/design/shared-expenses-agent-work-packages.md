# PandaPay shared expenses: multi-agent work packages

Updated 4 November 2026. Execution companion to the [production plan](shared-expenses-production-implementation-plan.md), [product/UX/accounting specification](shared-expenses-product-ux-accounting-spec.md) and [scenario matrix](shared-expenses-scenario-test-matrix.md). No agents or implementation jobs are launched by this document.

**Current assignment baseline: `sms-v2/integration` @ `bf6bec9b`.** Read the [branch review](shared-expenses-sms-v2-branch-review.md) and [live implementation register](../implementation/shared-expenses/README.md) first. The old nine draft contracts stay stashed. The revised foundation subset now has tested Node/Dart allocation, balances/cost and source identity/amount adapters; [P00](../implementation/shared-expenses/P00-status.md) and [P02](../implementation/shared-expenses/P02-status.md) remain open. No shared migration/accepted write/UI integration is enabled. Do not switch back to the old split branch or activate SMS v2 cutover.

Split packets P00–P13 are distinct from existing SMS v2 WP-00–WP-17. Current source pipeline owners retain interpretation, correction/replay, source contracts, category/instrument resolution and cutover. Shared-expense agents submit narrowly scoped adapter changes to the lead instead of rewriting those systems.

## 1. Operating model

One lead/integrator is accountable for architecture, contract changes, scope, migrations, integration and release. Each work packet has one current writer and a distinct reviewer. Multiple AI agents can implement packets, but no agent treats its private interpretation as a financial contract. A QA/reviewer should independently derive expected outputs from agreed fixtures, not merely mirror implementation.

Use a bounded active set: a practical starting arrangement is one lead and three independent packet workers, with review/QA staggered as workers finish. These are roles, not a requirement to run fourteen agents simultaneously. More agents do not remove dependencies and can increase conflicts, inconsistent assumptions and review load.

**Do not begin all packets at once.** P00 contracts precede financial implementations. P01/P02/P04/P05 may then progress within their seams. P03 plus local/UI adapters must produce a complete source-linked vertical slice before broad feature integration. Reviewers can inspect completed artifacts while other independent packets proceed.

Every agent reads `AGENTS.md`, current git/worktree status, packet instructions, relevant durable project context and the owning source before changing anything. Preserve unrelated edits and generated files. Do not reset/clean broadly, stage the entire worktree, rewrite applied migrations or infer permission to install/deploy from a design assignment.

## 2. Shared contracts that P00 must freeze

The owned [foundation contract directory](../contracts/shared-expenses-v1/README.md) now exists and permits only its pure calculation/identity subset. The complete artifacts below remain proposed deliverables unless explicitly marked complete in the live implementation register. Do not infer that every P00 interface is frozen because that directory exists.

| Contract artifact | Required contents |
| --- | --- |
| `money-and-recognition.md` | Minor-unit/string wire representation; accepted/provisional/disputed states; contribution/share/residual/cost; deterministic allocation; rounding tie order; bounds/overflow; corrections and offset policy. |
| `api.schema.json` / endpoint contract | Command envelopes, required revisions, IDs, read DTOs, allowed actions, basis/currency/coverage, pagination/cursor reset, structured errors and unknown-version handling. |
| `events-and-sync.md` | Event identity, aggregate revision, consumer idempotency, commit-safe change cursors, tombstones/revocations, pending overlay and reconciliation; metadata coalescing versus financial command immutability. |
| `authorization.md` | Role/action matrix, group/direct history access, source/receipt privacy, claim consent, membership revocation, account switch/erasure and replay authorization. |
| `ui-state-contract.md` | Every screen/tab state, amount labels, allowed actions, route owners, Back/deep-link behavior, Bamboo tokens/fonts and hidden-amount behavior. |
| `fixtures.json` | C01–C22 expected numbers, generated sample reconciliation, repeated rounding and named scenario inputs/outputs across Node and Dart; deterministic IDs/clocks and synthetic data only. |
| `capabilities-and-migration.md` | Client/server capabilities, legacy format meaning and conversion, minimum versions, reporting-basis migration, backup manifest and kill-switch semantics. |
| `load-profiles.json` | Reproducible workload assumptions, distributions, skew, target rates/durations, data size and expected correctness checks; no invented benchmark results. |

The lead owns this directory and approves amendments. An agent proposing a schema/error/enum change submits its reason, compatibility impact, changed fixture and affected consumers. The lead updates the contract first or rejects the change; consumers do not fork local DTOs to unblock themselves. Unknown facts are recorded as blockers for the affected packet while independent work continues.

## 3. File ownership and collision policy

| Surface | Writer policy |
| --- | --- |
| `app/lib/app/router.dart`, `app/lib/app/providers.dart`, `api/src/index.js` | Lead is sole integrator. Workers provide small adapter patches/instructions and focused tests; do not simultaneously modify these files. Extract new feature modules rather than growing them unnecessarily. |
| `app/lib/data/local/app_database.dart`, migration manifests/IDs, `api/src/db.js` | One migration/storage integration writer. P01/P05 prepare reviewed changes; lead reserves sequence and integrates without overwriting existing schema work. |
| Existing `transaction_detail_screen.dart`, `quick_add_screen.dart` | P06 current writer. Other UI packets consume extracted presenters/controllers or submit a handoff; do not append independent sheets/forms to these already-large files. |
| `spend_trends_screen.dart`, report/budget source files | P08 current writer, with P06/P07 consuming typed query/row interfaces. Shared provider composition remains lead-owned. |
| `subscriptions_screen.dart`, grouped Payments route/body adapter | P04 owns the bounded presentation extraction; P11 owns recurring domain behavior in separate modules. Coordinate a sequential adapter handoff for overlapping edits. |
| New `app/lib/features/shared_expenses/**` | P04 owns shell/theme/route-facing widgets; P07 owns friend/group/context views; P09 owns settlement UI. Give each a separate subtree and shared UI-state contract. |
| Proposed `api/src/shared_expenses/**` | P03 owns command/query core; P09 owns settlement modules; P10 owns invitation/claim modules; all use P01 authorization and P02 math. No competing repositories or journals. |
| Proposed `app/lib/data/shared_expenses/**`, local outbox/DTO adapters | P05 owns storage/sync/repository contracts; P06/P07/P09 use the public interface rather than writing SQLite directly from widgets. |
| `app/pubspec.yaml`, lockfiles, theme/global widgets, CI/workflows | Lead approval and one writer. Existing stack is reused; package upgrades/rewritten theme/CI are separate scope, not opportunistic packet work. |
| Tests / fixtures | Each worker owns its scoped tests; P12 owns integrated/fault/load harness. Financial golden fixtures are lead-owned. Reviewer tests must not mutate canonical expected values to make code pass. |
| SMS v2 `contracts/sms/v2`, pure Dart engine/linker/source ledger, correction/replay and source storage/sync | Existing source owners + root integrator. Split workers consume typed adapters; no competing parser, currency registry, event ledger or silent source contract edits. |
| `sms_v2/ledger/providers.dart`, `reports.dart`, `projection_writer.dart` and foreign valuation adapters | Root sequences P03/P05/P06/P08 handoffs. Freeze local v2 hash/server UUID/source alias mapping and source mutation notification before parallel consumers write to these seams. |

Separate branches/worktrees are useful for independent writes when the execution environment supports them. Use the workspace's approved worktree tooling and `codex/` prefix. Never move or delete another agent's files to resolve a conflict. In a shared worktree, exclusive ownership and explicit checkpoints are mandatory; two live writers never edit the same file. Branch isolation does not make conflicting contracts safe.

## 4. Work packet register

### P00 — Lead: contracts, risk decisions and baseline

- Inputs: all current plan artifacts, `AGENTS.md`, current source/runtime inventory and workload assumptions.
- Deliver: section 2 contract set; route/state map; all C01–C22 expected outputs; baseline data preservation manifest; dependency graph, assigned owners and capability plan; actual stack/deployment unknowns; proposed SLO/load limits recorded as proposals.
- Close: accepted/group claim policy, direct-context privacy, max bounds, source reservation protocol, global lock order, commit-safe cursor, idempotency retention and legacy conversion/old-client fencing. Obtain actual ops inputs before release-dependent decisions; do not guess them.
- Current branch gate: typed legacy/v2/confirmed-foreign source identity and eligibility, local projection versus canonical UUID mapping, v2 numeric-int/shared-string adapter, readiness/reporting matrix and source retraction/remap protocol. Whole accepted balanced revisions cannot become one-sided while a member's claim remains unaccepted. Old P00 drafts remain archived until these are frozen.
- Review: domain/math, security and UI reviewers examine the same fixtures and scenario IDs. No financial writer starts with placeholder contracts.
- Done: every dependent packet can implement against stable shapes; unresolved questions have an owner and gate, not contradictory hidden defaults.

### P01 — Schema, authorization, migration and data preservation

- Depends: P00.
- Owns: additive `shared_*` schema, policies, minimal roles/functions, constraints/index candidates and migration/backfill verification; coordinated SQLite schema seam with P05.
- Deliver: migrations on current baseline, rollback-compatible schema, entity/relationship diagram, populated-account before/after validation, app-role tests for cross-member and direct-context access, invalid-write constraints and migration runbook.
- Inspect current SMS v2 migrations/security/portable coverage and foreign payment writers. Reserve a successor after actual current lexical migration ordering, not the old suggested date prefix. Role setup broad grants and new-schema lifecycle/coverage remain gates.
- No scope: broad auth redesign, existing migration edits, unverified service-role bypass, deleting history, changing source/reward state.
- Gates: real PostgreSQL, not only mocked queries; two concurrent membership/source/command operations; least-privilege worker/export access; drift/checksum preflight; legacy data unchanged with feature off.

### P02 — Exact money and financial domain engine

- Depends: P00; can run beside P01.
- Owns: pure checked arithmetic, equal/exact/%/shares allocation, deterministic obligation matching, settlement allocation/correction functions and equivalent Dart contract adapters.
- Deliver: bounded arithmetic module, canonical request/hash serialization rules, golden fixtures/property-based/randomized tests across Node/Dart and exact error semantics.
- Reuse current amount/currency helpers through explicit checked adapters. Keep SMS v2 JSON integer minor types and foreign precision contracts compatible; no source schema migration solely for split wire strings. Bank source projection is not the shared obligation engine.
- Gates: C01–C22, paise remainder repetition, max bounds/overflow, zero-share payer, partial share/multiple sources, reverse/refund after settlement, circular obligations and no cross-group silent netting.
- No scope: network, SQL calls, widget math, rewards re-evaluation or a new independent Money framework.

### P03 — Command service, queries, journal and projections

- Depends: P00/P01/P02. Coordinate repository interface with P05.
- Owns: new command/query modules, idempotency receipts, current revisions, source reservation integration, transactionally consistent scoped balances/cost facts, domain events, keyset/change feeds and projection consumers.
- Deliver: auth-bound API behavior, retries and operation lookup, current DTOs, bounded reads, projection rebuild/reconciliation and race/fault tests.
- Gates: lost response → same effect; edit/settlement/source conflict → no partial effects; stale/cross-scope cursor denied; no public cache leak; read-your-write/projection lag truthful; safe event ordering and once-per-consumer effects.
- Include v2 event/hash → local display → active server transaction mapping, correction/replay/supersede and rejected-instrument cleanup in source reservations. Do not treat source event complete/user_confirmed as payment verification or shared acceptance.
- No scope: exposing private source data, every-read journal scans, calling a provider inside a DB transaction or an arbitrary group balance PATCH endpoint.

### P04 — Bamboo UI shell, navigation and Subscriptions relocation

- Depends: P00 UI contract; may start using named deterministic contract fakes while backend work proceeds.
- Owns: new Splits page with Friends/Groups/Activity TabBar, contextual Expenses/Balances/Totals shell, reusable loading/empty/error/offline presenters and subscription-body extraction. Lead integrates existing root routes/providers.
- Deliver: rendered tab/layout states and routing adapter proposal; subscription body/action reuse with one Payments header; fonts/tokens/accessibility evidence; dynamic text/hidden amounts/keyboard/Back behavior.
- Gates: actual `BambooFonts` Outfit + IBM Plex Sans, current theme/components; no nested headers/two simultaneous tab levels; old subscription links preserve IDs/list state; main dock unchanged; second-level pages match current shell visibility.
- No scope: copied dark reference UI, screenshot bitmap UI, new global add form, fabricated success/settled states, alternate analytics or new font/icon packages.

### P05 — SQLite, repository, offline commands, sync and recovery

- Depends: P00; P01 schema coordination; P03 API contract before end-to-end completion.
- Owns: namespaced local shared tables/repository, durable command graph and provisional overlays, bounded push/pull/cursor/coverage behavior, operation status lookup, restore/export coverage and worker-isolate integration.
- Deliver: one repository API consumed by UI; indexed local queries, cancellation/account fences, transactional local save/page cursor, explicit blocked/retry states and two-device restore fixtures.
- Gates: process death at each save/ack/pull phase; disk full; permission revoked offline; account switch; duplicate response/backup replay; pending shared commands never silently omitted by Backup complete; no main-isolate full scan.
- Current v2 outbox payload replacement and admitted kinds are not suitable for immutable financial commands. Persist shared dependency on source admission explicitly and preserve links/private metadata through replay and foreign valuation transitions.
- No scope: putting settlement events into last-write-wins field coalescing, regenerating IDs or deleting local rows because a page is incomplete.

### P06 — Existing-source detail, Quick Add and private metadata

- Depends: integrated P03/P04/P05 vertical slice; P02 allocation interface.
- Owns: additive existing split sheet/summary expansion, Quick Add payer/sharing fields and Scan Bill review, source linking and metadata preservation.
- Deliver: existing source / new own payment / someone else paid / multiple payers / partial sharing entry intents through one owner. One compound durable own-source+expense operation; explicit recoverable source-saved/split-pending state if temporary orchestration is not atomic.
- Gates: no fake own debit/default card for friend-paid; no second manual form per group/tag/category; same source cannot overfund two accepted expenses; notes/tags/receipts preserved; saved split loading/conflict never becomes empty overwrite.
- Legacy conversion: reviewed people/remainder mapping, pending edit fence and old-client compatibility; never infer people from notes automatically.
- Current v2-aware detail edits use correction owners. Reuse them and original foreign-payment confirmation/detail; never send `v2:<hash>` to a legacy UUID endpoint or insert a second source bank row as a workaround.

### P07 — Groups, friends, direct expenses, lifecycle and shared activity

- Depends: P03/P04/P05; repository/DTO contracts frozen.
- Owns: lists/search/filter/create/member/settings/date flows, direct-context bucket, selected person/group presenter and immutable social/audit row presentation.
- Deliver: matching friend/group/overall snapshots; settled visibility preference; roster/history permissions; optional timezone-aware reminder; no-expenses/settled/net-zero/credit/pending/disputed/incomplete variants; activity actor/action/time/provenance and safe event routing.
- Gates: hidden rows never change balances; new obligation resurfaces; direct expense privacy; leave/remove preserve past obligations; payer-only versus not-involved copy; group event between others doesn't become personal spending; search/paging/Back state restore.
- No scope: another app-level Account/Activity navigation bar, cross-group offset by display net, deleting a group to clear debt, independent group expense editor or public contact lookup.

### P08 — Reports, budgets, account/reward invariance and app-wide touchpoints

- Depends: P03/P05 and product amount rules; coordinate P06 source changes.
- Owns: personal-cost facts in server/local reports, current Home/Activity/Spending/category/tag/merchant/export/widget/assistant consumers, budget basis and snapshot/coverage, source/reward/cap invariance tests.
- Deliver: app-wide amount-basis map, shadow projection comparison, report rollups/invalidations and scoped read adapters. Reuse full Appendix A disposition; no agent reinvents new split UI on every page.
- Gates: personal total/rows/chart/filters/count/export agree; tags/parent categories don't inflate; friend-paid recognized once; settlements no extra spend/income/reward; actual account/issuer obligations remain full; explicit account-level basis transition preserves existing budget definitions.
- No scope: subtracting debts in widgets, reward denominator based on personal share, missed-reward claims for friends' cards, or changing all reports through one giant provider refresh.
- Adopt current source `LedgerReadModel` once across legacy, no-v2-ready, mixed replay and v2-ready states; retain own transfer/card-bill/wallet/points/investment/refund semantics. Profile existing full snapshot work before adding further per-tab scans.

### P09 — Settlement, corrections, payment attempts and UPI handoff

- Depends: P01/P02/P03/P05; P04 reusable UI.
- Owns: settlement quote/attempt/report/confirm/dispute/reversal, allocations/credits, safe UPI intent launch and source reconciliation; focused correction/void previews with preserved payment history.
- Deliver: explicit state machine and provenance, sender/receiver/context/currency UI, editable partial amount, actual excess credit, uncertain app-return recovery, permissions and atomic race tests.
- Gates: duplicated report/confirmation has one effect; no callback-only verified payment; no automatic uncertain retry; quote can expire/revalidate; refund/void after full settlement explains who returns money; concurrent source evidence reconciles once.
- No scope: new banking rails, credentials in intents/logs, automatic debits, netting unrelated groups, or marking a fake purchase named Settle all balances as payment.

### P10 — Invitations, shadow identity claims and scoped web preview

- Depends: P01/P03/P05/P07; payment links use P09 contract.
- Owns: expiring/revocable scoped invitation capabilities, preview/claim/join review, pending destination across permitted sign-in, verified identity binding and duplicate private/incoming expense consolidation.
- Deliver: authorized minimal web preview, official domain association requirements, manual share copy/action, claim-race handling, privacy/abuse tests and identity audit.
- Gates: GET/social crawler no side effects; forwarded/revoked/wrong-user links safe; phone OTP verification doesn't accept old debt; no private raw bank/receipt details; simultaneous claims bind once; ambiguous records remain reviewable; consent to save doesn't auto-send a message.
- No scope: authentication automation contrary to `AGENTS.md`, public account enumeration, treating referral/product-access invite as expense acceptance, production deployment or sending invitations without task authorization.

### P11 — Recurring sharing, SMS/import hooks and restrained notifications

- Depends: P06/P07/P08/P09 and canonical ingestion evidence; P10 if invitations involved.
- Owns: explicit recurring sharing preferences, actual-cycle expense linking, canonical eligible debit suggestions, reminder dedupe/mute/caps and existing notification-outbox integration.
- Deliver: one accepted real charge/cycle → one expense; manual review of uncertain evidence; separate forecast; foreground suggestion policy and notification event taxonomy/cost/throughput evidence.
- Gates: no debt from mandate/forecast/OCR-only receipt; historical bulk import quiet; manual/SMS/statement/recurring observation same identity linked once; self-transfer/card bill/settlement/failed/reversed/duplicate exclusions; delivery reauthorizes recipients and respects dispute/mute/quiet hours.
- Use typed current v2 event/ledger eligibility, not a generic debit/spend enum; partial-wallet-visibility purchase treatment and source corrections remain with SMS owner. No raw SMS parsing or competing category/instrument inference in split hooks.
- No scope: regex/AI guessing that bypasses the canonical SMS owner, per-import-row pushes, silent recurring consent or changing the notification worker's batch contract without a separate review.

### P12 — Integrated QA, load/fault engineering and security review

- Starts: fixture/harness preparation after P00; implementation gates after contributing packets integrate.
- Owns: scenario-to-test register, actual Postgres/RLS/SQLite/contract/e2e/device runs, data-preservation upgrades, performance regression/load/soak/fault/failover/restore evidence and independent review of privacy/concurrency.
- Deliver: per-scenario status/evidence/build/command/target, workload/hardware/dataset/result report, unmet targets and reproduce steps, signed-in visual flow evidence with allowed handoff.
- Gates: all P0 scenarios and enabled P1 capabilities; no zero-loss/capacity/verified-payment claims beyond evidence. Populate staging histories and skew, test event dedupe/out-of-order commits, update install only, no token injection or automated OTP entry.
- No scope: changing production data, rewriting golden outputs to match code, benchmarking a tiny fixture as a million-user proof, or declaring tests passed when tools stalled.
- Add V01–V18 current-branch cases and refresh dependencies from the branch lockfiles. In this investigation correction suites could not load `ajv/dist/2020`; that is an environment-blocked check, not a passed correction/security run. Preserve existing source cutover gates separately.

### P13 — Release/operations owner: rollout, observability and rollback

- Depends: P12 release artifacts and all enabled packet gates.
- Owns: feature capability matrix, dashboards/alerts, SLO/capacity/cost review, migrations/rollout/rollback runbook, on-call/support ownership and supported-client policy.
- Deliver: disabled compatible deployment; internal → incremental cohorts with holds; kill-switch/recovery and backup/restore drill; safe replay/repair procedures and final evidence manifest.
- Gates: confirmed actual infrastructure/RPO/RTO, no unresolved correctness/privacy risk, read access and recovery remain available when writes are disabled, real payment history never rolled back by dropping schema.
- No scope: unilateral deployment from a worker branch, mass message sends, all-at-once basis migration or stopping support for old accepted data without a compatibility decision.

## 5. Common task prompt for each implementing agent

Fill the placeholders with a single packet and actual approved paths; do not paste this as a broad request to implement everything.

```text
Implement packet <Pxx> for PandaPay shared expenses.

Read first: AGENTS.md, the product/accounting/UX specification,
the production implementation plan, this work-package register,
the scenario matrix, frozen contracts/fixtures and current owning source.

Objective: <one concrete deliverable and observable behavior>.
Owned writable paths: <explicit list>.
Dependency baseline: <commit/contract version and completed packets>.
Required scenario IDs: <list>.
Shared integration files reserved for lead: router.dart, providers.dart,
api/src/index.js, global DB/migration/dependency/theme files unless assigned.

Preserve all existing UI/data and unrelated work. Use existing Flutter/Riverpod,
SQLite/GoRouter, Express/PostgreSQL, auth/recovery/notification owners.
Follow Bamboo UI/UX guidance: Outfit via BambooFonts.heading/ui,
IBM Plex Sans tabular money via BambooFonts.money, current tokens/components.
Keep Insights and existing bottom navigation. No duplicate manual forms/pages.

Do not change money/API/event/authorization contracts to suit your implementation.
Propose a contract change to the lead with affected fixtures/consumers first.
No production mutation, migration deployment, external messages or device
data clearing. Follow authentication handoff and update-install rules.

Implement meaningful tests for financial/concurrency/persistence behavior.
Run scoped checks, inspect actual results, and distinguish pass/fail/inconclusive.
Include real DB/SQLite evidence where required; mocks are not substitute proof.

Return: changed paths, contract version, completed behavior, test commands/results,
scenario coverage, measured performance if any, limits/risks, migration impact,
lead integration patch/handoff and exact next dependency. Do not call a mock
or generated screenshot production-ready.
```

## 6. Required handoff artifact

Each packet updates its own proposed `docs/implementation/shared-expenses/Pxx-status.md`; actual path/creation is assigned by the lead. Fields:

```text
Packet / owner / reviewer:
Base commit / contract version / resulting commit:
Status: not_started | implementing | review | integrated | verified | blocked
Owned files changed:
Behavior delivered:
Scenario IDs and per-layer evidence:
Tests: exact command, environment, pass/fail/inconclusive, artifact:
Performance: device/backend/dataset/traffic/duration/metrics, or unmeasured:
Migration and existing-data preservation:
Security / privacy / replay / recovery checks:
Shared-file adapter requested from lead:
Known gaps / dependent packets / blockers:
Rollback / capability requirements:
```

No credentials/tokens/phones/VPAs/raw SMS in handoffs. Device reports include serial/version/backend/sign-in/flow as `AGENTS.md` requires. A packet may be implemented but unverified; use those words rather than upgrading status from a successful build.

## 7. Integration and conflict workflow

1. Before assignment, lead records the diff/provenance of unrelated work and the exact baseline. Do not solve a dirty checkout by reset/stash/drop/cleanup without scoped authorization.
2. Worker publishes a small coherent patch plus scoped test evidence. Contract fakes are labeled and cannot remain on the enabled financial path.
3. Reviewer checks requirements, boundaries, privacy, math, races, queries and test quality. Add independent cases where needed. Financial/authorization failures block integration; cosmetic nits do not justify rewriting unrelated UI.
4. Lead merges/integrates one packet at a time and owns shared-file adapters. Resolve conflicts by rereading both ownership/contracts; never choose ours/theirs wholesale for financial or migration code.
5. Run affected integration suites after each seam changes. Once they pass, broaden only when new changes/risks justify it. Preserve exact failed/inconclusive evidence, including runner hangs.
6. Mark integrated only when mainline behavior works through real dependencies; mark verified only after packet-specific runtime/data/performance gates pass.
7. Contract schema/cursor/migration changes trigger explicit consumer verification and version/capability review. Final acceptance runs on one pinned integrated commit, not a mixture of branches.
8. Lead updates both Markdown and HTML plan/status links when scope changes. Reviewers must be able to trace user-visible behavior to a packet, contract and scenario without reading private chat history.

## 8. Stop conditions for any agent

Stop the affected financial/UI path and report evidence when: current source contradicts an agreed amount/recognition rule; a migration baseline is incompatible; authorization requires a broad bypass; data-preserving conversion cannot be established; a queue can replay money twice; source reservations race; a payment result is uncertain; an accepted edit would erase settlement history; or implementation needs a shared-file/contract edit outside ownership.

Do not compensate by guessing, silently dropping records, fabricating bank rows, turning failed verification into success or expanding scope. Preserve drafts/evidence and continue truly independent authorized work. Release authority remains with the lead/user and the application's normal process.
