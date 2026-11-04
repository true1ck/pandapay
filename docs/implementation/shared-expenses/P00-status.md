# P00 handoff: foundation subset and remaining contracts

Updated 4 November 2026. Owner: root integrator. Packet status: **implementing**. Foundation subset: **delivered and tested; independent review pending**. Current contract version `1.0.0-foundation` is an internal helper boundary, not a frozen HTTP command/event schema.

Local code save points: `2d6163e1` (Node/contracts/fixtures) and `40d5cd5b` (Dart + JavaScript-target verification), on top of test portability prerequisite `9e23201d`. No push/deployment; the original inspection baseline remains `bf6bec9b`.

## Delivered

- [Foundation interfaces](../../contracts/shared-expenses-v1/README.md): integer-string money, caps, basis-point percentages, weighted/equal largest remainders, persisted tie order, multiple payers, one-expense obligations and residual/personal cost.
- Closed legacy/v2/foreign source-reference shapes. Pending v2 sources preserve hash/local identity and return no legacy API target until a real canonical UUID/version pair exists. Parsing provides no authorization or valuation proof.
- Exact typed source-integer to shared-wire adapter and checked Dart Money adapter without changing existing Money, SMS or FX schemas.
- Shared executable fixtures consumed by both Node and Dart; [P02 test evidence](P02-status.md).
- [Implementation register](README.md) and packet status vocabulary for multi-agent handoffs.

## Open before financial persistence/integration

1. Authenticated source resolver: active canonical owner/source/instrument/legs/type/currency/version, confirmed foreign valuation, source reservation, correction/retraction and replay remap under concurrency.
2. Full command/event JSON schemas, durable idempotency identity/lifetime, revision preconditions, error DTOs, bounded queries and monotone committed change-feed contract.
3. Group/direct/shadow identity permissions, financial visibility and historical access; claim/OTP is identity evidence, not debt consent. Resolve whole-revision review requirements with explicit posting policy.
4. Accepted/provisional/disputed/rejected/reversed journal states; exact correction/refund/partial-payment allocations and report-period recognition. Previously accepted balanced revisions stay until required review completes.
5. Recovery/schema compatibility/capability gates and contract-level race/fault fixtures. Do not reuse the coalescing SMS v2 outbox for financial commands.
6. Independent review and real populated PostgreSQL/RLS/role-setup/migration/restore checks, including coverage inventory. Source pipeline cutover remains separately gated.

No migrations, API routes, source reporting flags, existing transaction/split data or app navigation changed in this sub-increment. Do not start multiple writers against shared source/router/schema files until a path lease is recorded.
