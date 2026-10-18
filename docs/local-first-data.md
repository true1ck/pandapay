# Local-first financial data

Transactions and saved cards now have an account-scoped local entity store in
the existing SQLite database. Activity, Payments due, utilization and the
transaction-based Insights screens query this store through the shared loader.
They no longer reconstruct competing histories from endpoint response blobs.

## Capture and reads

`SmsImportStore` is shared by foreground delivery, inbox imports and the Android
background isolate. It commits intake, supported parsed observations and
provisional transactions locally before upload. Large scans capture in batches
of 100 and yield to the event loop between batches. SQLite WAL and a busy timeout
support the background connection; append/ack intake avoids replacing a queue
while new messages arrive. Pending intake has no drop-oldest limit.

`LocalSmsParser` version 1 handles conservative built-in card/account alerts,
income, transfers, explicit balances and due-date observations. OTP/security
messages are excluded. Unsupported formats remain in intake for the existing
server parser or local review. This does not claim parity with every dynamic
admin-configured server pattern. Shared fixtures verify the supported subset.
Raw intake is removed only after confirmed reconciliation or transfer to review.

Provisional entries have no confirmed rewards and are read-only until synced.
The app labels pending/partial data separately from authentication and network
status. A missing snapshot remains different from a successfully synced empty
history. Existing response snapshots migrate once, retaining their original
timestamps; report fragments do not establish complete-history coverage.

Successful transaction queries reconcile only their covered scope, including
valid empty results. Pending device records and queued corrections are retained.
Incoming server records replace provisional records by stable source identity.
Search includes both merchant and note, and inclusive end dates match the API.

Saved aggregate reports and budgets render before background HTTP refresh.
Transaction-derived report fallbacks read the central store. Server-derived
reward/cap calculations remain authoritative; this change does not manufacture
issuer balances or offline reward confirmations. Successful mutations mark
snapshots for refresh without changing their actual last-sync timestamps.

## Sync and ownership

All new SMS intake, review items, outbox entries, edits and cursors are scoped
to an account. Requests from a repository belonging to a different JWT subject
are rejected before they can use the new account's token. Old queues without
ownership are retained as `legacy`; Sync & backup offers explicit account
confirmation before moving them to the signed-in account. Guest-captured SMS
are not automatically assigned to an unrelated signed-in account.

Rejected edits remain saved and become blocked after the retry threshold,
rather than being deleted. Sync & backup can retry them. Edits made during an
upload get a new client sequence so acknowledgment of an older edit cannot
erase the newer one. On restart, interrupted claims become retryable again.

Both successful pushes and incoming change batches materialize authoritative
entity records locally before removing pending overlays or advancing the pull
cursor. Failed materialization leaves the operation/cursor retryable. Explicit
sign-out clears that account's display snapshots, while account-bound pending
work remains isolated for the same account; its cursor is reset for bootstrap.

The existing change feed does not establish complete coverage of every REST
producer. Resume/reconnect snapshot refresh remains necessary. The API's
transaction-list response now includes `source_key`; deploy that compatible API
change with the mobile release for deterministic SMS reconciliation. A server
that omits identity can require an additional retry and retained intake.

## Verification

Implemented checks:

* 212 affected Flutter regressions passed across storage, SMS, Activity,
  Payments due, Insights, card edits, quick-add and sync/backup.
* 88 API/parser/source-identity checks passed.
* A subsequent 18-test guard/store run passed, including accepted writes whose
  refresh-metadata observer fails; these overlap the broader regression suite.
* Five final integration/restart checks passed, including unsupported SMS
  review isolation, offline capture, retry reconciliation and separate SQLite
  connections surviving restart.
* Targeted analysis of the 17 changed components/tests reports no issues.
  Whole-app analysis also ran; unrelated existing/concurrent lint findings
  remain outside this change.
* `git diff --check` passed.

Regression coverage includes cold offline due-date reads, capture before failed
upload, successful reconciliation without double counting, scope-aware empty
responses, legacy migration, account isolation, retained rejected edits,
concurrent edits during upload and commit-before-acknowledgment behavior.

Physical Android validation remains a release step: receiving SMS while killed,
background/resume after token expiry, force-stop during sync, account switching,
large inbox import and upgrade with pending work. Authentication service
rotation/replay behavior remains a separate server concern; local availability
does not repair an invalid cloud credential.

On 2026-10-18 a production-flavor, debug-signed device-test APK was installed
over version 20047 on the connected Motorola edge 50 fusion. Version 20048
launched with saved wallet data and Payments due rendered a saved card and due
date while the session needed sign-in. Force-stop and relaunch also succeeded.
The build hash and signature check are recorded in the Android release runbook.
Background SMS delivery and cloud reconciliation still need a session-enabled
device test, and the compatible API change still needs deployment before a
distributable mobile release.
