# Physical database connection budgets — 25 October 2026

The next LP03/G05/G06 slice is implemented in the offline release tooling. It calculates connections per **physical PostgreSQL cluster**, including replica ceilings, temporary rollout replicas, dedicated service pools and reserved headroom. A manually entered total alone no longer satisfies the strict release check. No application runtime, schema, data, credentials, provider subscription, live setting or feature default changes in this batch.

This is a planning/release safeguard, not a capacity benchmark or deployment approval. LP03 remains unaccepted: actual provider limits, running topology, CPU/RAM/storage, performance and cost still require evidence. The previous live observation of 60 connections is historical input to review, not a freshly verified operating allowance. Canonical counts remain 76 findings, 50 unfinished, 14 packages and six gates; no finding is closed by this slice.

## What the calculator includes

| Process kind | Connections per process at its configured ceiling |
| --- | --- |
| `api` | Main `DB_POOL_MAX` plus webhook 2, IMAP 2 and product lifecycle 1 when their pools are configured. |
| `auth` | Main `DB_POOL_MAX` plus console session 3 and auth lifecycle 2 when configured. |
| `rewards-worker` | Main `DB_POOL_MAX`; it imports the API database module, so count any optional service pools present in that worker's environment too. The supplied production Compose does not pass those optional URLs to this worker. |
| `sms-learning-worker` | Two database clients. |
| `gemini-worker` | No direct database clients. Its HTTP/provider fan-out still requires separate load/admission testing. |
| `product-maintenance` | One dedicated database client per concurrent invocation. |
| `auth-retention-maintenance` | One product-ledger and one auth-retention client; both can coexist. |
| `backup-status-publisher`, `maintenance-alert-delivery` | One database client per concurrent invocation each. |

Each kind must be explicitly inventoried, including disabled kinds with zero replicas. Multiple entries of a kind allow old/new configurations to be counted separately. Pool aliases map to physical clusters, never connection URLs. Two logical databases on the same Supabase project use the same alias; use distinct aliases only after verifying distinct physical connection budgets. `replicas` means the maximum simultaneous steady-state processes, including autoscaling ceilings and concurrent scheduled invocations, rather than an instantaneous observation. `overlapReplicas` is additional concurrent processes during rollout/restart. A fenced deployment may record zero overlap after verifying all old writers are stopped.

For each cluster, required slots are:

`sum(pool maximum × (replicas + overlapReplicas)) + server-reserved + provider/other-service + operational + safety connections`

Provider/other-service allowance covers persistent consumers outside this fixed source model, including Supabase services, other applications and backend pooler allocations not already counted. Operational allowance must cover the actual overlapping backup/dump, migration, restore/drill, monitoring and operator sessions, including utility processes not modeled individually. Operational and safety allowances must each be at least one; that minimum is **not** a sizing recommendation. Classify connection usage once to avoid counting an observed application session again as a provider reserve. Physical/billable disk, WAL, memory, queueing, pool wait, throughput, provider quotas and load acceptance remain separate checks.

The model conservatively counts every configured client slot as one backend slot, even with transaction pooling. It applies no assumed multiplexing discount, and never substitutes a provider's pooler-client allowance for PostgreSQL's backend limit. A future topology that requires shared pooler-level accounting needs a reviewed extension and measured saturation/isolation tests; do not lower input limits to manufacture a pass. [Supabase pooling and limits](https://supabase.com/docs/guides/database/connecting-to-postgres/pooling-and-limits), [node-postgres pool configuration](https://node-postgres.com/apis/pool).

## Operator flow

1. Generate the credential-free template with `node db/scripts/connection_budget.js --template`. Store the result in a protected local JSON file. It initially fails because limits/review are unknown; its default replicas/pool sizes are examples, not approved production values.
2. Inventory the exact proposed and currently running service environments without putting credentials in the JSON. Review every pool constructor against this candidate; include all regions/process managers, maximum replicas, optional URLs, concurrent jobs, rollout overlap and external clients. Keep a private evidence record of the review. Do not pipe resolved Compose environments into an artifact: they can contain secrets.
3. Verify provider/server limits and reserved slots per physical cluster. Explicitly record the provider/other-service, operational and safety allocations. Set `limitsVerified`, `verifiedAt`, `inventoryReviewed` and `reviewedAt` only after the checks; review and limits expire after 48 hours. Unknown values remain `null` and block approval. Use UTC timestamps ending in `Z`.
4. Run `node db/scripts/connection_budget.js --inputs /protected/connection-budget.json --strict`. Exit 0 means this **connection budget** fits; exit 2 means a missing/overcommitted budget, and exit 1 means invalid input. No database or network connection is made. The CLI reads neither `.env` nor saved credentials, exports only bounded aliases/counts and uses generic errors for invalid input.
5. Copy the reviewed manifest into `connectionBudget` in the release-input JSON. `quotas.maxConnections` must equal the primary cluster's backend limit and `quotas.configuredConnectionBudget` must equal that cluster's computed application slots **including rollout overlap, excluding reserves**. Every additional cluster is checked independently. Existing manifests without `connectionBudget` remain readable but cannot pass the new aggregate gate.
6. Obtain fresh exact-candidate `connection_budget_acceptance` evidence through the existing private proof-file flow. The check must have `status: passed`, `failed: 0`, the exact `candidate_sha256`, hash-checked `proof_file`/`proof_sha256`, and `budget_sha256 = SHA-256(stableJson(connectionBudget))`. The full evidence also binds `configuration_sha256`; changes to pools, aliases, replicas, reserves or features invalidate it. Record actual deployment inventory/constructor review in the private proof. This is operator-supplied evidence, not independently discovered topology. All previous actual-data/provider/device/custody gates remain required.
7. Run `node db/scripts/release_security_check.js --inputs /protected/release-inputs.json --strict`. Enabled console, lifecycle or IMAP features cannot omit their required dedicated pools. Follow the existing fenced deployment procedure only after **all** release checks and the separate rollout approval pass. This tool performs no deployment and does not automatically install an enforcement hook in a provider dashboard.

The local checker does not reduce pool settings or change the application. Rehosting remains PostgreSQL-to-PostgreSQL; remap cluster aliases and reverify limits/evidence on the new provider while preserving IDs, data and original keys. No extra end-user password is introduced.

## Verification and next work

Local Node 24.15.0 verification: **209 database-tool tests passed**, including 42 focused calculator/release tests (overlapping scopes). Tests cover same-cluster aggregation, separate clusters, optional pools, steady/rollout pressure, maintenance concurrency, stale/missing limits, incomplete inventories, invalid/credential-bearing inputs, bounded regular files, safe CLI errors and exact-candidate/configuration evidence. No API/auth/Flutter runtime test, real database benchmark or provider delivery test was needed or run for this offline-tool-only batch. CI retains Node 22 coverage; this batch's local suite ran on the installed Node 24.

The checked-in synthetic case uses two API replicas, two auth replicas and one reward worker at ten main slots each: 50 application slots plus 13 **assumed** reserves = 63, exceeding a 60-slot test cluster. This demonstrates rejection, not current deployment configuration. [Inputs and output](../artifacts/security-connection-budget-2026-10-25/synthetic-overcommit.json). Unknown default inputs also remain blocked. [Verification](../artifacts/security-connection-budget-2026-10-25/verification.json).

Next: complete LP01 actual-role/isolation acceptance and LP02 independent recovery, populate the LP03 inventory from the intended hosts/provider, then run the approved isolated workload/failure tests. This batch does not delete the nine retained drill databases, purchase hosting, raise recovery quotas or establish that 100,000 signups/day can be admitted.
