# P01 shared-expense storage handoff

Status: **implementing / bounded foundation in review**, 4 November 2026. Owner: `/root/p00_storage_review`. Dependency: current `sms-v2/integration` foundation and `docs/contracts/shared-expenses-v1/journal.md`. This is not a full P01 acceptance or production activation.

## Owned files and order

- `db/supabase/migrations/20261112210000_shared_expenses_foundation.sql`
- `db/tests/shared_expenses_foundation.test.js`
- `db/tests/shared_expenses_postgres.test.js`
- `db/tests/shared_expenses_concurrency_postgres.test.js` (follow-up verification lease)
- This handoff only. Root owns global role policy/setup, backup/lifecycle, API wiring and activation.

The assigned migration timestamp was absent when checked and follows the then-latest `20261112200000_sms_v2_correction_update_guard.sql`. It is a single additive product-runner transaction. No existing transaction/category-split/SMS/FX table is rewritten or altered. Ordinary indexes are on new empty tables. No production database, emulator, account authentication, stash, git mutation, push or deployment was used by this packet.

## Implemented storage

Isolated `shared_expenses` schema owned by `shared_expenses_owner`: NOLOGIN, NOSUPERUSER, NOBYPASSRLS, NOCREATEDB/NOCREATEROLE/NOREPLICATION. Every table has enabled and forced RLS. The role cannot be inherited by `app_user`. Runtime has no generic table INSERT/UPDATE/DELETE. Named authenticated commands run with fixed `pg_catalog,shared_expenses,pg_temp` search path; helpers that post journal lines, finish receipts or accept revisions are not callable by runtime. Source fingerprint construction fixes UTC to avoid session-timezone drift.

Tables cover contexts, UUID members with nullable verified profile mapping, accepted expense heads, immutable full revisions, normalized revision participants and approvals, canonical source resources/aliases/reservations, immutable payment reports/events/allocations, journal, frozen obligation edges, actor-scoped durable receipts, context and actor streams, member/pair current balances and private personal-cost facts. Financial history has no cascade from a public bank transaction or profile. Deleting a profile can null the current member binding; history and lifecycle policy still require root integration.

Financial snapshots are exact integer strings converted to checked bigint. `_project_snapshot` independently validates closed shapes, totals, unique identities, payer/share caps and member order, then computes deterministic FIFO edges. Immutable `projection_version='pair_v1'` and saved edges identify the algorithm. A correction subtracts the saved previous edges rather than recomputing old history using a future algorithm. Each pair and member value is bounded; the complete active pair gross is checked against `9007199254740991` at the end of the atomic financial operation. Circular three-person debt remains three edges even when all net member balances are zero.

Indexes cover owner membership lookup, context expense and settlement pages, accepted heads, reviewer lookup, private-cost period reads and native context/profile event keys. A posting touches bounded per-context current balances rather than replaying the historical journal. This is an algorithmic bound, not a capacity benchmark.

## Callable interfaces

All command functions return JSONB. The actor comes exclusively from existing transaction-local `pandapay.uid()`, checked against the authenticated profile. Supplied request hash is also bound to an independently generated stored SQL input hash, command kind and context. Same actor/operation with changed input fails; an unchanged replay returns the saved result after current authorization.

| Function | Arguments | Behavior |
| --- | --- | --- |
| `capabilities` | none | Explicit current flags; linked source funding remains false. |
| `create_context` | UUID context, text group/direct, text name, UUID operation, text request hash | Creates the owner identity and one context event. |
| `invite_member` | JSONB payload, UUID operation, text request hash | `contextId,memberId,displayName,profileId?`; owner only, pending membership, max two direct / 200 group identities under context lock. |
| `respond_membership` | UUID context, UUID member, boolean accept, UUID operation, text hash | Only the bound invitee responds. Membership is never expense approval. |
| `inspect_source` | JSONB closed identity | Owner-only actual source discovery and fingerprint; no reservation or debt effect. |
| `admit_source` | JSONB typed reference | Requires exact current 64-hex server fingerprint and current eligibility; no financial effect by itself. |
| `submit_proposal` | JSONB frozen P03 expense.propose payload, UUID operation, text hash | Persists one full proposal. The author approves only their own required identities. |
| `respond_expense` | JSONB context/expense/revision/decision, UUID operation, text hash | Exact stored revision review. Previous accepted head remains until the whole required union approves. |
| `report_settlement` | JSONB frozen P03 settlement.report payload, UUID operation, text hash | Records an unconfirmed report; UPI launch/callback does not change balances. |
| `respond_settlement` | JSONB context/settlement/decision, UUID operation, text hash | Only the receiving member confirms/rejects. Confirmed pair payment posts once, independently of expense revisions. |

The public RLS predicates `_can_read_context(UUID)`, `_can_read_revision(UUID,UUID)` and `_can_read_invitation(UUID)` are read-only helpers and must appear in the global privilege policy. They return no private source information.

An invited bound profile can discover its own invitation and context summary/stream, while financial context reads still require active membership. A shadow identity has no profile or consent authority. Source-free expenses can be accepted after all financially involved previous/new identities review. A participant who is only a payer is still included. A rejected response cannot be overwritten as approval; a fresh revision is needed.

Partial confirmed payments reduce exactly that pair/context/currency balance. Settlement allocation receipts distinguish `pair_balance` and explicit overpayment `pair_credit`. No optional expense attribution is invented. A revised or voided expense preserves original confirmed payment and allocation events, so credit/refund obligations remain visible rather than being erased or rerouted to another creditor.

## Read ACL contract for P03

Runtime may select RLS-protected context/member/current balance/activity rows and its own receipt/profile stream. `expense_revisions` has column-level SELECT only: context_id, expense_id, revision_id, author_profile_id, expected_head_revision_id, revision_hash, projection_version, title, occurred_on, currency, total_minor, is_void, snapshot, projected_edges, created_at. `source_links` is deliberately denied, including to a different required approver. Use explicit columns, not SELECT star.

`settlement_reports` similarly grants only context_id, settlement_id, reporter_profile_id, payer_member_id, receiver_member_id, amount_minor, currency, method, paid_on, created_at. Optional private references are now in **`settlement_private_references`**, with no runtime grants and defensive party RLS. They can be erased independently of immutable payment/report history by a later trusted lifecycle command. Report rows additionally require reporter/payer/receiver identity. Group activity has safe settlement summary events without the reference. Canonical source resources/aliases remain owner-private.

## Source admission and still-gated work

- Existing sorted `transaction-ingest:<profile UUID>` advisory lock is taken before inspecting owner source truth.
- V2 discovery resolves `(owner,event_id)` to the actual PostgreSQL transaction UUID. It verifies active spend, eligible purchase/subscription/bill type, exact INR posted external consumption legs, confirmed owned instrument and exact total. Event complete/user_confirmed or entry_kind=spend alone is insufficient. Rejected/detected instrument, P2P, unposted/mismatched legs, transfers and ambiguous state fail closed.
- Legacy and v2 aliases of one canonical resource produce the same fingerprint. FX is resolved by canonical transaction for every alias: confirmed billed INR, direction, source identity and current revision must match. Estimated/unconfirmed valuation cannot be bypassed with a legacy alias.
- Untyped legacy spend can be discovered with `eligible=false`, `requiresReview=true`, reason `purchase_confirmation_required`; it cannot be admitted until the explicit owner source-classification certificate packet is implemented. A confirmed FX valuation alone does not supply missing purchase semantics.
- Proposal source links validate their exact wire shape, bound payer ownership and aggregate amount against that payer's contribution. They do not confer eligibility.
- **Linked-source proposals remain `awaiting_source_authorization` even if basic accepted writes are enabled.** Source resource/reservation tables are a foundation only; there is no accepted source funding function in this increment. Root must implement classification certificates, owner authorization/reservation, canonical alias/replacement/retraction guards and writer lock integration before enabling this flow. `capabilities.sourceFunding` remains false.
- Optional per-expense payment attribution, mutually reviewed reversal, shadow phone claiming/merge, context lifecycle/removal and source replacement/retraction correction commands are not implemented by this foundation. The paired payment facts and old revisions are preserved for those later commands.

## Verification evidence

RED: four new migration inventory/isolation/provenance/source-admission tests failed because the migration did not exist. Invitation behavior was added as a failing real PostgreSQL test before the function. The first actual PG executions exposed SQL parser errors; they were fixed and rerun. An added funding aggregation check also failed actual SQL grouping and was fixed before the final pass.

Completed command (explicit root-created disposable loopback database only; never reads .env or DATABASE_URL):

```powershell
$env:PANDAPAY_SHARED_EXPENSES_TEST_URL='postgres://postgres@127.0.0.1:55436/shared_expenses_test'
node --test db/tests/shared_expenses_foundation.test.js db/tests/shared_expenses_postgres.test.js db/tests/product_migrate.test.js
```

Foundation run before the concurrency/feed increment: **34 tests passed, zero failed, zero skipped**. Counts included 15 existing runner tests, five new static contract checks, fixture admission and real PG integration with twelve financial/read/source subtests. The real harness refuses non-loopback / non-`shared_expenses_test` names and any pre-existing product/user tables. It creates synthetic actual-column dependencies and forced owner RLS in a transaction, executes the entire new migration, restores the existing broad public/pandapay grant pattern, then rolls everything back. It never changes ambient product data.

Actual PG evidence includes: forced RLS and role attributes; denied generic CRUD/private helpers/private columns; actor-scoped replay and changed-payload conflicts; group invitation discoverability/direct group cap; all-party whole-revision approval; partial and full receiver-confirmed payments; immutable payment replay; approved correction and void refunds; explicit overpayment credit; source-linked no-post gate; v2 canonical identity and alias equivalence; source fingerprint timezone stability; typed P2P/leg/instrument rejection; FX valuation/alias rejection; four common projection vectors against the pure Node implementation; malformed money; circular debt; aggregate gross cap rollback; and current P03 read repository functions running as actual app_user.

## Required next gates / root-owned integration

1. Full existing product migration chain plus the real `setup_app_role.sql` and runtime privilege auditor, including after-setup replay. The local fixture reproduces the broad-grant seam but does **not** prove global production setup integration.
2. Independent financial/security review. Pure/SQL parity is evidence, not independent approval.
3. The follow-up below verifies real concurrent sessions for the bounded implemented flows. Source budget/alias replacement races remain unverified until the source-guard/funding packet exists. Full global setup, populated upgrade and production-shaped contention remain separate gates.
4. Global `product-runtime-privileges.json` managed schema/owner/function/column grants and all forbidden exposure roles. Do not regrant table SELECT on private source/reference columns or any write/helper authority to runtime.
5. Portable backup coverage for every new table; schema-aware shared restore/reconciliation (current generic restore uses public.<table>); local durable command/recovery integration; source/actor remapping and receipt/effect replay tests.
6. Account erasure/leave/reset policy: anonymize/null shared member bindings while preserving counterparties' immutable balances; remove private owner source/cost/reference material only through reviewed lifecycle rules. The existing profile cascade cannot be treated as the complete shared lifecycle policy.
7. Source writer inventory/guards: SMS v2 ingestion and legacy supersession, FX reconciliation, transaction create/edit/ignore/restore/delete, duplicate resolution, statements, manual/sync imports, self-transfer correction, repair jobs, portable restore and admin/lifecycle paths. They must share the owner-ingest-first lock order and never erase accepted shared obligations.
8. Activation/audience rollout, real populated upgrade/restore and production-shaped capacity measurements. Flags default off. No production-ready, complete P01, emulator, deployment or millions-of-users performance claim follows from this test run.

## Root integration: full upgrade and exact totals, 4 November 2026

The earlier full-chain upgrade gate is now verified for the local synthetic fixture. Added `20261112213000_shared_expense_totals.sql`: context totals and member paid/share totals update only when an accepted expense head changes. Corrections and voids apply deltas; confirmed payments never change consumption. The trigger processes the old/new bounded revision members, without scanning journal history on each screen read. Forced RLS, private trigger execution and explicit portable coverage remain in effect.

The real PostgreSQL fixture caught negative-delta INSERT check failures during correction. Replaced negative insert/upsert with update-first projection changes, then verified decrease/void/reconciliation again. New totals are also exercised by the existing concurrent financial-command harness.

Latest combined local command: foundation, totals, policy, rollback PostgreSQL, concurrent PostgreSQL, full upgrade and existing migration-runner tests: **53 passed, zero failed, zero skipped**. Environment: task-owned PostgreSQL 17 container `pandapay-shared-expenses-20261104-thread`, loopback port 55436. The upgrade harness creates an absent, uniquely marked `shared_expenses_upgrade_test` database, runs the existing product migration history and real `setup_app_role.sql`, adds a synthetic existing transaction, applies both shared migrations through the canonical runner, repeats setup/migration replay, and compares the existing transaction byte-for-byte. Cleanup checks the exact database marker before dropping only that owned database. Log: `.flutter-direct-appdata3/shared-postgres-regression.log`.

No ambient product database or production migration was changed. The global runtime privilege auditor, source-writer guards/reservations, shared portable export/restore, erasure, independent review and representative capacity remain open; this local upgrade result does not close all P01 gates. Source funding remains hard-disabled in capabilities.

## Follow-up: real concurrent transactions and private-field separation

The root authorized an additional strict `shared_expenses_concurrency_test` disposable database on its existing local test container. The harness refuses any pre-existing database of that name, creates it with a generated exact ownership marker, commits synthetic actual-column source fixtures, and uses independent physical sessions. Every financial session runs BEGIN / SET LOCAL ROLE app_user / transaction-local authenticated synthetic actor. A coordinator observes actual PostgreSQL lock waits, not timer-based guesses. Cleanup verifies the same database name and creation marker before dropping only that database; it never drops a pre-existing target or changes a product database.

Final combined command after private-reference separation and the current P03 projection feed:

```powershell
$env:PANDAPAY_SHARED_EXPENSES_TEST_URL='postgres://postgres@127.0.0.1:55436/shared_expenses_test'
$env:PANDAPAY_SHARED_EXPENSES_CONCURRENCY_TEST_URL='postgres://postgres@127.0.0.1:55436/shared_expenses_concurrency_test'
node --test db/tests/shared_expenses_foundation.test.js db/tests/shared_expenses_postgres.test.js db/tests/shared_expenses_concurrency_postgres.test.js db/tests/product_migrate.test.js
```

**48 tests passed, zero failed, zero skipped**: 15 existing runner tests, five static foundation checks, 15 rollback/source/read/feed checks including its outer tests, and 13 concurrency checks including its outer tests. The concurrency increment proves blocked unchanged-operation replay, changed-payload conflict, competing first heads, conflicting complete revisions, independent pair payments and overpayment credit, two confirmations applying one payment effect, direct/group identity caps, the shared owner-ingest lock protocol for a participating writer, profile stream commit ordering across contexts, and an owned database backend termination rolling back receipt/head/effect before one safe retry. It is not a claim that every existing source writer has been integrated or that local device recovery is complete.

The new bounded P03 projection feed was exercised with seven records per page through all context/member/expense/pair/private-cost/activity branches and a terminal membership grant. Actual PG caught an unused untyped SQL parameter (`42P18`); the P03 owner fixed it before the final pass. Private references/source-link bodies are absent from feed records. `shared_journal_origin(context_id,origin_id,low_member_id,high_member_id)` supports bounded event-to-pair lookup rather than a full account journal scan.

Self-review mutation: a process-local copy inverted the accepted-write activation condition. The actual PG test failed immediately when a revision was accepted while activation was disabled. The checked-in/working migration file was never mutated during this check. This proves the gate test detects that defect; it is not independent financial approval.

### Private fields and lifecycle ownership

| Store | Private/identity material | Preservation / erasure boundary |
| --- | --- | --- |
| `members` | Bound profile UUID and owner-provided display name | Erasure should null binding, replace display name and set `erased`; never turn a deleted member into a reclaimable `invited` shadow. Stable member ID and financial edges remain. |
| `contexts` / `expenses` | Shared group/title identity and creator UUID | Joint history remains; creator IDs are pseudonymous audit references. Root must define retained ownership/administration when the last owner leaves. |
| `expense_revisions` | Title/date, exact shared snapshot and private `source_links` typed IDs/fingerprint/optional source key | Immutable shared snapshot remains. Before linked funding, move the private source-reference body into an erasable source-owner claim store; retain resource/hash evidence in the immutable revision. No raw SMS/VPA is admitted. |
| `revision_members` / `revision_approvals` | Approver/actor UUID, immutable reviewed hash and exact share/paid amounts | Financial consent evidence retained under an explicit shared-audit retention policy; old binding must never authorize a new claimant. |
| `settlement_private_references` | Optional bank/UPI reference and entering owner's UUID | Separate mutable private store with no runtime grants; trusted private erasure can delete it without modifying report/payment facts. |
| `settlement_reports` / events / allocations | Parties, amount, date, method and recording/confirming actor UUIDs | Immutable financial evidence remains; no private bank reference body is stored in these rows. |
| `source_resources` / aliases / reservations | Canonical bank/event/FX IDs, owner UUID, private source snapshot, fingerprint and allocated amount | Erasure must redact private snapshot and remove private aliases/claims while retaining reviewed minimal resource/hash/reservation evidence. Retract funding without erasing accepted obligations. Currently no funded source writes exist. |
| `private_cost_facts` | Actor-private recognized consumption by date/expense | Root's reset/erasure policy must explicitly purge or rebuild it; current generic public-only reset cannot see it. |
| `operation_receipts` | Actor UUID, request/input hashes and safe result IDs/status/sequence | No raw command/title/reference body. Financial effect uniqueness must outlive any permitted receipt pruning; deletion/restore cannot revive an erased actor. |
| Context/profile events and heads | Safe shared activity, actor UUID and committed cursor | Shared immutable activity must survive counterparties' history. Actor-private stream retention/removal needs a dedicated policy; do not cascade-delete shared context events or recycle cursors. |

Current source anchors: `20261028150000_account_data_reset.sql:121` scans **public** profile tables; its `execute_account_deletion` at line 222 invokes that reset and then deletes the profile. `members.profile_id ON DELETE SET NULL` alone does not erase names/private facts or mark the identity unclaimable. `api/src/account_lifecycle_worker.js:8` explicitly performs denial/auth coordination without physically purging customer rows. Trusted tombstone claim/replay seams are in `20261023191847_durable_account_lifecycle.sql:149` / `:202`.

Proposed root-owned command: `shared_expenses.erase_profile_private(p_profile UUID,p_request UUID,p_generation bigint,p_after_context UUID,p_limit integer)` callable only by the existing trusted `account_lifecycle_owner`, never app_user/PUBLIC. Validate the exact committed lifecycle tombstone tuple; use the lifecycle fence, established owner-ingest lock first, then bounded sorted context locks. Tombstone-bind the idempotent purge cursor. Mark bindings erased with a non-reclaimable former-member label, purge erasable private reference/cost/source-claim data and redact source snapshots. Preserve immutable accepted revisions, consent, pair journal and confirmed payments. Emit counterparties' safe membership/source-state change events through normal committed streams. Retained receipt/audit UUID/hash rules must be explicit; do not delete effects merely to make FK cleanup pass. Distinguish personal-data reset from account erasure, and replay tombstones before any backup grants or command retries. This is a proposal, not an implemented or verified lifecycle function.

The first P01 migration and its tests are frozen for root review/savepoint after this run. Source funding, certification, private claim storage and source-retraction guards are the next reviewed additive migration; keeping those flags off here is temporary integration protection, not the final feature implementation.
