# Payments due session failure investigation

## Update sign-in incident, 2026-10-18

The phone logged `session refresh rejected; sign-in is required` at 12:27:29
from the previous app process. Android recorded the replacement APK installation
at 12:27:35, with the original first-install date retained. Installation used
`adb install -r`; it did not uninstall or clear app data. The server rejection
preceded the update. Its exact upstream cause is still unconfirmed.

The follow-up fix addresses two demonstrated failure paths without bypassing
authentication or changing UI:

* Refresh successor creation and parent revocation now share a PostgreSQL
  transaction and lock the parent row. A failed insert cannot consume the
  only usable credential; concurrent callers recheck the locked state.
* The device saves a UUID request identity in secure storage before refreshing.
  After a lost response or process interruption, the same credential and
  identity recover the same active successor rather than rotate again.
  The successor ID is derived with a server-secret HMAC. Its JWT can be
  reconstructed from existing DB fields (explicit expiry, no issued-at claim),
  and must match the stored hash. No plaintext token is added to the server DB,
  and no schema migration is required.
* Recovery requires the exact request identity and a matching, unexpired,
  non-idle, non-revoked successor for the same user/device. An unrelated reuse
  still triggers existing device revocation. Explicit logout also disables
  recovery. Older clients remain supported but cannot recover lost responses.
* A completed refresh cannot overwrite an explicit logout or a newer login.

Both server and client must be deployed for lost-response recovery. Already
cleared credentials cannot be reconstructed by this update; the affected phone
needs one fresh sign-in. This change does not claim that all future auth policy
rejections, expiry or deliberate revocation can be avoided.

Validation: server tests cover committed-response recovery, an overlapping
caller, insert rollback, unrelated reuse, logout, legacy clients and request
validation. Client regressions cover durable retry identity across restart,
credential replacement and an explicit logout during an in-flight refresh.
Server unit tests use a transactional database double, not a live PostgreSQL
instance; deployment health and device install are checked separately.

The follow-up implementation now provides centralized local entities, durable
SMS intake and local parsing. See [Local-first financial data](local-first-data.md)
for the current behavior and verification; the snapshot-loader findings below
describe the original incident investigation.

## Evidence and cause

The screenshot's exact message is produced by
`AuthenticationUnavailableException`. In Payments due, the path is
`paymentsDueProvider` -> `loadTransactionsWithOfflineCache` -> an API auth
failure with no usable fallback. The shared HTTP client already retries a
401 after a coordinated token refresh. A remaining rejection reaches this
loader; the message alone does not prove that the refresh endpoint failed.

Two confirmed client defects made this failure unnecessarily page-fatal:

* The loader treated a successfully synced empty transaction list as missing
  data after an auth failure. A card with a known due date and no logged spend
  could therefore disappear behind an error screen.
* Filtered reads did not normally reuse transaction rows saved by Spending
  and Insights. Visiting a secondary screen for the first time could fail even
  though relevant rows existed in another account-scoped snapshot.

The shared loader now accepts empty snapshots and enables report-snapshot
reuse by default, applying the requesting screen's filters to recovered rows.
No snapshot still produces an unavailable state; failed requests never write
fabricated empty data into the cache. Cached rows are last-known observations,
and report snapshots can cover only part of the requested period.

## Application audit

| Path | Finding / treatment |
| --- | --- |
| Payments due | Both shared-loader defects apply; regression covers saved due dates plus empty synced history and a rejected API read. |
| Activity / canonical transactions | Empty snapshot defect applies; preserve synced empty lists and retain existing merged-history recovery. |
| Credit utilization / card spend summaries | Filtered transaction loader now reuses report snapshots. |
| Insights overview / spending detail | Same loader; report rows available across cache keys. |
| Monthly savings / missed opportunities / portfolio audit | Same loader; filtered fallback now enabled by default. |
| Wallet | Shared card loader rejected auth fallback despite a cached snapshot; now uses the read-cache policy. Normal cache-first wallet reads already worked. |
| Manual overrides / recommendation inputs | Auth failures previously returned an empty list before consulting the saved overrides; now preserve the scoped snapshot. |
| Spend reports / monthly reports / recurring reports | Existing aggregate cache and local transaction fallback inspected; no change in this patch. |
| Budgets / notifications / profile / contribution stats | Existing read-cache paths inspected; no claim that every endpoint can work without a first successful sync. |
| HTTP/session | Live-token header replacement, concurrent refresh sharing, startup restore, keep-alive and rotated-token persistence already exist. Targeted regressions exercised. |

## Unresolved server diagnosis

The screenshot does not identify the API/auth deployment, response status,
refresh response, or device logs. Determining the incident's upstream trigger
requires redacted API and auth logs from the affected time, correlated by
request/device identifier. Do not log token values.

Inspect whether refresh failed because of transport, refresh expiry, revocation,
reuse detection, or policy rejection; if refresh succeeded but the retried API
call still returned 401, compare issuer/audience/signing-key configuration in
the two running services. See `offline-first-display-and-auth.md`.

The auth service rotates single-use refresh credentials. A lost refresh
response can leave the device with the consumed credential. The client used to
retry transient refresh errors immediately with that same credential; that
immediate replay was removed on 2026-10-18. The server's revoke-then-issue
rotation and a later retry after an ambiguous response still need a designed
server-side idempotency/rotation transaction with replay-protection tests.
This risk has not been established as the cause of the device's original 401.

The later global banner had a separate confirmed cause: a single rejected
background read persisted `authentication_required` in the financial store,
then every screen treated that as a sign-in instruction despite a locally
restored account. A startup inbox scan also saved 1,177 historical candidate
transactions before upload, and the global banner presented those ordinary
pending SMS items as an alarming failure count. Version 20050 keeps these
routine background states out of the global banner, while preserving their
records for Sync & backup. It records only a coarse refresh status/error type
for future device diagnostics; no token or response body is logged.

Version 20050 was installed over 20049 on the Motorola edge 50 fusion without
clearing data. Home and Payments due both rendered saved content without the
session or pending-count banner. The exact upstream cause of the older refresh
rejection still needs redacted auth/API telemetry; a screenshot alone cannot
distinguish expired/revoked refresh credentials, lost responses and an API
verification mismatch. Background SMS reconciliation remains to be checked
with an active server session. This is a device-test build, not a release.

## Validation

* 85 Insights and owned-card provider tests passed.
* 8 cache regressions passed, including Payments due with a previously synced
  empty history, filtered report fallback, and missing-snapshot errors.
* The initial 32-test targeted run covering auth HTTP retries, session
  keep-alive, cache recovery, and due-date arithmetic passed.
* `git diff --check` passed.
