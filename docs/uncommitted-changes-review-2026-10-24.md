# Uncommitted changes review — 24 October 2026

## Scope

Reviewed the uncommitted application, API, tests, and planning documents present
in this checkout, including additional edits that appeared during the review.
Parallel implementation reviews covered API ingestion/AI, local SMS parsing and
storage, bills/review reconciliation, and UI/reporting/geofence behavior. Two
independent final reviews checked financial correctness and commit contents.

## Confirmed defects corrected

| Area | Correction |
| --- | --- |
| AI results | Removed a result-route undefined-variable failure and prevented unconfirmed AI suggestions from invoking specialists or materializing projections through replay/backfill. |
| Gemini worker | Distinguished provider HTTP 422 from terminal API validation; removed conflicting standalone-envelope instructions from batch prompts. |
| Card identity | A suffix alone no longer implies a credit card. Unique active saved-card evidence may resolve type; ambiguous matches and conflicting caller selections remain conservative. |
| SMS parsing | Preserved debit refunds and explicit credit-card withdrawals; rejected invalid suffix captures and security-code messages; retained receipt classification ahead of downloaded transaction rules. |
| Insurance | Preserved month-only premium dates without inventing a day, retained actionable expiry notices through triage, and avoided fabricated monthly renewal cadence. Unknown premiums remain unknown. |
| Card dates | Restricted learning to eligible bill evidence and unique active non-debit matches; preserved user-sourced dates and excluded AutoPay arrival timestamps as statement dates. |
| Bill settlement | Allocated payments chronologically, preserved statement/AutoPay metadata, rejected contradictory card identities and invalid payment dates, and removed percentage-based underpayment acceptance. |
| Review persistence | Kept queue items when reconciliation writes fail, respected local tombstones/edits, checked stale queued items after asynchronous reads, and notified financial consumers after persisted changes. |
| Bill history | Stored structured card/account identity for cycle deduplication, preserved original evidence, and treated unknown archive statuses as needing confirmation. |
| Duplicate repair | Bound timestamp precision to its actual accounting timestamp, locked repair rows, reserved historical matches one-to-one, and restored suppressed neighbors when overlapping candidate resolutions invalidate them. |
| Spending sources | Kept unrelated bank accounts and unlinked cards distinct even when their last four digits coincide; aligned source-filter preview and results. |
| Rewards display | Used card/category identity for actual spend, computed catch-all category totals, and handled Fuel before category metadata becomes available. |
| Imports/editing | Recognized explicit Axio card repayments despite conflicting expense flags; preserved unknown payment methods and rejected non-finite edited amounts. |
| Geofence | Scoped persisted visits to the account, serialized processing, and canceled stale queued/in-flight notification work after monitoring stops. |
| UI | Added stable review keys, selected filter semantics, mounted checks, scrollable bill sheets, guarded saves, and monetary validation. |

## Verification

- API: `npm test` — **853 passed, 0 failed, 2 skipped**. The skipped tests require
  a configured integration database. Package syntax checks passed.
- App: `flutter test --no-pub --concurrency=1 --reporter=compact` — **1,666 passed**.
  Subsequent removal of unsafe last-four source merging passed all **49** tests
  in spending selection, spend trends, and both card-detail suites.
- App: `dart analyze` — **no errors or warnings**, 73 informational findings.
- Scoped diff whitespace checks passed during review; staged checks are repeated
  before commits.
- Financial regressions include cross-cycle allocation, ambiguous identity,
  underpayment boundaries, failed writes, reactive providers, duplicate-neighbor
  restoration, replay precision, and account/database isolation.

## Verification boundaries and retained local files

These are local unit/widget/contract checks, not production rollout or real-device
acceptance. Live PostgreSQL concurrency and the two skipped integration tests
remain unverified. Existing historical instrument classifications are not
automatically rewritten solely by the new parser policy. Bare `Premium Rs 2150`
without the supported amount-due wording remains an extraction gap; the value
stays unknown rather than being fabricated.

Local `scratch/` logs, inspection scripts, screenshots, XML, APKs, alternate Git
indexes, and temporary browser snapshots are excluded from commits. Existing
planning documents remain plans; their proposed features are not declared
implemented by this review.
