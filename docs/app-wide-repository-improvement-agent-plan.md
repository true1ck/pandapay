# PandaPay application-wide improvement review and implementation plan

## Objective

Review the six repositories named in the subscription audit for ideas that improve PandaPay anywhere in the product. Integrate only changes that address a demonstrated PandaPay gap and preserve or improve the relevant current behavior. Treat README claims as leads; inspect source and tests before accepting an idea.

## Agent setup

The coordinator spawns three independent implementation agents using **gpt-5.6-luna, high reasoning effort** (the requested “Luna 5.6 Hi”). Give each agent a narrow file ownership area and a written handoff. Run read-only discovery in parallel; sequence edits when files or database contracts overlap. The coordinator owns integration, conflict resolution, final evaluation, and user report.

1. **Agent A — external evidence:** inspect the six repositories, source paths, algorithms, fixtures, and actual behavior. Produce a short matrix: input, useful idea, code evidence, fit, risks, and whether PandaPay already does it. No PandaPay edits.
2. **Agent B — PandaPay data flow:** trace live/bulk SMS, email, statement, manual, and offline inputs into transaction classification, deduplication, corrections, reports, rewards, and recurring detection. Identify confirmed gaps with exact files and reproducible synthetic examples. No edits in shared files.
3. **Agent C — validation and product fit:** inventory existing tests, SMS evaluator, correction learning, offline queue, backup/restore, and relevant UI. Build a baseline fixture proposal and identify product ideas such as price-change or merchant-alias review only where data already supports them. No production edits during discovery.

The coordinator consolidates findings into a decision table. After approval of a candidate by the evidence gates below, delegate isolated implementation slices to available agents using the same model and effort. Agents must not edit another agent's owned files. Each handoff names changed files, evidence, observed behavior, and unresolved risks.

## Phase 1 — establish current behavior

- Record the current Git state and preserve existing user changes. Review `README.md`, `TRANSACTION_CLASSIFICATION_PLAN.md`, current SMS architecture and flow audits, and implementation status. Documents may be stale; current code is authoritative.
- Trace each input through parser, source facts/observations, transaction persistence, dedupe, user overrides, offline synchronization, and every aggregate. Inspect `api/src/sms_parser.js`, `api/src/index.js`, `api/src/transaction_dedup.js`, `api/src/spend_reports.js`, `app/lib/data/local_sms_parser.dart`, `app/lib/data/local/financial_store.dart`, and `app/lib/app/providers.dart`.
- Inventory existing infrastructure before proposing additions: `api/src/sms_evaluator.js`, SMS learning/rule bundles, merchant catalogs, `recurring_series`, card state reconciliation, portable backup, and their tests.
- Produce a gap register with: user-visible failure, synthetic reproduction, root cause, affected surfaces, current test coverage, and candidate remedy. Mark unverified concerns as hypotheses.

## Phase 2 — evaluate external ideas

Inspect AuraSpend, Subflo, Subscription Leak Radar, GiGurra subscription-detector, minh-stakc subscription-detector, and recur-scan. Prioritize these candidates:

| Candidate | PandaPay comparison | Adoption gate |
| --- | --- | --- |
| Sender-specific parsing and unreadable-message review | Compare with local/server SMS parsers and Needs Review | Demonstrated missed or wrong financial event |
| User correction memory and merchant aliases | Compare with overrides, learning rules, and merchant catalog | Repeated correction improves without ambiguous merchant merges |
| Rule/ML fusion | Compare with existing deterministic classifier | Measured gain on held-out cases with no lost valid transactions; otherwise defer |
| Processor/descriptor grouping | Compare with merchant normalization and recurring keys | Correctly links real variants without merging unrelated merchants |
| Price-change, duplicate-service, cancellation review | Compare with current insights and recurring lifecycle | Reliable supporting transactions and useful action for the user |
| Statement, email, backup, and offline workflows | Compare with existing import and portable backup | A concrete missing flow or recovery defect |

For every accepted idea, cite exact upstream source and exact PandaPay anchor. Do not port broad frameworks, a new model, or new tables solely because an upstream project has them.

## Phase 3 — baseline and decision gate

Create synthetic, privacy-safe fixtures for each confirmed failure and hard negatives. Include card repayment versus spend, refunds versus income, self-transfer versus merchant payment, failed/reminder versus posted payment, two legitimate equal purchases, duplicate SMS plus statement, renamed merchants, and offline correction replay. Reuse existing tests and evaluator where possible.

Measure baseline precision/recall for relevant classifications, false-positive rate, missed financial events, merchant match quality, aggregate rupee differences across Activity/Insights/budgets, and processing time for affected paths. Report sample counts and limitations. A candidate proceeds only when it improves its target cases, does not regress critical negatives or card/reward totals, and has a reversible rollout path.

## Phase 4 — implementation order

1. **Canonical transaction semantics:** finish only the confirmed portions of `TRANSACTION_CLASSIFICATION_PLAN.md` needed to keep refunds, transfers, repayments, rewards, and uncertain events consistent across server, offline store, reports, and rewards. Use additive schema and preserve existing API contracts during migration.
2. **Personal correction reuse:** apply confirmed user corrections before generic rules in the local parser, with versioning and explicit precedence. Keep user overrides authoritative after sync.
3. **Merchant identity:** add narrow, evidence-backed aliases and review ambiguous shared processors. Keep merchant identity separate from spend category and payment processor.
4. **Product insights:** add price-change or duplicate-service review only after reliable occurrence matching exists. Label expected dates and costs as estimates when evidence is incomplete.
5. **Recovery:** close specific offline save/restart/sync/restore defects found in Phase 1; avoid a new backup system if portable backup already handles the need.

Each slice must include the smallest production change, focused regression fixtures, migration/rollback notes if data changes, and a before/after comparison. Release slices independently; do not combine unverified changes into one rollout.

## Phase 5 — verification and rollout

- Run targeted existing tests and the shared fixtures for touched paths. Check server and device results against the same expected economic event and exact paise totals.
- Verify replay/idempotency, user correction precedence, cross-source duplicate handling, offline restart/sync, and card cap/reward reconciliation where affected.
- For riskier classification changes, first run a read-only shadow comparison on existing data. Review count and rupee impact by class without silently rewriting old records. Use staged enablement and retain a rollback switch for new read projections/rules.
- Coordinator reviews agent diffs, resolves overlap, and reports measured baseline and post-change results, remaining failures, and ideas deferred for lack of evidence.

## Completion criteria

A change is complete when its original failure is reproduced and resolved, hard negatives remain correct, affected totals agree across surfaces, user edits survive replay, and the new behavior is explained in user terms. If a candidate cannot meet these gates, document the finding and leave PandaPay's current behavior in place.
