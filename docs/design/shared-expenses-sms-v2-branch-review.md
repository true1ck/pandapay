# Shared expenses: SMS v2 integration baseline and plan revision

Investigated 4 November 2026. Target branch **`sms-v2/integration`**, HEAD **`bf6bec9b845b885279f9db7a4497bd2073549680`**, tracking `origin/sms-v2/integration` at the fetched commit. Previous planning baseline: `5cadaaa3` on `codex/ios-shortcuts-prototype`; split preparation branch remains `codex/feature/ios-shortcuts-prototype/split`.

## 1. Work preserved and current scope

**Subsequent execution, 4 November:** the user has now resumed implementation. The [live register](../implementation/shared-expenses/README.md) supersedes the inspection-time status in this section: a revised pure Node/Dart calculation/source-reference foundation has been delivered and tested. Full P00/P02, accepted persistence, app UI, real DB and production gates remain open. The original branch-comparison findings below remain historical evidence; the old stash was not reapplied.

The user requested a branch change and investigation/plan update **before implementation**. Prior implementation start produced nine draft contract files only; no application code, shared ledger, UI, database migration or payment flow was implemented.

Stash **`30cb0be3f60acb810970147417f063de99e3cc4e`**, message `preserve-split-planning-before-sms-v2-integration-20261104`, preserves 18 thread-owned files: nine draft contracts, six design documents and three sample/prompt files. The old contracts remain in that stash and are **not frozen contracts for this branch**. The design documents and samples were restored separately for revision without applying old code or dropping the stash. Unrelated existing local Flutter artifacts, logs, screenshots and `AGENTS.md` remain untouched. No staged changes, reset, deployment, device install or authentication operation was performed.

The fetched branch is 110 commits ahead of the old baseline, with no old-baseline-only commits. This is source-history evidence, not a production deployment statement. Implementation should continue on `sms-v2/integration` only after its revised P00 gate passes, as requested; do not automatically create or switch back to the old split branch.

## 2. Changes that alter the integration design

| Finding in current source | Plan change / owner |
| --- | --- |
| New source contracts in `contracts/sms/v2`, pure Dart fact/instrument/linker/ledger/category code, and server Ajv validation/storage. | Reuse the interpretation pipeline. A split suggestion must not reparse raw SMS or add a competing category/instrument resolver. Split financial math is its own allocation/obligation domain, not a new bank/SMS ledger. P00/P02/P11. |
| `TransactionEntry` now carries `eventId`, `pipelineVersion` and `sourceKey`. Local `transactionForEvent` creates `id: 'v2:${event.eventId}'`; server projections persist normal transaction UUIDs. | Replace universal `transactionId: UUID` assumptions with a typed, account-owned source reference. Never pass a local `v2:<hash>` to `/transactions/:id/splits`. Resolve canonical server transaction mapping after source sync; preserve a pending link locally. P00/P03/P05/P06. |
| Server event/fact IDs are hash strings and instrument IDs are UUIDs; a projected row is not the economic identity of the SMS. | Store owner + source kind + eventId/sourceKey + canonical transaction ID where available + explicit revision/fingerprint. Do not convert hash IDs into fabricated UUIDs or use sourceKey alone as expense identity. P01/P03. |
| Server split routes now require active parent transactions. | A retired/superseded/missing projected source cannot receive a legacy split PUT. Preserve existing split metadata and require canonical remap/review instead of silently clearing it. P03/P06. |
| SMS v2 has event status `complete`, `awaiting_leg`, `ambiguous`, `user_confirmed`, and source-ledger rows with `isSpend/isIncome/isInvestment/countsAsTransaction`. | Eligibility uses typed event, legs, unit, instrument and current ledger evidence, not only `TxnEntryKind.spend`, displayed status or a debit SMS. `complete` is interpretation/linking state, not receiver-confirmed debt repayment or provider-verified payment. P00/P09/P11. |
| The source projector excludes ambiguous/non-money rows and can retire projections when instruments are rejected or evidence changes. | Add source revision/retraction notifications and conflict policy. Losing a bank projection must not void a shared expense or delete real settlement history. Pending new links pause for review; accepted shared corrections require their consent policy. P03/P05/P06/P09. |
| Corrections/reprojection, local hide/restore and legacy replay/supersede are new source writers. | Include those paths in the reservation and identity-remap protocol. Old edit/delete/sync/import writer inventory alone is insufficient. P01/P03/P06. |
| `LedgerReadModel` adapts old manual/email/unreplayed rows into the same source ledger and reporting providers switch when SMS v2 reporting is ready. | Overlay shared personal cost once onto the current reporting owner; do not add source amount + projected v2 row + allocation copy. Test legacy/manual, flag off, flag on but no v2 facts, mixed replay and ready v2. P05/P08. |
| Bank, card, wallet, broker/IPO, points and recurring adapters now derive context from facts/events/instruments. | Keep own-funding basis and instrument direction. Card-bill repayments, own transfers, holds/releases, reward points and attempts are not general shareable purchases. Respect the wallet partial-visibility semantics rather than blindly excluding every wallet-related event. P08/P11. |
| Existing foreign payments persist original currency/amount, estimate/rate snapshot, billed INR, valuation/confirmation status, transaction link and refund direction. | Reuse this existing flow. Estimates/unknown/ignored amounts cannot fund accepted INR splits. A confirmed billed-INR purchase can link after identity resolution; a refund updates the original expense through reviewed correction. General foreign-currency group settlement remains deferred. P02/P06/P08/P09. |
| Existing currency precision helpers/tables and BigInt decimal FX calculations coexist with SMS v2 `Amount.minor` JSON integers and legacy Money. | Keep source contracts unchanged. Split wire strings must cross explicit checked adapters to source int/minor types; validate bounds without float coercion. Do not introduce a second currency registry or upgrade source schema as a side effect. P00/P02. |
| `SmsV2Schema` owns its module schema version, tables and namespaced SQLite state. `v2_outbox` replaces payloads for the same kind/ID; upload admits source/instrument/event/ledger kinds. | Acknowledging source upload and acknowledging a shared financial command are different dependencies. Reuse DB/recovery/scheduling principles, but do not insert settlement commands into the payload-replacing v2 outbox or generic metadata coalescing queue. P05. |
| Current recovery has namespaced state handling and foreign outbox coverage; PG coverage classifies v2 and foreign tables explicitly. | Inventory actual new shared tables, queued commands and aliases in every portable/account/paired-backup mechanism. Existing v2 export classification is not automatic coverage for shared history. P01/P05. |
| Current ledger read provider loads facts/events/instruments/transactions into a snapshot; LedgerStore filters some date ranges after reading. | Million-user optimization must include current source snapshot rebuild cost and mixed-ledger allocations. Avoid a second full account snapshot per tab; use indexed bounds, shared revisions and measured incremental projections. P03/P05/P08/P12. |
| V2 enablement is a build/provider flag plus server gate; reporting readiness has its own state. Source handoff WP-17 says no cutover scheduled. | Split capability is independent. Do not enable SMS v2, disable legacy compatibility, switch rule bundles or infer production readiness while adding Splits. Require compatible source/readiness matrix and leave existing cutover gates with their owner. P00/P12/P13. |

## 3. Required source reference contract

P00 must freeze a union similar to this **before** P01/P03 writes. This is a design shape, not an implemented route:

```text
SourceReference
  ownerAccountId (server derives/checks)
  kind: legacy_transaction | sms_v2_event | confirmed_foreign_payment
  localProjectionId?       # e.g. v2:<event hash>; display/navigation only
  eventId?                # actual validated v2 hash, never cast to UUID
  canonicalTransactionId? # actual active server UUID after source admission
  sourceKey?              # supporting provenance/alias, not sole uniqueness
  foreignPaymentId?
  expectedSourceVersion   # reviewed revision/fingerprint, not wall-clock guess
```

Eligibility output must include source type/status/unit/amount, source admission state, current identity aliases, permitted linked amount, reason code and allowed action. A local preview can retain an unresolved source reference; an accepted shared effect cannot claim server-owned funding before the canonical source is admitted and authorized. Friend-paid/cash/private entries do not invent a source to satisfy this requirement.

Reserve and reconcile the underlying source funding once even when a local display ID changes to a server UUID. If v2 reprojects, rejects an instrument or supersedes an old row, remap established equivalent identity atomically or retain a review conflict. An amount/time heuristic is insufficient proof. Existing legacy split notes and private metadata remain private and recoverable during replay.

## 4. Accounting and UI boundaries retained

The agreed architecture remains **Insights → Splits → Friends / Groups / Activity**, with contextual **Expenses / Balances / Totals**, plus **Payments → Bills & commitments / Due dates / Subscriptions**. Current Insights tiles and root Payments tabs are still present; these remain proposed additive changes. The app already has SMS v2 review/instrument/migration and ledger views. Use them for source issues; do not recreate them inside Splits.

Bank/SMS/foreign source truth describes the user's own movements and instruments. Shared expenses describe economic participation, acceptance, pair obligations and settlements. Keep their stores and consent models distinct, with explicit private links and one personal-cost projection. Never insert a friend's charge or a proposed debt into `sms_v2_ledger_entries` as the user's bank movement.

Under initial `explicit_review`, an author can keep a private recorded/provisional share. The accepted balanced journal stays unchanged until all required affected participants accept the complete revision. Do not accept only the creditor side while suppressing the debtor's unaccepted payable. Identity binding/OTP, event `user_confirmed`, receipt OCR and a payment app callback are not acceptance of a shared debt or authoritative settlement confirmation.

Bamboo Ink/Outfit/IBM Plex Sans requirements remain valid. Theme changes on this branch add deterministic test-font behavior; do not copy test system fonts into production or globally redesign new source review screens as part of Splits.

## 5. Current screen inventory and touched surfaces

Static inventory now finds **113 `*_screen.dart` source files** (previously 109), across **24 screen-bearing areas**. Four added files:

- [Foreign payments](../../app/lib/features/activity/foreign_payments_screen.dart): keep original currency, estimates, billed-INR confirmation, refunds and detail flow. Sharing waits for accepted usable funding, then opens the same split owner.
- [Found instruments](../../app/lib/features/sms_v2/ui/found_instruments_screen.dart): retain confirm/reject/link actions. Instrument decisions can affect split funding eligibility; no new expense form here.
- [Migration report](../../app/lib/features/sms_v2/ui/migration_report_screen.dart): retain replay progress/recovery. Add shared-link reconciliation status where needed; no accepted debt replay from imported observations.
- [Review inbox](../../app/lib/features/sms_v2/ui/review_inbox_screen.dart): reuse correction/why/review flow for uncertain source records before split entry. Do not duplicate source review in the group feature.

Also inspect reusable routed `ledger_screens.dart` (investments/IPOs/money-in/subscriptions), correction/why/personal-format forms, and foreign payment detail classes. These do not all use `*_screen.dart` filenames. File count is not a count of distinct live pages or a claim of device walkthrough.

## 6. Revised work order

1. **P00 rebaseline**: source identity/eligibility contract, source-to-shared adapter, numerical boundary/parity fixtures, source readiness and accepted-versus-proposed semantics. Old nine draft files remain stashed; do not call them frozen.
2. **P01 current schema/security review**: inspect current v2/foreign migrations and role manifests. The latest lexical migration now is `20261112200000_sms_v2_correction_update_guard.sql`. Reserve a unique successor in the actual ordered migration sequence, not the old proposed 20261104 prefix. Read runner ordering/checksum rules before assigning.
3. **P02 exact allocation adapter**: reuse current amount/currency types at explicit boundaries; retain integer minor arithmetic and no amount-weighted floating coercion.
4. **P03/P05 source admission and recovery**: link canonical source identity/aliases, preserve v2 correction/replay and local/source/shared command dependencies, then test the first complete source-linked slice.
5. **P04/P06/P07 UI**: preserve source review/foreign pages, move only subscription body under Payments, add shared tabs and extend Quick Add/detail through current v2-aware owners.
6. **P08/P09/P11**: reconcile legacy/v2/foreign source reports, pair obligations, confirmed settlement purpose overlay and recurring actual-cycle linkage. Suppress hooks on replay and unresolved source states.
7. **P12/P13**: extend source correction/replay/flag/FX/load fixtures, use current dependency lockfiles and real DB/device gates, and retain source pipeline cutover ownership.

Use the revised [production plan](shared-expenses-production-implementation-plan.md), [agent packages](shared-expenses-agent-work-packages.md) and [scenario matrix](shared-expenses-scenario-test-matrix.md). Split P00–P13 naming is separate from existing SMS v2 WP-00–WP-17 work; agents must not edit another feature's handoff as their own packet.

## 7. Verification performed and limits

- Current branch/ref/ancestry and changed owning source inspected; only the split design files are being updated. No runtime application source edits were made.
- Focused baseline command: `node --test api/test/transaction_splits.test.js api/test/transaction_paging.test.js api/test/sms_v2/projection_status.test.js api/test/sms_v2/legacy_supersede.test.js api/test/foreign_exchange.test.js api/test/foreign_payments.test.js`: **26 passed, 0 failed**. This establishes only those unit/contract fixtures, not real PostgreSQL, app UI, live FX or payment verification.
- Additional correction suites could not load because the old local `node_modules` lacks the branch's locked `ajv/dist/2020` dependency. Record as environment-blocked, not a financial regression or successful correction run. Refresh dependencies from this branch's existing lockfiles before implementation verification; no dependency upgrades were made for this investigation.
- No private message corpus or real customer data was opened, copied or summarized. No private evaluation counts/amounts are included. Historical SMS planning prose is not treated as current feature evidence when current source differs.
- No app install/sign-in, real DB migration, cutover, server deployment, live payment, provider verification or scale certification. User-requested investigation/plan update is complete only after document/source links and the refreshed HTML inventory pass validation.

## 8. Owning source anchors

| Concern | Current sources |
| --- | --- |
| Facts, types, currencies and event/ledger contracts | [types.dart](../../packages/pandapay_domain/lib/src/sms_v2/contract/types.dart), [enums.dart](../../packages/pandapay_domain/lib/src/sms_v2/contract/enums.dart), [event.dart](../../packages/pandapay_domain/lib/src/sms_v2/contract/event.dart), [source schemas](../../contracts/sms/v2/event.schema.json) |
| Pure source projection and reporting | [projector.dart](../../packages/pandapay_domain/lib/src/sms_v2/ledger/projector.dart), [snapshot.dart](../../packages/pandapay_domain/lib/src/sms_v2/ledger/snapshot.dart), [LedgerReadModel](../../app/lib/features/sms_v2/ledger/reports.dart), [report providers](../../app/lib/features/sms_v2/ledger/providers.dart) |
| Projection identity and writers | [local projection writer](../../app/lib/features/sms_v2/ledger/projection_writer.dart), [server mapper](../../api/src/sms_v2/projection.js), [server storage](../../api/src/sms_v2/storage.js), [transaction model](../../app/lib/data/user_cards_repository.dart) |
| Correction/replay/supersede | [transaction actions](../../app/lib/features/sms_v2/ui/transaction_actions.dart), [correction service](../../app/lib/features/sms_v2/corrections/corrections_service.dart), [legacy replay](../../app/lib/features/sms_v2/migration/legacy_replay.dart), [server supersede](../../api/src/sms_v2/legacy_supersede.js) |
| Local schema/outbox/sync | [schema.dart](../../app/lib/features/sms_v2/storage/schema.dart), [outbox_store.dart](../../app/lib/features/sms_v2/storage/outbox_store.dart), [facts upload](../../app/lib/features/sms_v2/sync/facts_upload.dart), [sync pull](../../app/lib/features/sms_v2/sync/sync_pull.dart) |
| Foreign source valuation | [ForeignPayment](../../app/lib/data/foreign_payment.dart), [currency precision](../../app/lib/data/foreign_money.dart), [foreign repository](../../app/lib/data/foreign_payments_repository.dart), [server FX math](../../api/src/foreign_exchange.js), [server foreign source](../../api/src/foreign_payments.js) |
| Legacy split boundary / recovery | [active split routes](../../api/src/transaction_splits.js), [portable coverage](../../api/src/portable_backup/coverage.json), [local export queues](../../app/lib/data/portable_backup/local_snapshot_source.dart), [account recovery](../../app/lib/data/portable_backup/account_recovery_local_snapshot.dart) |
| Gates and current navigation | [SMS v2 flag](../../app/lib/features/sms_v2/flag.dart), [server gate](../../api/src/sms_v2/guard.js), [source cutover gate](../sms-pipeline-v2/handoff/WP-17.md), [router](../../app/lib/app/router.dart), [Insights](../../app/lib/features/insights/insights_hub_screen.dart), [Bamboo theme](../../app/lib/app/design/app_theme.dart) |
