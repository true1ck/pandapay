# Shared expenses v1: foundation interfaces

Baseline `sms-v2/integration` at `bf6bec9b`, 4 November 2026. Owner: root integrator. These contracts replace the old stashed draft assumptions; the stash remains preserved. Current code increment: pure exact allocation/projection/cost and typed source references only. No route, DB mutation, accepted journal, UI or source cutover is enabled by these helpers.

## Implemented interface scope

- Node module `api/src/shared_expenses/domain.js`: `allocateExpense`, `projectExpense`, `personalCost`, `sourceIntToSharedMinor` and `SharedExpenseError`.
- Dart public `package:pandapay_domain/shared_expenses.dart`: `allocateSharedExpense`, `projectSharedExpense`, `sharedPersonalCost`, `sourceIntToSharedMinor`, `SharedExpenseSourceReference`, `SharedExpenseException` and checked `sharedMoneyFromMinor` adapter.
- Node source module `api/src/shared_expenses/source_reference.js`: closed source-reference parser and canonical legacy-route target resolver. It validates shape, **not ownership, funding eligibility or current server state**.
- Shared executable vectors: `contracts/shared_expenses/v1/domain_vectors.json`; source-reference vectors beside it. Fixtures use synthetic stable aliases for pure allocation and synthetic UUID/hash IDs for source references. Node and Dart consume the same vectors.

## Exact arithmetic contract

INR only. Monetary inputs are canonical ASCII unsigned integer decimal **strings**, `0` or nonzero leading digit followed by digits; no whitespace, signs, leading zeros, fractions, exponent, booleans or numeric coercion. Positive expense total ≤`1000000000` paise (₹1 crore). Source/share rows ≤same cap. Aggregate cost ≤`9007199254740991` paise. Derived balances serialize signed canonical strings without `-0`. Limit string length before parsing.

Compute with BigInt; convert to existing Money only after exact bounds checking. Do not change existing Money/SMS/FX schemas or roundtrip via rupee doubles. No new currency registry.

`sourceIntToSharedMinor` accepts an already interpreted nonnegative source integer, applies the single-expense cap and returns its exact decimal string. Node additionally requires a safe integer; Dart requires the `int` runtime type. Neither coerces strings, booleans or fractions, nor authorizes a source. JavaScript has one numeric type, so integer-valued JSON numbers are validated numerically; Dart source contracts already provide typed integers. `sharedMoneyFromMinor` converts canonical unsigned wire strings within the aggregate cap using `Money.fromPaise`, never rupee doubles.

Allocation input: `{currency,totalMinor,mode,participants,tieOrder}`. Modes equal (memberId only), exact (memberId/amountMinor), percentage or shares (memberId/weight). Closed object/row shapes; 1..50 unique opaque ASCII member IDs (`[A-Za-z0-9][A-Za-z0-9_-]{0,63}`). `tieOrder` is the exact unique participant-ID permutation, persisted per revision, independent of display names/order. Percentage weights are canonical integer strings 0..10000 with sum10000; shares weights 0..1000000 and positive sum. Exact amounts sum exactly to total. Weighted/equal allocations use floor plus largest fractional remainders; ties by tieOrder. Output `{currency,totalMinor,allocations:[{memberId,amountMinor}]}` sorted by memberId. No per-paisa loops; bounded O(n log n).

Projection input: `{currency,totalMinor,contributions,shares,memberOrder}` with 1..8 unique payer rows and 1..50 unique share rows, each `{memberId,amountMinor}`. Contribution and share sums both equal total; memberOrder is the exact union permutation (≤58), allowing payer-only members. Output `{currency,totalMinor,positions:[{memberId,paidMinor,shareMinor,balanceMinor}],obligations:[{debtorId,creditorId,amountMinor}]}`. Positions sort by memberId, `balance=paid-share`; deterministic two-pointer matching follows persisted memberOrder. It previews a complete snapshot, not acceptance or inter-expense/cross-context netting.

Personal cost input `{sourceAmountMinor,linkedAmountMinor,shareMinor}`: source/link ≤single cap, recognized share total ≤aggregate cap; linked≤source; output `{residualMinor,costMinor}`. Residual=source−linked; cost=residual+share checked against aggregate cap. Caller owns recognition/source scope and preaggregation; the function cannot validate bank ownership.

Stable errors expose `code` and `field` only: INVALID_INPUT, UNSUPPORTED_CURRENCY, INVALID_MEMBER_ID, DUPLICATE_MEMBER, INVALID_AMOUNT, AMOUNT_LIMIT_EXCEEDED, INVALID_PARTICIPANT_COUNT, INVALID_PAYER_COUNT, INVALID_MODE, INVALID_WEIGHT, INVALID_TIE_ORDER, ALLOCATION_TOTAL_MISMATCH, CONTRIBUTION_TOTAL_MISMATCH, SOURCE_OVERALLOCATED, AGGREGATE_LIMIT_EXCEEDED, INVALID_SOURCE_REFERENCE. No input payload or private label in error messages. Inputs are not mutated.

## Source-reference contract

Closed object common fields: `kind`, `ownerAccountId` (UUID). Node wire helper and Dart parser preserve optional fields without synthesizing IDs. Source identity kinds:

- `legacy_transaction`: required `canonicalTransactionId` UUID, `sourceVersion` opaque version/fingerprint string; optional sourceKey.
- `sms_v2_event`: required 64-lowercase-hex eventId; optional matching `localProjectionId` exactly `v2:<eventId>`, sourceKey and canonicalTransactionId UUID/sourceVersion pair. The canonical pair must appear together; absent means source admission pending.
- `confirmed_foreign_payment`: required foreignPaymentId UUID, canonicalTransactionId UUID, sourceVersion. SourceKey optional. The word confirmed in the kind is not evidence of actual valuation; the future resolver must fetch and reauthorize current source truth.

UUID syntax accepts canonical lowercase standard 8-4-4-4-12 hex; no hash-to-UUID conversion. Opaque sourceVersion is 1..128 ASCII `[A-Za-z0-9][A-Za-z0-9:._-]*`. SourceKey is 1..128 restricted opaque ASCII `[A-Za-z0-9][A-Za-z0-9:._-]*`; raw SMS/contact/VPA is not a source reference. Caller must supply authenticated ownership; parsers cannot confer permission. Canonical legacy target resolver returns the exact UUID if available, otherwise null. It never sends a request or authorizes a split.

## Consent and feature gates

Initial posting is `explicit_review`. Keep private author-recorded/provisional projection separate; previously accepted balanced revision remains until all required financially affected participants review the entire new revision. No one-sided accepted receivable/payable. Source event complete/user_confirmed, OTP, OCR and UPI callback prove neither shared debt consent nor confirmed settlement.

The source resolver must later check active canonical identity, ownership, type/legs/currency/amount/instrument, current version, reservations and correction/replay/foreign valuation. Any missing/changed/ambiguous state blocks accepted source funding while retaining a draft. New API schemas/migrations/source adapters/outbox/recovery need P01/P03/P05 review. Gifts, estimated FX, automatic cross-group offset, provider verification and generic write-off remain unsupported.

P00 **foundation interface subset** may be consumed by P02 after fixtures pass; independent review, full P00 command/ACL/source-version/recognition persistence and real DB gates remain open. Do not mark all P00/P02 complete from these pure functions. The [implementation register](../../implementation/shared-expenses/README.md) records the exact boundary and next writer.
